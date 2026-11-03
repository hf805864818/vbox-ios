/// 网盘授权中心控制器与账户视图模型（批次 F · F-01）。
///
/// 对齐 iOS `CloudAuthCenterView`（`vbox/Views/SettingsViews.swift:1561`）：
/// - 卡片顺序 [cloudAuthCenterOrder] 与 iOS 主 VStack 一致（9 张普通卡 + 3 张
///   Node 托管卡）；
/// - [CloudDriveAccount] 承载 `accountHeader` / `authStatusRow` / `authDetailLine`
///   三处所需的展示字段；
/// - 授权判定 [CloudDriveAccount.fromCredential] 逐档对齐 iOS
///   `CloudDriveAuthManager.isAuthorized(_:)`（百度看 BDUSS/STOKEN，光鸭看
///   `extra["token"]`，蜗牛/B站看 cookie，其余看 primarySecret）；
/// - 状态文本 [CloudDriveAccount.statusText] 对齐 iOS `statusText(for:)`
///   （过期 / 30 分钟内即将过期 / `正常 · HH:mm检测`）。
///
/// 说明：真实授权（扫码 / 短信 / 网页兜底）属 F-02；本控制器做「读取本地凭据 →
/// 构建展示态」+「测试按钮真实网络校验并落库状态」（F-P24，对齐 iOS
/// `validateCredential(for:)` → `markValid` / `markInvalid`）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/datasources/local/cloud_drive_credential_store.dart';
import '../../../data/datasources/local/prefs_manager.dart';
import '../../../data/datasources/remote/cloud_drive_credential_validator.dart';
import '../../../data/datasources/remote/node_credential_sync_service.dart';
import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../../platform/node/node_runtime_manager.dart' as node;

/// 授权中心网盘展示顺序（对齐 iOS `CloudAuthCenterView` 卡片顺序）。
const List<CloudDriveType> cloudAuthCenterOrder = <CloudDriveType>[
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
];

/// Node 常驻系统托管的网盘（对齐 iOS `nodeManagedAccountCard`）。
const Set<CloudDriveType> kNodeManagedDrives = <CloudDriveType>{
  CloudDriveType.guangya,
  CloudDriveType.woniu4k,
  CloudDriveType.bilibili,
};

/// 各网盘授权说明文案（对齐 iOS `providerAccountCard(note:)` /
/// `nodeManagedAccountCard(note:)` 的 note 参数，逐字保留）。
const Map<CloudDriveType, String> cloudDriveNotes = <CloudDriveType, String>{
  CloudDriveType.baidu: '百度主账号态按 iBox 路线使用 BDUSS+STOKEN；BDCLND 会在分享'
      '验证后动态追加。点击「扫码授权」可在页内切换「原生扫码 / Node扫码」：原生写本地'
      '百度账号，Node 写入 Node 常驻系统（两条路链互不影响）。',
  CloudDriveType.quark: '支持原生/Node 双模式扫码登录（页内可切换）；也可使用网页登录兜底。',
  CloudDriveType.ali: '阿里云盘通过 OpenList 授权页扫码获取 refresh_token（对齐 '
      'iOS「原生扫码」），用于解析播放文件链接；也可网页兜底或手动粘贴 Token。',
  CloudDriveType.uc: '优先使用授权中心保存的 UC Cookie；支持原生/Node 双模式扫码登录'
      '（点击「原生扫码」页内可切换）；也可使用网页登录兜底。',
  CloudDriveType.one15: '115 使用官方网页扫码/登录回收完整 Cookie，手动 Cookie 继续保留。',
  CloudDriveType.pan123: '123云盘支持网页扫码登录回收 Cookie，播放分享链接时自动使用。',
  CloudDriveType.pan139: '139云盘（移动云盘）支持网页扫码登录回收 Cookie。',
  CloudDriveType.pan189: '天翼云盘支持账号密码 + 短信验证码登录获取 Cookie，用于解析播放分享链接。',
  CloudDriveType.xunlei: '迅雷云盘支持网页登录获取 Cookie，用于后续迅雷云盘资源解析播放。',
  CloudDriveType.guangya: '光鸭网盘由 Node 常驻系统托管：手机验证码登录后自动回收 Token，'
      '解析链路走 A1 接缝。',
  CloudDriveType.woniu4k: '蜗牛网盘由 Node 常驻系统托管：账号+密码+验证码登录，登录态自动回收 Cookie。',
  CloudDriveType.bilibili: 'B站由 Node 常驻系统托管：扫码登录后自动回收 Cookie，用于哔哩|影视 资源播放。',
};

