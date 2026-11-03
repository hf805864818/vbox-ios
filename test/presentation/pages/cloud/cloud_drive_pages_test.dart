/// 网盘授权中心 / 排序弹窗 Widget 单测（批次 F · F-01 / F-06）。
///
/// 对齐基准（唯一真相源）：iOS `CloudAuthCenterView`（UI 图 14）与
/// `CloudDriveSortPopup`（UI 图 15）。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/cloud_drive_credential_store.dart';
import 'package:vbox/data/datasources/local/cloud_drive_sort_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/remote/emby_config_client.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/presentation/pages/cloud/auth_center.dart';
import 'package:vbox/presentation/pages/cloud/cloud_drive_auth_controller.dart';
import 'package:vbox/presentation/pages/cloud/cloud_drive_widgets.dart';
import 'package:vbox/presentation/pages/cloud/sort.dart';

CloudDriveCredential _cred(
  CloudDriveType type, {
  String? cookie,
  String? refreshToken,
  String? userName,
  CloudDriveAuthState state = CloudDriveAuthState.unknown,
}) =>
    CloudDriveCredential(
      driveType: type.id,
      updatedAt: DateTime(2026, 1, 1),
      cookie: cookie,
      refreshToken: refreshToken,
      userName: userName,
      state: state,
    );

