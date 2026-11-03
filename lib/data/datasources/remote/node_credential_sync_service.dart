/// 数据层：Node 凭据同步服务（批次 F · F-03）。
///
/// 对齐 iOS `NodeCredentialSyncService`（`vbox/Services/NodeCredentialSyncService.swift`）：
/// - **push（queryProfile）**：把本机安全存储（`cloud_drive_credentials_v1`）中
///   Node 托管网盘的凭据镜像到 Node 常驻系统
///   （`PUT /website/api/credential/:provider/:field` body `{"value": "..."}`）；
/// - **pull（saveProfile）**：把 Node 常驻系统凭据拉回本机安全存储
///   （`GET /website/api/credentials` → `{code:0, data:{...}}`）；
/// - **deleteNodeCredential**：级联删除 Node 侧逐字段凭据 + 本机主凭据；
/// - **onNodeReady**（NC-清5）：Node 就绪后**首次**自动推送本机凭据镜像
///   （对齐 iOS `handleNodeStatus` + `hasAutoSynced` 去重）；
/// - **wexfnwconfig.json 兜底**（NC-清5）：pull 时并读配置文件（覆盖全部 11 盘，
///   含 `thunder` / `guangya` / `woniu4k` 三个 HTTP 读接口不暴露者），
///   deleteNodeCredential 时直改配置文件移除字段
///   （对齐 iOS `readConfigFileValues` / `removeConfigFileFields`）。
///
/// 铁律（对齐 iOS）：
///   1. 同步范围严格限定 Node 托管 11 家（见 [nodeManagedProviders]）；
///   2. 百度 / 夸克 / UC / 阿里的**原生**既有凭据与 Node 无交集，本服务不读写；
///   3. 凭据落点统一为契约安全存储，Node 仅作镜像。
///
/// 协议调用经 [NodeCredentialApiClient] 抽象注入（UI/测试不依赖真实端口）；
/// 缺省 [UnavailableNodeCredentialApiClient] 行为对齐 iOS Node 未就绪。
///
/// **配置文件差异登记**：iOS 内置 `noderuntime/wexfnwconfig.json`（随包分发），
/// 故其读取失败会计入摘要错误；Flutter 侧 Node 运行时目录由 ND-01（未交付）
/// 负责，本层以 [defaultNodeConfigFilePath] 解析，**目录未配置 / 文件缺失时
/// 视为空配置（不报错）**，仅解析失败才计入 `pull(file)` 错误。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/storage/storage_paths.dart';
import '../../../core/utils/logger.dart';
import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../../domain/entities/cloud/node_credential_sync.dart';
import '../local/cloud_drive_credential_store.dart';
import '../local/prefs_manager.dart';

/// 缺省 `wexfnwconfig.json` 路径（对齐 iOS `NodeRuntimeManager.shared.runtimeDir`）。
///
/// 解析为「应用数据根目录 / `noderuntime` / `wexfnwconfig.json`」；目录布局
/// 尚未配置（纯单测等）时返回 null —— 此时配置文件兜底读写整体跳过。
String? defaultNodeConfigFilePath() {
  if (!StoragePaths.isConfigured) return null;
  return p.join(StoragePaths.root, 'noderuntime', 'wexfnwconfig.json');
}

/// Node 凭据同步错误（文案对齐 iOS `NodeCredentialSyncError`）。
class NodeCredentialSyncException implements Exception {
  /// 构造。
  const NodeCredentialSyncException(this.message);

  /// 面向用户的错误文案。
  final String message;

  @override
  String toString() => message;
}

/// Node 凭据同步 HTTP 接缝（可注入）。
abstract interface class NodeCredentialApiClient {
  /// 发起 [method] 请求到 [path]，返回解析后的 JSON 对象。
  ///
  /// 失败（Node 未就绪 / 非 2xx / `code!=0`）抛 [NodeCredentialSyncException]。
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  });
}

/// 缺省接缝：Node 常驻系统未接入（对齐 iOS `nodeNotReady`）。
class UnavailableNodeCredentialApiClient implements NodeCredentialApiClient {
  /// 构造。
  const UnavailableNodeCredentialApiClient();

  @override
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async =>
      throw const NodeCredentialSyncException('Node 常驻系统未就绪');
}

/// 本机常驻 Node 进程客户端（`127.0.0.1:<port>`，默认 58080）。
///
/// 对齐 iOS `requestJSON(_:_:body:attempts:)`：最多 3 次重试（0.5s 递增退避），
/// 校验 HTTP 2xx 与响应体 `code == 0`。
class LocalNodeCredentialApiClient implements NodeCredentialApiClient {
  /// 构造（[port] 默认 58080；[timeout] 单次超时）。
  LocalNodeCredentialApiClient({
    this.port = 58080,
    this.timeout = const Duration(seconds: 15),
    this.attempts = 3,
  });

