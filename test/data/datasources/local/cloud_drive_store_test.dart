/// 网盘数据层单测（批次 F · F-03 凭据存储 / F-06 排序持久化）。
///
/// 对齐基准（唯一真相源）：
/// - iOS `CloudDriveSortManager`（`displayOrder` / `sortableOrder` /
///   `normalizedOrder` / `move` / `resetToDefault`）
/// - iOS `SecureCredentialStore`（Keychain `cloud_drive_credentials_v1`）
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/cloud_drive_credential_store.dart';
import 'package:vbox/data/datasources/local/cloud_drive_sort_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';

/// 首启（无已存顺序）的完整显示顺序：defaultOrder 8 家 + 枚举序补全 7 家。
const List<CloudDriveType> _kFreshFullOrder = <CloudDriveType>[
  CloudDriveType.quark,
  CloudDriveType.uc,
  CloudDriveType.baidu,
  CloudDriveType.ali,
  CloudDriveType.one15,
  CloudDriveType.pan123,
  CloudDriveType.pan139,
  CloudDriveType.pan189,
  CloudDriveType.quarkNode,
  CloudDriveType.baiduNode,
  CloudDriveType.ucNode,
  CloudDriveType.xunlei,
  CloudDriveType.guangya,
  CloudDriveType.woniu4k,
  CloudDriveType.bilibili,
];