/// Emby 配置 fake 传输（空服务器列表，避免测试触碰 Node 运行时）。
class _FakeEmbyTransport implements EmbyTransport {
  @override
  Future<EmbyHttpResponse> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async =>
      const EmbyHttpResponse(
        statusCode: 200,
        json: <String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{'data': <dynamic>[]},
        },
      );
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required CloudDriveAuthController controller,
  void Function(CloudDriveAccount account, String action)? onAction,
}) async {
  // 12 张卡总高约 3000px；撑大视口让 ListView 一次性构建全部卡片。
  tester.view.physicalSize = const Size(1000, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: CloudDriveAuthCenterPage(
        controller: controller,
        onAction: onAction,
        embyClient: EmbyConfigClient(transport: _FakeEmbyTransport()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late CloudDriveCredentialStore credStore;
  late CloudDriveSortStore sortStore;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    credStore = CloudDriveCredentialStore(pm);
    sortStore = CloudDriveSortStore(pm);
  });

  group('CloudDriveAuthCenterPage', () {
    testWidgets('顶栏 + Node 横幅 + 12 张账号卡 + 底部说明', (WidgetTester tester) async {
      await _pumpPage(
        tester,
        controller: CloudDriveAuthController(
          credentialStore: credStore,
          nodeStatus: const NodeRuntimeStatus(
            state: NodeRuntimeState.ready,
            port: 58080,
          ),
        ),
      );

      expect(find.text('网盘账号授权'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      expect(find.text('Node 常驻系统'), findsOneWidget);
      expect(find.text('就绪'), findsOneWidget);
      expect(find.text('端口 58080 · 网盘解析链路可用'), findsOneWidget);
      expect(find.byType(VboxDriveAccountCard), findsNWidgets(12));
      // 12 网盘卡 + Emby 配置卡（批次 C）各一枚「未获取」徽标。
      expect(find.text('未获取'), findsNWidgets(13));
      expect(find.text('测试'), findsNWidgets(12));
      expect(find.text('基础登录 Web Cookie'), findsOneWidget);
      expect(
        find.textContaining('播放前不会强制检测授权状态'),
        findsOneWidget,
      );
    });

    testWidgets('各网盘动作按钮逐档对齐 iOS', (WidgetTester tester) async {
      await _pumpPage(
        tester,
        controller: CloudDriveAuthController(credentialStore: credStore),
      );

      expect(find.text('扫码授权'), findsOneWidget); // 百度
      expect(find.text('扫码登录'), findsOneWidget); // 夸克
      // P0-A2：阿里对齐 iOS「原生扫码」（OpenList 授权页），UC / B站 / 阿里各一枚。
      // P2-1：天翼 189 追加「原生扫码」（三段链，对齐 iOS pan189Helper 原生 API）。
      expect(find.text('原生扫码'), findsNWidgets(4));
      expect(find.text('网页登录兜底'), findsNWidgets(2)); // 夸克 / UC
      expect(find.text('网页兜底'), findsNWidgets(6)); // 百度/115/123/139/189/迅雷
      // 问题 11：百度/夸克/UC 原生卡对齐 iOS 后的 **2 项**矩阵（原生扫码 +
      // 网页兜底），Node 档不再在卡片上重复暴露（藏在原生扫码 Sheet 内的
      // Segmented 切换），因此「Node扫码登录」只剩 Node 托管派生卡 one15 一枚。
      expect(find.text('Node扫码登录'), findsOneWidget); // one15
      expect(find.text('Node账号登录'), findsNWidgets(2)); // 123/189
      expect(find.text('Node验证码登录'), findsNWidgets(2)); // 139/迅雷
      expect(find.text('手机验证码登录'), findsOneWidget); // 光鸭
      expect(find.text('账号登录'), findsOneWidget); // 蜗牛
    });

    testWidgets('点击动作按钮回调 (account, action)', (WidgetTester tester) async {
      final List<(CloudDriveType, String)> calls =
          <(CloudDriveType, String)>[];
      await _pumpPage(
        tester,
        controller: CloudDriveAuthController(credentialStore: credStore),
        onAction: (CloudDriveAccount account, String action) =>
            calls.add((account.type, action)),
      );

      await tester.tap(find.text('手机验证码登录'));
      await tester.pump();

      expect(calls, <(CloudDriveType, String)>[
        (CloudDriveType.guangya, '手机验证码登录'),
      ]);
    });

    testWidgets('已存凭据显示「已获取」与授权状态', (WidgetTester tester) async {
      await credStore.save(_cred(
        CloudDriveType.quark,
        cookie: 'k=v',
        userName: '夸友',
        state: CloudDriveAuthState.valid,
      ));
      await _pumpPage(
        tester,
        controller: CloudDriveAuthController(credentialStore: credStore),
      );

      expect(find.text('已获取'), findsOneWidget);
      // 11 张未授权网盘卡 + Emby 配置卡（批次 C）= 12 枚「未获取」徽标。
      expect(find.text('未获取'), findsNWidgets(12));
      // 副标题与详情行回退文案都取 displayName（2 处），
      // 另加「已保存 Token」列表内的账号名（1 处）= 3。
      expect(find.text('夸友'), findsNWidgets(3));
    });

    testWidgets('点击「测试」刷新本地检测时间', (WidgetTester tester) async {
      await credStore.save(_cred(
        CloudDriveType.ali,
        refreshToken: 'r',
        state: CloudDriveAuthState.valid,
      ));
      await _pumpPage(
        tester,
        controller: CloudDriveAuthController(credentialStore: credStore),
      );

      await tester.tap(find.byKey(
        ValueKey<String>(CloudDriveAccount.actionKey(CloudDriveType.ali)),
      ));
      await tester.pumpAndSettle();

      expect(
        (await credStore.credential(CloudDriveType.ali))!.lastCheckedAt,
        isNotNull,
      );
      expect(find.textContaining('正常 · '), findsOneWidget);
    });
  });

  group('VboxDriveAccountCard', () {
    testWidgets('百度卡展示 Cookie 状态行与状态配色文案', (WidgetTester tester) async {
      final CloudDriveAccount account = CloudDriveAccount.fromCredential(
        CloudDriveType.baidu,
        _cred(
          CloudDriveType.baidu,
          cookie: 'BDUSS=b; STOKEN=s',
          state: CloudDriveAuthState.valid,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: VboxDriveAccountCard(account: account)),
        ),
      );

      expect(find.text('百度网盘'), findsOneWidget);
      expect(find.text('已获取'), findsOneWidget);
      expect(find.text('基础登录 Web Cookie'), findsOneWidget);
      expect(find.text('BDUSS/STOKEN 已获取'), findsOneWidget);
      expect(find.text('扫码授权'), findsOneWidget);
      expect(find.text('网页兜底'), findsOneWidget);
      expect(find.text('正常'), findsOneWidget);

      // 未注入回调时点击动作按钮不应崩溃。
      await tester.tap(find.text('扫码授权'));
      await tester.pump();
    });
  });

  group('CloudDriveSortPopup', () {
    Future<void> pumpPopup(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(home: CloudDriveSortPopup(store: sortStore)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('标题 + 副标题 + 12 行（排除 3 张 Node 派生盘）', (WidgetTester tester) async {
      await pumpPopup(tester);

      expect(find.text('网盘排序'), findsOneWidget);
      expect(find.text('长按拖动调整详情页网盘显示顺序'), findsOneWidget);
      expect(find.text('恢复默认'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);

      // 列表为 sortableOrder（12 家）；首行 = defaultOrder 首位（夸克）。
      final ReorderableListView list =
          tester.widget<ReorderableListView>(find.byType(ReorderableListView));
      expect(list.itemCount, 12);
      expect(find.text(CloudDriveType.quark.displayName), findsOneWidget);

      // 3 张 Node 派生盘不参与排序，不出现在列表中。
      for (final CloudDriveType type in CloudDriveType.values) {
        if (!type.isNodeDerived) continue;
        expect(find.text(type.displayName), findsNothing, reason: type.id);
      }
    });

    testWidgets('「恢复默认」把顺序重置回 defaultOrder', (WidgetTester tester) async {
      await sortStore.move(0, 11);
      expect(await sortStore.isCustomized(), isTrue);

      await pumpPopup(tester);
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();

      expect(await sortStore.isCustomized(), isFalse);
    });

    testWidgets('长按拖拽重排写回存储（onReorderItem 接线）', (WidgetTester tester) async {
      await pumpPopup(tester);
      expect((await sortStore.sortableOrder()).first, CloudDriveType.quark);

      final Finder handle = find.byKey(const ValueKey<String>('cloud_sort_quark'));
      final TestGesture gesture =
          await tester.startGesture(tester.getCenter(handle));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect((await sortStore.sortableOrder()).first, isNot(CloudDriveType.quark));
    });
  });
}
