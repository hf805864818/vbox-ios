/// 数据层单测：`remote_source_repository_impl.dart`。
///
/// 用 MockClient 模拟 HTTP（走真实 [HttpClient] + [RemoteManifestDatasource] 校验链）、
/// 临时目录做缓存落盘、mock prefs 校验契约同步键。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/core/storage/storage_paths.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/remote/remote_manifest_datasource.dart';
import 'package:vbox/data/repositories/repositories.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';

const String _url = 'https://example.com/manifest.json';
const String _version = '2026.09.29.1';

String _manifestJson({int ttl = 21600}) => jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'configVersion': _version,
      'ttlSeconds': ttl,
      'forceRefresh': false,
      'files': <String, String>{
        'allSources': 'https://example.com/all_sources.json',
      },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await PrefsManager.instance.init();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vbox_remote_');
    StoragePaths.configure(tmp.path);
    await StoragePaths.ensureLayout();
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.clear();
  });

  tearDown(() async {
    StoragePaths.reset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// 构造仓储（走真实 StoragePaths 缓存路径；HTTP 用 [client]）。
  RemoteSourceRepositoryImpl repoWith(http.Client client) =>
      RemoteSourceRepositoryImpl(
        datasource: RemoteManifestDatasource(
          client: HttpClient(inner: client, maxRetries: 0),
        ),
      );

  MockClient okServer() => MockClient((http.Request _) async => http.Response(
        _manifestJson(),
        200,
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      ));

  test('未配置 manifest 地址 → ValidationFailure', () async {
    // 契约默认自带内置 manifest 地址；显式清空才能触发「未配置」分支。
    await PrefsManager.instance.set('remote_default_manifest_url', '');
    final Result<RemoteManifest> r = await repoWith(okServer()).fetchManifest();
    expect(r.isSuccess, isFalse);
    expect(r.failureOrNull, isA<ValidationFailure>());
  });

  test('fetch → save → cachedManifest 往返 + 契约同步键镜像', () async {
    await PrefsManager.instance.set('remote_default_manifest_url', _url);
    final RemoteSourceRepositoryImpl repo = repoWith(okServer());

    final RemoteManifest m = (await repo.fetchManifest()).valueOrNull!;
    expect(m.configVersion, _version);
    expect(m.ttlSeconds, 21600);

    expect((await repo.saveManifest(m)).valueOrNull, isTrue);

    final RemoteManifest? cached = (await repo.cachedManifest()).valueOrNull;
    expect(cached!.configVersion, _version);
    expect(cached.files[RemoteManifest.keyAllSources], isNotNull);

    final int at = (await repo.cachedAtSeconds()).valueOrNull!;
    expect(at, greaterThan(0));

    // 契约同步键（prefs_keys_v1.json）
    expect(
      await PrefsManager.instance.getString('remote_default_last_config_version'),
      _version,
    );
    expect(
      await PrefsManager.instance.getInt('remote_default_last_sync_time'),
      at,
    );
  });

  test('saveManifest 镜像 Node bundle 键（ND-02，对齐 iOS syncNow）', () async {
    await PrefsManager.instance.set('remote_default_manifest_url', _url);
    final RemoteSourceRepositoryImpl repo = repoWith(okServer());

    // 下发 → 写入
    final RemoteManifest withBundle = RemoteManifest.fromJson(<String, Object?>{
      'configVersion': _version,
      'files': <String, Object?>{
        'allSources': 'https://example.com/all_sources.json',
        'nodeRuntimeBundle': 'https://cdn/kstore_index.js',
        'nodeRuntimeBundleVer': 'https://cdn/kstore_index.version',
      },
    });
    await repo.saveManifest(withBundle);
    expect(
      await PrefsManager.instance.getString('remote_node_bundle_url'),
      'https://cdn/kstore_index.js',
    );
    expect(
      await PrefsManager.instance.getString('remote_node_bundle_ver'),
      'https://cdn/kstore_index.version',
    );

    // 未下发 → 清除（启动回退本地内置资源）；PrefsManager.getString 对缺失键
    // 返回契约默认值（string 键为 ''），故断言为空而非 null。
    final RemoteManifest plain = (await repo.fetchManifest()).valueOrNull!;
    await repo.saveManifest(plain);
    expect(await PrefsManager.instance.getString('remote_node_bundle_url'), isEmpty);
    expect(await PrefsManager.instance.getString('remote_node_bundle_ver'), isEmpty);
  });

  test('needsRefresh：无缓存恒 true；有缓存按 ttl 判定', () async {
    await PrefsManager.instance.set('remote_default_manifest_url', _url);
    final RemoteSourceRepositoryImpl repo = repoWith(okServer());

    expect((await repo.needsRefresh(1000)).valueOrNull, isTrue);

    final RemoteManifest m = (await repo.fetchManifest()).valueOrNull!;
    await repo.saveManifest(m);
    final int at = (await repo.cachedAtSeconds()).valueOrNull!;

    expect((await repo.needsRefresh(at)).valueOrNull, isFalse);
    expect((await repo.needsRefresh(at + 21599)).valueOrNull, isFalse);
    expect((await repo.needsRefresh(at + 21600)).valueOrNull, isTrue);
  });

  test('无缓存时 cachedManifest 为 null / cachedAtSeconds 为 0', () async {
    final RemoteSourceRepositoryImpl repo = repoWith(okServer());
    expect((await repo.cachedManifest()).valueOrNull, isNull);
    expect((await repo.cachedAtSeconds()).valueOrNull, 0);
  });

  test('HTTP 5xx → NetworkFailure', () async {
    await PrefsManager.instance.set('remote_default_manifest_url', _url);
    final MockClient bad =
        MockClient((http.Request _) async => http.Response('boom', 500));
    final Result<RemoteManifest> r = await repoWith(bad).fetchManifest();
    expect(r.isSuccess, isFalse);
    expect(r.failureOrNull, isA<NetworkFailure>());
  });

  test('缺必需文件条目 allSources → ParseFailure', () async {
    await PrefsManager.instance.set('remote_default_manifest_url', _url);
    final MockClient bad = MockClient((http.Request _) async => http.Response(
          jsonEncode(<String, Object?>{'configVersion': _version}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ));
    final Result<RemoteManifest> r = await repoWith(bad).fetchManifest();
    expect(r.isSuccess, isFalse);
    expect(r.failureOrNull, isA<ParseFailure>());
  });

  test('configVersion 格式非法 → ParseFailure', () async {
    await PrefsManager.instance.set('remote_default_manifest_url', _url);
    final MockClient bad = MockClient((http.Request _) async => http.Response(
          jsonEncode(<String, Object?>{
            'configVersion': 'v1',
            'files': <String, String>{'allSources': 'https://x/a.json'},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ));
    final Result<RemoteManifest> r = await repoWith(bad).fetchManifest();
    expect(r.isSuccess, isFalse);
    expect(r.failureOrNull, isA<ParseFailure>());
  });
}