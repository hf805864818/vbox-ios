/// 平台层单测：自更新器（批次 K · K-更1）。
///
/// 用 `MockClient` 模拟 GitHub Releases API 与安装包下载，用 fake 安装桥
/// 验证分平台安装分派；目录提供者注入临时目录，全程无真实网络 / 文件插件 / 原生通道。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/domain/entities/update/update_manifest.dart';
import 'package:vbox/platform/update/update.dart';

/// 假安装桥：记录调用，返回可控状态。
class _FakeBridge implements UpdateInstallBridge {
  bool canInstallValue = true;
  int canInstallCalls = 0;
  int openSettingsCalls = 0;
  final List<String> installedPaths = <String>[];
  String result = UpdateInstallStatus.started;

  @override
  Future<bool> canInstall() async {
    canInstallCalls++;
    return canInstallValue;
  }

  @override
  Future<void> openInstallPermissionSettings() async {
    openSettingsCalls++;
  }

  @override
  Future<String> installApk(String path) async {
    installedPaths.add(path);
    return result;
  }
}

const String _apkUrl =
    'https://github.com/vbox-Ai/app/releases/download/v3.9999.0/vbox-arm64.apk';

/// 构造 GitHub Releases `?per_page=1` 回包（单条 release，含一个 arm64 APK）。
String _releaseJson({
  required String tag,
  String apkUrl = _apkUrl,
  String digest = '',
}) {
  return jsonEncode(<Object>[
    <String, Object?>{
      'tag_name': tag,
      'body': '## 更新\n1、修复崩溃\n- 新增倍速',
      'html_url': 'https://github.com/vbox-Ai/app/releases/tag/$tag',
      'published_at': '2026-10-05T10:00:00Z',
      'assets': <Object>[
        <String, Object?>{
          'name': 'vbox-arm64.apk',
          'browser_download_url': apkUrl,
          'size': 12,
          if (digest.isNotEmpty) 'digest': 'sha256:$digest',
        },
      ],
    },
  ]);
}

