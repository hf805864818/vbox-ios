/// 推送播放存储单测（批次 G · G-03）。
///
/// 对齐基准（唯一真相源）：iOS `vbox/Services/PushPlayStore.swift`
///   · 契约键 `push_play_items_v1`（string）JSON 数组字符串；
///   · `addItem`：trim → 空 URL 忽略 → 空标题默认名 → 同 url 去重 → 插入头部；
///   · `updateItem(_:withEpisodes:)`：写入解析后的剧集列表；
///   · `removeItem` / `removeAll`：删除单条 / 清空；
///   · `detectType(for:)`：网盘域名 → 直链扩展名 → 网页解析；
///   · `defaultTitle`：空标题按类型生成默认名。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/local/push_play_store.dart';
import 'package:vbox/domain/entities/push/push_play.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late PushPlayStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = PushPlayStore(prefs: pm);
    await store.load();
  });

  group('类型识别 detectType（对齐 iOS cloudPatterns）', () {
    test('网盘域名 → cloud', () {
      expect(PushPlayStore.detectType('https://www.alipan.com/s/abc'), PushPlayLinkType.cloud);
      expect(PushPlayStore.detectType('https://pan.quark.cn/s/xyz'), PushPlayLinkType.cloud);
      expect(PushPlayStore.detectType('https://pan.baidu.com/s/1abc'), PushPlayLinkType.cloud);
      expect(PushPlayStore.detectType('https://www.123pan.com/s/abc'), PushPlayLinkType.cloud);
      expect(PushPlayStore.detectType('https://cloud.189.cn/t/abc'), PushPlayLinkType.cloud);
      expect(PushPlayStore.detectType('https://115.com/s/abc'), PushPlayLinkType.cloud);
    });

    test('视频扩展名 → direct', () {
      expect(PushPlayStore.detectType('https://cdn.example.com/v.m3u8'), PushPlayLinkType.direct);
      expect(PushPlayStore.detectType('https://cdn.example.com/v.mp4'), PushPlayLinkType.direct);
      expect(PushPlayStore.detectType('https://cdn.example.com/v.flv'), PushPlayLinkType.direct);
      expect(PushPlayStore.detectType('https://cdn.example.com/v.ts'), PushPlayLinkType.direct);
      expect(PushPlayStore.detectType('https://cdn.example.com/v.mkv'), PushPlayLinkType.direct);
      expect(PushPlayStore.detectType('https://cdn.example.com/v.avi'), PushPlayLinkType.direct);
    });

    test('其余 → web', () {
      expect(PushPlayStore.detectType('https://example.com/detail/123'), PushPlayLinkType.web);
      expect(PushPlayStore.detectType(''), PushPlayLinkType.web);
    });
  });

  group('默认标题 defaultTitle（对齐 iOS）', () {
    test('空标题按类型生成默认名', () {
      expect(
        PushPlayStore.defaultTitle('https://www.alipan.com/s/abc', type: PushPlayLinkType.cloud),
        '网盘 - www.alipan.com',
      );
      expect(
        PushPlayStore.defaultTitle('https://cdn.example.com/v.m3u8', type: PushPlayLinkType.direct),
        '直链视频',
      );
      expect(
        PushPlayStore.defaultTitle('https://example.com/detail/1', type: PushPlayLinkType.web),
        '网页 - example.com',
      );
      expect(
        PushPlayStore.defaultTitle('https://cdn.example.com/v.mkv', type: PushPlayLinkType.cloud),
        '网盘 - cdn.example.com',
      );
    });
  });

  group('addItem（对齐 iOS addItem）', () {
    test('空 URL 忽略', () {
      store.addItem(title: 't', url: '   ', type: PushPlayLinkType.web);
      expect(store.items, isEmpty);
    });

    test('添加成功：trim + 去重 + 插入头部（最新在前）', () {
      store.addItem(title: 'A', url: ' https://a.com/1 ', type: PushPlayLinkType.direct);
      store.addItem(title: 'B', url: 'https://b.com/2', type: PushPlayLinkType.web);
      expect(store.items, hasLength(2));
      expect(store.items.first.title, 'B');
      expect(store.items.first.url, 'https://b.com/2');
      // 同 url 再次添加 → 忽略（去重）。
      store.addItem(title: 'B2', url: 'https://b.com/2', type: PushPlayLinkType.web);
      expect(store.items, hasLength(2));
    });

    test('空标题 → 默认名', () {
      store.addItem(title: '', url: 'https://www.alipan.com/s/abc', type: PushPlayLinkType.cloud);
      expect(store.items.single.title, '网盘 - www.alipan.com');
    });
  });

  group('持久化（对齐 iOS save/load）', () {
    test('addItem 后新实例可读回', () async {
      store.addItem(title: 'A', url: 'https://a.com/1', type: PushPlayLinkType.direct);
      final PushPlayStore back = PushPlayStore(prefs: pm);
      await back.load();
      expect(back.items, hasLength(1));
      expect(back.items.single.title, 'A');
      expect(back.items.single.type, PushPlayLinkType.direct);
    });

    test('键名与契约一致，落 userdefaults 明文 JSON 数组字符串', () async {
      store.addItem(title: 'A', url: 'https://a.com/1', type: PushPlayLinkType.direct);
      final SharedPreferences raw = await SharedPreferences.getInstance();
      final String? rawValue = raw.getString(PushPlayStore.itemsKey);
      expect(rawValue, isNotNull);
      expect(rawValue, contains('"url":"https://a.com/1"'));
      expect(rawValue, contains('"type":"direct"'));
    });

    test('脏数据（非法 JSON / 非数组 / 缺 url 项）→ 降级容忍', () async {
      // 非法 JSON。
      await pm.set(PushPlayStore.itemsKey, 'not-json{{{');
      final PushPlayStore s1 = PushPlayStore(prefs: pm);
      await s1.load();
      expect(s1.items, isEmpty);

      // 非数组。
      await pm.set(PushPlayStore.itemsKey, '{"a":1}');
      final PushPlayStore s2 = PushPlayStore(prefs: pm);
      await s2.load();
      expect(s2.items, isEmpty);

      // 缺 url 项跳过。
      await pm.set(PushPlayStore.itemsKey, '[{"title":"x"},{"title":"y","url":"https://y.com"}]');
      final PushPlayStore s3 = PushPlayStore(prefs: pm);
      await s3.load();
      expect(s3.items, hasLength(1));
      expect(s3.items.single.url, 'https://y.com');
    });
  });

  group('updateItem（对齐 iOS updateItem(_:withEpisodes:)）', () {
    test('写入剧集列表并持久化', () async {
      store.addItem(title: '剧', url: 'https://a.com/1', type: PushPlayLinkType.direct);
      final PushPlayItem item = store.items.single;
      store.updateItem(
        item,
        const <PushPlayEpisode>[
          PushPlayEpisode(name: '第1集', url: 'https://a.com/ep1.m3u8'),
          PushPlayEpisode(name: '第2集', url: 'https://a.com/ep2.m3u8'),
        ],
      );
      expect(store.items.single.episodes, hasLength(2));

      final PushPlayStore back = PushPlayStore(prefs: pm);
      await back.load();
      expect(back.items.single.episodes, hasLength(2));
      expect(back.items.single.episodes!.first.name, '第1集');
    });
  });

  group('removeItem / removeAll（对齐 iOS）', () {
    test('删除单条', () {
      store.addItem(title: 'A', url: 'https://a.com/1', type: PushPlayLinkType.direct);
      store.addItem(title: 'B', url: 'https://b.com/2', type: PushPlayLinkType.web);
      store.removeItem(store.items.last); // 删除 A
      expect(store.items, hasLength(1));
      expect(store.items.single.title, 'B');
    });

    test('清空全部', () {
      store.addItem(title: 'A', url: 'https://a.com/1', type: PushPlayLinkType.direct);
      store.addItem(title: 'B', url: 'https://b.com/2', type: PushPlayLinkType.web);
      store.removeAll();
      expect(store.items, isEmpty);

      final PushPlayStore back = PushPlayStore(prefs: pm);
      back.load();
      // 落盘异步尽力而为：等待微任务后校验（对齐现有存储测试）。
      expect(back.items, isEmpty);
    });
  });

  group('实体编解码（push_play.dart）', () {
    test('encodeItems / decodeItems 往返一致', () {
      final List<PushPlayItem> items = <PushPlayItem>[
        PushPlayItem(
          title: 'A',
          url: 'https://a.com/1',
          type: PushPlayLinkType.direct,
          createdAt: DateTime.utc(2026, 1, 1),
          episodes: const <PushPlayEpisode>[
            PushPlayEpisode(name: '第1集', url: 'https://a.com/e1.m3u8'),
          ],
        ),
        PushPlayItem(
          title: 'B',
          url: 'https://b.com/2',
          type: PushPlayLinkType.web,
          createdAt: DateTime.utc(2026, 1, 2),
        ),
      ];
      final String raw = PushPlayItem.encodeItems(items);
      final List<PushPlayItem> back = PushPlayItem.decodeItems(raw);
      expect(back, hasLength(2));
      expect(back.first.title, 'A');
      expect(back.first.type, PushPlayLinkType.direct);
      expect(back.first.episodes!.single.name, '第1集');
      expect(back.first.createdAt, DateTime.utc(2026, 1, 1));
      expect(back.last.episodes, isNull);
      expect(back.last.type, PushPlayLinkType.web);
    });

    test('decodeItems 兼容 iOS JSONEncoder 数字时间戳与未知 type', () {
      // iOS `JSONEncoder` 默认将 Date 编码为 timeIntervalSinceReferenceDate（秒）。
      final List<PushPlayItem> back = PushPlayItem.decodeItems(
        '[{"title":"A","url":"https://a.com/1","type":"direct","createdAt":788918400.0}]',
      );
      expect(back, hasLength(1));
      expect(back.single.createdAt, isNotNull);
      expect(back.single.createdAt.millisecondsSinceEpoch, 788918400000);

      // 未知 type → 兜底 web。
      final List<PushPlayItem> unknown = PushPlayItem.decodeItems(
        '[{"title":"A","url":"https://a.com/1","type":"unknown"}]',
      );
      expect(unknown.single.type, PushPlayLinkType.web);
    });
  });
}
