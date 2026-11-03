/// 领域层单测：TVBox 订阅配置（批次 G · G-07）。
///
/// 对齐基准（唯一真相源）：iOS `vbox/Services/SubscriptionManager.swift`
///   · `loadConfig(from:)`（L61-L281）站点合成链：标准 sites → apiyuan(type=1)
///     → zhanyuan(type=2) → 按 name 去重 → parses；
///   · `SubscribeConfig` / `ParseConfig` 的 Codable 往返（缓存读写）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/site_config.dart';
import 'package:vbox/domain/entities/subscribe/subscribe.dart';

void main() {
  group('ParseConfig（对齐 iOS ParseConfig）', () {
    test('fromRaw：name/url 齐全 → 实体；任一缺失 → null', () {
      final ParseConfig? ok = ParseConfig.fromRaw(
        <String, Object?>{'name': '解析A', 'url': 'https://p.example.com/jx', 'type': 1},
      );
      expect(ok, isNotNull);
      expect(ok!.name, '解析A');
      expect(ok.url, 'https://p.example.com/jx');
      expect(ok.type, 1);

      expect(
        ParseConfig.fromRaw(<String, Object?>{'name': '', 'url': 'https://x'}),
        isNull,
      );
      expect(
        ParseConfig.fromRaw(<String, Object?>{'name': 'x', 'url': ''}),
        isNull,
      );
      expect(ParseConfig.fromRaw('not-a-map'), isNull);
    });

    test('fromRaw：type 为字符串时按 int 解析；缺省为 null', () {
      final ParseConfig? s = ParseConfig.fromRaw(
        <String, Object?>{'name': 'x', 'url': 'https://x', 'type': '2'},
      );
      expect(s!.type, 2);
      final ParseConfig? n = ParseConfig.fromRaw(
        <String, Object?>{'name': 'x', 'url': 'https://x'},
      );
      expect(n!.type, isNull);
    });

    test('缓存往返：toJson → fromJson 一致', () {
      const ParseConfig p = ParseConfig(name: '解析A', url: 'https://p/jx', type: 3);
      final ParseConfig back = ParseConfig.fromJson(p.toJson());
      expect(back.name, p.name);
      expect(back.url, p.url);
      expect(back.type, p.type);
      // type 为 null 时不落键（对齐 iOS 可选编码）。
      const ParseConfig noType = ParseConfig(name: 'y', url: 'https://y');
      expect(noType.toJson().containsKey('type'), isFalse);
    });
  });

  group('buildFromSource 站点合成（对齐 iOS loadConfig 链）', () {
    test('① 标准 sites 原样转换；spider/wallpaper/lives/flags/banned 透传', () {
      final SubscribeConfig c = SubscribeConfig.buildFromSource(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{'key': 'k1', 'name': '站一', 'type': 3, 'api': 'https://a.js'},
        ],
        'spider': 'https://cdn/spider.jar',
        'wallpaper': 'https://cdn/bg.jpg',
        'lives': <Object?>[<String, Object?>{'name': 'live'}],
        'flags': <String>['flag1'],
        'banned': <String>['ad'],
      });
      expect(c.sites, hasLength(1));
      expect(c.sites.single.key, 'k1');
      expect(c.sites.single.type, 3);
      expect(c.spider, 'https://cdn/spider.jar');
      expect(c.wallpaper, 'https://cdn/bg.jpg');
      expect(c.lives, isA<List<Object?>>());
      expect(c.flags, <String>['flag1']);
      expect(c.banned, <String>['ad']);
      expect(c.hasSites, isTrue);
    });

    test('② apiyuan → type=1、key api_N、searchurl 补尾分隔符', () {
      final SubscribeConfig c = SubscribeConfig.buildFromSource(<String, Object?>{
        'apiyuan': <Object?>[
          <String, Object?>{'name': 'API甲', 'searchurl': 'https://api.a/search'},
          <String, Object?>{'name': 'API乙', 'searchurl': 'https://api.b/search?'},
          <String, Object?>{'name': 'API丙', 'searchurl': 'https://api.c/search='},
          <String, Object?>{'name': 'API丁', 'searchurl': 'https://api.d/search&'},
        ],
      });
      expect(c.sites.map((SiteConfig s) => s.key).toList(),
          <String>['api_1', 'api_2', 'api_3', 'api_4']);
      expect(c.sites.every((SiteConfig s) => s.type == 1), isTrue);
      // 无尾分隔符 → 补 `&`；已含 `?` / `=` / `&` 原样保留。
      expect(c.sites[0].api, 'https://api.a/search&');
      expect(c.sites[1].api, 'https://api.b/search?');
      expect(c.sites[2].api, 'https://api.c/search=');
      expect(c.sites[3].api, 'https://api.d/search&');
    });

    test('③ zhanyuan → type=2、key zhan_N、api=searchUrl、ext 存整条原始 JSON', () {
      final Map<String, Object?> item = <String, Object?>{
        'name': '站源甲',
        'searchUrl': 'https://z.a/search',
        'searchname': 'wd',
      };
      final SubscribeConfig c = SubscribeConfig.buildFromSource(<String, Object?>{
        'zhanyuan': <Object?>[item],
      });
      final SiteConfig s = c.sites.single;
      expect(s.key, 'zhan_1');
      expect(s.type, 2);
      expect(s.api, 'https://z.a/search');
      expect(jsonDecode(s.ext!), item);
    });

    test('④ 三源按 name 去重（先到先得）', () {
      final SubscribeConfig c = SubscribeConfig.buildFromSource(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{'key': 'std', 'name': '同名', 'type': 0, 'api': 'https://std'},
        ],
        'apiyuan': <Object?>[
          <String, Object?>{'name': '同名', 'searchurl': 'https://api.same'},
          <String, Object?>{'name': '独立API', 'searchurl': 'https://api.uni'},
        ],
        'zhanyuan': <Object?>[
          <String, Object?>{'name': '同名', 'searchUrl': 'https://zhan.same'},
        ],
      });
      expect(c.sites.map((SiteConfig s) => s.name).toList(), <String>['同名', '独立API']);
      // 去重后按追加顺序编号（标准站 1 + 首条被跳过的同名 → 独立 API 落在 api_2）。
      expect(c.sites[0].key, 'std');
      expect(c.sites[1].key, 'api_2');
    });

    test('缺 name / searchurl 的 apiyuan 项忽略', () {
      final SubscribeConfig c = SubscribeConfig.buildFromSource(<String, Object?>{
        'apiyuan': <Object?>[
          <String, Object?>{'name': '', 'searchurl': 'https://x'},
          <String, Object?>{'name': 'x', 'searchurl': ''},
          <String, Object?>{'name': '有效', 'searchurl': 'https://ok'},
        ],
      });
      expect(c.sites, hasLength(1));
      expect(c.sites.single.name, '有效');
    });

    test('⑤ parses 转换（忽略缺字段项）', () {
      final SubscribeConfig c = SubscribeConfig.buildFromSource(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{'key': 'k', 'name': '站', 'type': 0},
        ],
        'parses': <Object?>[
          <String, Object?>{'name': '解析A', 'url': 'https://p/a', 'type': 1},
          <String, Object?>{'name': '', 'url': 'https://p/b'},
        ],
      });
      expect(c.parses, hasLength(1));
      expect(c.parses.single.name, '解析A');
    });

    test('空 sites / 无任何源 → hasSites=false', () {
      expect(SubscribeConfig.buildFromSource(const <String, Object?>{}).hasSites, isFalse);
      expect(
        SubscribeConfig.buildFromSource(<String, Object?>{'sites': <Object?>[]}).hasSites,
        isFalse,
      );
    });
  });

  group('缓存往返（对齐 iOS JSONEncoder / JSONDecoder）', () {
    test('buildFromSource → toJson → fromJson 保真', () {
      final SubscribeConfig built = SubscribeConfig.buildFromSource(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{'key': 'k1', 'name': '站一', 'type': 3, 'api': 'https://a.js'},
        ],
        'apiyuan': <Object?>[
          <String, Object?>{'name': 'API甲', 'searchurl': 'https://api.a/search'},
        ],
        'spider': 'https://cdn/spider.jar',
        'wallpaper': 'https://cdn/bg.jpg',
        'parses': <Object?>[
          <String, Object?>{'name': '解析A', 'url': 'https://p/a', 'type': 1},
        ],
      });

      final SubscribeConfig back = SubscribeConfig.fromJson(
        (jsonDecode(jsonEncode(built.toJson())) as Map).cast<String, Object?>(),
      );

      expect(back.sites.map((SiteConfig s) => s.key).toList(),
          built.sites.map((SiteConfig s) => s.key).toList());
      expect(back.sites.map((SiteConfig s) => s.type).toList(), <int>[3, 1]);
      expect(back.sites[1].api, 'https://api.a/search&');
      expect(back.parses.single.name, '解析A');
      expect(back.parses.single.type, 1);
      expect(back.spider, 'https://cdn/spider.jar');
      expect(back.wallpaper, 'https://cdn/bg.jpg');
      expect(back.hasSites, isTrue);
    });

    test('fromJson 容忍缺字段 / 脏值（缺 sites、parses 非数组）', () {
      final SubscribeConfig c = SubscribeConfig.fromJson(<String, Object?>{
        'sites': 'not-a-list',
        'parses': 42,
      });
      expect(c.sites, isEmpty);
      expect(c.parses, isEmpty);
      expect(c.hasSites, isFalse);
    });
  });
}