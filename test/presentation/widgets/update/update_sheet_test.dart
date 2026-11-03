/// 呈现层单测：更新弹窗与悬浮气泡（批次 K · K-更1 UI）。
///
/// 覆盖「发现新版本 / 已下载 / 悬浮气泡」三态渲染与关键文案，驱动真实 [Updater]
/// 状态（`MockClient` 模拟 Releases 与下载，无真实网络）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/constants/app_constants.dart';
import 'package:vbox/domain/entities/update/update_manifest.dart';
import 'package:vbox/platform/update/update.dart';
import 'package:vbox/presentation/widgets/update/update_sheet.dart';

const String _apkUrl =
    'https://github.com/vbox-Ai/app/releases/download/v3.9999.0/vbox-arm64.apk';

String _releaseJson() => jsonEncode(<Object>[
      <String, Object?>{
        'tag_name': 'v3.9999.0',
        'body': '## 更新\n1、修复崩溃\n- 新增倍速',
        'html_url': 'https://github.com/vbox-Ai/app/releases/tag/v3.9999.0',
        'assets': <Object>[
          <String, Object?>{
            'name': 'vbox-arm64.apk',
            'browser_download_url': _apkUrl,
            'size': 12,
          },
        ],
      },
    ]);

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('vbox_sheet_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Updater buildUpdater() {
    final http.Client client = MockClient(
      (http.Request _) async => http.Response(
        _releaseJson(),
        200,
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      ),
    );
    return Updater(
      client: client,
      platformOverride: UpdatePlatform.androidArm64,
      androidOverride: true,
      localVersion: '3.1621.0',
      directoryProvider: () async => tempDir,
    );
  }

  testWidgets('发现新版本态：标题 / 版本号 / 说明 / 主按钮 / 降级入口', (WidgetTester tester) async {
    final Updater u = buildUpdater();
    await tester.runAsync(() => u.check(force: true));

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: UpdateSheet(updater: u))),
    );

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('3.9999.0'), findsOneWidget);
    expect(find.text('马上升级'), findsOneWidget);
    expect(find.text('1、'), findsOneWidget);
    expect(find.textContaining('修复崩溃'), findsOneWidget);
    expect(find.text('当前版本 ${AppInfo.version}'), findsOneWidget);
    expect(find.text('用浏览器下载'), findsOneWidget);
  });

  testWidgets('已下载态：标题「下载完成」+ 按钮「安装更新」', (WidgetTester tester) async {
    final Updater u = buildUpdater();
    await tester.runAsync(() async {
      await u.check(force: true);
      await u.download();
    });

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: UpdateSheet(updater: u))),
    );

    expect(find.text('下载完成'), findsOneWidget);
    expect(find.text('安装更新'), findsOneWidget);
  });

  testWidgets('悬浮气泡：非下载态显示完成图标', (WidgetTester tester) async {
    final Updater u = buildUpdater();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              FloatingUpdateBubble(updater: u, onTap: () {}),
            ],
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.download_done), findsOneWidget);
  });
}