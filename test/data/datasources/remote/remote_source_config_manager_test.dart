/// 数据层单测：远程源配置管理器（第 2 轮批次 B · B-01 / B-02 / B-03）。
///
/// 覆盖 iOS `RemoteSourceConfigManager.syncIfNeeded` 五级状态机全分支：
/// 开关 / 空地址 / App 升级 / 版本探测（未变不进全量）/ 降级 TTL，
/// 以及代理降级链（B-02）、6 合 1 聚合解析（B-03）、兼容门控、契约键镜像。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/remote/all_sources_datasource.dart';
import 'package:vbox/data/datasources/remote/remote_manifest_datasource.dart';
import 'package:vbox/data/datasources/remote/remote_source_config_manager.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/repositories/remote_source_repository.dart';

const String _version = '2026.09.30.1';
const String _nowVersion = '2026.10.01.2';
const int _now = 1000000;
const String _appVer = '3.1656.0';

/// 按请求路径分发的 MockClient（记录每个 URL 的命中次数）。
class _Router {
  _Router(this.routes);

  final Map<String, http.Response> routes;
  final Map<String, int> hits = <String, int>{};

  bool called(String url) => (hits[url] ?? 0) > 0;
  int times(String url) => hits[url] ?? 0;

  http.Client client() => MockClient((http.Request r) async {
        hits[r.url.toString()] = (hits[r.url.toString()] ?? 0) + 1;
        for (final MapEntry<String, http.Response> e in routes.entries) {
          if (r.url.toString().endsWith(e.key)) return e.value;
        }
        return http.Response('{"error":"not found"}', 404);
      });
}

http.Response _json(Object? body, [int status = 200]) => http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );

Map<String, Object?> _manifestJson({
  String version = _version,
  String? minAppVersion,
  List<String> disabledKeys = const <String>[],
  Map<String, String> extraFiles = const <String, String>{},
  bool forceRefresh = false,
}) =>
    <String, Object?>{
      'schemaVersion': 1,
      'configVersion': version,
      'ttlSeconds': 21600,
      'forceRefresh': forceRefresh,
      'disabledKeys': disabledKeys,
      'files': <String, String>{
        'allSources': 'https://example.com/all_sources.json',
        ...extraFiles,
      },
      if (minAppVersion != null) 'minAppVersion': minAppVersion,
    };

const Map<String, Object?> _allSourcesJson = <String, Object?>{
  'apiSources': <String, Object?>{
    'sites': <Object?>[
      <String, Object?>{'key': 'api_苹果', 'name': '苹果CMS', 'type': 1},
    ],
  },
  'spiderSources': <String, Object?>{
    'sites': <Object?>[
      <String, Object?>{'key': 'nodejs_demo', 'name': 'Node 演示', 'type': 3},
      <String, Object?>{'key': 'api_苹果', 'name': '重复 key', 'type': 0},
      <String, Object?>{'key': '', 'name': '空 key', 'type': 0},
      <String, Object?>{'key': 'js_演示', 'name': 'JS 演示', 'type': 3},
    ],
  },
  // 契约：parsers / disabledSources 为**对象**（非数组）；回归覆盖真实
  // all_sources.json 结构，防止 `as List?` 型转换崩溃（UnknownFailure）。
  'parsers': <String, Object?>{
    'parses': <Object?>[
      <String, Object?>{
        'name': '远程解析',
        'url': 'https://parse.example.com/?url=',
      },
    ],
  },
  'disabledSources': <String, Object?>{
    'disabledKeys': <Object?>[],
    'disabledHosts': <Object?>[],
  },
};

/// 内存版远程源仓储（镜像真实现：saveManifest 落契约同步键）。
class _FakeRepo implements RemoteSourceRepository {
  RemoteManifest? saved;
  int savedAt = 0;
  bool failSave = false;

  @override
  Future<Result<RemoteManifest>> fetchManifest({bool forceRefresh = false}) async =>
      const Err<RemoteManifest>(UnknownFailure('manager 不经仓储拉取'));

  @override
  Future<Result<RemoteManifest?>> cachedManifest() async =>
      Success<RemoteManifest?>(saved);