/// 授权中心账户视图模型（对齐 iOS `accountHeader` / `authStatusRow` /
/// `authDetailLine` 所需字段）。
@immutable
class CloudDriveAccount {
  /// 构造。
  const CloudDriveAccount({
    required this.type,
    required this.subtitle,
    required this.authorized,
    required this.statusText,
    required this.statusReady,
    required this.detailFallback,
    this.hasCookieRow = false,
    this.cookieLabel,
    this.cookieReady = false,
    this.cookieStatusText = '',
    this.description,
  });

  /// 网盘类型。
  final CloudDriveType type;

  /// 副标题（对齐 `accountHeader(subtitle:)` / `authSubtitle`）。
  final String subtitle;

  /// 是否已授权（决定「已获取 / 未获取」角标）。
  final bool authorized;

  /// 状态文本（对齐 `authDetailLine` 的 `authManager.statusText`）。
  final String statusText;

  /// 状态是否就绪（决定状态文本配色）。
  final bool statusReady;

  /// 详情行左侧回退文案（对齐 `authDetailLine(fallback:)`）。
  final String detailFallback;

  /// 是否展示 Cookie 状态行（仅百度，对齐 `authStatusRow`）。
  final bool hasCookieRow;

  /// Cookie 行标题（如「基础登录 Web Cookie」）。
  final String? cookieLabel;

  /// Cookie 是否就绪。
  final bool cookieReady;

  /// Cookie 状态文本（如「BDUSS/STOKEN 已获取」）。
  final String cookieStatusText;

  /// 授权说明（对齐 iOS note 文案）。
  final String? description;

  /// 是否 Node 托管盘。
  bool get isNodeManaged => kNodeManagedDrives.contains(type);

  /// 「测试」按钮的 Widget key（供测试与自动化定位）。
  static String actionKey(CloudDriveType type) => 'cloud_drive_test_${type.id}';

  /// 由凭据构建展示态（无凭据 = 未授权）。
  factory CloudDriveAccount.fromCredential(
    CloudDriveType type,
    CloudDriveCredential? credential, {
    DateTime? now,
  }) {
    final DateTime at = now ?? DateTime.now();
    final bool authorized = isAuthorized(type, credential);
    final ({String text, bool ready}) webStatus = baiduWebStatus(
      type == CloudDriveType.baidu ? credential?.cookie : null,
    );
    return CloudDriveAccount(
      type: type,
      subtitle: authorized
          ? (credential?.displayName ?? '已授权账号')
          : '未登录',
      authorized: authorized,
      statusText: statusTextFor(credential, at),
      statusReady: credential?.isReady ?? false,
      detailFallback: kNodeManagedDrives.contains(type)
          ? 'Node 托管'
          : (credential?.displayName ?? '暂无 Token'),
      hasCookieRow: type == CloudDriveType.baidu,
      cookieLabel: type == CloudDriveType.baidu ? '基础登录 Web Cookie' : null,
      cookieReady: webStatus.ready,
      cookieStatusText: webStatus.text,
      description: cloudDriveNotes[type],
    );
  }

  /// 授权判定（对齐 iOS `CloudDriveAuthManager.isAuthorized(_:)`）。
  static bool isAuthorized(
    CloudDriveType type,
    CloudDriveCredential? credential,
  ) {
    if (credential == null || credential.state == CloudDriveAuthState.invalid) {
      return false;
    }
    if (type == CloudDriveType.baidu && credential.cookie != null) {
      return isBaiduAccountCookie(credential.cookie);
    }
    if (type == CloudDriveType.guangya) {
      final String? token = credential.extra['token'];
      return token != null && token.isNotEmpty;
    }
    if (type == CloudDriveType.woniu4k || type == CloudDriveType.bilibili) {
      final String? cookie = credential.cookie;
      return cookie != null && cookie.isNotEmpty;
    }
    return credential.hasSecret;
  }

  /// 百度账号 Cookie 判定（同时含 `BDUSS=` 与 `STOKEN=`）。
  static bool isBaiduAccountCookie(String? cookie) =>
      baiduWebStatus(cookie).ready;

  /// 百度 Web Cookie 状态（对齐 iOS `baiduWebStatus(_:)`）。
  static ({String text, bool ready}) baiduWebStatus(String? cookie) {
    final String lower = (cookie ?? '').toLowerCase();
    final bool hasBduss = lower.contains('bduss=');
    final bool hasStoken = lower.contains('stoken=');
    if (hasBduss && hasStoken) {
      return (text: 'BDUSS/STOKEN 已获取', ready: true);
    }
    if (hasBduss) return (text: '缺少 STOKEN', ready: false);
    if (hasStoken) return (text: '缺少 BDUSS', ready: false);
    return (text: '缺少 BDUSS/STOKEN', ready: false);
  }

