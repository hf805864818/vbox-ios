/// 站点诊断管理器单测（批次 G · G-08）。
///
/// 唯一真相源：iOS `vbox/Models/SiteDiagnostics.swift`
///   · `SiteStatus` 11 态 + `diagnoseSite` 判定链；
///   · `testEngineCompatibility` 双引擎语法测试；
///   · `DiagnosticSummary` 统计口径。
///
/// 无真实网络 / 无原生依赖：注入 `MockClient`（脚本下载）+ fake JSC/QuickJS 桥
/// （`loadScript` 语法测试）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/domain/entities/spider/engine_type.dart';
import 'package:vbox/domain/entities/spider/site_config.dart';
import 'package:vbox/platform/runtime/jsc_ffi.dart';
import 'package:vbox/platform/runtime/quickjs_ffi.dart';
import 'package:vbox/presentation/pages/diagnostics/site_diagnostics_manager.dart';

/// 可用桥：`loadScript` 全部 eval 返回空串（无异常）→ 语法测试通过。
class _OkBridge implements JsCoreNativeBridge, QuickJsNativeBridge {
  @override
  bool get isAvailable => true;

  @override
  int createRuntime() => 1;

  @override
  int createContext(int runtime) => 1;

  @override
  void freeContext(int context) {}

  @override
  void freeRuntime(int runtime) {}

  @override
  String? eval(int context, String script) => '';
}

/// 报错桥：eval 返回 `SyntaxError` 前缀 → `loadScript` 抛 `E_SCRIPT_LOAD`。
class _FailBridge implements JsCoreNativeBridge, QuickJsNativeBridge {
  @override
  bool get isAvailable => true;

  @override
  int createRuntime() => 1;

  @override
  int createContext(int runtime) => 1;

  @override
  void freeContext(int context) {}

  @override
  void freeRuntime(int runtime) {}

  @override
  String? eval(int context, String script) => 'SyntaxError: unexpected token';
}

/// 站点构造（只填诊断关心的字段）。
SiteConfig _site({
  required String key,
  required int type,
  String? api,
  int? searchable,
}) =>
    SiteConfig(
      key: key,
      name: key,
      type: type,
      api: api,
      searchable: searchable,
    );

/// 合法长脚本（≥200 字符 + 含 `function ` 关键字 + `__JS_SPIDER__` 导出）。
String get _validScript =>
    'var __JS_SPIDER__ = { homeContent: function (){ return {}; } };'
    '${'x' * 200}';

/// 下载成功客户端（返回 [body]）。
HttpClient _downloadClient(String body, {int status = 200}) => HttpClient(
      inner: MockClient((http.Request _) async => http.Response(body, status)),
    );

