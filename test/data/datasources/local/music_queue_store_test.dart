/// 音乐队列存储单测（批次 G · G-01 首段）。
///
/// 对齐基准（唯一真相源）：iOS `AudioPlayerManager` 的阶段四持久化
/// （`saveQueue` / `restoreQueue` / `hasRestorableQueue`）：
/// `music_queue_items`（string）+ `music_queue_index`（int）。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/music_queue_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/music/music.dart';

MusicQueueItem _item(String id, {String? url}) {
  return MusicQueueItem(
    id: id,
    name: '歌$id',
    artist: '来源',
    coverURL: 'https://c/$id.jpg',
    playURL: url ?? 'https://p/$id.mp3',
    sourceName: '测试源',
    engineKey: 'lx_test',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late MusicQueueStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = MusicQueueStore(pm);
  });

  test('空存储 load() = 空队列', () async {
    final MusicQueue q = await store.load();
    expect(q.isEmpty, isTrue);
    expect(q.currentIndex, -1);
  });

  test('save 后可跨实例读回（持久化 + 当前下标）', () async {
    final MusicQueue q = MusicQueue.empty
        .setQueue(<MusicQueueItem>[_item('1'), _item('2'), _item('3')], startIndex: 2);
    await store.save(q);

    final MusicQueue back = await MusicQueueStore(pm).load();
    expect(back.items, q.items);
    expect(back.currentIndex, 2);
    expect(back.current?.id, '3');
  });

  test('两键落 userdefaults（明文可见，键名与契约一致）', () async {
    final MusicQueue q = MusicQueue.empty
        .setQueue(<MusicQueueItem>[_item('1'), _item('2')], startIndex: 1);
    await store.save(q);

    final SharedPreferences raw = await SharedPreferences.getInstance();
    expect(raw.getInt(MusicQueueStore.indexKey), 1);
    expect(raw.getString(MusicQueueStore.itemsKey), isNotNull);
    expect(raw.getString(MusicQueueStore.itemsKey), contains('"id":"1"'));
  });

  test('空队列 save → 移除两键（对齐 iOS saveQueue 空队列分支）', () async {
    final MusicQueue q = MusicQueue.empty
        .setQueue(<MusicQueueItem>[_item('1')]);
    await store.save(q);
    expect(await store.hasRestorable(), isTrue);

    await store.save(MusicQueue.empty);
    final SharedPreferences raw = await SharedPreferences.getInstance();
    expect(raw.getInt(MusicQueueStore.indexKey), isNull);
    expect(raw.getString(MusicQueueStore.itemsKey), isNull);
    expect(await store.hasRestorable(), isFalse);
  });

  test('clear 移除两键', () async {
    await store.save(
      MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1')]),
    );
    await store.clear();
    expect(await store.load(), MusicQueue.empty);
  });

  test('下标越界时收敛（对齐 iOS restoreQueue 越界重置）', () async {
    await pm.set(
      MusicQueueStore.itemsKey,
      MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1'), _item('2')]).encodeItems(),
    );
    await pm.set(MusicQueueStore.indexKey, 9);

    final MusicQueue q = await store.load();
    expect(q.length, 2);
    expect(q.currentIndex, 1);
  });

  test('非法 JSON 容忍为空队列', () async {
    await pm.set(MusicQueueStore.itemsKey, 'not-json');
    expect(await store.load(), MusicQueue.empty);
    expect(await store.hasRestorable(), isFalse);
  });

  test('allKeys 覆盖 2 个契约键（去重、无遗漏）', () {
    expect(MusicQueueStore.allKeys.length, 2);
    expect(MusicQueueStore.allKeys.toSet().length, 2);
    expect(MusicQueueStore.allKeys, contains(MusicQueueStore.indexKey));
    expect(MusicQueueStore.allKeys, contains(MusicQueueStore.itemsKey));
  });
}
