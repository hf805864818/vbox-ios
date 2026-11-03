/// 单元测试：Spider 引擎类型与站点模式解析。
///
/// 对应源码：lib/domain/entities/spider/engine_type.dart
/// 契约：contract/docs/abi_v1.md §1 + §1.1，contract/schema/site_v1.json $defs
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/engine_type.dart';

void main() {
  group('SpiderEngineType 枚举值', () {
    test('枚举成员顺序与数量（4 个 iOS 原生 + 1 个 Flutter 补充的 python）', () {
      expect(SpiderEngineType.values, <SpiderEngineType>[
        SpiderEngineType.javaScriptCore,
        SpiderEngineType.quickJS,
        SpiderEngineType.node,
        SpiderEngineType.nodeLX,
        SpiderEngineType.python,
      ]);
      expect(SpiderEngineType.values.length, 5);
    });

    test('rawValue 与契约 §1 / site_v1.json \$defs.engineType 一致', () {
      expect(SpiderEngineType.javaScriptCore.rawValue, 'JavaScriptCore');
      expect(SpiderEngineType.quickJS.rawValue, 'QuickJS');
      expect(SpiderEngineType.node.rawValue, 'Node');
      expect(SpiderEngineType.nodeLX.rawValue, 'NodeLX');
      expect(SpiderEngineType.python.rawValue, 'python');
    });

    test('displayName 与契约 §1 表格一致', () {
      expect(SpiderEngineType.javaScriptCore.displayName, 'JSC (Apple)');
      expect(SpiderEngineType.quickJS.displayName, 'QuickJS');
      expect(SpiderEngineType.node.displayName, 'Node');
      expect(SpiderEngineType.nodeLX.displayName, 'Node-LX');
      expect(SpiderEngineType.python.displayName, 'Python');
    });
  });

  group('SpiderEngineType.fromRawValue', () {
    test('每个 rawValue 精确解析回对应枚举', () {
      for (final SpiderEngineType t in SpiderEngineType.values) {
        expect(SpiderEngineType.fromRawValue(t.rawValue), t,
            reason: 'rawValue=${t.rawValue}');
      }
    });

    test('大小写敏感：除 python 外不接受变体', () {
      expect(SpiderEngineType.fromRawValue('javascriptcore'), isNull);
      expect(SpiderEngineType.fromRawValue('JavaScriptCore '), isNull);
      expect(SpiderEngineType.fromRawValue('quickjs'), isNull);
      expect(SpiderEngineType.fromRawValue('node'), isNull);
      expect(SpiderEngineType.fromRawValue('NODELX'), isNull);
    });

    test('python 允许大小写变体（契约 §1 建议值）', () {
      expect(SpiderEngineType.fromRawValue('python'), SpiderEngineType.python);
      expect(SpiderEngineType.fromRawValue('Python'), SpiderEngineType.python);
      expect(SpiderEngineType.fromRawValue('PYTHON'), SpiderEngineType.python);
      expect(SpiderEngineType.fromRawValue('PyThOn'), SpiderEngineType.python);
    });

    test('未知/空/带空白输入返回 null', () {
      expect(SpiderEngineType.fromRawValue(''), isNull);
      expect(SpiderEngineType.fromRawValue('python3'), isNull);
      expect(SpiderEngineType.fromRawValue(' python'), isNull);
      expect(SpiderEngineType.fromRawValue('NodeLX '), isNull);
      expect(SpiderEngineType.fromRawValue('unknown'), isNull);
    });
  });

  group('SiteMode 枚举值', () {
    test('成员与顺序（对齐 contract/schema/site_v1.json \$defs.siteMode 语义）', () {
      expect(SiteMode.values, <SiteMode>[
        SiteMode.node,
        SiteMode.apiEndpoint,
        SiteMode.zhanyuan,
        SiteMode.jsSpider,
        SiteMode.pythonSpider,
        SiteMode.unsupported,
      ]);
      expect(SiteMode.values.length, 6);
    });

    test('name 与契约字面量一致', () {
      expect(SiteMode.apiEndpoint.name, 'apiEndpoint');
      expect(SiteMode.pythonSpider.name, 'pythonSpider');
      expect(SiteMode.zhanyuan.name, 'zhanyuan');
    });
  });
}