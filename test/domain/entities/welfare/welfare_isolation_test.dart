/// 领域层单测：福利三重隔离策略（批次 H · H-04）。
///
/// 覆盖：脚本路径判定（对齐 iOS `isAllowedWelfareScriptPath`）/ 规范化 /
/// 三重隔离判定（仅 `welfare_spider`）/ 违规说明 / 全量校验 / 模型字段往返。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';

WelfarePlatform _platform({
  String serviceType = 'welfare_spider',
  String? api,
  bool? visibleInNormalSpider,
  bool? visibleInGlobalSearch,
  bool? visibleInHome,
}) =>
    WelfarePlatform(
      platformKey: 'missav',
      name: 'MissAV',
      category: WelfarePlatformCategory.video,
      serviceType: serviceType,
      api: api,
      visibleInNormalSpider: visibleInNormalSpider ?? false,
      visibleInGlobalSearch: visibleInGlobalSearch ?? false,
      visibleInHome: visibleInHome ?? false,
    );

void main() {
  group('WelfareIsolationPolicy.normalizeScriptPath', () {
    test('反斜杠归一 + 剥离 ./', () {
      expect(WelfareIsolationPolicy.normalizeScriptPath(r'.\sources\a.py'),
          'sources/a.py');
      expect(WelfareIsolationPolicy.normalizeScriptPath('./sources/a.py'),
          'sources/a.py');
      expect(WelfareIsolationPolicy.normalizeScriptPath('././welfare-js/a.py'),
          'welfare-js/a.py');
    });
  });

  group('WelfareIsolationPolicy.isAllowedScriptPath', () {
    test('合规路径命中（对齐 iOS 语义）', () {
      expect(WelfareIsolationPolicy.isAllowedScriptPath('./sources/welfare-js/missav.py'),
          isTrue);
      expect(WelfareIsolationPolicy.isAllowedScriptPath('sources/welfare-js/a.js'),
          isTrue);
      expect(WelfareIsolationPolicy.isAllowedScriptPath('welfare-js/b.py'),
          isTrue);
      expect(WelfareIsolationPolicy.isAllowedScriptPath('./sources/welfare-js/sub/c.py'),
          isTrue);
    });

    test('越界 / 空 / 绝对 URL 一律拒绝', () {
      expect(WelfareIsolationPolicy.isAllowedScriptPath('./sources/other/x.py'),
          isFalse);
      expect(WelfareIsolationPolicy.isAllowedScriptPath('sources/spider_sources.json'),
          isFalse);
      expect(WelfareIsolationPolicy.isAllowedScriptPath('http://cdn/x.js'),
          isFalse);
      expect(WelfareIsolationPolicy.isAllowedScriptPath(''), isFalse);
      expect(WelfareIsolationPolicy.isAllowedScriptPath(null), isFalse);
      expect(WelfareIsolationPolicy.isAllowedScriptPath('   '), isFalse);
    });
  });

  group('WelfareIsolationPolicy.isWelfareSpider', () {
    test('welfare_spider / python_spider 均命中（对齐 iOS L211-L214）', () {
      expect(WelfareIsolationPolicy.isWelfareSpider(_platform()), isTrue);
      expect(
        WelfareIsolationPolicy.isWelfareSpider(
          _platform(serviceType: 'python_spider'),
        ),
        isTrue,
      );
      expect(
        WelfareIsolationPolicy.isWelfareSpider(
          _platform(serviceType: 'kanliao'),
        ),
        isFalse,
      );
    });
  });

  group('WelfareIsolationPolicy 三重隔离判定', () {
    test('welfare_spider 三字段全 false → 合规', () {
      expect(WelfareIsolationPolicy.satisfiesTripleIsolation(_platform()),
          isTrue);
    });

    test('任一可见性字段为 true → 违规', () {
      expect(
        WelfareIsolationPolicy.satisfiesTripleIsolation(
          _platform(visibleInNormalSpider: true),
        ),
        isFalse,
      );
      expect(
        WelfareIsolationPolicy.satisfiesTripleIsolation(
          _platform(visibleInGlobalSearch: true),
        ),
        isFalse,
      );
      expect(
        WelfareIsolationPolicy.satisfiesTripleIsolation(
          _platform(visibleInHome: true),
        ),
        isFalse,
      );
    });

    test('非 welfare_spider 平台不在此判定范围（视为合规）', () {
      expect(
        WelfareIsolationPolicy.satisfiesTripleIsolation(
          _platform(serviceType: 'ybox_special', visibleInHome: true),
        ),
        isTrue,
      );
      expect(
        WelfareIsolationPolicy.satisfiesTripleIsolation(
          _platform(serviceType: 'python_spider', visibleInNormalSpider: true),
        ),
        isTrue,
      );
    });
  });

  group('WelfareIsolationPolicy.violationFor', () {
    test('合规福利 Spider（含合规 api 路径）→ null', () {
      expect(
        WelfareIsolationPolicy.violationFor(
          _platform(api: './sources/welfare-js/missav.py'),
        ),
        isNull,
      );
    });

    test('三重隔离违规 → 列明违规字段', () {
      final String? v = WelfareIsolationPolicy.violationFor(
        _platform(visibleInNormalSpider: true, visibleInHome: true),
      );
      expect(v, isNotNull);
      expect(v, contains('visibleInNormalSpider'));
      expect(v, contains('visibleInHome'));
      expect(v, contains('missav'));
    });

    test('脚本路径越界 → 提示只允许 sources/welfare-js/', () {
      final String? v = WelfareIsolationPolicy.violationFor(
        _platform(api: './sources/other/x.py'),
      );
      expect(v, isNotNull);
      expect(v, contains('sources/welfare-js/'));
    });

    test('非 welfare_spider 一律返回 null', () {
      expect(
        WelfareIsolationPolicy.violationFor(
          _platform(serviceType: 'kanliao', visibleInHome: true),
        ),
        isNull,
      );
      expect(
        WelfareIsolationPolicy.violationFor(
          _platform(serviceType: 'ybox_special', api: './sources/other/x.py'),
        ),
        isNull,
      );
    });
  });

  group('WelfareIsolationPolicy.violationsForAll', () {
    test('混合配置仅报违规项', () {
      const WelfarePlatformConfig config = WelfarePlatformConfig(
        platforms: <WelfarePlatform>[
          WelfarePlatform(
            platformKey: 'ok',
            name: '合规',
            category: WelfarePlatformCategory.video,
            serviceType: 'welfare_spider',
          ),
          WelfarePlatform(
            platformKey: 'bad-visible',
            name: '越界可见',
            category: WelfarePlatformCategory.video,
            serviceType: 'welfare_spider',
            visibleInHome: true,
          ),
          WelfarePlatform(
            platformKey: 'bad-api',
            name: '越界脚本',
            category: WelfarePlatformCategory.video,
            serviceType: 'welfare_spider',
            api: './sources/other/x.py',
          ),
          WelfarePlatform(
            platformKey: 'native',
            name: '原生',
            category: WelfarePlatformCategory.video,
            serviceType: 'kanliao',
          ),
        ],
      );
      final List<String> violations =
          WelfareIsolationPolicy.violationsForAll(config);
      expect(violations, hasLength(2));
      expect(violations.join('\n'), contains('bad-visible'));
      expect(violations.join('\n'), contains('bad-api'));
    });
  });

  group('WelfarePlatform 隔离字段解析', () {
    test('tryParse 读入 api 与三个可见性字段', () {
      final WelfarePlatform? p = WelfarePlatform.tryParse(<String, Object?>{
        'platformKey': 'missav',
        'name': 'MissAV',
        'category': 'video',
        'serviceType': 'welfare_spider',
        'api': './sources/welfare-js/missav.py',
        'visibleInNormalSpider': false,
        'visibleInGlobalSearch': false,
        'visibleInHome': false,
      });
      expect(p, isNotNull);
      expect(p!.api, './sources/welfare-js/missav.py');
      expect(p.visibleInNormalSpider, isFalse);
      expect(p.visibleInGlobalSearch, isFalse);
      expect(p.visibleInHome, isFalse);
    });

    test('缺省（字段缺失）→ false，且 toJson 显式回写', () {
      final WelfarePlatform? p = WelfarePlatform.tryParse(<String, Object?>{
        'platformKey': 'kanliao-1',
        'name': '今日看料',
        'category': 'video',
      });
      expect(p, isNotNull);
      expect(p!.visibleInNormalSpider, isFalse);
      final Map<String, Object?> json = p.toJson();
      expect(json['visibleInNormalSpider'], isFalse);
      expect(json['visibleInGlobalSearch'], isFalse);
      expect(json['visibleInHome'], isFalse);
    });

    test('true 值如实解析且 JSON 往返一致', () {
      final WelfarePlatform? p = WelfarePlatform.tryParse(<String, Object?>{
        'platformKey': 'x',
        'name': 'X',
        'category': 'video',
        'visibleInNormalSpider': true,
      });
      expect(p!.visibleInNormalSpider, isTrue);
      final WelfarePlatform? r =
          WelfarePlatform.tryParse(<String, Object?>{...p.toJson()});
      expect(r!.visibleInNormalSpider, isTrue);
      expect(r.visibleInGlobalSearch, isFalse);
    });
  });
}
