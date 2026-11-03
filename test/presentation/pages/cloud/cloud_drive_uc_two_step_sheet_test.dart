/// 表现层单测：UCNode 两步扫码登录（对齐 iOS `NodeUcTwoStepLoginView`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive_login.dart';
import 'package:vbox/presentation/pages/cloud/login_gateway.dart';
import 'package:vbox/presentation/pages/cloud/login_sheet.dart';

/// 记录 provider 的假网关（其余继承「未接入」实现）。
class _TwoStepGateway extends UnavailableCloudDriveLoginGateway {
  _TwoStepGateway();

  final List<String> providers = <String>[];

  @override
  Future<CloudDriveQrTask> startQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    String? providerOverride,
  }) async {
    providers.add(providerOverride ?? '');
    return (taskId: 't-${providerOverride ?? 'default'}', qrDataUrl: '');
  }

  @override
  Future<CloudDriveLoginPhase> pollQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String taskId,
    String? providerOverride,
  }) async =>
      CloudDriveLoginPhase.waitingScan;
}

Widget _host(_TwoStepGateway gateway, {required bool hasCookie}) => MaterialApp(
      home: Scaffold(
        body: CloudDriveUcTwoStepQrSheet(
          driveType: CloudDriveType.ucNode,
          gateway: gateway,
          hasExistingCookie: hasCookie,
        ),
      ),
    );

void main() {
  testWidgets('两步：初始 provider=ucCookie 且展示步骤 chip', (WidgetTester tester) async {
    final _TwoStepGateway gateway = _TwoStepGateway();
    await tester.pumpWidget(_host(gateway, hasCookie: false));
    await tester.pump(); // postFrameCallback → _startStep
    await tester.pump(); // async generateQr 完成
    expect(find.text('Cookie'), findsOneWidget);
    expect(find.text('TV Token'), findsOneWidget);
    expect(gateway.providers, contains('ucCookie'));
    await tester.pumpWidget(const SizedBox()); // dispose（取消轮询）
  });

  testWidgets('已有 Cookie：展示跳过入口并切到 ucToken', (WidgetTester tester) async {
    final _TwoStepGateway gateway = _TwoStepGateway();
    await tester.pumpWidget(_host(gateway, hasCookie: true));
    await tester.pump();
    await tester.pump();
    expect(find.text('本机已有 Cookie，直接进行第 2 步'), findsOneWidget);
    await tester.tap(find.text('本机已有 Cookie，直接进行第 2 步'));
    await tester.pump();
    await tester.pump();
    expect(gateway.providers, contains('ucToken'));
    await tester.pumpWidget(const SizedBox());
  });
}