/// TG 搜索配置存储单测（批次 G · G-04）。
///
/// 对齐基准（唯一真相源）：iOS `vbox/Services/TGSearchConfigStore.swift`
///   · 契约键三枚：`tg_search_proxy_url_v1` / `tg_search_channel_mode_v1` /
///     `tg_search_channels_v1`（string，JSON 数组字符串）；
///   · `addChannel`：trim → 空 ID 忽略 → 空名称回退 ID → 追加尾部；
///   · `removeChannels` / `moveChannel`：删除 / 排序；
///   · `hasValidProxy`：trim 非空且以 `http` 开头；
///   · `generateConfigJS`：`__TG_CONFIG__`（channels 注入侧键名为 `id`）。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/local/tg_search_config_store.dart';
import 'package:vbox/domain/entities/tg/tg_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late TGSearchConfigStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = TGSearchConfigStore(prefs: pm);
    await store.load();
  });

  group('契约键（prefs_keys_v1.json → _group_tg）', () {
    test('键名与契约一致', () {
      expect(TGSearchConfigStore.proxyUrlKey, 'tg_search_proxy_url_v1');
      expect(TGSearchConfigStore.channelModeKey, 'tg_search_channel_mode_v1');
      expect(TGSearchConfigStore.channelsKey, 'tg_search_channels_v1');
    });
  });

  group('代理地址（对齐 iOS proxyURL + hasValidProxy）', () {
    test('默认空串且无有效代理', () {
      expect(store.proxyUrl, '');
      expect(store.hasValidProxy, isFalse);
    });

    test('setProxyUrl 落盘 + hasValidProxy 判定（trim 非空且 http 开头）', () async {
      store.setProxyUrl('https://proxy.example.com/?url=');
      expect(store.hasValidProxy, isTrue);

      final SharedPreferences raw = await SharedPreferences.getInstance();
      expect(
        raw.getString(TGSearchConfigStore.proxyUrlKey),
        'https://proxy.example.com/?url=',
      );

      store.setProxyUrl('  ftp://x  ');
      expect(store.hasValidProxy, isFalse);
      store.setProxyUrl('');
      expect(store.hasValidProxy, isFalse);
    });
  });

  group('频道来源模式（对齐 iOS ChannelMode）', () {
    test('默认 remoteDefault；三档 rawValue 与文案', () {
      expect(store.channelMode, TGChannelMode.remoteDefault);
      expect(TGChannelMode.remoteDefault.rawValue, 'default');
      expect(TGChannelMode.custom.rawValue, 'custom');
      expect(TGChannelMode.all.rawValue, 'all');
      expect(TGChannelMode.remoteDefault.displayName, '远程默认');
      expect(TGChannelMode.remoteDefault.description, '仅使用远程仓库内置的默认频道');
    });

    test('setChannelMode 落盘', () async {
      store.setChannelMode(TGChannelMode.all);
      final SharedPreferences raw = await SharedPreferences.getInstance();
      expect(raw.getString(TGSearchConfigStore.channelModeKey), 'all');
    });

    test('fromRaw 未知值兜底 remoteDefault', () {
      expect(TGChannelMode.fromRaw('custom'), TGChannelMode.custom);
      expect(TGChannelMode.fromRaw('nope'), TGChannelMode.remoteDefault);
      expect(TGChannelMode.fromRaw(null), TGChannelMode.remoteDefault);
    });
  });

  group('addChannel（对齐 iOS addChannel）', () {
    test('空频道 ID 忽略', () {
      store.addChannel(name: 'A', channelId: '   ');
      expect(store.channels, isEmpty);
    });

    test('trim + 空名称回退 ID + 追加尾部', () {
      store.addChannel(name: ' UC夸克资源 ', channelId: ' ucquark ');
      store.addChannel(name: '  ', channelId: 'quarkshare');
      expect(store.channels, hasLength(2));
      expect(store.channels.first.name, 'UC夸克资源');
      expect(store.channels.first.channelId, 'ucquark');
      // 空名称 → 回退为频道 ID。
      expect(store.channels.last.name, 'quarkshare');
    });

    test('containsChannel / channelIds', () {
      store.addChannel(name: 'A', channelId: 'ucquark');
      expect(store.containsChannel('ucquark'), isTrue);
      expect(store.containsChannel('nope'), isFalse);
      expect(store.channelIds, <String>{'ucquark'});
    });
  });

  group('删除与排序（对齐 iOS removeChannels / moveChannel）', () {
    setUp(() {
      store.addChannel(name: 'A', channelId: 'a');
      store.addChannel(name: 'B', channelId: 'b');
      store.addChannel(name: 'C', channelId: 'c');
    });

    test('removeChannelAt（越界忽略）', () {
      store.removeChannelAt(1);
      expect(store.channels.map((TGChannel c) => c.channelId), <String>['a', 'c']);
      store.removeChannelAt(9);
      expect(store.channels, hasLength(2));
    });

    test('removeChannels 批量（跳过越界下标）', () {
      store.removeChannels(<int>[0, 2, 99]);
      expect(store.channels.map((TGChannel c) => c.channelId), <String>['b']);
    });

    test('moveChannel（移除后插入语义；to 越界收敛到末位）', () {
      // 前移：[a,b,c] → 移 a 到末位 → [b,c,a]。
      store.moveChannel(from: 0, to: 2);
      expect(store.channels.map((TGChannel c) => c.channelId), <String>['b', 'c', 'a']);
      // 回移：移 a 到首位 → [a,b,c]。
      store.moveChannel(from: 2, to: 0);
      expect(store.channels.map((TGChannel c) => c.channelId), <String>['a', 'b', 'c']);
      // to 越界 → clamp 到末位。
      store.moveChannel(from: 0, to: 99);
      expect(store.channels.map((TGChannel c) => c.channelId), <String>['b', 'c', 'a']);
    });
  });

  group('配置注入 generateConfigJs（对齐 iOS generateConfigJS）', () {
    test('结构：proxyUrl / channelMode / channels[{name,id}]', () {
      store.setProxyUrl('https://proxy.example.com/?url=');
      store.setChannelMode(TGChannelMode.custom);
      store.addChannel(name: 'UC夸克资源', channelId: 'ucquark');
      final String js = store.generateConfigJs();
      expect(js, startsWith('var __TG_CONFIG__ = '));
      expect(js, endsWith(';'));
      expect(js, contains('"proxyUrl":"https://proxy.example.com/?url="'));
      expect(js, contains('"channelMode":"custom"'));
      // 注入侧频道键名为 `id`（供 JS 蜘蛛读取 ch.id），非持久化的 channelId。
      expect(js, contains('{"name":"UC夸克资源","id":"ucquark"}'));
      expect(js, isNot(contains('channelId')));
    });

    test('空配置也产出合法赋值语句', () {
      final String js = store.generateConfigJs();
      expect(js, contains('"proxyUrl":""'));
      expect(js, contains('"channelMode":"default"'));
      expect(js, contains('"channels":[]'));
    });
  });

  group('持久化（对齐 iOS save/load）', () {
    test('三键落盘且新实例可读回', () async {
      store.setProxyUrl('https://proxy.example.com/?url=');
      store.setChannelMode(TGChannelMode.all);
      store.addChannel(name: 'UC夸克资源', channelId: 'ucquark');
      await Future<void>.delayed(Duration.zero);

      final TGSearchConfigStore back = TGSearchConfigStore(prefs: pm);
      await back.load();
      expect(back.proxyUrl, 'https://proxy.example.com/?url=');
      expect(back.channelMode, TGChannelMode.all);
      expect(back.channels.single.channelId, 'ucquark');

      final SharedPreferences raw = await SharedPreferences.getInstance();
      expect(raw.getString(TGSearchConfigStore.channelsKey), contains('"channelId":"ucquark"'));
    });

    test('load 只恢复一次（_loaded 守卫；此后以内存态为准）', () async {
      store.addChannel(name: 'A', channelId: 'a');
      await pm.set(TGSearchConfigStore.channelsKey, '[{"name":"X","channelId":"x"}]');
      // 第二次 load 不覆盖（对齐 iOS「启动恢复一次」语义）。
      await store.load();
      expect(store.channels.single.channelId, 'a');
    });

    test('脏数据（非法 JSON / 非数组 / 缺 channelId 项）→ 降级容忍', () async {
      await pm.set(TGSearchConfigStore.channelsKey, 'not-json{{{');
      final TGSearchConfigStore s1 = TGSearchConfigStore(prefs: pm);
      await s1.load();
      expect(s1.channels, isEmpty);

      await pm.set(TGSearchConfigStore.channelsKey, '{"a":1}');
      final TGSearchConfigStore s2 = TGSearchConfigStore(prefs: pm);
      await s2.load();
      expect(s2.channels, isEmpty);

      await pm.set(
        TGSearchConfigStore.channelsKey,
        '[{"name":"x"},{"name":"y","channelId":"y"}]',
      );
      final TGSearchConfigStore s3 = TGSearchConfigStore(prefs: pm);
      await s3.load();
      expect(s3.channels, hasLength(1));
      expect(s3.channels.single.channelId, 'y');
    });

    test('兼容 iOS 编码含 UUID id 字段（读取忽略）', () async {
      await pm.set(
        TGSearchConfigStore.channelsKey,
        '[{"id":"1B4B1F1E-0000-4000-8000-000000000000","name":"UC夸克资源","channelId":"ucquark"}]',
      );
      final TGSearchConfigStore back = TGSearchConfigStore(prefs: pm);
      await back.load();
      expect(back.channels.single.name, 'UC夸克资源');
      expect(back.channels.single.channelId, 'ucquark');
    });
  });

  group('实体编解码（tg_channel.dart）', () {
    test('encodeChannels / decodeChannels 往返一致', () {
      final List<TGChannel> channels = <TGChannel>[
        const TGChannel(name: 'UC夸克资源', channelId: 'ucquark'),
        const TGChannel(name: '夸克分享', channelId: 'quarkshare'),
      ];
      final List<TGChannel> back = TGChannel.decodeChannels(TGChannel.encodeChannels(channels));
      expect(back, channels);
    });

    test('fromJson：空名称回退 ID；缺 channelId → null', () {
      final TGChannel? c = TGChannel.fromJson(<String, Object?>{'name': '  ', 'channelId': 'x'});
      expect(c!.name, 'x');
      expect(TGChannel.fromJson(<String, Object?>{'name': 'x'}), isNull);
    });

    test('presetChannels 共 10 个且 ID 唯一（对齐 iOS presetChannels）', () {
      expect(TGChannel.presetChannels, hasLength(10));
      final Set<String> ids =
          TGChannel.presetChannels.map((TGChannel c) => c.channelId).toSet();
      expect(ids, hasLength(10));
      expect(TGChannel.presetChannels.first.name, 'UC夸克资源');
      expect(TGChannel.presetChannels.first.channelId, 'ucquark');
      expect(ids, contains('yunpanxunlei'));
    });
  });
}