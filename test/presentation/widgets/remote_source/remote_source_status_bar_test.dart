/// UI-D1：远程源加载状态胶囊（对齐 iOS `RemoteSourceStatusBar.swift`）。
///
/// 回归锁定：
///   · 胶囊高度回归 —— `MarqueeText` 内层 `Align` 必须同时设
///     `widthFactor` / `heightFactor`（缺 heightFactor 会在有界约束下
///     撑满可用高度，胶囊被拉成近全屏色块）；
///   · 显隐时长对齐 iOS `handleStateChange` —— `loading` 常显到终态、
///     `loadedRemote` / `loadedCache` 4s 自动消失、`failed` 8s 自动消失；
///   · 远程源通道超时对齐 iOS `fetchData`（单请求 15s、单点不重试）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/remote/all_sources_datasource.dart';
import 'package:vbox/data/datasources/remote/remote_manifest_datasource.dart';
import 'package:vbox/data/datasources/remote/remote_source_config_manager.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/repositories/remote_source_repository.dart';
import 'package:vbox/presentation/widgets/remote_source/remote_source_status_bar.dart';

/// 最小内存仓储（避免 file 缓存依赖 path_provider）。
class _FakeRepo implements RemoteSourceRepository {
  RemoteManifest? saved;

  @override
  Future<Result<RemoteManifest?>> cachedManifest() async =>
      Success<RemoteManifest?>(saved);

  @override
  Future<Result<bool>> saveManifest(RemoteManifest manifest) async {
    saved = manifest;
    return const Success<bool>(true);
  }

  @override
  Future<Result<RemoteManifest>> fetchManifest({bool forceRefresh = false}) async =>
      const Err<RemoteManifest>(UnknownFailure('测试不走此通道'));

  @override
  Future<Result<bool>> needsRefresh(int nowSeconds) async =>
      const Success<bool>(false);

  @override
  Future<Result<int>> cachedAtSeconds() async => const Success<int>(0);

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
    return const Success<bool>(true);
  }
}

const String _manifestUrl = 'https://cdn.test/manifest.json';

