/// Node 凭据同步领域模型（批次 F · F-03）。
///
/// 对齐 iOS `NodeCredentialSyncService`（`vbox/Services/NodeCredentialSyncService.swift`）：
/// - 同步范围严格限定 Node 托管网盘（11 家：115 / 123 / 139 / 天翼 / 迅雷 /
///   光鸭 / 蜗牛 / B站 / 夸克Node / UC Node / 百度Node）；
/// - 字段映射逐档对齐 iOS `FieldMap`（`nodeField` → `keychainSlot` + `dbPath`）；
/// - 凭据槽位两档：`cookie`（主 Cookie 字段）与 `extra:<key>`（扩展字典键）；
/// - 拉取方向仅覆盖 Node bundle 权威读接口暴露的 7 家（`GET /website/api/credentials`）。
///
/// 本文件只承载**纯领域**语义（映射表 / 槽位读写 / 摘要），不含 Flutter 与 IO 依赖。
library;

import 'cloud_drive.dart';

/// Node 侧单字段映射。
///
/// 对齐 iOS `NodeCredentialSyncService.FieldMap`：
/// - [nodeField]：Node bundle 侧字段名（PUT / DELETE 的路径末段）；
/// - [keychainSlot]：本机凭据落点，取值 `cookie` 或 `extra:<key>`；
/// - [dbPath]：`wexfnwconfig.json` 中的嵌套存储路径段。
class NodeCredentialFieldMap {
  /// 构造。
  const NodeCredentialFieldMap({
    required this.nodeField,
    required this.keychainSlot,
    required this.dbPath,
  });

  /// Node bundle 字段名。
  final String nodeField;

  /// 本机凭据落点（`cookie` / `extra:<key>`）。
  final String keychainSlot;

  /// `wexfnwconfig.json` 存储路径段。
  final List<String> dbPath;
}

/// Node 提供方规格（bundle 侧 provider + 字段集）。
class NodeCredentialProviderSpec {
  /// 构造。
  const NodeCredentialProviderSpec({
    required this.provider,
    required this.fields,
  });

  /// Node bundle provider 名（`pan115` / `pan123` / `new139` …）。
  final String provider;

  /// 字段集。
  final List<NodeCredentialFieldMap> fields;
}

