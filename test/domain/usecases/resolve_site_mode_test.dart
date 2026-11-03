/// 领域层单测：站点模式判定用例（第 2 轮批次 B · B-04，验收口径「全分支用例」）。
///
/// 对齐 iOS `SpiderManager.resolveSiteMode` / `isNodeSite` /
/// `registerNodeEngine` 的 lx 分流（NodeSpiderEngine.lxKeyMap 白名单）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/engine_type.dart';
import 'package:vbox/domain/entities/spider/site_config.dart';
import 'package:vbox/domain/usecases/resolve_site_mode.dart';

SiteConfig _site({
  required String key,
  required int type,
  String? api,
  String? group,
  String? engineType,
  String name = '站点',
}) =>
    SiteConfig(
      key: key,
      name: name,
      type: type,
      api: api,
      group: group,
      engineType: engineType,
    );

void main() {
  const ResolveSiteModeUseCase useCase = ResolveSiteModeUseCase();

  test('构造函数可在运行时非 const 实例化（lcov 覆盖回归）', () {
    // 故意使用非 const 实例化：const 上下文的实例化不产生运行时构造调用，
    // 无法覆盖 `const ResolveSiteModeUseCase()` 构造行（lcov 覆盖回归）。
    // ignore: prefer_const_constructors
    final ResolveSiteModeUseCase runtime = ResolveSiteModeUseCase();
    expect(runtime, isA<ResolveSiteModeUseCase>());
  });

  group('B-04 · 常规 type 分流（iOS resolveSiteMode switch）', () {
    test('type 0 → apiEndpoint，无引擎', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'a', type: 0, api: 'https://example.com/api.php'),
      );
      expect(r.mode, SiteMode.apiEndpoint);
      expect(r.isNodeHosted, isFalse);
      expect(r.engineType, isNull);
    });

    test('type 1 → apiEndpoint', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'a', type: 1, api: 'https://example.com/api.php'),
      );
      expect(r.mode, SiteMode.apiEndpoint);
    });

    test('type 2 → zhanyuan（站源）', () {
      final ResolvedSiteMode r = useCase(_site(key: 'zy', type: 2, api: './x.js'));
      expect(r.mode, SiteMode.zhanyuan);
      expect(r.engineType, isNull);
    });

    test('type 3 + .jar → unsupported', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'jar', type: 3, api: 'https://example.com/sp.jar'),
      );
      expect(r.mode, SiteMode.unsupported);
      expect(r.engineType, isNull);
    });

    test('type 3 + .py → pythonSpider + python 引擎', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'py', type: 3, api: './spider.py'),
      );
      expect(r.mode, SiteMode.pythonSpider);
      expect(r.engineType, SpiderEngineType.python);
    });

    test('type 3 + http .js → jsSpider + JSC 主引擎（D6）', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'js', type: 3, api: 'https://example.com/spider.js'),
      );
      expect(r.mode, SiteMode.jsSpider);
      expect(r.engineType, SpiderEngineType.javaScriptCore);
    });

    test('type 3 + http 非 .js → apiEndpoint（HTTP API 双模式）', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'httpapi', type: 3, api: 'https://example.com/provide/vod'),
      );
      expect(r.mode, SiteMode.apiEndpoint);
      expect(r.engineType, isNull);
    });

    test('type 3 + 相对路径 ./x.js 或纯文件名 → jsSpider', () {
      expect(
        useCase(_site(key: 'js1', type: 3, api: './lib/spider.js')).mode,
        SiteMode.jsSpider,
      );
      expect(
        useCase(_site(key: 'js2', type: 3, api: 'spider.js')).mode,
        SiteMode.jsSpider,
      );
    });

    test('type 3 + 纯类名（非 csp_/nodejs_）→ unsupported', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'SomeClass', type: 3, api: 'SomeClass'),
      );
      expect(r.mode, SiteMode.unsupported);
    });

    test('api 为空 → unsupported', () {
      final ResolvedSiteMode r = useCase(_site(key: 'x', type: 3));
      expect(r.mode, SiteMode.unsupported);
    });

    test('未知 type（如 4）→ unsupported', () {
      expect(useCase(_site(key: 'x', type: 4, api: 'a.js')).mode,
          SiteMode.unsupported);
    });
  });

  group('B-04 · Node 托管蜘蛛识别（双保险，对齐 iOS isNodeSite）', () {
    test('group == "node" → node', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'anything', type: 3, api: 'https://a.com/x', group: 'node'),
      );
      expect(r.mode, SiteMode.node);
      expect(r.isNodeHosted, isTrue);
      expect(r.engineType, SpiderEngineType.node);
    });

    test('key 前缀 nodejs_ → node', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'nodejs_video', type: 3, api: 'http://127.0.0.1:58080/spider/x'),
      );
      expect(r.isNodeHosted, isTrue);
      expect(r.engineType, SpiderEngineType.node);
    });

    test('key 前缀 csp_ 且 type==3 → node（TVBox 蜘蛛类名形态）', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'csp_Douban', type: 3, api: 'csp_Douban'),
      );
      expect(r.isNodeHosted, isTrue);
      expect(r.engineType, SpiderEngineType.node);
    });

    test('api 前缀 nodejs_ → node（兼容直链形态）', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'k', type: 3, api: 'nodejs_something'),
      );
      expect(r.isNodeHosted, isTrue);
    });

    test('api 指向本地 Node 路由 http://127.0.0.1:PORT/spider/ → node', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'k', type: 0, api: 'http://127.0.0.1:58080/spider/demo'),
      );
      expect(r.isNodeHosted, isTrue);
      expect(r.mode, SiteMode.node);
    });

    test('csp_ 但 type != 3 → 不按 Node 处理（type 1 → apiEndpoint）', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'csp_X', type: 1, api: 'https://example.com/api'),
      );
      expect(r.isNodeHosted, isFalse);
      expect(r.mode, SiteMode.apiEndpoint);
    });
  });

  group('B-04 · lx-music 分流（A2，白名单式识别）', () {
    test('engineType == lxMusic → nodeLX', () {
      final ResolvedSiteMode r = useCase(
        _site(
          key: 'nodejs_music',
          type: 3,
          api: 'http://127.0.0.1:58080/spider/m',
          engineType: 'lxMusic',
        ),
      );
      expect(r.mode, SiteMode.node);
      expect(r.engineType, SpiderEngineType.nodeLX);
    });

    test('lx 白名单 key（nodejs_musicaidaxe / nodejs_musicainianxin）→ nodeLX', () {
      expect(
        useCase(_site(key: 'nodejs_musicaidaxe', type: 3)).engineType,
        SpiderEngineType.nodeLX,
      );
      expect(
        useCase(_site(key: 'nodejs_musicainianxin', type: 3)).engineType,
        SpiderEngineType.nodeLX,
      );
    });

    test('非白名单 nodejs_ key → node（防误判：api 含 lx 不分流）', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'nodejs_kstore', type: 3, api: 'http://127.0.0.1:1/spider/lx'),
      );
      expect(r.engineType, SpiderEngineType.node);
    });

    test('白名单常量与 iOS lxKeyMap 键集一致', () {
      expect(ResolveSiteModeUseCase.lxMusicKeyMap, <String, String>{
        'nodejs_musicaidaxe': 'daxe',
        'nodejs_musicainianxin': 'nianxin',
      });
    });
  });

  group('B-04 · enableDualMode 双模式开关（关闭回到旧逻辑）', () {
    test('关闭 + type 3 + http .js → jsSpider（可加载）', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'js', type: 3, api: 'https://example.com/s.js'),
        enableDualMode: false,
      );
      expect(r.mode, SiteMode.jsSpider);
    });

    test('关闭 + type 3 + 纯类名 → unsupported（不做 HTTP API 细分）', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'SomeClass', type: 3, api: 'SomeClass'),
        enableDualMode: false,
      );
      expect(r.mode, SiteMode.unsupported);
    });

    test('关闭 + type 3 + http 非 .js → jsSpider（旧逻辑一律尝试加载 JS）', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'httpapi', type: 3, api: 'https://example.com/provide/vod'),
        enableDualMode: false,
      );
      expect(r.mode, SiteMode.jsSpider);
    });

    test('关闭 + type 3 + .jar → unsupported', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'j', type: 3, api: 'https://example.com/x.jar'),
        enableDualMode: false,
      );
      expect(r.mode, SiteMode.unsupported);
    });

    test('Node 识别不受开关影响（优先级最高，独立于 type 分支）', () {
      final ResolvedSiteMode r = useCase(
        _site(key: 'nodejs_x', type: 3),
        enableDualMode: false,
      );
      expect(r.mode, SiteMode.node);
      expect(r.isNodeHosted, isTrue);
    });
  });
}