  @override
  Future<Result<bool>> saveManifest(RemoteManifest manifest) async {
    if (failSave) return const Err<bool>(UnknownFailure('落盘失败'));
    saved = manifest;
    savedAt = _now;
    await PrefsManager.instance
        .set('remote_default_last_config_version', manifest.configVersion);
    await PrefsManager.instance.set('remote_default_last_sync_time', _now);
    return const Success<bool>(true);
  }

  @override
  Future<Result<bool>> needsRefresh(int nowSeconds) async =>
      Success<bool>(saved == null || nowSeconds - savedAt >= 21600);

  @override
  Future<Result<int>> cachedAtSeconds() async => Success<int>(savedAt);

  @override
  Future<Result<RemoteSourceSettings>> settings() async =>
      const Success<RemoteSourceSettings>(RemoteSourceSettings.defaults());

  @override
  Future<Result<bool>> setEnabled(bool enabled) async =>
      const Success<bool>(true);

  @override
  Future<Result<bool>> setManifestUrl(String url) async =>
      const Success<bool>(true);

  @override
  Future<Result<bool>> clearCache() async {
    saved = null;
    savedAt = 0;
    return const Success<bool>(true);
  }
}

/// 全绿服务器：manifest / version / allSources 均可用。
_Router _okRouter() => _Router(<String, http.Response>{
      '/manifest.json': _json(_manifestJson()),
      '/manifest.version': _json(<String, Object?>{'configVersion': _version}),
      '/all_sources.json': _json(_allSourcesJson),
    });

RemoteSourceConfigManager _manager(
  _Router router, {
  required _FakeRepo repo,
  List<ProxyHost> proxies = RemoteSourceStrategy.proxyHosts,
}) =>
    RemoteSourceConfigManager(
      manifestDatasource: RemoteManifestDatasource(
        client: HttpClient(inner: router.client(), maxRetries: 0),
      ),
      allSourcesDatasource: AllSourcesDatasource(
        client: HttpClient(inner: router.client(), maxRetries: 0),
      ),
      repository: repo,
      probeClient: HttpClient(inner: router.client(), maxRetries: 0),
      appVersion: () => _appVer,
      nowSeconds: () => _now,
      proxies: proxies,
    );