  /// Node 端口。
  final int port;

  /// 单次请求超时。
  final Duration timeout;

  /// 最大尝试次数。
  final int attempts;

  final HttpClient _client = HttpClient();

  @override
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    NodeCredentialSyncException last =
        const NodeCredentialSyncException('未知错误');
    for (int attempt = 1; attempt <= attempts; attempt++) {
      try {
        final HttpClientRequest req = await _client
            .openUrl(method, Uri.parse('http://127.0.0.1:$port$path'))
            .timeout(timeout);
        req.headers.contentType = ContentType.json;
        if (body != null) req.write(jsonEncode(body));
        final HttpClientResponse res = await req.close().timeout(timeout);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw NodeCredentialSyncException('HTTP ${res.statusCode}');
        }
        final String text = await res.transform(utf8.decoder).join();
        final Object? decoded =
            text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
        final Map<String, dynamic> json = decoded is Map
            ? <String, dynamic>{
                for (final MapEntry<Object?, Object?> e in decoded.entries)
                  e.key.toString(): e.value,
              }
            : <String, dynamic>{};
        final Object? code = json['code'];
        if (code is int && code != 0) {
          throw NodeCredentialSyncException(
            'Node 拒绝: ${json['msg'] ?? 'code=$code'}',
          );
        }
        return json;
      } catch (e) {
        last = e is NodeCredentialSyncException
            ? e
            : NodeCredentialSyncException('$e');
        if (attempt < attempts) {
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        }
      }
    }
    throw last;
  }

  /// 释放连接资源。
  void close() => _client.close(force: true);
}

/// Node 凭据同步服务。
class NodeCredentialSyncService {
  /// 构造（[client] 供测试注入；缺省「未接入」）。
  ///
  /// [configFilePath] 为 `wexfnwconfig.json` 绝对路径；缺省经
  /// [defaultNodeConfigFilePath] 解析（目录未配置时为 null → 配置文件兜底跳过）。
  NodeCredentialSyncService({
    CloudDriveCredentialStore? store,
    NodeCredentialApiClient client = const UnavailableNodeCredentialApiClient(),
    String? configFilePath,
  })  : _store = store,
        _client = client,
        _configFilePath = configFilePath ?? defaultNodeConfigFilePath();

  final CloudDriveCredentialStore? _store;
  final NodeCredentialApiClient _client;

  /// `wexfnwconfig.json` 绝对路径（null → 配置文件兜底读写整体跳过）。
  final String? _configFilePath;

  /// Node 就绪自动推送去重（对齐 iOS `hasAutoSynced`：只推一次，避免重复 PUT）。
  bool _hasAutoSynced = false;

  /// 是否已完成 Node 就绪自动推送。
  bool get hasAutoSynced => _hasAutoSynced;

  /// 懒取存储（缺省 `CloudDriveCredentialStore(PrefsManager.instance)`）。
  CloudDriveCredentialStore get store =>
      _store ?? CloudDriveCredentialStore(PrefsManager.instance);

  /// 按方向编排同步（对齐 iOS `syncNow(direction:)`）。
  Future<NodeCredentialSyncSummary> syncNow([
    NodeCredentialSyncDirection direction = NodeCredentialSyncDirection.both,
  ]) async {
    switch (direction) {
      case NodeCredentialSyncDirection.push:
        return push();
      case NodeCredentialSyncDirection.pull:
        return pull();
      case NodeCredentialSyncDirection.both:
        final NodeCredentialSyncSummary pushResult = await push();
        final NodeCredentialSyncSummary pullResult = await pull();
        return NodeCredentialSyncSummary(
          pushedFields: pushResult.pushedFields,
          pulledDrives: pullResult.pulledDrives,
          errors: <String>[...pushResult.errors, ...pullResult.errors],
          duration: pushResult.duration + pullResult.duration,
        );
    }
  }

  /// 本机 → Node（对齐 iOS `queryProfile()`）。
  Future<NodeCredentialSyncSummary> queryProfile() => push();

  /// Node → 本机（对齐 iOS `saveProfile()`）。
  Future<NodeCredentialSyncSummary> saveProfile() => pull();

