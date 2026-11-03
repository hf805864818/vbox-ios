/// 领域层单测：福利平台配置模型（批次 H · H-01）。
///
/// 依据：`contract/schema/welfare_v1.json`（必需项 `schemaVersion` / `categories`
/// / `platforms`；平台必需 `platformKey` / `name` / `category`）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';

/// 合法配置（三分类 + 四平台，含未知字段以验证透传）。
Map<String, Object?> validConfig() => <String, Object?>{
      'schemaVersion': 1,
      '_meta': <String, Object?>{'version': '2026.10.03.1'},
      'categories': <Object?>[
        <String, Object?>{
          'key': 'video',
          'name': '视频',
          'icon': 'play.rectangle.fill',
        },
        <String, Object?>{'key': 'live', 'name': '直播'},
        <String, Object?>{'key': 'comic', 'name': '漫画'},
      ],
      'platforms': <Object?>[
        <String, Object?>{
          'platformKey': 'p1',
          'name': '平台一',
          'category': 'video',
          'icon': 'leaf.fill',
          'desc': '描述',
          'serviceType': 'ybox_special',
          'defaultHosts': <Object?>['https://a.com', '', ' https://b.com '],
          'sortOrder': 2,
          'defaultProxy': true,
          'notes': '备注',
          'unknownField': '透传',
        },
        <String, Object?>{
          'platformKey': 'p2',
          'name': '平台二',
          'category': 'video',
          'sortOrder': 1,
        },
        <String, Object?>{
          'platformKey': 'p3',
          'name': '直播一',
          'category': 'live',
        },
        <String, Object?>{
          'platformKey': 'p4',
          'name': '漫画一',
          'category': 'comic',
        },
      ],
    };

void main() {
  group('WelfarePlatformConfig.tryParse', () {
    test('合法配置 → 字段解析正确', () {
      final WelfarePlatformConfig? c = WelfarePlatformConfig.tryParse(validConfig());
      expect(c, isNotNull);
      expect(c!.schemaVersion, 1);
      expect(c.meta?['version'], '2026.10.03.1');
      expect(c.categories.length, 3);
      expect(c.categories.first.key, 'video');
      expect(c.categories.first.name, '视频');
      expect(c.categories.first.icon, 'play.rectangle.fill');
      expect(c.platforms.length, 4);
    });

    test('平台可选项解析（icon/desc/serviceType/hosts/sortOrder/defaultProxy/notes）', () {
      final WelfarePlatformConfig c =
          WelfarePlatformConfig.tryParse(validConfig())!;
      final WelfarePlatform p1 =
          c.platforms.firstWhere((WelfarePlatform p) => p.platformKey == 'p1');
      expect(p1.icon, 'leaf.fill');
      expect(p1.desc, '描述');
      expect(p1.serviceType, 'ybox_special');
      // 空串丢弃 + 首尾空白 trim。
      expect(p1.defaultHosts, <String>['https://a.com', 'https://b.com']);
      expect(p1.sortOrder, 2);
      expect(p1.defaultProxy, isTrue);
      expect(p1.notes, '备注');
    });

    test('platformsIn：过滤分类并按 sortOrder 升序', () {
      final WelfarePlatformConfig c =
          WelfarePlatformConfig.tryParse(validConfig())!;
      final List<WelfarePlatform> video =
          c.platformsIn(WelfarePlatformCategory.video);
      expect(video.map((WelfarePlatform p) => p.platformKey).toList(),
          <String>['p2', 'p1']);
      expect(c.platformsIn(WelfarePlatformCategory.live).length, 1);
      expect(c.platformsIn(WelfarePlatformCategory.comic).length, 1);
    });

    test('schemaVersion 缺失 / 非 1 → null', () {
      final Map<String, Object?> noVersion = validConfig()..remove('schemaVersion');
      expect(WelfarePlatformConfig.tryParse(noVersion), isNull);

      final Map<String, Object?> wrong = validConfig()..['schemaVersion'] = 2;
      expect(WelfarePlatformConfig.tryParse(wrong), isNull);
    });

    test('categories / platforms 非数组 → null', () {
      expect(
        WelfarePlatformConfig.tryParse(
          validConfig()..['categories'] = 'x',
        ),
        isNull,
      );
      expect(
        WelfarePlatformConfig.tryParse(
          validConfig()..['platforms'] = <String, Object?>{},
        ),
        isNull,
      );
    });

    test('非 Map → null', () {
      expect(WelfarePlatformConfig.tryParse(<Object?>[1, 2, 3]), isNull);
      expect(WelfarePlatformConfig.tryParse('x'), isNull);
      expect(WelfarePlatformConfig.tryParse(null), isNull);
    });

    test('分类逐项过滤：未知 key / 缺 name 丢弃，不整包拒收', () {
      final Map<String, Object?> j = validConfig();
      j['categories'] = <Object?>[
        <String, Object?>{'key': 'video', 'name': '视频'},
        <String, Object?>{'key': 'unknown', 'name': '未知'},
        <String, Object?>{'key': 'live'},
        'not a map',
      ];
      final WelfarePlatformConfig c = WelfarePlatformConfig.tryParse(j)!;
      expect(c.categories.length, 1);
      expect(c.categories.single.key, 'video');
    });

    test('平台逐项过滤：缺 platformKey / 未知 category 丢弃', () {
      final Map<String, Object?> j = validConfig();
      j['platforms'] = <Object?>[
        <String, Object?>{'name': '缺键', 'category': 'video'},
        <String, Object?>{
          'platformKey': 'x',
          'name': '未知分类',
          'category': 'other',
        },
        <String, Object?>{
          'platformKey': 'ok',
          'name': '正常',
          'category': 'video',
        },
      ];
      final WelfarePlatformConfig c = WelfarePlatformConfig.tryParse(j)!;
      expect(c.platforms.length, 1);
      expect(c.platforms.single.platformKey, 'ok');
    });

    test('未知字段透传不报错（additionalProperties）', () {
      final WelfarePlatformConfig c =
          WelfarePlatformConfig.tryParse(validConfig())!;
      expect(c.platforms.length, 4);
    });
  });

  group('WelfarePlatformConfig 序列化', () {
    test('toJson ⇄ tryParse 往返一致', () {
      final WelfarePlatformConfig original =
          WelfarePlatformConfig.tryParse(validConfig())!;
      final WelfarePlatformConfig restored =
          WelfarePlatformConfig.tryParse(original.toJson())!;
      expect(restored.schemaVersion, original.schemaVersion);
      expect(restored.meta?['version'], original.meta?['version']);
      expect(restored.categories.length, original.categories.length);
      expect(restored.platforms.length, original.platforms.length);
      expect(restored.platforms.first.defaultHosts,
          original.platforms.first.defaultHosts);
    });

    test('fromJson 非法结构 → FormatException', () {
      expect(
        () => WelfarePlatformConfig.fromJson(<String, Object?>{'schemaVersion': 1}),
        throwsFormatException,
      );
    });
  });

  group('WelfarePlatformCategory', () {
    test('fromKey：已知三值命中，未知返回 null', () {
      expect(WelfarePlatformCategory.fromKey('video'),
          WelfarePlatformCategory.video);
      expect(WelfarePlatformCategory.fromKey('live'),
          WelfarePlatformCategory.live);
      expect(WelfarePlatformCategory.fromKey('comic'),
          WelfarePlatformCategory.comic);
      expect(WelfarePlatformCategory.fromKey('other'), isNull);
    });
  });
}