/// Node 托管网盘 → 提供方规格（键为 [CloudDriveType.id]）。
///
/// 逐档对齐 iOS `NodeCredentialSyncService.managedProviders`。
const Map<String, NodeCredentialProviderSpec> nodeManagedProviders =
    <String, NodeCredentialProviderSpec>{
  '115': NodeCredentialProviderSpec(
    provider: 'pan115',
    fields: <NodeCredentialFieldMap>[
      NodeCredentialFieldMap(
        nodeField: 'cookie',
        keychainSlot: 'cookie',
        dbPath: <String>['pan', 'pan115', 'cookie'],
      ),
    ],
  ),
  '123pan': NodeCredentialProviderSpec(
    provider: 'pan123',
    fields: <NodeCredentialFieldMap>[
      NodeCredentialFieldMap(
        nodeField: 'account',
        keychainSlot: 'extra:account',
        dbPath: <String>['pan', 'pan123', 'account'],
      ),
      NodeCredentialFieldMap(
        nodeField: 'password',
        keychainSlot: 'extra:password',
        dbPath: <String>['pan', 'pan123', 'password'],
      ),
      NodeCredentialFieldMap(
        nodeField: 'auth',
        keychainSlot: 'extra:auth',
        dbPath: <String>['pan', 'pan123', 'auth'],
      ),
    ],
  ),
  '139pan': NodeCredentialProviderSpec(
    provider: 'new139',
    fields: <NodeCredentialFieldMap>[
      NodeCredentialFieldMap(
        nodeField: 'session',
        keychainSlot: 'extra:session',
        dbPath: <String>['pan', 'new139', 'session'],
      ),
      NodeCredentialFieldMap(
        nodeField: 'device',
        keychainSlot: 'extra:device',
        dbPath: <String>['pan', 'new139', 'device'],
      ),
    ],
  ),
  '189pan': NodeCredentialProviderSpec(
    provider: 'tyi',
    fields: <NodeCredentialFieldMap>[
      NodeCredentialFieldMap(
        nodeField: 'account',
        keychainSlot: 'extra:account',
        dbPath: <String>['pan', 'pan189', 'account'],
      ),
      NodeCredentialFieldMap(
        nodeField: 'password',
        keychainSlot: 'extra:password',
        dbPath: <String>['pan', 'pan189', 'password'],
      ),
      NodeCredentialFieldMap(
        nodeField: 'cookie',
        keychainSlot: 'cookie',
        dbPath: <String>['pan', 'pan189', 'cookie'],
      ),
      NodeCredentialFieldMap(
        nodeField: 'refreshCookie',
        keychainSlot: 'extra:refreshCookie',
        dbPath: <String>['pan', 'pan189', 'refreshCookie'],
      ),
    ],
  ),
  'xunlei': NodeCredentialProviderSpec(
    provider: 'thunder',
    fields: <NodeCredentialFieldMap>[
      NodeCredentialFieldMap(
        nodeField: 'config',
        keychainSlot: 'extra:config',
        dbPath: <String>['pan', 'thunder', 'config'],
      ),
    ],
  ),
  'guangya': NodeCredentialProviderSpec(
    provider: 'guangya',
    fields: <NodeCredentialFieldMap>[
      NodeCredentialFieldMap(
        nodeField: 'token',
        keychainSlot: 'extra:token',
        dbPath: <String>['pan', 'guangya', 'token'],
      ),
    ],
  ),
  'woniu4k': NodeCredentialProviderSpec(
    provider: 'woniu4k',
    fields: <NodeCredentialFieldMap>[
      NodeCredentialFieldMap(
        nodeField: 'account',
        keychainSlot: 'extra:account',
        dbPath: <String>['siteCookie', 'woniu4k', 'account'],
      ),
      NodeCredentialFieldMap(
        nodeField: 'password',
        keychainSlot: 'extra:password',
        dbPath: <String>['siteCookie', 'woniu4k', 'password'],
      ),
      NodeCredentialFieldMap(
        nodeField: 'cookie',
        keychainSlot: 'cookie',
        dbPath: <String>['siteCookie', 'woniu4k', 'cookie'],
      ),
    ],
  ),
  'bilibili': NodeCredentialProviderSpec(
    provider: 'bili',
    fields: <NodeCredentialFieldMap>[
      NodeCredentialFieldMap(
        nodeField: 'cookie',
        keychainSlot: 'cookie',
        dbPath: <String>['siteCookie', 'bili', 'cookie'],
      ),
    ],
  ),
  'quarkNode': NodeCredentialProviderSpec(
    provider: 'quark',
    fields: <NodeCredentialFieldMap>[
      NodeCredentialFieldMap(
        nodeField: 'cookie',
        keychainSlot: 'cookie',
        dbPath: <String>['pan', 'quark', 'cookie'],
      ),
    ],
  ),
  'ucNode': NodeCredentialProviderSpec(
    provider: 'uc',
    fields: <NodeCredentialFieldMap>[
      NodeCredentialFieldMap(
        nodeField: 'cookie',
        keychainSlot: 'cookie',
        dbPath: <String>['pan', 'uc', 'cookie'],
      ),
      NodeCredentialFieldMap(
        nodeField: 'token',
        keychainSlot: 'extra:uc_node_tv_token',
        dbPath: <String>['pan', 'uc', 'token'],
      ),
      NodeCredentialFieldMap(
        nodeField: 'refreshtoken',
        keychainSlot: 'extra:uc_node_refresh_token',
        dbPath: <String>['pan', 'uc', 'refreshToken'],
      ),
    ],
  ),
  'baiduNode': NodeCredentialProviderSpec(
    provider: 'baidu',
    fields: <NodeCredentialFieldMap>[
      NodeCredentialFieldMap(
        nodeField: 'cookie',
        keychainSlot: 'cookie',
        dbPath: <String>['pan', 'baidu', 'cookie'],
      ),
    ],
  ),
};

/// 拉取方向映射：Node bundle `GET /website/api/credentials` 的 data key → 网盘。
///
/// 对齐 iOS `NodeCredentialSyncService.pullable`：迅雷 / 光鸭 / 蜗牛由各自登录
/// 路由管理，不走通用读接口，故不在本表。
const Map<String, String> nodePullableProviders = <String, String>{
  'pan115': '115',
  'pan123': '123pan',
  'pan189': '189pan',
  'new139': '139pan',
  'quark': 'quarkNode',
  'uc': 'ucNode',
  'baidu': 'baiduNode',
};

/// 是否 Node 托管网盘（决定同步范围与级联删除）。
bool isNodeManagedDrive(CloudDriveType type) =>
    nodeManagedProviders.containsKey(type.id);

