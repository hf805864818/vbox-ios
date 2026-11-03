/// Node 凭据同步领域模型单测（批次 F · F-03）。
///
/// 对齐基准（唯一真相源）：iOS `NodeCredentialSyncService`
/// （`vbox/Services/NodeCredentialSyncService.swift` 的 `managedProviders` /
/// `pullable` / `value(from:slot:)` / `setting(value:slot:into:)`）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/node_credential_sync.dart';

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
  group('nodeManagedProviders', () {
    test('覆盖 11 家 Node 托管盘（对齐 iOS managedProviders）', () {
      expect(nodeManagedProviders.keys.toSet(), <String>{
        '115',
        '123pan',
        '139pan',
        '189pan',
        'xunlei',
        'guangya',
        'woniu4k',
        'bilibili',
        'quarkNode',
        'ucNode',
        'baiduNode',
      });
    });

    test('provider 名逐档对齐 iOS（pan115 / new139 / tyi / thunder / bili）', () {
      expect(nodeManagedProviders['115']!.provider, 'pan115');
      expect(nodeManagedProviders['123pan']!.provider, 'pan123');
      expect(nodeManagedProviders['139pan']!.provider, 'new139');
      expect(nodeManagedProviders['189pan']!.provider, 'tyi');
      expect(nodeManagedProviders['xunlei']!.provider, 'thunder');
      expect(nodeManagedProviders['guangya']!.provider, 'guangya');
      expect(nodeManagedProviders['woniu4k']!.provider, 'woniu4k');
      expect(nodeManagedProviders['bilibili']!.provider, 'bili');
      expect(nodeManagedProviders['quarkNode']!.provider, 'quark');
      expect(nodeManagedProviders['ucNode']!.provider, 'uc');
      expect(nodeManagedProviders['baiduNode']!.provider, 'baidu');
    });

    test('字段映射逐档对齐 iOS（含 UC Node 独立槽位）', () {
      final NodeCredentialProviderSpec uc =
          nodeManagedProviders['ucNode']!;
      expect(
        uc.fields.map((NodeCredentialFieldMap f) => f.nodeField).toList(),
        <String>['cookie', 'token', 'refreshtoken'],
      );
      expect(
        uc.fields.map((NodeCredentialFieldMap f) => f.keychainSlot).toList(),
        <String>['cookie', 'extra:uc_node_tv_token', 'extra:uc_node_refresh_token'],
      );
      // 189 天翼 4 字段（account / password / cookie / refreshCookie）。
      expect(nodeManagedProviders['189pan']!.fields.length, 4);
      // 百度Node / 夸克Node / 115 / B站 均单 Cookie 字段。
      expect(nodeManagedProviders['baiduNode']!.fields.single.keychainSlot, 'cookie');
      expect(nodeManagedProviders['quarkNode']!.fields.single.nodeField, 'cookie');
      expect(nodeManagedProviders['115']!.fields.single.dbPath,
          <String>['pan', 'pan115', 'cookie']);
      expect(nodeManagedProviders['woniu4k']!.fields.first.dbPath,
          <String>['siteCookie', 'woniu4k', 'account']);
    });
  });

  group('nodePullableProviders', () {
    test('7 家可拉取（对齐 iOS pullable），迅雷 / 光鸭 / 蜗牛不在其中', () {
      expect(nodePullableProviders, <String, String>{
        'pan115': '115',
        'pan123': '123pan',
        'pan189': '189pan',
        'new139': '139pan',
        'quark': 'quarkNode',
        'uc': 'ucNode',
        'baidu': 'baiduNode',
      });
      expect(nodePullableProviders.containsValue('xunlei'), isFalse);
      expect(nodePullableProviders.containsValue('guangya'), isFalse);
      expect(nodePullableProviders.containsValue('woniu4k'), isFalse);
    });
  });

  group('isNodeManagedDrive', () {
    test('11 家 Node 托管盘为真', () {
      const List<CloudDriveType> managed = <CloudDriveType>[
        CloudDriveType.one15,
        CloudDriveType.pan123,
        CloudDriveType.pan139,
        CloudDriveType.pan189,
        CloudDriveType.xunlei,
        CloudDriveType.guangya,
        CloudDriveType.woniu4k,
        CloudDriveType.bilibili,
        CloudDriveType.quarkNode,
        CloudDriveType.ucNode,
        CloudDriveType.baiduNode,
      ];
      for (final CloudDriveType type in managed) {
        expect(isNodeManagedDrive(type), isTrue, reason: type.id);
      }
    });

    test('原生四盘（阿里 / 夸克 / 百度 / UC）为非托管', () {
      const List<CloudDriveType> native = <CloudDriveType>[
        CloudDriveType.ali,
        CloudDriveType.quark,
        CloudDriveType.baidu,
        CloudDriveType.uc,
      ];
      for (final CloudDriveType type in native) {
        expect(isNodeManagedDrive(type), isFalse, reason: type.id);
      }
    });
  });

  group('槽位读写', () {
    test('cookie 槽位取值 / 写回', () {
      final CloudDriveCredential c = _cred(CloudDriveType.one15, cookie: 'k=v');
      expect(nodeCredentialSlotValue(c, 'cookie'), 'k=v');
      final CloudDriveCredential next =
          withNodeCredentialSlot(c, 'cookie', 'k2=v2');
      expect(next.cookie, 'k2=v2');
      // 不变性：原对象未被改动。
      expect(c.cookie, 'k=v');
    });

    test('extra 槽位取值 / 写回（保留其余扩展键）', () {
      final CloudDriveCredential c = _cred(
        CloudDriveType.pan189,
        extra: <String, String>{'account': 'a', 'password': 'p'},
      );
      expect(nodeCredentialSlotValue(c, 'extra:account'), 'a');
      expect(nodeCredentialSlotValue(c, 'extra:missing'), isNull);
      final CloudDriveCredential next =
          withNodeCredentialSlot(c, 'extra:refreshCookie', 'rc');
      expect(next.extra, <String, String>{
        'account': 'a',
        'password': 'p',
        'refreshCookie': 'rc',
      });
    });

    test('非法槽位：取值 null / 写回原样', () {
      final CloudDriveCredential c = _cred(CloudDriveType.one15, cookie: 'x');
      expect(nodeCredentialSlotValue(c, 'bogus'), isNull);
      expect(identical(withNodeCredentialSlot(c, 'bogus', 'v'), c), isTrue);
    });
  });

  group('NodeCredentialSyncSummary', () {
    test('succeeded 取决于 errors 是否为空', () {
      expect(const NodeCredentialSyncSummary().succeeded, isTrue);
      expect(
        const NodeCredentialSyncSummary(errors: <String>['x']).succeeded,
        isFalse,
      );
    });

    test('copyWith 覆盖指定字段并保留其余', () {
      const NodeCredentialSyncSummary base = NodeCredentialSyncSummary(
        pushedFields: 3,
        pulledDrives: <String>['115'],
        duration: Duration(seconds: 1),
      );
      final NodeCredentialSyncSummary next =
          base.copyWith(pushedFields: 5, errors: <String>['e']);
      expect(next.pushedFields, 5);
      expect(next.pulledDrives, <String>['115']);
      expect(next.errors, <String>['e']);
      expect(next.duration, const Duration(seconds: 1));
    });

    test('方向枚举三档', () {
      expect(NodeCredentialSyncDirection.values, <NodeCredentialSyncDirection>[
        NodeCredentialSyncDirection.push,
        NodeCredentialSyncDirection.pull,
        NodeCredentialSyncDirection.both,
      ]);
    });
  });

  group('wexfnwconfig 兜底（NC-清5）', () {
    test('标量转字符串逐档对齐 iOS readConfigFileValues', () {
      expect(nodeConfigScalarToString('abc'), 'abc');
      expect(nodeConfigScalarToString('  x  '), 'x');
      expect(nodeConfigScalarToString(1.0), '1'); // 整数 num → 整数文本
      expect(nodeConfigScalarToString(42), '42');
      expect(nodeConfigScalarToString(1.5), '1.5');
      expect(nodeConfigScalarToString(''), isNull);
      expect(nodeConfigScalarToString('   '), isNull);
      expect(nodeConfigScalarToString(null), isNull);
    });

    test('按路径段取值（嵌套命中 / 缺键 / 中途非字典）', () {
      final Map<String, dynamic> root = <String, dynamic>{
        'pan': <String, dynamic>{
          'pan115': <String, dynamic>{'cookie': 'CID=1'},
          'scalar': 7,
        },
      };
      expect(
        nodeConfigValueAtPath(root, <String>['pan', 'pan115', 'cookie']),
        'CID=1',
      );
      expect(nodeConfigValueAtPath(root, <String>['pan', 'pan115', 'miss']),
          isNull);
      expect(nodeConfigValueAtPath(root, <String>['pan', 'scalar', 'x']),
          isNull);
      expect(nodeConfigValueAtPath(root, <String>['missing', 'x']), isNull);
    });

    test('按路径段移除（叶子 / 嵌套 / 缺键 / 中途非字典）', () {
      final Map<String, dynamic> root = <String, dynamic>{
        'pan': <String, dynamic>{
          'pan115': <String, dynamic>{'cookie': 'c', 'other': 'o'},
        },
        'siteCookie': <String, dynamic>{'bili': <String, dynamic>{'cookie': 'bc'}},
      };
      expect(nodeConfigRemoveAtPath(root, <String>['pan', 'pan115', 'cookie']),
          isTrue);
      final Map<String, dynamic> pan115 =
          (root['pan'] as Map<String, dynamic>)['pan115'] as Map<String, dynamic>;
      expect(pan115.containsKey('cookie'), isFalse);
      expect(pan115['other'], 'o'); // 兄弟键保留

      expect(nodeConfigRemoveAtPath(root, <String>['siteCookie', 'bili']),
          isTrue);
      expect((root['siteCookie'] as Map<String, dynamic>).containsKey('bili'),
          isFalse);

      expect(nodeConfigRemoveAtPath(root, <String>['pan', 'pan115', 'nope']),
          isFalse);
      expect(nodeConfigRemoveAtPath(root, <String>['pan', 'pan115', 'cookie']),
          isFalse);
    });

    test('提取全部 Node 托管盘字段（覆盖 HTTP 不暴露的 thunder/guangya/woniu4k）',
        () {
      final Map<String, dynamic> root = <String, dynamic>{
        'pan': <String, dynamic>{
          'pan115': <String, dynamic>{'cookie': 'CID=1'},
          'thunder': <String, dynamic>{'config': '{"xunlei":1}'},
          'guangya': <String, dynamic>{'token': 'gy-token'},
          'pan123': <String, dynamic>{'account': 'a', 'auth': 'tok'},
          'uc': <String, dynamic>{
            'cookie': 'uc-c',
            'token': 'tv',
            'refreshToken': 'rt',
          },
        },
        'siteCookie': <String, dynamic>{
          'woniu4k': <String, dynamic>{'account': 'wa', 'cookie': 'wc'},
          'bili': <String, dynamic>{'cookie': 'bili-c'},
        },
      };
      final Map<String, Map<String, String>> values =
          nodeConfigValuesByDrive(root);

      expect(values['115'], <String, String>{'cookie': 'CID=1'});
      expect(values['xunlei'], <String, String>{'config': '{"xunlei":1}'});
      expect(values['guangya'], <String, String>{'token': 'gy-token'});
      expect(values['123pan'],
          <String, String>{'account': 'a', 'auth': 'tok'});
      expect(values['woniu4k'],
          <String, String>{'account': 'wa', 'cookie': 'wc'});
      expect(values['bilibili'], <String, String>{'cookie': 'bili-c'});
      expect(values['ucNode'], <String, String>{
        'cookie': 'uc-c',
        'token': 'tv',
        'refreshtoken': 'rt',
      });
      // 未出现的盘不收录。
      expect(values.containsKey('139pan'), isFalse);
      expect(values.containsKey('baiduNode'), isFalse);
    });
  });
}