void main() {
  group('type 0/1（API 端点）', () {
    test('api 为 http(s) → apiOnly + canSearch', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager(
        jscBridge: _OkBridge(),
        qjsBridge: _OkBridge(),
      );
      await m.diagnoseAll(<SiteConfig>[
        _site(key: 'a', type: 0, api: 'https://a.example.com/api'),
      ]);
      final SiteDiagnosticResult r = m.results.single;
      expect(r.status, SiteDiagnosticStatus.apiOnly);
      expect(r.canSearch, isTrue);
      expect(r.errorMessage, isNull);
    });

    test('api 为空 / 非 http → noApi + 错误文案', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager(
        jscBridge: _OkBridge(),
        qjsBridge: _OkBridge(),
      );
      await m.diagnoseAll(<SiteConfig>[
        _site(key: 'a', type: 1),
        _site(key: 'b', type: 1, api: 'ftp://b.example.com'),
      ]);
      expect(m.results[0].status, SiteDiagnosticStatus.noApi);
      expect(m.results[0].errorMessage, 'API地址为空或无效');
      expect(m.results[1].status, SiteDiagnosticStatus.noApi);
      expect(m.results[0].canSearch, isFalse);
    });
  });

  group('type 2（站源）', () {
    test('内置解析始终就绪 → engineReady', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager();
      await m.diagnoseAll(<SiteConfig>[_site(key: 'z', type: 2)]);
      final SiteDiagnosticResult r = m.results.single;
      expect(r.status, SiteDiagnosticStatus.engineReady);
      expect(r.engineLoaded, isTrue);
      expect(r.canSearch, isTrue);
    });
  });

  group('type 3（JS 蜘蛛）', () {
    test('api 为空 → noApi「api 字段为空」', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager();
      await m.diagnoseAll(<SiteConfig>[_site(key: 's', type: 3)]);
      expect(m.results.single.status, SiteDiagnosticStatus.noApi);
      expect(m.results.single.errorMessage, 'api 字段为空');
    });

    test('api 非 http(s) → noApi', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager();
      await m.diagnoseAll(<SiteConfig>[
        _site(key: 's', type: 3, api: 'file:///tmp/a.js'),
      ]);
      expect(m.results.single.status, SiteDiagnosticStatus.noApi);
      expect(m.results.single.errorMessage, contains('不是 http/https URL'));
    });

    test('HTTP 非 200 → downloadFailed', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager(
        httpClient: _downloadClient('nope', status: 404),
      );
      await m.diagnoseAll(<SiteConfig>[
        _site(key: 's', type: 3, api: 'https://s.example.com/a.js'),
      ]);
      final SiteDiagnosticResult r = m.results.single;
      expect(r.status, SiteDiagnosticStatus.downloadFailed);
      expect(r.errorMessage, contains('HTTP 404'));
    });

    test('脚本过短（<200）→ invalidContent', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager(
        httpClient: _downloadClient('short'),
      );
      await m.diagnoseAll(<SiteConfig>[
        _site(key: 's', type: 3, api: 'https://s.example.com/a.js'),
      ]);
      expect(m.results.single.status, SiteDiagnosticStatus.invalidContent);
      expect(m.results.single.errorMessage, contains('JS 代码太短'));
    });

    test('缺 function/spider 关键字 → invalidContent', () async {
      final String body = 'var a = 1;${'z' * 300}';
      final SiteDiagnosticsManager m = SiteDiagnosticsManager(
        httpClient: _downloadClient(body),
      );
      await m.diagnoseAll(<SiteConfig>[
        _site(key: 's', type: 3, api: 'https://s.example.com/a.js'),
      ]);
      expect(m.results.single.status, SiteDiagnosticStatus.invalidContent);
      expect(m.results.single.errorMessage, contains('function/spider'));
    });

    test('双引擎均可解析 → registerFailed（运行时注册失败）', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager(
        httpClient: _downloadClient(_validScript),
        jscBridge: _OkBridge(),
        qjsBridge: _OkBridge(),
      );
      await m.diagnoseAll(<SiteConfig>[
        _site(key: 's', type: 3, api: 'https://s.example.com/a.js'),
      ]);
      final SiteDiagnosticResult r = m.results.single;
      expect(r.status, SiteDiagnosticStatus.registerFailed);
      expect(r.errorMessage, contains('JSC 和 QuickJS 都能解析'));
    });

    test('缺 __JS_SPIDER__ 导出 → registerFailed（双侧失败文案）', () async {
      final String body = 'function foo(){ return 1; }${'y' * 300}';
      final SiteDiagnosticsManager m = SiteDiagnosticsManager(
        httpClient: _downloadClient(body),
        jscBridge: _OkBridge(),
        qjsBridge: _OkBridge(),
      );
      await m.diagnoseAll(<SiteConfig>[
        _site(key: 's', type: 3, api: 'https://s.example.com/a.js'),
      ]);
      final SiteDiagnosticResult r = m.results.single;
      expect(r.status, SiteDiagnosticStatus.registerFailed);
      expect(r.errorMessage, contains('脚本缺少 __JS_SPIDER__ 导出'));
    });

    test('仅 JSC 兼容 → jscOnly + engineType=javaScriptCore', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager(
        httpClient: _downloadClient(_validScript),
        jscBridge: _OkBridge(),
        qjsBridge: _FailBridge(),
      );
      await m.diagnoseAll(<SiteConfig>[
        _site(key: 's', type: 3, api: 'https://s.example.com/a.js'),
      ]);
      final SiteDiagnosticResult r = m.results.single;
      expect(r.status, SiteDiagnosticStatus.jscOnly);
      expect(r.jscCompatible, isTrue);
      expect(r.engineType, SpiderEngineType.javaScriptCore);
      expect(r.errorMessage, contains('仅 JSC 兼容'));
    });

    test('仅 QuickJS 兼容 → qjsOnly + engineType=quickJS', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager(
        httpClient: _downloadClient(_validScript),
        jscBridge: _FailBridge(),
        qjsBridge: _OkBridge(),
      );
      await m.diagnoseAll(<SiteConfig>[
        _site(key: 's', type: 3, api: 'https://s.example.com/a.js'),
      ]);
      final SiteDiagnosticResult r = m.results.single;
      expect(r.status, SiteDiagnosticStatus.qjsOnly);
      expect(r.qjsCompatible, isTrue);
      expect(r.engineType, SpiderEngineType.quickJS);
    });
  });

  group('边界与摘要', () {
    test('未知 type → unknown', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager();
      await m.diagnoseAll(<SiteConfig>[_site(key: 'u', type: 9)]);
      expect(m.results.single.status, SiteDiagnosticStatus.unknown);
      expect(m.results.single.errorMessage, contains('未知类型'));
    });

    test('searchable==0 覆盖 → 追加禁用搜索文案', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager();
      await m.diagnoseAll(<SiteConfig>[
        _site(key: 'n', type: 0, api: 'https://n.example.com', searchable: 0),
      ]);
      final SiteDiagnosticResult r = m.results.single;
      expect(r.canSearch, isFalse);
      expect(r.errorMessage, contains('searchable=0，已禁用搜索'));
    });

    test('摘要统计口径（failed 四态 / searchable / jsc / qjs）', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager(
        httpClient: _downloadClient(_validScript),
        jscBridge: _OkBridge(),
        qjsBridge: _FailBridge(),
      );
      await m.diagnoseAll(<SiteConfig>[
        _site(key: 'api', type: 0, api: 'https://api.example.com'), // apiOnly
        _site(key: 'zhanyuan', type: 2), // engineReady
        _site(key: 'bad', type: 1), // noApi → failed
        _site(key: 'js', type: 3, api: 'https://js.example.com/a.js'), // jscOnly
      ]);
      final DiagnosticSummary s = m.summary;
      expect(s.total, 4);
      expect(s.apiOnly, 1);
      expect(s.engineReady, 1);
      expect(s.failed, 1); // noApi
      expect(s.skipped, 0);
      expect(s.searchableCount, 2); // apiOnly + engineReady
      expect(s.jscCount, 1);
      expect(s.qjsCount, 0);
    });

    test('诊断中标志：diagnoseAll 前后翻转', () async {
      final SiteDiagnosticsManager m = SiteDiagnosticsManager();
      expect(m.isDiagnosing, isFalse);
      final Future<void> running =
          m.diagnoseAll(<SiteConfig>[_site(key: 'a', type: 2)]);
      expect(m.isDiagnosing, isTrue);
      await running;
      expect(m.isDiagnosing, isFalse);
      expect(m.results, hasLength(1));
    });
  });
}