  /// Node 就绪回调（对齐 iOS `handleNodeStatus`）：**仅首次**把本机凭据推送到 Node。
  ///
  /// 幂等：重复调用直接返回 null（不再 PUT）；返回首次推送摘要，或 null（已推过）。
  /// 由 Node 常驻系统就绪事件（ND-01 交付后）或启动编排调用。
  Future<NodeCredentialSyncSummary?> onNodeReady() async {
    if (_hasAutoSynced) return null;
    _hasAutoSynced = true;
    AppLog.info(
      'NodeSync',
      '✅ Node 就绪，自动推送本机凭据镜像',
      category: LogCategory.node,
    );
    return queryProfile();
  }

  /// 本机 → Node：逐字段 PUT。
  Future<NodeCredentialSyncSummary> push() async {
    final Stopwatch sw = Stopwatch()..start();
    int pushed = 0;
    final List<String> errors = <String>[];
    final Map<String, CloudDriveCredential> all = await store.loadAll();

    for (final MapEntry<String, NodeCredentialProviderSpec> entry
        in nodeManagedProviders.entries) {
      final CloudDriveCredential? credential = all[entry.key];
      if (credential == null) continue;
      for (final NodeCredentialFieldMap field in entry.value.fields) {
        final String? value =
            nodeCredentialSlotValue(credential, field.keychainSlot);
        if (value == null || value.isEmpty) continue;
        try {
          await _client.requestJson(
            'PUT',
            '/website/api/credential/${entry.value.provider}/${field.nodeField}',
            body: <String, dynamic>{'value': value},
          );
          pushed += 1;
        } catch (e) {
          errors.add('push ${entry.key}.${field.nodeField}: $e');
        }
      }
    }
    sw.stop();
    return NodeCredentialSyncSummary(
      pushedFields: pushed,
      errors: errors,
      duration: sw.elapsed,
    );
  }

  /// Node → 本机：GET 权威读接口 + 并读 `wexfnwconfig.json` 后合并落库。
  Future<NodeCredentialSyncSummary> pull() async {
    final Stopwatch sw = Stopwatch()..start();
    final Set<String> pulled = <String>{};
    final List<String> errors = <String>[];

    final Map<String, CloudDriveCredential> all = await store.loadAll();

    // 1) HTTP：GET /website/api/credentials（bundle 权威读接口，覆盖 7 盘）。
    try {
      final Map<String, dynamic> json =
          await _client.requestJson('GET', '/website/api/credentials');
      final Object? data = json['data'];
      if (data is Map) {
        for (final MapEntry<String, String> entry
            in nodePullableProviders.entries) {
          final Object? raw = data[entry.key];
          if (raw is! Map) continue;
          final NodeCredentialProviderSpec? spec =
              nodeManagedProviders[entry.value];
          if (spec == null) continue;
          final Map<String, String> values = <String, String>{};
          for (final NodeCredentialFieldMap field in spec.fields) {
            final Object? v = raw[field.nodeField];
            if (v is String && v.isNotEmpty) values[field.nodeField] = v;
          }
          if (values.isEmpty) continue;
          all[entry.value] =
              _upsert(all[entry.value], entry.value, values, spec);
          pulled.add(entry.value);
        }
      }
    } catch (e) {
      errors.add('pull(HTTP): $e');
    }

    // 2) 配置文件：直接读 wexfnwconfig.json（覆盖全部 11 盘，含 HTTP 不暴露的
    //    thunder / guangya / woniu4k）。目录未配置 / 文件缺失 → 空配置，不报错。
    try {
      final Map<String, Map<String, String>> fileValues =
          await _readConfigFileValues();
      for (final MapEntry<String, Map<String, String>> entry
          in fileValues.entries) {
        final NodeCredentialProviderSpec? spec =
            nodeManagedProviders[entry.key];
        if (spec == null) continue;
        all[entry.key] = _upsert(all[entry.key], entry.key, entry.value, spec);
        pulled.add(entry.key);
      }
    } catch (e) {
      errors.add('pull(file): $e');
    }

    if (pulled.isNotEmpty) {
      await store.saveAll(all);
    }
    sw.stop();
    return NodeCredentialSyncSummary(
      pulledDrives: pulled.toList()..sort(),
      errors: errors,
      duration: sw.elapsed,
    );
  }