http.Response _json(Map<String, Object?> body) => http.Response(
      jsonEncode(body),
      200,
      headers: <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

/// 常规路由：manifest / all_sources 均成功（非 GitHub 域 → 单候选直连）。
MockClient _okClient() => MockClient((http.Request r) async {
      if (r.url.toString().endsWith('manifest.json')) {
        return _json(<String, Object?>{
          'configVersion': '2026.01.01.1',
          'files': <String, Object?>{
            'allSources': 'https://cdn.test/all_sources.json',
          },
        });
      }
      if (r.url.toString().endsWith('all_sources.json')) {
        return _json(<String, Object?>{});
      }
      return http.Response('not found', 404);
    });

RemoteSourceConfigManager _installManager(
  _FakeRepo repo, {
  required MockClient client,
}) {
  // 对齐生产装配（app.dart / _createDefault）：单请求 15s、单点不重试。
  final HttpClient hc = HttpClient(
    inner: client,
    maxRetries: 0,
    receiveTimeout: const Duration(seconds: 15),
  );
  final RemoteManifestDatasource ds = RemoteManifestDatasource(client: hc);
  final RemoteSourceConfigManager manager = RemoteSourceConfigManager(
    manifestDatasource: ds,
    allSourcesDatasource: AllSourcesDatasource(client: hc),
    repository: repo,
    probeClient: hc,
    appVersion: () => '3.1774.0',
    nowSeconds: () => 1760000000,
  );
  RemoteSourceConfigManager.install(manager);
  return manager;
}

Widget _host() => const MaterialApp(
      home: Stack(
        children: <Widget>[
          Positioned.fill(child: ColoredBox(color: Colors.white)),
          Positioned.fill(child: RemoteSourceStatusBar()),
        ],
      ),
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await PrefsManager.instance.init();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await PrefsManager.instance.set('remote_default_manifest_url', _manifestUrl);
  });

  testWidgets('loading 态：胶囊为底栏上方小胶囊（高度回归，不撑满可用高度）',
      (WidgetTester tester) async {
    final _FakeRepo repo = _FakeRepo();
    // manifest 永不响应 → 停留 loading（15s 超时远晚于断言窗口）。
    final RemoteSourceConfigManager manager = _installManager(
      repo,
      client: MockClient(
        (http.Request r) => Completer<http.Response>().future,
      ),
    );
    unawaited(manager.syncNow());
    await tester.pump();
    expect(manager.loadState.value.state, RemoteLoadState.loading);

    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 500));

    final Finder marquee = find.byType(MarqueeText);
    expect(marquee, findsOneWidget, reason: 'loading 态胶囊应可见');
    final Size capsuleSize = tester.getSize(
      find.ancestor(
        of: marquee,
        matching: find.byWidgetPredicate(
          (Widget w) => w is Container && w.decoration is BoxDecoration,
        ),
      ).first,
    );
    // 回归：heightFactor 缺失时胶囊会被拉到 ~450+ 高（600 高测试屏）。
    expect(
      capsuleSize.height,
      lessThan(100),
      reason: '胶囊应保持单行固有高度，而非撑满可用高度',
    );
    final Rect rect = tester.getRect(
      find.ancestor(
        of: marquee,
        matching: find.byWidgetPredicate(
          (Widget w) => w is Container && w.decoration is BoxDecoration,
        ),
      ).first,
    );
    expect(
      rect.top,
      greaterThan(300),
      reason: '胶囊应贴底栏上方（bottom:55，紧贴底栏顶边），不遮盖上半屏',
    );
    // 回归：此前 bottom:132 让胶囊悬空（底边 ~468 < 屏高 600 - 77）。
    // 现应紧贴底栏顶边：600 高屏 → 底边 = 600 - 55 = 545（±8 渲染容差）。
    expect(
      rect.bottom,
      closeTo(545, 8),
      reason: '胶囊底边应距屏底 ~55（紧贴底栏顶边），而非悬空',
    );

    // 排干挂起请求的 15s 超时 Timer → failed → 8s 自动消失，避免
    // 测试结束时仍有 pending Timer。
    await tester.pump(const Duration(seconds: 15));
    expect(manager.loadState.value.state, RemoteLoadState.failed);
    await tester.pump(const Duration(seconds: 9));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MarqueeText), findsNothing);
  });

  testWidgets('loading 态：不自动消失（对齐 iOS「同步中常显到终态」）',
      (WidgetTester tester) async {
    final _FakeRepo repo = _FakeRepo();
    final RemoteSourceConfigManager manager = _installManager(
      repo,
      client: MockClient(
        (http.Request r) => Completer<http.Response>().future,
      ),
    );
    unawaited(manager.syncNow());
    await tester.pump();

    await tester.pumpWidget(_host());
    await tester.pump(const Duration(seconds: 10));

    expect(find.byType(MarqueeText), findsOneWidget,
        reason: '同步未到终态前胶囊应常显（iOS loading 不自动消失）');

    // 排干挂起请求的 15s 超时 Timer → failed → 8s 自动消失。
    await tester.pump(const Duration(seconds: 6));
    expect(manager.loadState.value.state, RemoteLoadState.failed);
    await tester.pump(const Duration(seconds: 9));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MarqueeText), findsNothing);
  });

  testWidgets('loadedRemote 态：4s 后自动消失（对齐 iOS scheduleAutoDismiss 4.0）',
      (WidgetTester tester) async {
    final _FakeRepo repo = _FakeRepo();
    final RemoteSourceConfigManager manager = _installManager(
      repo,
      client: _okClient(),
    );
    unawaited(manager.syncNow());
    await tester.pump();
    await tester.pumpWidget(_host());
    await tester.pump();
    expect(manager.loadState.value.state, RemoteLoadState.loadedRemote);

    await tester.pump(const Duration(seconds: 3, milliseconds: 500));
    expect(find.byType(MarqueeText), findsOneWidget, reason: '4s 内应仍可见');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MarqueeText), findsNothing, reason: '4s 后应自动消失');
  });

  testWidgets('failed 态：8s 后自动消失（对齐 iOS scheduleAutoDismiss 8.0）',
      (WidgetTester tester) async {
    final _FakeRepo repo = _FakeRepo();
    final RemoteSourceConfigManager manager = _installManager(
      repo,
      // manifest 返回 500（单点不重试 → 单候选直接失败）→ failed。
      client: MockClient(
        (http.Request r) async => http.Response('server error', 500),
      ),
    );
    unawaited(manager.syncNow());
    await tester.pump();
    await tester.pumpWidget(_host());
    await tester.pump();
    expect(manager.loadState.value.state, RemoteLoadState.failed);

    await tester.pump(const Duration(seconds: 7, milliseconds: 500));
    expect(find.byType(MarqueeText), findsOneWidget, reason: '8s 内应仍可见');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MarqueeText), findsNothing, reason: '8s 后应自动消失');
  });
}
