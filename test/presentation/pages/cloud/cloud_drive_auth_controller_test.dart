/// 网盘授权中心控制器与视图模型单测（批次 F · F-01）。
///
/// 对齐基准（唯一真相源）：iOS `CloudAuthCenterView`
/// （`vbox/Views/SettingsViews.swift:1561`）与 `CloudDriveAuthManager.isAuthorized`
/// （`CloudDriveAuthManager.swift:2445`）。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/cloud_drive_credential_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/remote/cloud_drive_credential_validator.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/presentation/pages/cloud/cloud_drive_auth_controller.dart';

CloudDriveCredential _cred(
  CloudDriveType type, {
  String? cookie,
  String? refreshToken,
  String? userName,
  DateTime? expiresAt,
  DateTime? lastCheckedAt,
  CloudDriveAuthState state = CloudDriveAuthState.unknown,
  Map<String, String> extra = const <String, String>{},
}) =>
    CloudDriveCredential(
      driveType: type.id,
      updatedAt: DateTime(2026, 1, 1),
      cookie: cookie,
      refreshToken: refreshToken,
      userName: userName,
      expiresAt: expiresAt,
      lastCheckedAt: lastCheckedAt,
      state: state,
      extra: extra,
    );

/// 固定结果的校验器桩（继承并覆写 [CloudDriveCredentialValidator.validate]）。
class _StubValidator extends CloudDriveCredentialValidator {
  _StubValidator(this.result);

  final CredentialValidationResult result;

