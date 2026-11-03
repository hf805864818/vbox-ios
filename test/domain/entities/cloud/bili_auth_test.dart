/// 领域层单测：B 站扫码登录（批次 F · F-05）。
///
/// 对齐基准（唯一真相源）：iOS `BiliAuthManager.swift`
/// （Node `/website/api/bili/login/*` 的状态档与文案）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/bili_auth.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive_login.dart';

void main() {
  group('BiliAuthStatus.fromWire', () {
    test('waiting 无「已扫码」文案 → 等待扫码', () {
      expect(BiliAuthStatus.fromWire('waiting'), BiliAuthStatus.waiting);
      expect(BiliAuthStatus.fromWire('WAITING'), BiliAuthStatus.waiting);
    });

    test('waiting + msg 含「已扫码」→ 已扫码', () {
      expect(
        BiliAuthStatus.fromWire('waiting', msg: '已扫码，请确认'),
        BiliAuthStatus.scanned,
      );
    });

    test('scanned / confirm / confirmed → 已扫码', () {
      for (final String wire in <String>['scanned', 'confirm', 'confirmed']) {
        expect(BiliAuthStatus.fromWire(wire), BiliAuthStatus.scanned);
      }
    });

    test('success / expired / error / failed 档位', () {
      expect(BiliAuthStatus.fromWire('success'), BiliAuthStatus.success);
      expect(BiliAuthStatus.fromWire('expired'), BiliAuthStatus.expired);
      expect(BiliAuthStatus.fromWire('error'), BiliAuthStatus.error);
      expect(BiliAuthStatus.fromWire('failed'), BiliAuthStatus.error);
    });

    test('未知 / 空状态：以「已扫码」文案兜底，否则等待', () {
      expect(BiliAuthStatus.fromWire(null), BiliAuthStatus.waiting);
      expect(BiliAuthStatus.fromWire(''), BiliAuthStatus.waiting);
      expect(BiliAuthStatus.fromWire('weird'), BiliAuthStatus.waiting);
      expect(
        BiliAuthStatus.fromWire('weird', msg: '已扫码啦'),
        BiliAuthStatus.scanned,
      );
    });
  });

  group('BiliAuthStatus 语义', () {
    test('isTerminal 仅 success / expired / error', () {
      expect(BiliAuthStatus.success.isTerminal, isTrue);
      expect(BiliAuthStatus.expired.isTerminal, isTrue);
      expect(BiliAuthStatus.error.isTerminal, isTrue);
      expect(BiliAuthStatus.waiting.isTerminal, isFalse);
      expect(BiliAuthStatus.scanned.isTerminal, isFalse);
    });

    test('toPhase 映射统一登录阶段', () {
      expect(BiliAuthStatus.waiting.toPhase(), CloudDriveLoginPhase.waitingScan);
      expect(BiliAuthStatus.scanned.toPhase(), CloudDriveLoginPhase.scanned);
      expect(BiliAuthStatus.success.toPhase(), CloudDriveLoginPhase.saving);
      expect(BiliAuthStatus.expired.toPhase(), CloudDriveLoginPhase.failed);
      expect(BiliAuthStatus.error.toPhase(), CloudDriveLoginPhase.failed);
    });
  });

  group('BiliQrStart', () {
    test('qrDataUrl：qrImage 为空返回 null，否则原样返回', () {
      const BiliQrStart empty = BiliQrStart(taskId: 't');
      expect(empty.qrDataUrl, isNull);
      const BiliQrStart withImage = BiliQrStart(
        taskId: 't',
        qrImage: 'data:image/png;base64,AAAA',
      );
      expect(withImage.qrDataUrl, 'data:image/png;base64,AAAA');
    });

    test('displayMessage：空 msg 回退默认文案', () {
      expect(
        const BiliQrStart(taskId: 't').displayMessage,
        '请使用哔哩哔哩 App 扫码确认',
      );
      expect(
        const BiliQrStart(taskId: 't', msg: '自定义').displayMessage,
        '自定义',
      );
    });
  });

  group('BiliAuthPaths 常量（契约敏感）', () {
    test('路径与 provider 值对齐 iOS', () {
      expect(BiliAuthPaths.start, '/website/api/bili/login/start');
      expect(BiliAuthPaths.poll, '/website/api/bili/login/poll');
      expect(BiliAuthPaths.cancel, '/website/api/bili/login/cancel');
      expect(BiliAuthPaths.cookie, '/website/api/bili/cookie');
      expect(BiliAuthPaths.provider, 'bili');
    });
  });

  test('BiliAuthException.toString 返回文案', () {
    expect(const BiliAuthException('boom').toString(), 'boom');
  });
}
