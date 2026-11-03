/// 领域层单测：福利 Spider 脚本状态服务（批次 H · H-03）。
///
/// 对齐 iOS `WelfareSpiderService.swift`：
/// 覆盖状态机（idle / loading / loaded / failed）、缓存恢复、重载成功与失败、
/// 脚本预览（前 28 行）、本地缓存文件名、当前域名与状态标题。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/welfare/welfare_spider_loader.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';
import 'package:vbox/domain/services/welfare_spider_service.dart';

/// 构造一个合规的福利 Spider 平台。
WelfarePlatform _platform() => const WelfarePlatform(
      platformKey: 'missav',
      name: 'MissAV',
      category: WelfarePlatformCategory.video,
      serviceType: 'welfare_spider',
      scriptType: 'javascript',
      api: './sources/welfare-js/missav.js',
      defaultHosts: <String>[
        'https://a.example.com',
        'https://b.example.com',
      ],
    );

/// 固定脚本（40 行，验证预览只取前 28 行）。
WelfareSpiderScript _script() => WelfareSpiderScript(
      platformKey: 'missav',
      remoteURL: Uri.parse(
          'https://vbox-ai.github.io/api/sources/welfare-js/missav.js'),
      localURL: '/cache/welfare_spider/missav.js',
      content:
          List<String>.generate(40, (int i) => 'line${i + 1}').join('\n'),
      loadedAt: DateTime(2026, 1, 1),
    );

/// 内存假加载器（重写 `loadScript` / `cachedScript`，不做真实 IO）。
class _FakeLoader extends WelfareSpiderLoader {
  _FakeLoader({this.script, this.failWith, this.cacheReturns = true});

  final WelfareSpiderScript? script;
  final Object? failWith;

  /// 是否让 `cachedScript` 返回脚本（`false` 模拟无缓存）。
  final bool cacheReturns;

  int loadCount = 0;

  @override
  Future<WelfareSpiderScript> loadScript(WelfarePlatform platform) async {
    loadCount++;
    final Object? f = failWith;
    if (f != null) throw f;
    return script!;
  }

  @override
  WelfareSpiderScript? cachedScript(WelfarePlatform platform) =>
      cacheReturns ? script : null;
}

void main() {
  group('初始状态', () {
    test('无缓存 → idle，脚本 / 预览 / 缓存文件均为空', () {
      final WelfareSpiderService service = WelfareSpiderService(
        platform: _platform(),
        loader: _FakeLoader(script: null, cacheReturns: false),
      );
      expect(service.state, WelfareSpiderLoadState.idle);
      expect(service.script, isNull);
      expect(service.scriptPreview, isNull);
      expect(service.localScriptPath, isNull);
      expect(service.errorMessage, isNull);
      // currentDomain 优先首个默认域（对齐 iOS `currentDomain` 回退语义）。
      expect(service.currentDomain, 'https://a.example.com');
    });

    test('有缓存 → 构造即恢复 loaded（对齐 iOS init 恢复态）', () {
      final WelfareSpiderService service = WelfareSpiderService(
        platform: _platform(),
        loader: _FakeLoader(script: _script()),
      );
      expect(service.state, WelfareSpiderLoadState.loaded);
      expect(service.script, isNotNull);
      expect(service.localScriptPath, 'missav.js');
    });
  });

  group('reload', () {
    test('成功：loading → loaded，预览取前 28 行，缓存文件名可读', () async {
      final _FakeLoader loader = _FakeLoader(script: _script());
      final WelfareSpiderService service =
          WelfareSpiderService(platform: _platform(), loader: loader);
      final List<WelfareSpiderLoadState> transitions =
          <WelfareSpiderLoadState>[];
      service.addListener(() => transitions.add(service.state));

      final Future<void> done = service.reload();
      // 同步先置 loading（对齐 iOS `reload()` 先发布 loading 态）。
      expect(service.state, WelfareSpiderLoadState.loading);
      await done;

      expect(loader.loadCount, 1);
      expect(service.state, WelfareSpiderLoadState.loaded);
      expect(service.errorMessage, isNull);
      expect(
        service.scriptPreview,
        List<String>.generate(28, (int i) => 'line${i + 1}').join('\n'),
      );
      expect(service.localScriptPath, 'missav.js');
      expect(transitions, contains(WelfareSpiderLoadState.loading));
      expect(transitions.last, WelfareSpiderLoadState.loaded);
      service.dispose();
    });

    test('失败：loading → failed，错误信息可见且脚本清空', () async {
      final WelfareSpiderService service = WelfareSpiderService(
        platform: _platform(),
        loader: _FakeLoader(
          failWith: WelfareSpiderLoaderError.fetchFailed,
          cacheReturns: false,
        ),
      );
      await service.reload();
      expect(service.state, WelfareSpiderLoadState.failed);
      expect(service.script, isNull);
      expect(service.errorMessage, isNotNull);
      expect(service.errorMessage, contains('下载失败'));
      service.dispose();
    });

    test('非枚举异常 → 透传为失败信息', () async {
      final WelfareSpiderService service = WelfareSpiderService(
        platform: _platform(),
        loader: _FakeLoader(failWith: StateError('boom'), cacheReturns: false),
      );
      await service.reload();
      expect(service.state, WelfareSpiderLoadState.failed);
      expect(service.errorMessage, contains('boom'));
      service.dispose();
    });
  });

  group('状态标题（对齐 iOS `LoadState.title`）', () {
    test('四态标题一致', () {
      expect(WelfareSpiderLoadState.idle.title, '未加载');
      expect(WelfareSpiderLoadState.loading.title, '正在加载脚本');
      expect(WelfareSpiderLoadState.loaded.title, '脚本已缓存');
      expect(WelfareSpiderLoadState.failed.title, '脚本加载失败');
    });
  });
}