  /// 状态文本（对齐 iOS `statusText(for:)`）。
  static String statusTextFor(CloudDriveCredential? credential, DateTime now) {
    if (credential == null) {
      return CloudDriveAuthState.notAuthorized.displayText;
    }
    final DateTime? expiresAt = credential.expiresAt;
    if (expiresAt != null) {
      if (expiresAt.isBefore(now)) {
        return CloudDriveAuthState.expired.displayText;
      }
      if (expiresAt.difference(now) < const Duration(minutes: 30)) {
        return CloudDriveAuthState.expiringSoon.displayText;
      }
    }
    final DateTime? checked = credential.lastCheckedAt;
    if (checked != null) {
      return '${credential.state.displayText} · ${_shortTime(checked)}检测';
    }
    return credential.state.displayText;
  }

  static String _shortTime(DateTime value) {
    final DateTime local = value.toLocal();
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${pad(local.hour)}:${pad(local.minute)}';
  }
}

/// 网盘授权中心控制器。
///
/// 生命周期由使用方持有（页面自建或测试注入）；[load] 读契约安全存储
/// （`cloud_drive_credentials_v1`）构建 [accounts]。
class CloudDriveAuthController extends ChangeNotifier {
  /// 构造（[credentialStore] / [validator] 供测试注入；缺省走
  /// [PrefsManager] / [CloudDriveCredentialValidator]）。
  ///
  /// [nodeRuntimeManager] 非空时订阅其状态流，把 Node 常驻系统的真实运行态
  /// （就绪 / 启动中 / 内存告警 / 失败 / 崩溃）映射到 [nodeStatus]，对齐 iOS
  /// `CloudAuthCenterView` 直接 `@ObservedObject NodeRuntimeManager.shared`
  /// 的做法（此前恒为 `未知` 是因为从未接线状态源）。
  CloudDriveAuthController({
    CloudDriveCredentialStore? credentialStore,
    CloudDriveCredentialValidator? validator,
    NodeRuntimeStatus nodeStatus = const NodeRuntimeStatus(),
    node.NodeRuntimeManager? nodeRuntimeManager,
  })  : _store = credentialStore ??
            CloudDriveCredentialStore(PrefsManager.instance),
        _validator = validator ??
            CloudDriveCredentialValidator(prefs: PrefsManager.instance),
        _nodeStatus = nodeStatus,
        _nodeRuntime = nodeRuntimeManager {
    final node.NodeRuntimeManager? runtime = _nodeRuntime;
    if (runtime != null) {
      _syncNodeStatus(runtime);
      _nodeSub = runtime.statusStream.listen((node.NodeRuntimeStatus _) {
        _syncNodeStatus(runtime);
      });
    }
  }

  final CloudDriveCredentialStore _store;
  final CloudDriveCredentialValidator _validator;
  final node.NodeRuntimeManager? _nodeRuntime;
  StreamSubscription<node.NodeRuntimeStatus>? _nodeSub;
  NodeRuntimeStatus _nodeStatus;
  List<CloudDriveAccount> _accounts = const <CloudDriveAccount>[];
  List<CloudDriveCredential> _credentials = const <CloudDriveCredential>[];
  bool _loading = true;

  /// 账户列表（顺序 = [cloudAuthCenterOrder]）。
  List<CloudDriveAccount> get accounts => _accounts;

  /// 已保存凭据清单（底部「复制粘贴 Token 兜底」卡片消费）。
  List<CloudDriveCredential> get savedTokens => _credentials;

  /// Node 常驻系统状态快照。
  NodeRuntimeStatus get nodeStatus => _nodeStatus;

  /// 是否加载中。
  bool get loading => _loading;

  @override
  void dispose() {
    unawaited(_nodeSub?.cancel());
    super.dispose();
  }

