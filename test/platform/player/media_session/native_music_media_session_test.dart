/// 音乐媒体会话原生后端单测（批次 D · D3）。
///
/// 对齐基准：iOS `AudioPlayerManager.swift:517-583`
/// （`MPNowPlayingInfoCenter` 写入 + `MPRemoteCommandCenter` 六命令）。
/// 通道协议：MethodChannel `update` / `clear`；EventChannel 回派 `{command,...}`。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/media_session.dart';
import 'package:vbox/platform/player/media_session/native_music_media_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel method = MethodChannel('com.vbox.player/music_media');

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger().setMockMethodCallHandler(method, null));

  test('updateNowPlaying：透传全字段（title/artist/album/cover/duration/playing/position）', () async {
    Map<Object?, Object?>? payload;
    messenger().setMockMethodCallHandler(method, (MethodCall call) async {
      if (call.method == 'update') {
        payload = (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
      }
      return null;
    });

    final NativeMusicMediaSession session = NativeMusicMediaSession();
    await session.updateNowPlaying(
      const MusicMediaMetadata(
        title: '歌名',
        artist: '歌手',
        album: '专辑',
        coverURL: 'https://cdn/cover.jpg',
        duration: Duration(seconds: 200),
      ),
      const MusicMediaPlaybackState(
        playing: true,
        position: Duration(seconds: 31),
      ),
    );

    expect(payload?['title'], '歌名');
    expect(payload?['artist'], '歌手');
    expect(payload?['album'], '专辑');
    expect(payload?['coverURL'], 'https://cdn/cover.jpg');
    expect(payload?['durationMs'], 200000);
    expect(payload?['playing'], true);
    expect(payload?['positionMs'], 31000);
  });

  test('updateNowPlaying：可空字段（album/coverURL）缺省不下发', () async {
    Map<Object?, Object?>? payload;
    messenger().setMockMethodCallHandler(method, (MethodCall call) async {
      payload = (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
      return null;
    });

    await NativeMusicMediaSession().updateNowPlaying(
      const MusicMediaMetadata(title: 'T'),
      const MusicMediaPlaybackState(playing: false),
    );

    expect(payload?.containsKey('album'), isFalse);
    expect(payload?.containsKey('coverURL'), isFalse);
    expect(payload?['playing'], false);
  });

  test('updateNowPlaying / clear：原生 PlatformException 静默降级（不抛出）', () async {
    messenger().setMockMethodCallHandler(method, (MethodCall call) async {
      throw PlatformException(code: 'E_NATIVE', message: 'boom');
    });

    final NativeMusicMediaSession session = NativeMusicMediaSession();
    await expectLater(
      session.updateNowPlaying(
        const MusicMediaMetadata(title: 'T'),
        const MusicMediaPlaybackState(playing: true),
      ),
      completes,
    );
    await expectLater(session.clear(), completes);
  });

  test('clear：下发 clear 方法', () async {
    final List<String> methods = <String>[];
    messenger().setMockMethodCallHandler(method, (MethodCall call) async {
      methods.add(call.method);
      return null;
    });

    await NativeMusicMediaSession().clear();
    expect(methods, <String>['clear']);
  });

  test('onCommand：读回写入的处理器（测试环境不订阅事件流）', () {
    final NativeMusicMediaSession session = NativeMusicMediaSession();
    expect(session.onCommand, isNull);

    void handler(MusicMediaCommand command) {}
    session.onCommand = handler;
    expect(session.onCommand, same(handler));

    session.onCommand = null;
    expect(session.onCommand, isNull);
  });

  test('dispose：可重复调用（无订阅时安全）', () async {
    final NativeMusicMediaSession session = NativeMusicMediaSession();
    await expectLater(session.dispose(), completes);
    await expectLater(session.dispose(), completes);
  });

  test('未接线（MissingPluginException）静默降级', () async {
    // 未注册 mock handler → MethodChannel 抛 MissingPluginException。
    final NativeMusicMediaSession session = NativeMusicMediaSession();
    await expectLater(
      session.updateNowPlaying(
        const MusicMediaMetadata(title: 'T'),
        const MusicMediaPlaybackState(playing: true),
      ),
      completes,
    );
    await expectLater(session.clear(), completes);
  });
}
