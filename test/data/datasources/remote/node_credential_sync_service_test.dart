/// Node 凭据同步服务单测（批次 F · F-03）。
///
/// 对齐基准（唯一真相源）：iOS `NodeCredentialSyncService`
/// （push / pull / deleteNodeCredential 的协议与落库行为）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/cloud_drive_credential_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/remote/node_credential_sync_service.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/node_credential_sync.dart';

/// 记录型假客户端：按路径返回预设结果或抛错。
class _FakeClient implements NodeCredentialApiClient {
  _FakeClient({this.getResponse});

  /// GET /website/api/credentials 的返回体。
  Map<String, dynamic>? getResponse;

  /// 记为失败的路径（含 method，如 `PUT /x`）。
  final Set<String> failOn = <String>{};

  /// 请求记录（`method path body`）。
  final List<String> calls = <String>[];

  @override
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    calls.add('$method $path');
    if (failOn.contains('$method $path')) {
      throw const NodeCredentialSyncException('boom');
    }
    if (method == 'GET' && path == '/website/api/credentials') {
      return getResponse ?? <String, dynamic>{'code': 0};
    }
    return <String, dynamic>{'code': 0};
  }
}

CloudDriveCredential _cred(
  CloudDriveType type, {
  String? cookie,
  Map<String, String> extra = const <String, String>{},
}) =>
    CloudDriveCredential(
      driveType: type.id,
      updatedAt: DateTime(2026, 1, 1),
      cookie: cookie,
      extra: extra,
    );

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

  group('push', () {
    test('仅推送 Node 托管盘的 Node 字段（原生四盘不参与）', () async {
      await store.save(_cred(CloudDriveType.one15, cookie: 'CID=1'));
      await store.save(_cred(CloudDriveType.pan123,
          extra: <String, String>{'account': 'a', 'auth': 'tok'}));
      // 原生盘：不入 Node。
      await store.save(_cred(CloudDriveType.ali, cookie: 'should-not-push'));

      final _FakeClient client = _FakeClient();
      final NodeCredentialSyncService service =
          NodeCredentialSyncService(store: store, client: client);
      final NodeCredentialSyncSummary summary = await service.push();

      expect(summary.pushedFields, 3); // 115 cookie + 123 account + 123 auth
      expect(summary.succeeded, isTrue);
      expect(client.calls, <String>[
        'PUT /website/api/credential/pan115/cookie',
        'PUT /website/api/credential/pan123/account',
        'PUT /website/api/credential/pan123/auth',
      ]);
    });

    test('空槽位跳过（不产生请求）', () async {
      await store.save(_cred(CloudDriveType.one15)); // 无 cookie
      final _FakeClient client = _FakeClient();
      final NodeCredentialSyncSummary summary =
          await NodeCredentialSyncService(store: store, client: client).push();

      expect(summary.pushedFields, 0);
      expect(client.calls, isEmpty);
    });

    test('单字段失败不阻断其余（错误进摘要）', () async {
      await store.save(_cred(CloudDriveType.one15, cookie: 'CID=1'));
      await store.save(_cred(CloudDriveType.pan189,
          cookie: 'c', extra: <String, String>{'account': 'a'}));
      final _FakeClient client = _FakeClient()
        ..failOn.add('PUT /website/api/credential/pan115/cookie');

      final NodeCredentialSyncSummary summary =
          await NodeCredentialSyncService(store: store, client: client).push();

      expect(summary.pushedFields, 2); // 189 account + cookie
      expect(summary.succeeded, isFalse);
      expect(summary.errors.single, contains('push 115.cookie'));
    });

    test('缺省「未接入」客户端：推送全失败并报 Node 未就绪', () async {
      await store.save(_cred(CloudDriveType.one15, cookie: 'CID=1'));
      final NodeCredentialSyncSummary summary =
          await NodeCredentialSyncService(store: store).push();

      expect(summary.pushedFields, 0);
      expect(summary.succeeded, isFalse);
      expect(summary.errors.single, contains('Node 常驻系统未就绪'));
    });
  });

  group('pull', () {
    test('拉取命中 → 落库 valid + 同步说明 + pulledDrives', () async {
      final _FakeClient client = _FakeClient(
        getResponse: <String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{
            'pan115': <String, dynamic>{'cookie': 'UID=1; CID=2'},
            'uc': <String, dynamic>{
              'cookie': 'uc-cookie',
              'token': 'tv-token',
            },
          },
        },
      );
      final NodeCredentialSyncSummary summary =
          await NodeCredentialSyncService(store: store, client: client).pull();

      expect(summary.pulledDrives, <String>['115', 'ucNode']);
      expect(summary.succeeded, isTrue);

      final CloudDriveCredential? one15 =
          await store.credential(CloudDriveType.one15);
      expect(one15, isNotNull);
      expect(one15!.cookie, 'UID=1; CID=2');
      expect(one15.state, CloudDriveAuthState.valid);
      expect(one15.statusMessage, '已与 Node 常驻系统同步');

      final CloudDriveCredential? ucNode =
          await store.credential(CloudDriveType.ucNode);
      expect(ucNode!.cookie, 'uc-cookie');
      expect(ucNode.extra['uc_node_tv_token'], 'tv-token');
    });

    test('合并保留既有扩展键（不丢字段）', () async {
      await store.save(_cred(CloudDriveType.pan123,
          extra: <String, String>{'password': 'p'}));
      final _FakeClient client = _FakeClient(
        getResponse: <String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{
            'pan123': <String, dynamic>{'account': 'a'},
          },
        },
      );
      await NodeCredentialSyncService(store: store, client: client).pull();

      final CloudDriveCredential? c =
          await store.credential(CloudDriveType.pan123);
      expect(c!.extra['password'], 'p');
      expect(c.extra['account'], 'a');
    });

    test('HTTP 失败 → 摘要记错且本机凭据不变', () async {
      await store.save(_cred(CloudDriveType.one15, cookie: 'keep'));
      final _FakeClient client = _FakeClient()
        ..failOn.add('GET /website/api/credentials');
      final NodeCredentialSyncSummary summary =
          await NodeCredentialSyncService(store: store, client: client).pull();

      expect(summary.succeeded, isFalse);
      expect(summary.errors.single, contains('pull(HTTP)'));
      final CloudDriveCredential? c =
          await store.credential(CloudDriveType.one15);
      expect(c!.cookie, 'keep');
    });

    test('data 无命中字段：不写入、pulledDrives 为空', () async {
      final _FakeClient client = _FakeClient(
        getResponse: <String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{
            'pan115': <String, dynamic>{'cookie': ''},
          },
        },
      );
      final NodeCredentialSyncSummary summary =
          await NodeCredentialSyncService(store: store, client: client).pull();

      expect(summary.pulledDrives, isEmpty);
      expect(summary.succeeded, isTrue);
      expect(await store.loadAll(), isEmpty);
    });
  });

  group('deleteNodeCredential', () {
    test('逐字段 DELETE + 本机凭据删除', () async {
      await store.save(_cred(CloudDriveType.pan189,
          cookie: 'c', extra: <String, String>{'account': 'a'}));
      final _FakeClient client = _FakeClient();
      final NodeCredentialSyncSummary summary =
          await NodeCredentialSyncService(store: store, client: client)
              .deleteNodeCredential(CloudDriveType.pan189);

      expect(summary.succeeded, isTrue);
      expect(client.calls, <String>[
        'DELETE /website/api/credential/tyi/account',
        'DELETE /website/api/credential/tyi/password',
        'DELETE /website/api/credential/tyi/cookie',
        'DELETE /website/api/credential/tyi/refreshCookie',
      ]);
      expect(await store.credential(CloudDriveType.pan189), isNull);
    });

    test('DELETE 失败仍删本机凭据（错误进摘要）', () async {
      await store.save(_cred(CloudDriveType.one15, cookie: 'c'));
      final _FakeClient client = _FakeClient()
        ..failOn.add('DELETE /website/api/credential/pan115/cookie');
      final NodeCredentialSyncSummary summary =
          await NodeCredentialSyncService(store: store, client: client)
              .deleteNodeCredential(CloudDriveType.one15);

      expect(summary.succeeded, isFalse);
      expect(await store.credential(CloudDriveType.one15), isNull);
    });

    test('非 Node 托管盘：空摘要且无请求', () async {
      final _FakeClient client = _FakeClient();
      final NodeCredentialSyncSummary summary =
          await NodeCredentialSyncService(store: store, client: client)
              .deleteNodeCredential(CloudDriveType.ali);

      expect(summary.succeeded, isTrue);
      expect(client.calls, isEmpty);
    });
  });

  group('syncNow 编排', () {
    test('both：合并 push 与 pull 结果', () async {
      await store.save(_cred(CloudDriveType.one15, cookie: 'CID=1'));
      final _FakeClient client = _FakeClient(
        getResponse: <String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{
            'pan115': <String, dynamic>{'cookie': 'CID=1'},
          },
        },
      );
      final NodeCredentialSyncSummary summary =
          await NodeCredentialSyncService(store: store, client: client)
              .syncNow();

      expect(summary.pushedFields, 1);
      expect(summary.pulledDrives, <String>['115']);
      expect(summary.succeeded, isTrue);
    });

    test('queryProfile / saveProfile 分别为 push / pull 别名', () async {
      final _FakeClient client = _FakeClient();
      final NodeCredentialSyncService service =
          NodeCredentialSyncService(store: store, client: client);
      await service.queryProfile();
      expect(client.calls, isEmpty); // 无凭据不推
      await service.saveProfile();
      expect(client.calls, <String>['GET /website/api/credentials']);
    });
  });

  group('onNodeReady 自动推送（NC-清5）', () {
    test('首次推送 Node 托管凭据，再次调用短路（不重复 PUT）', () async {
      await store.save(_cred(CloudDriveType.one15, cookie: 'CID=1'));
      final _FakeClient client = _FakeClient();
      final NodeCredentialSyncService service =
          NodeCredentialSyncService(store: store, client: client);

      expect(service.hasAutoSynced, isFalse);
      final NodeCredentialSyncSummary? first = await service.onNodeReady();
      expect(first, isNotNull);
      expect(first!.pushedFields, 1);
      expect(service.hasAutoSynced, isTrue);
      expect(client.calls, <String>['PUT /website/api/credential/pan115/cookie']);

      final NodeCredentialSyncSummary? second = await service.onNodeReady();
      expect(second, isNull);
      expect(client.calls.length, 1); // 去重：不再 PUT
    });
  });

  group('wexfnwconfig.json 兜底（NC-清5）', () {
    late Directory tmp;
    late File cfg;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('vbox_nodecfg');
      cfg = File('${tmp.path}${Platform.pathSeparator}wexfnwconfig.json');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('pull 并读配置文件，覆盖 HTTP 不暴露的 guangya', () async {
      await cfg.writeAsString(jsonEncode(<String, dynamic>{
        'pan': <String, dynamic>{
          'guangya': <String, dynamic>{'token': 'gy-token'},
        },
      }));
      final _FakeClient client = _FakeClient(
        getResponse: <String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{
            'pan115': <String, dynamic>{'cookie': 'CID=1'},
          },
        },
      );
      final NodeCredentialSyncSummary summary = await NodeCredentialSyncService(
        store: store,
        client: client,
        configFilePath: cfg.path,
      ).pull();

      expect(summary.pulledDrives, <String>['115', 'guangya']);
      expect(summary.succeeded, isTrue);
      final CloudDriveCredential? gy =
          await store.credential(CloudDriveType.guangya);
      expect(gy, isNotNull);
      expect(gy!.extra['token'], 'gy-token');
    });

    test('配置文件缺失：不报错、不落库', () async {
      final _FakeClient client = _FakeClient();
      final NodeCredentialSyncSummary summary = await NodeCredentialSyncService(
        store: store,
        client: client,
        configFilePath: cfg.path,
      ).pull();

      expect(summary.succeeded, isTrue);
      expect(summary.pulledDrives, isEmpty);
      expect(await store.loadAll(), isEmpty);
    });

    test('deleteNodeCredential 兜底清理配置文件字段（保留兄弟键）', () async {
      await cfg.writeAsString(jsonEncode(<String, dynamic>{
        'pan': <String, dynamic>{
          'pan115': <String, dynamic>{'cookie': 'CID=1', 'other': 'keep'},
        },
      }));
      final _FakeClient client = _FakeClient();
      await NodeCredentialSyncService(
        store: store,
        client: client,
        configFilePath: cfg.path,
      ).deleteNodeCredential(CloudDriveType.one15);

      final Map<String, dynamic> root =
          jsonDecode(await cfg.readAsString()) as Map<String, dynamic>;
      final Map<String, dynamic> pan115 =
          (root['pan'] as Map<String, dynamic>)['pan115'] as Map<String, dynamic>;
      expect(pan115.containsKey('cookie'), isFalse);
      expect(pan115['other'], 'keep');
    });
  });
}