  /// 把 Node 运行时快照映射为授权中心横幅状态（对齐 iOS `nodeRuntimeStatusInfo`）。
  void _syncNodeStatus(node.NodeRuntimeManager manager) {
    final node.NodeRuntimeStatus platform = manager.status;
    NodeRuntimeState state;
    String detail = '';
    if (platform == node.NodeRuntimeStatus.memoryWarning) {
      state = NodeRuntimeState.memoryWarning;
    } else if (manager.isSystemReady) {
      state = NodeRuntimeState.ready;
    } else if (manager.isCrashed) {
      final String? error = manager.lastError;
      if (error != null && error.isNotEmpty) {
        state = NodeRuntimeState.failed;
        detail = error;
      } else {
        state = NodeRuntimeState.crashed;
      }
    } else {
      state = switch (platform) {
        node.NodeRuntimeStatus.stopped => NodeRuntimeState.stopped,
        node.NodeRuntimeStatus.starting => NodeRuntimeState.starting,
        node.NodeRuntimeStatus.ready => NodeRuntimeState.ready,
        node.NodeRuntimeStatus.memoryWarning => NodeRuntimeState.memoryWarning,
        node.NodeRuntimeStatus.crashed => NodeRuntimeState.crashed,
        node.NodeRuntimeStatus.failed => NodeRuntimeState.failed,
      };
      if (state == NodeRuntimeState.failed) {
        detail = manager.lastError ?? '';
      }
    }
    final int port = manager.activePort;
    if (_nodeStatus.state == state &&
        _nodeStatus.port == port &&
        _nodeStatus.detail == detail) {
      return;
    }
    _nodeStatus = NodeRuntimeStatus(state: state, port: port, detail: detail);
    notifyListeners();
  }

  /// 读取凭据并重建账户列表。
  Future<void> load() async {
    _loading = true;
    notifyListeners();
    final node.NodeRuntimeManager? runtime = _nodeRuntime;
    if (runtime != null) _syncNodeStatus(runtime);
    final Map<String, CloudDriveCredential> all = await _store.loadAll();
    _credentials = all.values.toList(growable: false);
    _accounts = <CloudDriveAccount>[
      for (final CloudDriveType type in cloudAuthCenterOrder)
        CloudDriveAccount.fromCredential(type, all[type.id]),
    ];
    _loading = false;
    notifyListeners();
  }

  /// 「测试」按钮：真实校验凭据并落库状态（F-P24，对齐 iOS
  /// `validateCredential(for:)` → `markValid` / `markInvalid`）。
  Future<void> testCredential(CloudDriveType type) async {
    final CloudDriveCredential? credential = await _store.credential(type);
    if (credential == null) return;
    final CredentialValidationResult result =
        await _validator.validate(type, credential);
    // P2-5：防风控冷却跳过 → 不落库不改状态（结果既非已验证有效也非失效）。
    if (result.skipped) return;
    final DateTime now = DateTime.now();
    await _store.save(
      credential.copyWith(
        state: result.valid ? CloudDriveAuthState.valid : CloudDriveAuthState.invalid,
        statusMessage: result.message,
        lastCheckedAt: now,
        updatedAt: now,
      ),
    );
    await load();
  }

  /// 手动粘贴保存 Token / Cookie（对齐 iOS `addDriveTokenFromFallback`）。
  ///
  /// 写入契约安全存储 `cloud_drive_credentials_v1`：`userName` 存备注名，
  /// 主密钥按网盘类型落到合适字段（百度 → cookie，其余 → accessToken）；
  /// 同时追加到手动 Token 向量 `saved_drive_tokens_v1`（对齐 iOS `addToken`）。
  Future<void> saveManualToken(
    CloudDriveType type,
    String name,
    String value,
  ) async {
    final DateTime now = DateTime.now();
    final CloudDriveCredential credential = CloudDriveCredential(
      driveType: type.id,
      authType: CloudDriveAuthType.manual,
      userName: name,
      cookie: type == CloudDriveType.baidu ? value : null,
      accessToken: type == CloudDriveType.baidu ? null : value,
      updatedAt: now,
      lastCheckedAt: now,
      state: CloudDriveAuthState.valid,
    );
    await _store.save(credential);
    await _store.addToken(DriveToken(type: type.id, name: name, value: value));
    await load();
  }

  /// 删除某网盘凭据（对齐 iOS `removeToken(at:)`）。
  Future<void> removeCredential(CloudDriveType type) async {
    // P2-4：删除前级联清 Node 侧登录态（对齐 iOS
    // `NodeCredentialSyncService.deleteNodeCredential(driveType:)`，
    // `NodeCredentialSyncService.swift:231-260`）：逐字段 DELETE +
    // 配置文件兜底清理，防止 Node 登录态被 pull「复活」。
    // 实现已在 [NodeCredentialSyncService.deleteNodeCredential]，此处仅接线；
    // Node 侧失败不中断本地删除（本地凭据必须删掉），错误吞掉记日志。
    try {
      await NodeCredentialSyncService(
        client: LocalNodeCredentialApiClient(),
      ).deleteNodeCredential(type);
    } catch (e) {
      debugPrint('[CloudDriveAuth] 删除 Node 侧凭据失败($type): $e');
    }
    await _store.remove(type);
    await load();
  }
}