Future<void> _presetSyncedState({String version = _version, int? syncAt}) async {
  final PrefsManager p = PrefsManager.instance;
  await p.set('remote_default_source_enabled', true);
  await p.set('remote_default_manifest_url', 'https://example.com/manifest.json');
  await p.set('remote_default_last_config_version', version);
  await p.set('remote_default_last_sync_time', syncAt ?? _now);
  await p.set('remote_default_last_sync_app_version', _appVer);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await PrefsManager.instance.init();
  });

  setUp(() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.clear();
  });

  group('syncIfNeeded 状态机（对齐 iOS syncIfNeeded 五级分支）', () {
    test('① 开关关闭 → skippedDisabled，不发起任何网络请求，回退缓存', () async {
      final _Router router = _okRouter();
      final _FakeRepo repo = _FakeRepo()
        ..saved = RemoteManifest.fromJson(_manifestJson());
      await PrefsManager.instance.set('remote_default_source_enabled', false);
      await PrefsManager.instance
          .set('remote_default_manifest_url', 'https://example.com/manifest.json');

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncIfNeeded();

      expect(r.action, RemoteSourceSyncAction.skippedDisabled);
      expect(router.hits, isEmpty);
      expect(r.status.state, RemoteLoadState.loadedCache);
      expect(r.manifest, isNotNull);
    });

    test('② 地址留空 → skippedEmptyUrl，不联网', () async {
      final _Router router = _okRouter();
      await PrefsManager.instance.set('remote_default_source_enabled', true);
      await PrefsManager.instance.set('remote_default_manifest_url', '');

      final RemoteSourceSyncResult r =
          await _manager(router, repo: _FakeRepo()).syncIfNeeded();

      expect(r.action, RemoteSourceSyncAction.skippedEmptyUrl);
      expect(router.hits, isEmpty);
    });

    test('③ App 版本变化 → appVersionChanged，强制全量（B-01 兼容门控前置分支）', () async {
      final _Router router = _okRouter();
      final _FakeRepo repo = _FakeRepo();
      await _presetSyncedState();
      await PrefsManager.instance
          .set('remote_default_last_sync_app_version', '3.1000.0');

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncIfNeeded();

      expect(r.action, RemoteSourceSyncAction.appVersionChanged);
      expect(r.didFullSync, isTrue);
      // 版本探测被跳过（强制刷新优先）
      expect(router.called('https://example.com/manifest.version'), isFalse);
    });

    test('④ 从未同步（lastSyncTime=0）→ firstSync 全量', () async {
      final _Router router = _okRouter();
      final _FakeRepo repo = _FakeRepo();
      await PrefsManager.instance.set('remote_default_source_enabled', true);
      await PrefsManager.instance
          .set('remote_default_manifest_url', 'https://example.com/manifest.json');
      await PrefsManager.instance.set('remote_default_last_sync_time', 0);

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncIfNeeded();

      expect(r.action, RemoteSourceSyncAction.firstSync);
      expect(r.didFullSync, isTrue);
    });

    test('⑤ 版本探测一致 → versionUnchanged，不进全量（B-01 核心验收）', () async {
      final _Router router = _okRouter();
      final _FakeRepo repo = _FakeRepo();
      await _presetSyncedState();

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncIfNeeded();

      expect(r.action, RemoteSourceSyncAction.versionUnchanged);
      // 只探测了 version（30 字节级），没拉 manifest 全量，也没拉 allSources
      expect(router.times('https://example.com/manifest.version'), 1);
      expect(router.called('https://example.com/manifest.json'), isFalse);
      expect(router.called('https://example.com/all_sources.json'), isFalse);
      expect(r.sites, isEmpty);
    });

    test('⑥ 版本探测变化 → versionChanged，全量同步 + 契约键镜像', () async {
      final _Router router = _Router(<String, http.Response>{
        '/manifest.json': _json(_manifestJson(version: _nowVersion, extraFiles: <String, String>{
          'nodeRuntimeBundle': 'https://example.com/node/bundle.zip',
          'nodeRuntimeBundleVer': 'v2026.10.01',
        })),
        '/manifest.version': _json(<String, Object?>{'configVersion': _nowVersion}),
        '/all_sources.json': _json(_allSourcesJson),
      });
      final _FakeRepo repo = _FakeRepo();
      await _presetSyncedState();

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncIfNeeded();

      expect(r.action, RemoteSourceSyncAction.versionChanged);
      expect(r.didFullSync, isTrue);
      expect(r.status.state, RemoteLoadState.loadedRemote);
      expect(r.status.version, _nowVersion);

      // 契约同步键镜像（_group_remote_source 9 键中本管理器管理的 8 键）
      final PrefsManager p = PrefsManager.instance;
      expect(await p.get('remote_default_last_config_version'), _nowVersion);
      expect(await p.get('remote_default_last_sync_app_version'), _appVer);
      expect(await p.get('remote_default_last_sync_error'), isNull);
      expect(await p.get('remote_node_bundle_url'), 'https://example.com/node/bundle.zip');
      expect(await p.get('remote_node_bundle_ver'), 'v2026.10.01');
    });

    test('⑦ 探测失败 + TTL 未过期 → probeFailedUpToDate，用缓存不联网', () async {
      final _Router router = _okRouter();
      // version 探测 500 → 降级 TTL
      router.routes['/manifest.version'] = _json(<String, Object?>{}, 500);
      final _FakeRepo repo = _FakeRepo()
        ..saved = RemoteManifest.fromJson(_manifestJson());
      await _presetSyncedState(); // syncAt = now → TTL 未过期

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncIfNeeded();

      expect(r.action, RemoteSourceSyncAction.probeFailedUpToDate);
      expect(router.called('https://example.com/manifest.json'), isFalse);
      expect(r.status.state, RemoteLoadState.loadedCache);
    });

    test('⑧ 探测失败 + TTL 过期 → probeFailedTtlExpired，全量同步', () async {
      final _Router router = _okRouter();
      router.routes['/manifest.version'] = _json(<String, Object?>{}, 500);
      final _FakeRepo repo = _FakeRepo();
      // syncAt = now - 21600 - 1 → 已过 TTL
      await _presetSyncedState(syncAt: _now - 21601);

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncIfNeeded();

      expect(r.action, RemoteSourceSyncAction.probeFailedTtlExpired);
      expect(r.didFullSync, isTrue);
    });

    test('⑧b 缓存清单自带 forceRefresh=true → 视为过期，全量同步（对齐 iOS shouldRefresh）', () async {
      final _Router router = _okRouter();
      router.routes['/manifest.version'] = _json(<String, Object?>{}, 500);
      final _FakeRepo repo = _FakeRepo()
        ..saved = RemoteManifest.fromJson(
          _manifestJson(forceRefresh: true),
        );
      await _presetSyncedState(syncAt: _now); // 时间未过期，但 forceRefresh

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncIfNeeded();

      expect(r.action, RemoteSourceSyncAction.probeFailedTtlExpired);
    });

    test('⑨ force=true → forceRefresh 全量（跳过探测）', () async {
      final _Router router = _okRouter();
      final _FakeRepo repo = _FakeRepo();
      await _presetSyncedState();

      final RemoteSourceSyncResult r =
          await _manager(router, repo: repo).syncIfNeeded(force: true);

      expect(r.action, RemoteSourceSyncAction.forceRefresh);
      expect(r.didFullSync, isTrue);
      expect(router.called('https://example.com/manifest.version'), isFalse);
    });
  });

  group('B-02 代理降级链（仅 GitHub 域名，主代理 → 备用代理 → 直连）', () {
    test('GitHub manifest：主代理 500 → 备用代理成功', () async {
      final List<String> requests = <String>[];
      final _Router router = _Router(<String, http.Response>{});
      final http.Client counting = MockClient((http.Request r) async {
        final String u = r.url.toString();
        requests.add(u);
        if (u == 'https://ghfast.top/https://github.com/x/manifest.json') {
          return _json(<String, Object?>{}, 500);
        }
        if (u == 'https://gh-proxy.com/https://github.com/x/manifest.json') {
          return _json(_manifestJson(version: _nowVersion));
        }
        if (u.endsWith('/all_sources.json')) return _json(_allSourcesJson);
        return _json(<String, Object?>{}, 404);
      });
      final RemoteSourceConfigManager manager = RemoteSourceConfigManager(
        manifestDatasource: RemoteManifestDatasource(
          client: HttpClient(inner: counting, maxRetries: 0),
        ),
        allSourcesDatasource: AllSourcesDatasource(
          client: HttpClient(inner: counting, maxRetries: 0),
        ),
        repository: _FakeRepo(),
        probeClient: HttpClient(inner: counting, maxRetries: 0),
        appVersion: () => _appVer,
        nowSeconds: () => _now,
      );
      await PrefsManager.instance.set('remote_default_source_enabled', true);
      await PrefsManager.instance
          .set('remote_default_manifest_url', 'https://github.com/x/manifest.json');
      router.toString(); // keep analyzer satisfied

      final RemoteSourceSyncResult r = await manager.syncNow();

      expect(r.action, RemoteSourceSyncAction.synced);
      // 主代理先试、失败后备代理接管，未走直连
      expect(requests.first, 'https://ghfast.top/https://github.com/x/manifest.json');
      expect(requests, contains('https://gh-proxy.com/https://github.com/x/manifest.json'));
      expect(requests, isNot(contains('https://github.com/x/manifest.json')));
    });

    test('非 GitHub 域名 → 直连（不套代理，对齐 iOS isGitHubDomain）', () async {
      final List<String> requests = <String>[];
      final http.Client counting = MockClient((http.Request r) async {
        final String u = r.url.toString();
        requests.add(u);
        if (u.endsWith('/manifest.json')) return _json(_manifestJson());
        if (u.endsWith('/all_sources.json')) return _json(_allSourcesJson);
        return _json(<String, Object?>{}, 404);
      });
      final RemoteSourceConfigManager manager = RemoteSourceConfigManager(
        manifestDatasource: RemoteManifestDatasource(
          client: HttpClient(inner: counting, maxRetries: 0),
        ),
        allSourcesDatasource: AllSourcesDatasource(
          client: HttpClient(inner: counting, maxRetries: 0),
        ),
        repository: _FakeRepo(),
        probeClient: HttpClient(inner: counting, maxRetries: 0),
        appVersion: () => _appVer,
        nowSeconds: () => _now,
      );
      await PrefsManager.instance.set('remote_default_source_enabled', true);
      await PrefsManager.instance
          .set('remote_default_manifest_url', 'https://example.com/manifest.json');

      final RemoteSourceSyncResult r = await manager.syncNow();

      expect(r.action, RemoteSourceSyncAction.synced);
      expect(
        requests.where((String u) => u.contains('ghfast.top')).toList(),
        isEmpty,
      );
    });

    test('candidates：GitHub → [主代理, 备代理, 第三镜像, 直连]；非 GitHub → [直连]；可配置常量注入空链 → 直连', () {
      const String gh = 'https://raw.githubusercontent.com/x/y.json';
      expect(RemoteSourceStrategy.candidates(gh), <String>[
        'https://ghfast.top/$gh',
        'https://gh-proxy.com/$gh',
        'https://ghproxy.link/$gh',
        gh,
      ]);
      expect(RemoteSourceStrategy.isGithubHost('vbox-ai.github.io'), isTrue);
      expect(RemoteSourceStrategy.isGithubHost('github.com'), isTrue);
      expect(RemoteSourceStrategy.isGithubHost('example.com'), isFalse);
      expect(
        RemoteSourceStrategy.candidates(gh, proxies: const <ProxyHost>[]),
        <String>[gh],
      );
      expect(
        RemoteSourceStrategy.candidates('https://example.com/a.json'),
        <String>['https://example.com/a.json'],
      );
    });
  });

  group('B-03 6 合 1 聚合解析', () {
    test('apiSources + spiderSources 合并；空 key 剔除；disabledKeys 剔除；key 去重首见优先', () {
      final AllSourcesContainer container =
          AllSourcesContainer.fromJson(_allSourcesJson);
      final List<Map<String, Object?>> sites = RemoteSourceConfigManager
          .aggregateSites(container, disabledKeys: <String>['js_演示']);

      expect(sites.map((Map<String, Object?> s) => s['key']).toList(), <String>[
        'api_苹果',
        'nodejs_demo',
      ]);
      // 首见优先：重复 key 保留 apiSources 的原始配置
      expect(sites.first['name'], '苹果CMS');
    });

    test('全量同步结果携带聚合站点（synced 时 sites 非空）', () async {
      final _Router router = _okRouter();
      final _FakeRepo repo = _FakeRepo();
      await PrefsManager.instance.set('remote_default_source_enabled', true);
      await PrefsManager.instance
          .set('remote_default_manifest_url', 'https://example.com/manifest.json');

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncNow();

      expect(r.didFullSync, isTrue);
      // _okRouter 的 manifest 未声明 disabledKeys → 3 个有效站点全量聚合
      expect(r.sites, hasLength(3));
      expect(r.sites.first['key'], 'api_苹果');
    });
  });

  group('兼容门控与失败路径', () {
    test('minAppVersion 高于当前版本 → incompatibleMinAppVersion，拒绝同步并落盘错误', () async {
      final _Router router = _Router(<String, http.Response>{
        '/manifest.json': _json(_manifestJson(minAppVersion: '9.9.9')),
        '/manifest.version': _json(<String, Object?>{'configVersion': _version}),
        '/all_sources.json': _json(_allSourcesJson),
      });
      final _FakeRepo repo = _FakeRepo();
      await PrefsManager.instance.set('remote_default_source_enabled', true);
      await PrefsManager.instance
          .set('remote_default_manifest_url', 'https://example.com/manifest.json');

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncNow();

      expect(r.action, RemoteSourceSyncAction.incompatibleMinAppVersion);
      expect(router.called('https://example.com/all_sources.json'), isFalse);
      expect(r.error, contains('minAppVersion'));
      expect(
        await PrefsManager.instance.get('remote_default_last_sync_error'),
        contains('minAppVersion'),
      );
    });

    test('minAppVersion 不高于当前版本 → 正常同步', () async {
      final _Router router = _Router(<String, http.Response>{
        '/manifest.json': _json(_manifestJson(minAppVersion: '1.0.0')),
        '/manifest.version': _json(<String, Object?>{'configVersion': _version}),
        '/all_sources.json': _json(_allSourcesJson),
      });
      final _FakeRepo repo = _FakeRepo();
      await PrefsManager.instance.set('remote_default_source_enabled', true);
      await PrefsManager.instance
          .set('remote_default_manifest_url', 'https://example.com/manifest.json');

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncNow();

      expect(r.action, RemoteSourceSyncAction.synced);
    });

    test('manifest 全通道失败 → syncFailed + last_sync_error 落盘 + 缓存兜底', () async {
      final _Router router = _Router(<String, http.Response>{
        '/manifest.json': _json(<String, Object?>{}, 500),
      });
      final _FakeRepo repo = _FakeRepo()
        ..saved = RemoteManifest.fromJson(_manifestJson());
      await PrefsManager.instance.set('remote_default_source_enabled', true);
      await PrefsManager.instance
          .set('remote_default_manifest_url', 'https://example.com/manifest.json');

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncNow();

      expect(r.action, RemoteSourceSyncAction.syncFailed);
      expect(r.error, isNotNull);
      expect(r.status.state, RemoteLoadState.failed);
      // 失败但缓存仍可用（降级可用）
      expect(r.manifest?.configVersion, _version);
      expect(
        await PrefsManager.instance.get('remote_default_last_sync_error'),
        isNotNull,
      );
    });

    test('allSources 拉取失败 → syncFailed', () async {
      final _Router router = _Router(<String, http.Response>{
        '/manifest.json': _json(_manifestJson()),
        '/all_sources.json': _json(<String, Object?>{}, 500),
      });
      final _FakeRepo repo = _FakeRepo();
      await PrefsManager.instance.set('remote_default_source_enabled', true);
      await PrefsManager.instance
          .set('remote_default_manifest_url', 'https://example.com/manifest.json');

      final RemoteSourceSyncResult r = await _manager(router, repo: repo).syncNow();

      expect(r.action, RemoteSourceSyncAction.syncFailed);
      expect(r.error, contains('allSources'));
    });
  });

  group('versionProbeUrlFor 派生规则（对齐 iOS checkManifestVersion）', () {
    test('…/manifest.json → …/manifest.version；其余 → <url>.version', () {
      expect(
        RemoteSourceConfigManager.versionProbeUrlFor(
            'https://vbox-ai.github.io/api/sources/manifest.json'),
        'https://vbox-ai.github.io/api/sources/manifest.version',
      );
      expect(
        RemoteSourceConfigManager.versionProbeUrlFor('https://example.com/cfg'),
        'https://example.com/cfg.version',
      );
    });
  });

  group('cachedNodeBundle*（ND-02 远端增量刷新地址，对齐 iOS cachedNodeBundleRefreshURL）',
      () {
    test('未写入 / 空串 → null；写入 → 返回去空格值', () async {
      expect(await RemoteSourceConfigManager.cachedNodeBundleRefreshUrl(), isNull);
      expect(await RemoteSourceConfigManager.cachedNodeBundleVersionUrl(), isNull);

      await PrefsManager.instance
          .set('remote_node_bundle_url', '  https://cdn/kstore_index.js  ');
      await PrefsManager.instance
          .set('remote_node_bundle_ver', 'https://cdn/kstore_index.version');
      expect(
        await RemoteSourceConfigManager.cachedNodeBundleRefreshUrl(),
        'https://cdn/kstore_index.js',
      );
      expect(
        await RemoteSourceConfigManager.cachedNodeBundleVersionUrl(),
        'https://cdn/kstore_index.version',
      );

      await PrefsManager.instance.set('remote_node_bundle_url', '   ');
      expect(await RemoteSourceConfigManager.cachedNodeBundleRefreshUrl(), isNull);
    });
  });
}