  /// 读取 `wexfnwconfig.json` 并提取全部 Node 托管盘字段
  /// （对齐 iOS `readConfigFileValues`；文件缺失返回空，不报错）。
  Future<Map<String, Map<String, String>>> _readConfigFileValues() async {
    final String? path = _configFilePath;
    if (path == null) return const <String, Map<String, String>>{};
    final File file = File(path);
    if (!await file.exists()) return const <String, Map<String, String>>{};
    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const NodeCredentialSyncException('wexfnwconfig.json 格式异常');
    }
    return nodeConfigValuesByDrive(decoded);
  }

  /// 从 `wexfnwconfig.json` 移除该盘字段（对齐 iOS `removeConfigFileFields`）。
  ///
  /// 任一环节失败不中断（对齐 iOS 容错），错误写日志。
  Future<void> _removeConfigFileFields(NodeCredentialProviderSpec spec) async {
    final String? path = _configFilePath;
    if (path == null) return;
    final File file = File(path);
    if (!await file.exists()) return;
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final Map<String, dynamic> root = <String, dynamic>{
        for (final MapEntry<Object?, Object?> e in decoded.entries)
          e.key.toString(): e.value,
      };
      bool changed = false;
      for (final NodeCredentialFieldMap field in spec.fields) {
        if (nodeConfigRemoveAtPath(root, field.dbPath)) changed = true;
      }
      if (!changed) return;
      await file.writeAsString(_encodePrettySorted(root));
      AppLog.info(
        'NodeSync',
        '🗑 已从 wexfnwconfig.json 清理凭据字段',
        category: LogCategory.node,
      );
    } catch (e) {
      AppLog.warn(
        'NodeSync',
        '⚠️ wexfnwconfig.json 兜底清理失败: $e',
        category: LogCategory.node,
      );
    }
  }

  /// 排序键 + 两空格缩进的 JSON 编码（对齐 iOS `.prettyPrinted, .sortedKeys`）。
  static String _encodePrettySorted(Object? value) =>
      const JsonEncoder.withIndent('  ').convert(_sortJsonKeys(value));

  static Object? _sortJsonKeys(Object? value) {
    if (value is Map) {
      final Map<String, Object?> converted = <String, Object?>{
        for (final MapEntry<Object?, Object?> e in value.entries)
          e.key.toString(): _sortJsonKeys(e.value),
      };
      final List<String> keys = converted.keys.toList()..sort();
      return <String, Object?>{
        for (final String key in keys) key: converted[key],
      };
    }
    if (value is List) return value.map(_sortJsonKeys).toList();
    return value;
  }

  /// 级联删除 Node 登录态（对齐 iOS `deleteNodeCredential(driveType:)`）：
  /// 逐字段 DELETE + `wexfnwconfig.json` 兜底清理 + 本机主凭据删除。
  ///
  /// 说明：配置文件兜底清理防止 Node DELETE 失败后 pull 复活登录态
  /// （对齐 iOS `removeConfigFileFields`）；任一环节失败不中断，错误进摘要/日志。
  Future<NodeCredentialSyncSummary> deleteNodeCredential(
    CloudDriveType type,
  ) async {
    final Stopwatch sw = Stopwatch()..start();
    final NodeCredentialProviderSpec? spec = nodeManagedProviders[type.id];
    if (spec == null) {
      return const NodeCredentialSyncSummary();
    }
    final List<String> errors = <String>[];
    for (final NodeCredentialFieldMap field in spec.fields) {
      try {
        await _client.requestJson(
          'DELETE',
          '/website/api/credential/${spec.provider}/${field.nodeField}',
        );
      } catch (e) {
        errors.add('delete ${type.id}.${field.nodeField}: $e');
      }
    }
    await _removeConfigFileFields(spec);
    await store.remove(type);
    sw.stop();
    return NodeCredentialSyncSummary(errors: errors, duration: sw.elapsed);
  }

  /// 合并 Node 侧字段到本机凭据（统一标记 `valid` + 同步说明）。
  CloudDriveCredential _upsert(
    CloudDriveCredential? existing,
    String driveTypeId,
    Map<String, String> values,
    NodeCredentialProviderSpec spec,
  ) {
    CloudDriveCredential credential =
        existing ?? _emptyCredential(driveTypeId);
    for (final NodeCredentialFieldMap field in spec.fields) {
      final String? value = values[field.nodeField];
      if (value == null || value.isEmpty) continue;
      credential = withNodeCredentialSlot(credential, field.keychainSlot, value);
    }
    final DateTime now = DateTime.now();
    return credential.copyWith(
      state: CloudDriveAuthState.valid,
      statusMessage: '已与 Node 常驻系统同步',
      updatedAt: now,
      lastCheckedAt: now,
    );
  }

  CloudDriveCredential _emptyCredential(String driveTypeId) =>
      CloudDriveCredential(
        driveType: driveTypeId,
        updatedAt: DateTime.now(),
        state: CloudDriveAuthState.unknown,
      );
}
