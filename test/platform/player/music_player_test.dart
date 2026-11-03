/// 音乐播放控制器单测（批次 G · G-01 首段）。
///
/// 对齐基准（唯一真相源）：iOS `AudioPlayerManager`
/// （`vbox/Services/AudioPlayerManager.swift`）的队列 / 播放控制 / 持久化语义。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/music_queue_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/music/music.dart';
import 'package:vbox/platform/player/media_session.dart';
import 'package:vbox/platform/player/music_player.dart';

MusicQueueItem _item(String id, {String? url, int? duration}) {
  return MusicQueueItem(
    id: id,
    name: '歌$id',
    artist: '来源',
    coverURL: 'https://c/$id.jpg',
    playURL: url ?? 'https://p/$id.mp3',
    sourceName: '测试源',
    engineKey: 'lx_test',
    duration: duration,
  );
}

/// 记录调用的假引擎。
class _FakeEngine implements MusicAudioEngine {
  final List<String> calls = <String>[];
  bool throwOnLoad = false;

  @override
  Future<void> load(String url) async {
    calls.add('load:$url');
    if (throwOnLoad) throw StateError('boom');
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek:${position.inMilliseconds}');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> dispose() async => calls.add('dispose');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late _FakeEngine engine;
  late MusicQueueStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    engine = _FakeEngine();
    store = MusicQueueStore(pm);
  });

  MusicPlayerController build([MusicMediaSession? mediaSession]) =>
      MusicPlayerController(store: store, engine: engine, mediaSession: mediaSession);

  /// 等待 unawaited 的媒体会话同步落定。
  Future<void> flushMediaSync() => Future<void>.delayed(Duration.zero);

  test('setQueue 起播并落盘', () async {
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1'), _item('2')]);

    expect(c.hasQueue, isTrue);
    expect(c.currentSong?.id, '1');
    expect(c.isPlaying, isTrue);
    expect(engine.calls, containsAllInOrder(<String>['load:https://p/1.mp3', 'play']));
    expect(await store.hasRestorable(), isTrue);
  });

  test('playItem：不存在则追加并定位，已存在则定位', () async {
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1')]);
    await c.playItem(_item('2'));
    expect(c.queue.length, 2);
    expect(c.currentSong?.id, '2');

    await c.playItem(_item('1'));
    expect(c.queue.length, 2);
    expect(c.currentSong?.id, '1');
  });

  test('addToQueue 不改当前下标', () async {
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1')]);
    await c.addToQueue(_item('2'));
    expect(c.queue.length, 2);
    expect(c.currentIndex, 0);
  });

  test('togglePlayPause 暂停 / 继续', () async {
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1')]);

    await c.togglePlayPause();
    expect(c.isPlaying, isFalse);
    expect(engine.calls, contains('pause'));

    await c.togglePlayPause();
    expect(c.isPlaying, isTrue);
    expect(engine.calls.last, 'play');
  });

  test('playNext：顺序换下标；单曲循环重播；随机落在范围内', () async {
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1'), _item('2'), _item('3')]);

    await c.playNext();
    expect(c.currentSong?.id, '2');

    c.setRepeatMode(MusicRepeatMode.single);
    await c.playNext();
    expect(c.currentSong?.id, '2');
    expect(engine.calls, contains('seek:0'));

    c.setRepeatMode(MusicRepeatMode.shuffle);
    await c.playNext();
    expect(c.currentIndex, inInclusiveRange(0, 2));
  });

  test('playPrevious：进度 > 3s 回本曲开头；否则上一首', () async {
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1'), _item('2')], startIndex: 1);

    c.reportPosition(const Duration(seconds: 5));
    await c.playPrevious();
    expect(c.currentSong?.id, '2');
    expect(c.position, Duration.zero);

    await c.playPrevious();
    expect(c.currentSong?.id, '1');
  });

  test('removeFromQueue：移除当前项 → stop 语义清空', () async {
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1'), _item('2')], startIndex: 1);
    await c.removeFromQueue(1);

    expect(c.hasQueue, isFalse);
    expect(c.isPlaying, isFalse);
    expect(engine.calls, contains('stop'));
    expect(await store.hasRestorable(), isFalse);
  });

  test('removeFromQueue：移除非当前项，下标前移', () async {
    final MusicPlayerController c = build();
    await c.setQueue(
      <MusicQueueItem>[_item('1'), _item('2'), _item('3')],
      startIndex: 2,
    );
    await c.removeFromQueue(0);
    expect(c.currentSong?.id, '3');
    expect(c.currentIndex, 1);
  });

  test('stop 清空并移除落盘', () async {
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1')]);
    await c.stop();

    expect(c.hasQueue, isFalse);
    expect(c.isPlaying, isFalse);
    expect(c.notice, isNull);
    expect(await store.hasRestorable(), isFalse);
  });

  test('replaceCurrent 保留下标并回补进度（音质切换）', () async {
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1'), _item('2')]);
    c.reportPosition(const Duration(seconds: 42));

    await c.replaceCurrent(_item('1', url: 'https://p/1.flac'));
    expect(c.currentIndex, 0);
    expect(c.currentSong?.playURL, 'https://p/1.flac');
    expect(engine.calls.last, 'seek:42000');
  });

  test('restore 恢复存档；空存档不动', () async {
    await store.save(
      MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1'), _item('2')], startIndex: 1),
    );
    final MusicPlayerController c = build();
    await c.restore();
    expect(c.queue.length, 2);
    expect(c.currentSong?.id, '2');
    expect(c.isPlaying, isFalse);

    await store.clear();
    final MusicPlayerController c2 = build();
    await c2.restore();
    expect(c2.hasQueue, isFalse);
  });

  test('空播放地址 → 提示且不播', () async {
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1', url: '')]);
    expect(c.notice, '播放地址为空');
    expect(c.isPlaying, isFalse);
    expect(engine.calls, isNot(contains('play')));
  });

  test('引擎异常 → 提示并自动跳下一首（连续失败保护）', () async {
    engine.throwOnLoad = true;
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1'), _item('2')]);

    expect(c.notice, '播放失败，正在切换下一首');
    expect(c.isPlaying, isFalse);
    // 连续失败到达队列长度后停止，不无限递归。
    expect(engine.calls.where((String e) => e.startsWith('load:')).length, 2);
  });

  test('report / notice / 模式切换', () async {
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1', duration: 180)]);
    expect(c.duration, const Duration(seconds: 180));

    c.reportDuration(const Duration(seconds: 200));
    c.reportPosition(const Duration(seconds: 30));
    expect(c.duration, const Duration(seconds: 200));
    expect(c.position, const Duration(seconds: 30));

    c.cycleRepeatMode();
    expect(c.repeatMode, MusicRepeatMode.single);
    c.cycleRepeatMode();
    expect(c.repeatMode, MusicRepeatMode.shuffle);
    c.cycleRepeatMode();
    expect(c.repeatMode, MusicRepeatMode.sequential);

    // 空播放地址场景设置提示后清除
    await c.setQueue(<MusicQueueItem>[_item('2', url: '')]);
    expect(c.notice, isNotNull);
    c.clearNotice();
    expect(c.notice, isNull);
  });

  test('reportCompleted 触发下一首', () async {
    final MusicPlayerController c = build();
    await c.setQueue(<MusicQueueItem>[_item('1'), _item('2')]);
    await c.reportCompleted();
    expect(c.currentSong?.id, '2');
  });

  group('UI-F15 媒体会话（对齐 iOS AudioPlayerManager 媒体会话段）', () {
    late RecordingMusicMediaSession session;

    setUp(() {
      session = RecordingMusicMediaSession();
    });

    test('起播 → 锁屏信息一次写入（元数据 + 播放态）', () async {
      final MusicPlayerController c =
          build(session);
      await c.setQueue(<MusicQueueItem>[_item('1', duration: 180)]);
      await flushMediaSync();

      expect(session.updates, hasLength(1));
      final (MusicMediaMetadata meta, MusicMediaPlaybackState st) =
          session.updates.single;
      expect(meta.title, '歌1');
      expect(meta.artist, '来源');
      expect(meta.coverURL, 'https://c/1.jpg');
      expect(meta.duration, const Duration(seconds: 180));
      expect(st.playing, isTrue);
      expect(st.position, Duration.zero);
      expect(session.clearCount, 0);
    });

    test('暂停 / 恢复 / seek → 播放态随状态刷新', () async {
      final MusicPlayerController c = build(session);
      await c.setQueue(<MusicQueueItem>[_item('1')]);
      await flushMediaSync();

      await c.pause();
      await flushMediaSync();
      expect(session.updates.last.$2.playing, isFalse);

      await c.resume();
      await flushMediaSync();
      expect(session.updates.last.$2.playing, isTrue);

      c.reportPosition(const Duration(seconds: 42));
      await c.seek(const Duration(seconds: 42));
      await flushMediaSync();
      expect(session.updates.last.$2.position, const Duration(seconds: 42));
      expect(session.clearCount, 0);
    });

    test('stop / 移除末曲 → 清空锁屏信息（对齐 iOS nowPlayingInfo = nil）',
        () async {
      final MusicPlayerController c = build(session);
      await c.setQueue(<MusicQueueItem>[_item('1')]);
      await flushMediaSync();
      expect(session.updates, isNotEmpty);

      await c.stop();
      await flushMediaSync();
      expect(session.clearCount, 1);

      // 再走一遍「移除清空」分支。
      final MusicPlayerController c2 = build(session);
      await c2.setQueue(<MusicQueueItem>[_item('1')]);
      await flushMediaSync();
      await c2.removeFromQueue(0);
      await flushMediaSync();
      expect(session.clearCount, 2);
    });

    test('无当前曲目 → 不写锁屏（restore 空存档等场景）', () async {
      final MusicPlayerController c = build(session);
      await c.restore();
      await flushMediaSync();
      expect(session.updates, isEmpty);
      expect(session.clearCount, 0);
    });

    test('线控命令分派（对齐 iOS MPRemoteCommandCenter 六命令）', () async {
      final MusicPlayerController c = build(session);
      await c.setQueue(<MusicQueueItem>[_item('1'), _item('2')]);
      await flushMediaSync();

      final MusicMediaCommandHandler? dispatch = session.onCommand;
      expect(dispatch, isNotNull);

      dispatch!(MusicMediaCommand.pause);
      await flushMediaSync();
      expect(c.isPlaying, isFalse);

      dispatch(MusicMediaCommand.play);
      await flushMediaSync();
      expect(c.isPlaying, isTrue);

      dispatch(MusicMediaCommand.toggle);
      await flushMediaSync();
      expect(c.isPlaying, isFalse);

      dispatch(MusicMediaCommand.play);
      await flushMediaSync();
      expect(c.isPlaying, isTrue);

      dispatch(MusicMediaCommand.next);
      await flushMediaSync();
      expect(c.currentSong?.id, '2');

      // 上一曲（进度 < 3s → 切回上一首）。
      dispatch(MusicMediaCommand.previous);
      await flushMediaSync();
      expect(c.currentSong?.id, '1');

      dispatch(const MusicMediaSeekCommand(Duration(seconds: 7)));
      await flushMediaSync();
      expect(c.position, const Duration(seconds: 7));
    });

    test('缺省构造 → Noop 后端不抛', () async {
      final MusicPlayerController c = build();
      await c.setQueue(<MusicQueueItem>[_item('1')]);
      await c.stop();
      expect(c.hasQueue, isFalse);
    });
  });
}