  @override
  Future<CredentialValidationResult> validate(
    CloudDriveType type,
    CloudDriveCredential credential,
  ) async =>
      result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late CloudDriveCredentialStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = CloudDriveCredentialStore(pm);
  });

  group('授权中心布局常量', () {
    test('cloudAuthCenterOrder = 12 张卡且顺序对齐 iOS 主 VStack', () {
      expect(cloudAuthCenterOrder.length, 12);
      expect(cloudAuthCenterOrder, <CloudDriveType>[
        CloudDriveType.baidu,
        CloudDriveType.quark,
        CloudDriveType.ali,
        CloudDriveType.uc,
        CloudDriveType.one15,
        CloudDriveType.pan123,
        CloudDriveType.pan139,
        CloudDriveType.pan189,
        CloudDriveType.xunlei,
        CloudDriveType.guangya,
        CloudDriveType.woniu4k,
        CloudDriveType.bilibili,
      ]);
    });

    test('Node 托管盘 = 光鸭 / 蜗牛 / B站', () {
      expect(kNodeManagedDrives, <CloudDriveType>{
        CloudDriveType.guangya,
        CloudDriveType.woniu4k,
        CloudDriveType.bilibili,
      });
      expect(CloudDriveAccount.fromCredential(CloudDriveType.guangya, null)
          .isNodeManaged, isTrue);
      expect(CloudDriveAccount.fromCredential(CloudDriveType.ali, null)
          .isNodeManaged, isFalse);
    });

    test('12 家网盘说明文案齐备且非空', () {
      for (final CloudDriveType type in cloudAuthCenterOrder) {
        expect(cloudDriveNotes[type], isNotNull, reason: type.id);
        expect(cloudDriveNotes[type]!.isNotEmpty, isTrue, reason: type.id);
      }
    });
  });

  group('CloudDriveAccount.isAuthorized（逐档对齐 iOS）', () {
    test('无凭据 / invalid 一律未授权', () {
      expect(CloudDriveAccount.isAuthorized(CloudDriveType.ali, null), isFalse);
      expect(
        CloudDriveAccount.isAuthorized(
          CloudDriveType.ali,
          _cred(CloudDriveType.ali,
              refreshToken: 'r', state: CloudDriveAuthState.invalid),
        ),
        isFalse,
      );
    });

    test('百度：需同时含 BDUSS+STOKEN', () {
      expect(
        CloudDriveAccount.isAuthorized(
          CloudDriveType.baidu,
          _cred(CloudDriveType.baidu, cookie: 'BDUSS=b; STOKEN=s'),
        ),
        isTrue,
      );
      expect(
        CloudDriveAccount.isAuthorized(
          CloudDriveType.baidu,
          _cred(CloudDriveType.baidu, cookie: 'BDUSS=b'),
        ),
        isFalse,
      );
    });

    test('光鸭：看 extra["token"]', () {
      expect(
        CloudDriveAccount.isAuthorized(
          CloudDriveType.guangya,
          _cred(CloudDriveType.guangya,
              extra: <String, String>{'token': 't'}),
        ),
        isTrue,
      );
      expect(
        CloudDriveAccount.isAuthorized(
          CloudDriveType.guangya,
          _cred(CloudDriveType.guangya, cookie: 'c'),
        ),
        isFalse,
      );
    });

    test('蜗牛 / B站：看 cookie', () {
      for (final CloudDriveType type in <CloudDriveType>[
        CloudDriveType.woniu4k,
        CloudDriveType.bilibili,
      ]) {
        expect(
          CloudDriveAccount.isAuthorized(type, _cred(type, cookie: 'c')),
          isTrue,
          reason: type.id,
        );
        expect(
          CloudDriveAccount.isAuthorized(type, _cred(type)),
          isFalse,
          reason: type.id,
        );
      }
    });

    test('其余网盘：看 primarySecret（refreshToken / cookie / accessToken）', () {
      expect(
        CloudDriveAccount.isAuthorized(
          CloudDriveType.ali,
          _cred(CloudDriveType.ali, refreshToken: 'r'),
        ),
        isTrue,
      );
      expect(
        CloudDriveAccount.isAuthorized(
          CloudDriveType.uc,
          _cred(CloudDriveType.uc, cookie: 'c'),
        ),
        isTrue,
      );
      expect(
        CloudDriveAccount.isAuthorized(
          CloudDriveType.one15,
          _cred(CloudDriveType.one15),
        ),
        isFalse,
      );
    });
  });

  group('CloudDriveAccount.baiduWebStatus', () {
    test('BDUSS/STOKEN 组合分档', () {
      expect(CloudDriveAccount.baiduWebStatus('BDUSS=b; STOKEN=s').ready, isTrue);
      expect(
        CloudDriveAccount.baiduWebStatus('BDUSS=b; STOKEN=s').text,
        'BDUSS/STOKEN 已获取',
      );
      expect(CloudDriveAccount.baiduWebStatus('BDUSS=b').text, '缺少 STOKEN');
      expect(CloudDriveAccount.baiduWebStatus('STOKEN=s').text, '缺少 BDUSS');
      expect(CloudDriveAccount.baiduWebStatus('x=y').text, '缺少 BDUSS/STOKEN');
      expect(CloudDriveAccount.baiduWebStatus(null).ready, isFalse);
      // 大小写不敏感（对齐 iOS lowercase 归一口径）。
      expect(CloudDriveAccount.baiduWebStatus('bduss=b; stoken=s').ready, isTrue);
    });
  });

  group('CloudDriveAccount.statusTextFor', () {
    final DateTime now = DateTime(2026, 3, 1, 12, 0);

    test('无凭据 → 未授权', () {
      expect(CloudDriveAccount.statusTextFor(null, now), '未授权');
    });

    test('过期 / 30 分钟内即将过期 优先于状态文本', () {
      expect(
        CloudDriveAccount.statusTextFor(
          _cred(CloudDriveType.ali,
              expiresAt: now.subtract(const Duration(minutes: 1))),
          now,
        ),
        '已过期',
      );
      expect(
        CloudDriveAccount.statusTextFor(
          _cred(CloudDriveType.ali,
              expiresAt: now.add(const Duration(minutes: 10))),
          now,
        ),
        '即将过期',
      );
    });

    test('有检测时间 → 「状态 · HH:mm检测」', () {
      expect(
        CloudDriveAccount.statusTextFor(
          _cred(
            CloudDriveType.ali,
            state: CloudDriveAuthState.valid,
            lastCheckedAt: DateTime(2026, 3, 1, 9, 8),
            expiresAt: now.add(const Duration(days: 1)),
          ),
          now,
        ),
        '正常 · 09:08检测',
      );
    });

    test('无检测时间 → 仅状态文本', () {
      expect(
        CloudDriveAccount.statusTextFor(
          _cred(CloudDriveType.ali, state: CloudDriveAuthState.valid),
          now,
        ),
        '正常',
      );
    });
  });

  group('CloudDriveAccount.fromCredential 展示态', () {
    test('无凭据：未登录 / 未授权 / 暂无 Token；Node 托管盘回退 Node 托管', () {
      final CloudDriveAccount ali =
          CloudDriveAccount.fromCredential(CloudDriveType.ali, null);
      expect(ali.subtitle, '未登录');
      expect(ali.authorized, isFalse);
      expect(ali.statusText, '未授权');
      expect(ali.statusReady, isFalse);
      expect(ali.detailFallback, '暂无 Token');
      expect(ali.hasCookieRow, isFalse);

      final CloudDriveAccount guangya =
          CloudDriveAccount.fromCredential(CloudDriveType.guangya, null);
      expect(guangya.detailFallback, 'Node 托管');
    });

    test('百度：Cookie 行状态 + 副标题取 displayName', () {
      final CloudDriveAccount baidu = CloudDriveAccount.fromCredential(
        CloudDriveType.baidu,
        _cred(
          CloudDriveType.baidu,
          cookie: 'BDUSS=b; STOKEN=s',
          userName: '度友',
          state: CloudDriveAuthState.valid,
        ),
      );
      expect(baidu.authorized, isTrue);
      expect(baidu.subtitle, '度友');
      expect(baidu.hasCookieRow, isTrue);
      expect(baidu.cookieLabel, '基础登录 Web Cookie');
      expect(baidu.cookieReady, isTrue);
      expect(baidu.cookieStatusText, 'BDUSS/STOKEN 已获取');
      expect(baidu.statusReady, isTrue);
      expect(baidu.detailFallback, '度友');
    });

    test('非百度卡不展示 Cookie 行', () {
      final CloudDriveAccount ali = CloudDriveAccount.fromCredential(
        CloudDriveType.ali,
        _cred(CloudDriveType.ali, refreshToken: 'r'),
      );
      expect(ali.hasCookieRow, isFalse);
      expect(ali.cookieLabel, isNull);
      expect(ali.detailFallback, '已授权账号');
    });
  });

  group('CloudDriveAuthController', () {
    test('load() 构建 12 张卡且顺序 = cloudAuthCenterOrder', () async {
      final CloudDriveAuthController controller =
          CloudDriveAuthController(credentialStore: store);
      await controller.load();
      expect(controller.loading, isFalse);
      expect(controller.accounts.length, 12);
      expect(
        controller.accounts.map((CloudDriveAccount a) => a.type).toList(),
        cloudAuthCenterOrder,
      );
      expect(controller.nodeStatus.state, NodeRuntimeState.unknown);
    });

    test('load() 反映已存凭据的授权态', () async {
      await store.save(_cred(
        CloudDriveType.quark,
        cookie: 'k=v',
        state: CloudDriveAuthState.valid,
      ));
      final CloudDriveAuthController controller =
          CloudDriveAuthController(credentialStore: store);
      await controller.load();
      final CloudDriveAccount quark = controller.accounts
          .firstWhere((CloudDriveAccount a) => a.type == CloudDriveType.quark);
      expect(quark.authorized, isTrue);
      expect(quark.statusReady, isTrue);
    });

    test('testCredential 刷新 lastCheckedAt 并重建账户', () async {
      await store.save(_cred(
        CloudDriveType.ali,
        refreshToken: 'r',
        state: CloudDriveAuthState.valid,
      ));
      final CloudDriveAuthController controller =
          CloudDriveAuthController(credentialStore: store);
      await controller.load();
      expect(
        controller.accounts
            .firstWhere((CloudDriveAccount a) => a.type == CloudDriveType.ali)
            .statusText,
        '正常',
      );

      await controller.testCredential(CloudDriveType.ali);
      final CloudDriveCredential? after =
          await store.credential(CloudDriveType.ali);
      expect(after!.lastCheckedAt, isNotNull);
      expect(
        controller.accounts
            .firstWhere((CloudDriveAccount a) => a.type == CloudDriveType.ali)
            .statusText,
        contains('检测'),
      );
    });

    test('testCredential 对无凭据网盘为 no-op', () async {
      final CloudDriveAuthController controller =
          CloudDriveAuthController(credentialStore: store);
      await controller.load();
      await controller.testCredential(CloudDriveType.ali);
      expect(await store.credential(CloudDriveType.ali), isNull);
    });

    test('testCredential 校验通过 → 落库 valid + 文案（F-P24 对齐 markValid）',
        () async {
      await store.save(_cred(CloudDriveType.uc, cookie: 'k=v'));
      final CloudDriveAuthController controller = CloudDriveAuthController(
        credentialStore: store,
        validator: _StubValidator(
          const CredentialValidationResult(valid: true, message: '授权检测正常'),
        ),
      );
      await controller.load();

      await controller.testCredential(CloudDriveType.uc);

      final CloudDriveCredential? after = await store.credential(CloudDriveType.uc);
      expect(after!.state, CloudDriveAuthState.valid);
      expect(after.statusMessage, '授权检测正常');
      expect(after.lastCheckedAt, isNotNull);
    });

    test('testCredential 校验失败 → 落库 invalid + 失败文案（对齐 markInvalid）',
        () async {
      await store.save(_cred(CloudDriveType.uc, cookie: 'k=v'));
      final CloudDriveAuthController controller = CloudDriveAuthController(
        credentialStore: store,
        validator: _StubValidator(
          const CredentialValidationResult(valid: false, message: 'HTTP 401'),
        ),
      );
      await controller.load();

      await controller.testCredential(CloudDriveType.uc);

      final CloudDriveCredential? after = await store.credential(CloudDriveType.uc);
      expect(after!.state, CloudDriveAuthState.invalid);
      expect(after.statusMessage, 'HTTP 401');
      // 对齐 iOS：invalid 凭据 `isAuthorized` 直接 false。
      expect(
        CloudDriveAccount.isAuthorized(CloudDriveType.uc, after),
        isFalse,
      );
    });

    test('load() 通知监听者', () async {
      final CloudDriveAuthController controller =
          CloudDriveAuthController(credentialStore: store);
      int notified = 0;
      controller.addListener(() => notified++);
      await controller.load();
      expect(notified, greaterThanOrEqualTo(2));
    });

    test('P2-4：removeCredential 删除本地凭据（Node 侧级联失败不阻断）', () async {
      // 测试环境 Node 常驻系统不可达 → deleteNodeCredential 抛错被吞，
      // 本地凭据仍必须删掉（对齐 iOS「本地必须删、Node 失败只记日志」）。
      await store.save(_cred(CloudDriveType.uc, cookie: 'k=v'));
      final CloudDriveAuthController controller =
          CloudDriveAuthController(credentialStore: store);
      await controller.load();
      int notified = 0;
      controller.addListener(() => notified++);

      await controller.removeCredential(CloudDriveType.uc);

      expect(await store.credential(CloudDriveType.uc), isNull);
      expect(notified, greaterThanOrEqualTo(1));
    });
  });
}
