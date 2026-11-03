/// 数据层单测：福利 Spider 脚本加载器（批次 H · H-03）。
///
/// 覆盖：四重校验、远程 URL 生成（绝对 / `sources/` / `welfare-js/`）、
/// GitHub 代理候选链、下载缓存与读回、空脚本拒绝、非 welfare_spider 拒绝。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/data/datasources/welfare/welfare_spider_loader.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';

/// 固定 manifest 地址（对齐 `RemoteSourceStrategy.defaultManifestUrl`）。
const String kManifest = 'https://vbox-ai.github.io/api/sources/manifest.json';

/// 构造一个合规的福利 Spider 平台。
WelfarePlatform spiderPlatform({String? api}) => WelfarePlatform(
      platformKey: 'welfare-spider-1',
      name: '福利蜘蛛甲',
      category: WelfarePlatformCategory.video,
      serviceType: 'welfare_spider',
      scriptType: 'python',
      api: api ?? './sources/welfare-js/welfare_spider_1.py',
      defaultHosts: const <String>['https://api.example.com'],
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('welfare_spider_loader');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  WelfareSpiderLoader loaderWith({
    MockClient? mock,
    String Function()? manifestUrl,
    String Function()? cacheRoot,
  }) =>
      WelfareSpiderLoader(
        client: HttpClient(inner: mock ?? MockClient((_) async => http.Response('body', 200))),
        cacheRootProvider: cacheRoot ?? () => tempDir.path,
        manifestUrlProvider: manifestUrl ?? () => kManifest,
      );

  group('四重校验（对齐 iOS `validate`）', () {
    test('非 welfare_spider 平台 → invalidServiceType', () async {
      const WelfarePlatform p = WelfarePlatform(
        platformKey: 'x',
        name: 'x',
        category: WelfarePlatformCategory.video,
        serviceType: 'kanliao',
        api: './sources/welfare-js/x.py',
      );
      try {
        await loaderWith().loadScript(p);
        fail('应当抛出 invalidServiceType');
      } on WelfareSpiderLoaderError catch (e) {
        expect(e, WelfareSpiderLoaderError.invalidServiceType);
      }
    });

    test('scriptType 不在白名单 → unsupportedScriptType', () async {
      final WelfarePlatform p = spiderPlatform().copyWith(scriptType: 'lua');
      try {
        await loaderWith().loadScript(p);
        fail('应当抛出 unsupportedScriptType');
      } on WelfareSpiderLoaderError catch (e) {
        expect(e, WelfareSpiderLoaderError.unsupportedScriptType);
      }
    });

    test('缺 api → missingAPI', () async {
      final WelfarePlatform p = spiderPlatform().copyWith(api: '   ');
      try {
        await loaderWith().loadScript(p);
        fail('应当抛出 missingAPI');
      } on WelfareSpiderLoaderError catch (e) {
        expect(e, WelfareSpiderLoaderError.missingAPI);
      }
    });

    test('脚本路径越界 → invalidScriptPath', () async {
      final WelfarePlatform p = spiderPlatform().copyWith(api: './sources/xxx.py');
      try {
        await loaderWith().loadScript(p);
        fail('应当抛出 invalidScriptPath');
      } on WelfareSpiderLoaderError catch (e) {
        expect(e, WelfareSpiderLoaderError.invalidScriptPath);
      }
    });
  });

  group('远程 URL 生成（对齐 iOS `makeRemoteURL`）', () {
    // 远程源为 GitHub 系域名（vbox-ai.github.io）→ 必然套代理链；
    // mock 仅对最终直连地址放行，其余候选返回 500，从而验证解析结果。
    Future<WelfareSpiderScript> loadResolved({
      required String api,
      required String expected,
    }) async {
      final List<Uri> urls = <Uri>[];
      final MockClient mock = MockClient((http.Request req) async {
        urls.add(req.url);
        return req.url.toString() == expected
            ? http.Response('body', 200)
            : http.Response('boom', 500);
      });
      final WelfareSpiderScript script =
          await loaderWith(mock: mock).loadScript(spiderPlatform(api: api));
      expect(urls.last.toString(), expected, reason: '降级链兜底应命中直连地址');
      return script;
    }

    test('绝对 URL 直用（含 sources/welfare-js/ 段，通过路径校验）', () async {
      await loadResolved(
        api: 'https://example.com/sources/welfare-js/abs.py',
        expected: 'https://example.com/sources/welfare-js/abs.py',
      );
    });

    test('sources/ 前缀相对 manifest 仓库根（剥离 ./ 与反斜杠）', () async {
      await loadResolved(
        api: r'.\sources\welfare-js\x.py',
        expected: 'https://vbox-ai.github.io/api/sources/welfare-js/x.py',
      );
    });

    test('welfare-js/ 前缀相对 sources 目录', () async {
      await loadResolved(
        api: 'welfare-js/y.js',
        expected: 'https://vbox-ai.github.io/api/sources/welfare-js/y.js',
      );
    });
  });

  group('代理候选链（对齐 iOS `proxyCandidateURLs`）', () {
    test('GitHub 系域名套 ghfast / gh-proxy 降级链', () async {
      final Set<String> hosts = <String>{};
      final MockClient mock = MockClient((http.Request req) async {
        hosts.add(req.url.host);
        // 仅直连放行，代理候选全部 500 → 验证降级到直连成功。
        if (req.url.host != 'vbox-ai.github.io') {
          return http.Response('boom', 500);
        }
        return http.Response('body', 200);
      });
      final WelfareSpiderScript script = await loaderWith(mock: mock).loadScript(
        spiderPlatform(),
      );
      expect(hosts, contains('ghfast.top'));
      expect(hosts, contains('gh-proxy.com'));
      expect(hosts, contains('vbox-ai.github.io'));
      expect(script.content, 'body');
    });

    test('非 GitHub 域名直连（不套代理）', () async {
      final Set<String> hosts = <String>{};
      final MockClient mock = MockClient((http.Request req) async {
        hosts.add(req.url.host);
        return http.Response('body', 200);
      });
      await loaderWith(
        mock: mock,
        manifestUrl: () => 'https://api.example.com/api/sources/manifest.json',
      ).loadScript(spiderPlatform(api: 'welfare-js/x.py'));
      expect(hosts, <String>{'api.example.com'});
    });
  });

  group('下载缓存（对齐 iOS `loadScript` / `cachedScript`）', () {
    test('loadScript 落盘缓存，cachedScript 可读回', () async {
      final WelfareSpiderLoader loader = loaderWith();
      final WelfarePlatform p = spiderPlatform();
      final WelfareSpiderScript script = await loader.loadScript(p);

      expect(script.platformKey, p.platformKey);
      expect(script.content, 'body');
      expect(script.localScriptPath, 'welfare-spider-1.py');
      expect(File(script.localURL).existsSync(), isTrue);

      final WelfareSpiderScript? cached = loader.cachedScript(p);
      expect(cached, isNotNull);
      expect(cached!.content, 'body');
    });

    test('JS 脚本缓存文件名带 .js 扩展名', () async {
      final WelfareSpiderLoader loader = loaderWith();
      final WelfarePlatform p =
          spiderPlatform(api: 'welfare-js/y.js').copyWith(scriptType: 'javascript');
      final WelfareSpiderScript script = await loader.loadScript(p);
      expect(script.localScriptPath, 'welfare-spider-1.js');
    });

    test('无缓存 → cachedScript 返回 null', () {
      final WelfareSpiderLoader loader = loaderWith();
      expect(loader.cachedScript(spiderPlatform()), isNull);
    });

    test('远程脚本内容为空 → emptyScript', () async {
      final WelfareSpiderLoader loader = loaderWith(
        mock: MockClient((_) async => http.Response('   ', 200)),
      );
      try {
        await loader.loadScript(spiderPlatform());
        fail('应当抛出 emptyScript');
      } on WelfareSpiderLoaderError catch (e) {
        expect(e, WelfareSpiderLoaderError.emptyScript);
      }
    });
  });
}