http.Response _json(String body) => http.Response(
      body,
      200,
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  late Directory tempDir;
  late List<String> hosts;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('vbox_upd_');
    hosts = <String>[];
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Updater build({
    required http.Client client,
    _FakeBridge? bridge,
    UpdatePlatform platform = UpdatePlatform.androidArm64,
    bool android = true,
    String local = '3.1621.0',
    UpdateDirectoryProvider? directoryProvider,
  }) {
    return Updater(
      client: client,
      bridge: bridge ?? _FakeBridge(),
      platformOverride: platform,
      androidOverride: android,
      localVersion: local,
      directoryProvider: directoryProvider ?? () async => tempDir,
    );
  }

  group('check：检查更新', () {
    test('发现新版本：解析版本 / 下载地址 / 说明', () async {
      final http.Client client = MockClient((http.Request req) async {
        hosts.add(req.url.host);
        return _json(_releaseJson(tag: 'v3.9999.0'));
      });
      final Updater u = build(client: client);

      await u.check(force: true);

      expect(hosts, contains('api.github.com'));
      expect(u.isChecking, isFalse);
      expect(u.hasUpdate, isTrue);
      expect(u.latestVersion, '3.9999.0');
      expect(u.downloadUrl, contains('vbox-arm64.apk'));
      expect(u.releaseNotes, contains('修复崩溃'));
      expect(u.updateError, isNull);
    });

    test('已是最新版本：hasUpdate 为 false', () async {
      final http.Client client = MockClient(
        (http.Request _) async => _json(_releaseJson(tag: 'v3.1000.0')),
      );
      final Updater u = build(client: client);
      await u.check(force: true);
      expect(u.hasUpdate, isFalse);
      expect(u.latestVersion, '3.1000.0');
    });

    test('5 分钟内非强制检查短路（不再发请求）', () async {
      final http.Client client = MockClient((http.Request req) async {
        hosts.add(req.url.host);
        return _json(_releaseJson(tag: 'v3.9999.0'));
      });
      final Updater u = build(client: client);
      await u.check(force: true);
      final int first = hosts.length;
      await u.check();
      expect(hosts.length, first);
    });

    test('HTTP 非 200 → updateError 有值', () async {
      final http.Client client = MockClient(
        (http.Request _) async => http.Response('nope', 500),
      );
      final Updater u = build(client: client);
      await u.check(force: true);
      expect(u.updateError, isNotNull);
      expect(u.hasUpdate, isFalse);
    });

    test('有新版本但当前平台无资产 → 有更新且提示无安装包', () async {
      final http.Client client = MockClient(
        (http.Request _) async => _json(_releaseJson(tag: 'v3.9999.0')),
      );
      final Updater u = build(client: client, platform: UpdatePlatform.windows);
      await u.check(force: true);
      expect(u.hasUpdate, isTrue);
      expect(u.downloadUrl, isNull);
      expect(u.updateError, contains('暂无可用安装包'));
    });
  });

  group('download：代理链下载 + 校验', () {
    test('走主代理下载成功并落盘（进度归 1）', () async {
      final List<int> bytes = utf8.encode('apk-bytes-1234');
      final http.Client client = MockClient((http.Request req) async {
        hosts.add(req.url.host);
        if (req.url.host == 'api.github.com') {
          return _json(_releaseJson(
            tag: 'v3.9999.0',
            digest: sha256.convert(bytes).toString(),
          ));
        }
        return http.Response.bytes(bytes, 200);
      });
      final Updater u = build(client: client);
      await u.check(force: true);
      hosts.clear();

      await u.download();

      expect(hosts.first, 'ghfast.top'); // 降级链首位
      expect(u.isDownloading, isFalse);
      expect(u.hasDownloaded, isTrue);
      expect(u.downloadProgress, 1);
      expect(File(u.downloadedPath!).readAsBytesSync(), bytes);
      expect(u.downloadError, isNull);
    });

    test('主代理失败 → 回退备用代理', () async {
      final List<int> bytes = utf8.encode('fallback-ok');
      final http.Client client = MockClient((http.Request req) async {
        if (req.url.host == 'api.github.com') {
          return _json(_releaseJson(tag: 'v3.9999.0'));
        }
        hosts.add(req.url.host);
        if (req.url.host == 'ghfast.top') {
          return http.Response('busy', 503);
        }
        return http.Response.bytes(bytes, 200);
      });
      final Updater u = build(client: client);
      await u.check(force: true);

      await u.download();

      expect(hosts, <String>['ghfast.top', 'gh-proxy.com']);
      expect(u.hasDownloaded, isTrue);
    });

    test('SHA-256 校验失败 → 不落盘并报错', () async {
      final List<int> bytes = utf8.encode('tampered-bytes');
      final http.Client client = MockClient((http.Request req) async {
        if (req.url.host == 'api.github.com') {
          return _json(_releaseJson(
            tag: 'v3.9999.0',
            digest: sha256.convert(utf8.encode('expected')).toString(),
          ));
        }
        return http.Response.bytes(bytes, 200);
      });
      final Updater u = build(client: client);
      await u.check(force: true);

      await u.download();

      expect(u.hasDownloaded, isFalse);
      expect(u.downloadError, isNotNull);
    });

    test('无下载地址 → 直接报错', () async {
      // Windows 平台但 release 只含 APK → 无可用资产 → 无下载地址。
      final Updater u = build(
        client: MockClient((http.Request _) async => _json(_releaseJson(tag: 'v3.9999.0'))),
        platform: UpdatePlatform.windows,
        android: false,
      );
      await u.check(force: true);
      await u.download();
      expect(u.downloadError, '下载链接无效');
    });

    test('取消下载：状态复位', () async {
      final http.Client client = MockClient(
        (http.Request _) async => _json(_releaseJson(tag: 'v3.9999.0')),
      );
      final Updater u = build(client: client);
      await u.check(force: true);
      u.cancelDownload();
      expect(u.isDownloading, isFalse);
      expect(u.downloadProgress, 0);
    });

    test('断点续传：.part 残留 → Range 请求 → 206 追加完成', () async {
      final List<int> head = utf8.encode('first-half-');
      final List<int> tail = utf8.encode('second-half');
      final List<int> all = <int>[...head, ...tail];
      final List<String?> rangeHeaders = <String?>[];
      final Directory dir = await Directory.systemTemp.createTemp('vbox_update_resume');
      addTearDown(() => dir.delete(recursive: true));
      final File part =
          File('${dir.path}/vbox_update.apk.part')..createSync(recursive: true);
      part.writeAsBytesSync(head);

      final http.Client client = MockClient((http.Request req) async {
        if (req.url.host == 'api.github.com') {
          return _json(_releaseJson(
            tag: 'v3.9999.0',
            digest: sha256.convert(all).toString(),
          ));
        }
        rangeHeaders.add(req.headers['range']);
        return http.Response.bytes(tail, 206, headers: <String, String>{
          'content-length': '${tail.length}',
        });
      });
      final Updater u = build(
        client: client,
        directoryProvider: () async => dir,
      );
      await u.check(force: true);
      await u.download();

      expect(rangeHeaders, <String?>['bytes=${head.length}-']);
      expect(File(u.downloadedPath!).readAsBytesSync(), all);
      expect(File('${u.downloadedPath}.part').existsSync(), isFalse);
    });

    test('断点续传：服务端不支持 Range（200 全量）→ 重头写', () async {
      final List<int> all = utf8.encode('full-body-redownload');
      final Directory dir =
          await Directory.systemTemp.createTemp('vbox_update_full');
      addTearDown(() => dir.delete(recursive: true));
      final File part =
          File('${dir.path}/vbox_update.apk.part')..createSync(recursive: true);
      part.writeAsBytesSync(utf8.encode('stale-stale'));

      final http.Client client = MockClient((http.Request req) async {
        if (req.url.host == 'api.github.com') {
          return _json(_releaseJson(
            tag: 'v3.9999.0',
            digest: sha256.convert(all).toString(),
          ));
        }
        return http.Response.bytes(all, 200);
      });
      final Updater u = build(
        client: client,
        directoryProvider: () async => dir,
      );
      await u.check(force: true);
      await u.download();

      expect(File(u.downloadedPath!).readAsBytesSync(), all,
          reason: '200 全量响应必须覆盖旧 .part，而不是追加');
    });
  });

  group('install：分平台安装分派', () {
    Future<Updater> downloaded(_FakeBridge bridge) async {
      final List<int> bytes = utf8.encode('apk-for-install');
      final http.Client client = MockClient((http.Request req) async {
        if (req.url.host == 'api.github.com') {
          return _json(_releaseJson(tag: 'v3.9999.0'));
        }
        return http.Response.bytes(bytes, 200);
      });
      final Updater u = build(client: client, bridge: bridge);
      await u.check(force: true);
      await u.download();
      return u;
    }

    test('Android：拉起安装器返回 started', () async {
      final _FakeBridge bridge = _FakeBridge();
      final Updater u = await downloaded(bridge);

      final String status = await u.install();

      expect(status, UpdateInstallStatus.started);
      expect(bridge.installedPaths.single, u.downloadedPath);
    });

    test('Android：未授权 → 引导授权页并提示', () async {
      final _FakeBridge bridge = _FakeBridge()
        ..result = UpdateInstallStatus.needPermission;
      final Updater u = await downloaded(bridge);

      final String status = await u.install();

      expect(status, UpdateInstallStatus.needPermission);
      expect(bridge.openSettingsCalls, 1);
      expect(u.installMessage, isNotNull);
    });

    test('无已下载安装包 → failed', () async {
      final Updater u = build(
        client: MockClient((http.Request _) async => _json(_releaseJson(tag: 'v3.1000.0'))),
      );
      expect(await u.install(), UpdateInstallStatus.failed);
    });
  });

  group('悬浮态', () {
    test('minimize / restore 切换', () {
      final Updater u = build(
        client: MockClient((http.Request _) async => _json(_releaseJson(tag: 'v3.9999.0'))),
      );
      expect(u.isMinimized, isFalse);
      u.minimize();
      expect(u.isMinimized, isTrue);
      u.restore();
      expect(u.isMinimized, isFalse);
    });
  });
}