/// `wexfnwconfig.json` 字段标量转字符串（对齐 iOS `readConfigFileValues`）。
///
/// - 字符串原样；
/// - 整数值的 num 转整数文本（JSON 中 `1.0` → `1`，与 iOS `Double.rounded()` 分支同口径）；
/// - 其余走 `toString()`；
/// - 去空白后为空串返回 null（视为无值）。
String? nodeConfigScalarToString(Object? raw) {
  if (raw == null) return null;
  final String text;
  if (raw is String) {
    text = raw;
  } else if (raw is num && raw == raw.roundToDouble()) {
    text = raw.toInt().toString();
  } else {
    text = raw.toString();
  }
  final String trimmed = text.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 按路径段在嵌套 JSON 中取值（对齐 iOS `valueAtPath`）。
///
/// 例：`['pan','pan115','cookie']` → `root['pan']['pan115']['cookie']`；
/// 任一段非字典或缺键返回 null。
Object? nodeConfigValueAtPath(Object? root, List<String> path) {
  Object? current = root;
  for (final String key in path) {
    if (current is! Map) return null;
    if (!current.containsKey(key)) return null;
    current = current[key];
  }
  return current;
}

/// 按路径段移除嵌套 JSON 中的值（对齐 iOS `removeValueAtPath`）。
///
/// 返回是否发生变更（供调用方判定是否需回写文件）。
bool nodeConfigRemoveAtPath(Map<String, dynamic> root, List<String> path) {
  if (path.isEmpty) return false;
  final String first = path.first;
  if (path.length == 1) {
    if (!root.containsKey(first)) return false;
    root.remove(first);
    return true;
  }
  final Object? child = root[first];
  if (child is! Map) return false;
  final Map<String, dynamic> childMap = <String, dynamic>{
    for (final MapEntry<Object?, Object?> e in child.entries)
      e.key.toString(): e.value,
  };
  final bool changed = nodeConfigRemoveAtPath(childMap, path.sublist(1));
  if (changed) root[first] = childMap;
  return changed;
}

/// 从 `wexfnwconfig.json` 根对象提取全部 Node 托管盘字段值。
///
/// 对齐 iOS `readConfigFileValues`：逐盘逐字段按 [NodeCredentialFieldMap.dbPath]
/// 取值，非空方收录；返回 `driveType.id → {nodeField: value}`（空盘不收录）。
Map<String, Map<String, String>> nodeConfigValuesByDrive(Object? root) {
  final Map<String, Map<String, String>> result =
      <String, Map<String, String>>{};
  for (final MapEntry<String, NodeCredentialProviderSpec> entry
      in nodeManagedProviders.entries) {
    final Map<String, String> values = <String, String>{};
    for (final NodeCredentialFieldMap field in entry.value.fields) {
      final String? value =
          nodeConfigScalarToString(nodeConfigValueAtPath(root, field.dbPath));
      if (value != null) values[field.nodeField] = value;
    }
    if (values.isNotEmpty) result[entry.key] = values;
  }
  return result;
}

/// 读取凭据槽位值（槽位非法返回 null）。
String? nodeCredentialSlotValue(CloudDriveCredential credential, String slot) {
  if (slot == 'cookie') return credential.cookie;
  if (slot.startsWith('extra:')) {
    return credential.extra[slot.substring('extra:'.length)];
  }
  return null;
}

/// 写回凭据槽位（返回新凭据；槽位非法原样返回）。
///
/// 仅用于**写入非空值**；`extra:<key>` 走整表覆盖（[CloudDriveCredential.copyWith]
/// 对 `cookie` / `extra` 均为覆盖语义）。
CloudDriveCredential withNodeCredentialSlot(
  CloudDriveCredential credential,
  String slot,
  String value,
) {
  if (slot == 'cookie') return credential.copyWith(cookie: value);
  if (slot.startsWith('extra:')) {
    final String key = slot.substring('extra:'.length);
    return credential.copyWith(
      extra: <String, String>{...credential.extra, key: value},
    );
  }
  return credential;
}

/// 同步方向（对齐 iOS `SyncDirection`）。
enum NodeCredentialSyncDirection {
  /// 本机 → Node（本地登录成功后调用）。
  push,

  /// Node → 本机（Node 网页登录后调用）。
  pull,

  /// 双向。
  both,
}

/// 同步结果摘要（对齐 iOS `NodeCredentialSyncSummary`）。
class NodeCredentialSyncSummary {
  /// 构造。
  const NodeCredentialSyncSummary({
    this.pushedFields = 0,
    this.pulledDrives = const <String>[],
    this.errors = const <String>[],
    this.duration = Duration.zero,
  });

  /// 成功推送的字段数。
  final int pushedFields;

  /// 成功拉取的网盘（[CloudDriveType.id] 升序）。
  final List<String> pulledDrives;

  /// 错误明细。
  final List<String> errors;

  /// 耗时。
  final Duration duration;

  /// 是否全部成功。
  bool get succeeded => errors.isEmpty;

  /// 复制并覆盖部分字段。
  NodeCredentialSyncSummary copyWith({
    int? pushedFields,
    List<String>? pulledDrives,
    List<String>? errors,
    Duration? duration,
  }) {
    return NodeCredentialSyncSummary(
      pushedFields: pushedFields ?? this.pushedFields,
      pulledDrives: pulledDrives ?? this.pulledDrives,
      errors: errors ?? this.errors,
      duration: duration ?? this.duration,
    );
  }
}