/// 首启可排序列表（12 家，排除 3 张 Node 派生盘）。
const List<CloudDriveType> _kFreshSortableOrder = <CloudDriveType>[
  CloudDriveType.quark,
  CloudDriveType.uc,
  CloudDriveType.baidu,
  CloudDriveType.ali,
  CloudDriveType.one15,
  CloudDriveType.pan123,
  CloudDriveType.pan139,
  CloudDriveType.pan189,
  CloudDriveType.xunlei,
  CloudDriveType.guangya,
  CloudDriveType.woniu4k,
  CloudDriveType.bilibili,
];

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late CloudDriveSortStore sortStore;
  late CloudDriveCredentialStore credStore;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    sortStore = CloudDriveSortStore(pm);
    credStore = CloudDriveCredentialStore(pm);
  });

  group('CloudDriveSortStore', () {
    test('首启 order() = defaultOrder + 枚举序补全（对齐 iOS normalizedOrder）', () async {
      expect(await sortStore.order(), _kFreshFullOrder);
    });

    test('sortableOrder() 排除 3 张 Node 派生盘（12 家）', () async {
      expect(await sortStore.sortableOrder(), _kFreshSortableOrder);
    });

    test('orderIndex 命中返回位次，未登记不出现', () async {
      expect(await sortStore.orderIndex(CloudDriveType.quark), 0);
      expect(await sortStore.orderIndex(CloudDriveType.bilibili), 14);
    });

    test('move 下移：索引语义与 onReorderItem 一致（不再 -1）', () async {
      // 12 项 sortable：把 quark(0) 拖到末尾(11)。
      await sortStore.move(0, 11);
      final List<CloudDriveType> order = await sortStore.order();
      expect(order.first, CloudDriveType.uc);
      expect(order[11], CloudDriveType.quark);
      expect(await sortStore.isCustomized(), isTrue);
    });

    test('move 上移：baidu(2) → 0', () async {
      await sortStore.move(2, 0);
      expect(
        (await sortStore.sortableOrder()).take(4).toList(),
        <CloudDriveType>[
          CloudDriveType.baidu,
          CloudDriveType.quark,
          CloudDriveType.uc,
          CloudDriveType.ali,
        ],
      );
    });

    test('move 越界 oldIndex 静默忽略', () async {
      await sortStore.move(99, 0);
      expect(await sortStore.order(), _kFreshFullOrder);
    });

    test('resetToDefault 恢复默认且 isCustomized=false', () async {
      await sortStore.move(0, 11);
      expect(await sortStore.isCustomized(), isTrue);
      await sortStore.resetToDefault();
      expect(await sortStore.order(), _kFreshFullOrder);
      expect(await sortStore.isCustomized(), isFalse);
    });

    test('持久化跨实例：新 store 读回同一顺序', () async {
      await sortStore.move(2, 0);
      final CloudDriveSortStore next = CloudDriveSortStore(pm);
      expect((await next.sortableOrder()).first, CloudDriveType.baidu);
    });

    test('已存顺序含未知 id / 重复项时按 iOS normalize 归一化', () async {
      await pm.setJsonList(
        CloudDriveSortStore.storageKey,
        <String>['115', 'bogus', 'ali', '115'],
      );
      final List<CloudDriveType> order = await sortStore.order();
      expect(order.take(2).toList(),
          <CloudDriveType>[CloudDriveType.one15, CloudDriveType.ali]);
      expect(order.length, 15);
      expect(order.toSet().length, 15);
    });
  });

  group('CloudDriveCredentialStore', () {
    test('空存储 loadAll = {}，credential = null，hasCredentials = false', () async {
      expect(await credStore.loadAll(), isEmpty);
      expect(await credStore.credential(CloudDriveType.ali), isNull);
      expect(await credStore.hasCredentials(CloudDriveType.ali), isFalse);
    });

    test('save → credential 往返（含 cookie / 状态 / 用户名）', () async {
      await credStore.save(_cred(
        CloudDriveType.quark,
        cookie: 'k=v',
        userName: '张飞',
        state: CloudDriveAuthState.valid,
      ));
      final CloudDriveCredential? back =
          await credStore.credential(CloudDriveType.quark);
      expect(back, isNotNull);
      expect(back!.driveType, 'quark');
      expect(back.cookie, 'k=v');
      expect(back.userName, '张飞');
      expect(back.state, CloudDriveAuthState.valid);
      expect(await credStore.hasCredentials(CloudDriveType.quark), isTrue);
    });

    test('save 覆盖单个网盘且保留其余网盘', () async {
      await credStore.save(_cred(CloudDriveType.ali, refreshToken: 'r1'));
      await credStore.save(_cred(CloudDriveType.baidu, cookie: 'BDUSS=b'));
      await credStore.save(_cred(CloudDriveType.ali, refreshToken: 'r2'));
      final Map<String, CloudDriveCredential> all = await credStore.loadAll();
      expect(all.keys.toSet(), <String>{'ali', 'baidu'});
      expect(all['ali']!.refreshToken, 'r2');
      expect(all['baidu']!.cookie, 'BDUSS=b');
    });

    test('remove 删除单个，clear 清空全部', () async {
      await credStore.save(_cred(CloudDriveType.ali, refreshToken: 'r'));
      await credStore.save(_cred(CloudDriveType.baidu, cookie: 'BDUSS=b'));
      await credStore.remove(CloudDriveType.ali);
      expect(await credStore.credential(CloudDriveType.ali), isNull);
      expect(await credStore.credential(CloudDriveType.baidu), isNotNull);
      await credStore.clear();
      expect(await credStore.loadAll(), isEmpty);
    });

    test('remove 未命中不写入（保持空存储）', () async {
      await credStore.remove(CloudDriveType.ali);
      expect(await pm.getString(CloudDriveCredentialStore.storageKey), '');
    });

    test('非法 JSON / 非对象 JSON 容忍为空字典', () async {
      await pm.set(CloudDriveCredentialStore.storageKey, '{not-json');
      expect(await credStore.loadAll(), isEmpty);
      await pm.set(CloudDriveCredentialStore.storageKey, '[1,2,3]');
      expect(await credStore.loadAll(), isEmpty);
    });

    test('凭据落安全存储（SharedPreferences 无明文）', () async {
      await credStore.save(_cred(CloudDriveType.baidu, cookie: 'BDUSS=secret'));
      final SharedPreferences raw = await SharedPreferences.getInstance();
      expect(raw.getString(CloudDriveCredentialStore.storageKey), isNull);
      const FlutterSecureStorage secure = FlutterSecureStorage();
      expect(
        await secure.read(key: CloudDriveCredentialStore.storageKey),
        contains('BDUSS=secret'),
      );
    });
  });

  group('CloudDriveCredentialStore · Token 向量（F-P17）', () {
    test('空存储 loadTokens = []', () async {
      expect(await credStore.loadTokens(), isEmpty);
      expect(await credStore.tokensFor(CloudDriveType.quark), isEmpty);
    });

    test('saveTokens → loadTokens 往返（三字段保持）', () async {
      await credStore.saveTokens(<DriveToken>[
        const DriveToken(type: 'quark', name: 'A', value: 'ck=1'),
        const DriveToken(type: 'baidu', name: 'B', value: 'BDUSS=x; STOKEN=y'),
      ]);
      final List<DriveToken> back = await credStore.loadTokens();
      expect(back.length, 2);
      expect(back.first.type, 'quark');
      expect(back.first.name, 'A');
      expect(back.first.value, 'ck=1');
      expect(back.last.value, 'BDUSS=x; STOKEN=y');
    });

    test('addToken 同盘同名覆盖、异名并存（对齐 iOS addToken）', () async {
      await credStore.addToken(
        const DriveToken(type: 'quark', name: 'A', value: 'v1'),
      );
      await credStore.addToken(
        const DriveToken(type: 'quark', name: 'B', value: 'v2'),
      );
      await credStore.addToken(
        const DriveToken(type: 'quark', name: 'A', value: 'v3'),
      );
      final List<DriveToken> tokens = await credStore.loadTokens();
      expect(tokens.length, 2);
      expect(
        tokens.firstWhere((DriveToken t) => t.name == 'A').value,
        'v3',
      );
    });

    test('遗留键 saved_drive_tokens 兜底读取（v1 为空时）', () async {
      await pm.set(
        CloudDriveCredentialStore.savedTokensKey,
        jsonEncode(<dynamic>[
          <String, dynamic>{'type': 'uc', 'name': '旧', 'value': 'k=v'},
        ]),
      );
      final List<DriveToken> tokens = await credStore.loadTokens();
      expect(tokens.single.type, 'uc');
      expect(tokens.single.value, 'k=v');
    });

    test('tokensFor 合并手动向量 + 授权中心主密钥（非百度插队首）', () async {
      await credStore.addToken(
        const DriveToken(type: 'quark', name: '手动', value: 'manual'),
      );
      await credStore.save(
        _cred(CloudDriveType.quark, cookie: 'auth-cookie', userName: '账号'),
      );
      final List<DriveToken> tokens =
          await credStore.tokensFor(CloudDriveType.quark);
      expect(tokens.length, 2);
      expect(tokens.first.value, 'auth-cookie');
      expect(tokens.first.name, '账号');
      expect(tokens.last.value, 'manual');
    });

    test('tokensFor 百度过滤非 PCS / Web 形态 token', () async {
      await credStore.saveTokens(<DriveToken>[
        const DriveToken(type: 'baidu', name: 'pcs', value: 'PANPSC=a'),
        const DriveToken(type: 'baidu', name: 'web', value: 'BDUSS=a; STOKEN=b'),
        const DriveToken(type: 'baidu', name: '垃圾', value: 'hello'),
        const DriveToken(type: 'quark', name: 'x', value: 'z'),
      ]);
      final List<DriveToken> tokens =
          await credStore.tokensFor(CloudDriveType.baidu);
      expect(tokens.length, 2);
      expect(tokens.any((DriveToken t) => t.value == 'hello'), isFalse);
      expect(tokens.any((DriveToken t) => t.value == 'PANPSC=a'), isTrue);
    });

    test('baiduTokenPair：Web 取账号 Cookie，PCS 取 extra（对齐 iOS）', () async {
      await credStore.save(
        CloudDriveCredential(
          driveType: CloudDriveType.baidu.id,
          cookie: 'BDUSS=web; STOKEN=tok',
          userName: '百度账号',
          updatedAt: DateTime(2026, 1, 1),
          extra: <String, String>{'pcs_cookie': 'PANPSC=pcs'},
        ),
      );
      final BaiduTokenPair? pair = await credStore.baiduTokenPair();
      expect(pair, isNotNull);
      expect(pair!.web.value, 'BDUSS=web; STOKEN=tok');
      expect(pair.web.name, '百度账号');
      expect(pair.pcs?.value, 'PANPSC=pcs');
      expect(pair.pcs?.name, '授权中心-PCS');
    });

    test('baiduTokenPair：非 PCS 形态 extra 值不入选，缺 Web Cookie 返回 null', () async {
      await credStore.save(
        CloudDriveCredential(
          driveType: CloudDriveType.baidu.id,
          cookie: 'PANPSC=only',
          updatedAt: DateTime(2026, 1, 1),
          extra: <String, String>{'pcs_cookie': 'invalid'},
        ),
      );
      expect(await credStore.baiduTokenPair(), isNull);
    });

    test('Token 向量落安全存储（SharedPreferences 无明文）', () async {
      await credStore.addToken(
        const DriveToken(type: 'baidu', name: 'A', value: 'BDUSS=secret'),
      );
      final SharedPreferences raw = await SharedPreferences.getInstance();
      expect(
        raw.getString(CloudDriveCredentialStore.savedTokensV1Key),
        isNull,
      );
      const FlutterSecureStorage secure = FlutterSecureStorage();
      expect(
        await secure.read(key: CloudDriveCredentialStore.savedTokensV1Key),
        contains('BDUSS=secret'),
      );
    });
  });
}
