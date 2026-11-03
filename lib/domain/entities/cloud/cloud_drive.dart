/// 网盘领域模型（批次 F · F-01 / F-03）。
///
/// 对齐 iOS（唯一契约来源）：
/// - `CloudDriveManager.DriveType`（`vbox/Services/CloudDriveManager.swift:63`）
/// - `CloudDriveAuthType` / `CloudDriveAuthState`（`vbox/Services/CloudDriveAuthManager.swift:7/14`）
/// - `CloudDriveCredential`（`vbox/Services/CloudDriveAuthManager.swift:34`）
/// - `CloudDriveSortManager.defaultOrder`（`vbox/Services/CloudDriveSortManager.swift:9`）
library;

/// 网盘类型（15 项，对齐 iOS `CloudDriveManager.DriveType`）。
///
/// `id` 为契约字符串值（详设页排序持久化 / 凭据字典键均用它）。
enum CloudDriveType {
  /// 阿里云盘。
  ali('ali', '阿里云盘', 'Refresh Token'),

  /// 夸克网盘。
  quark('quark', '夸克网盘', 'Cookie'),

  /// 夸克网盘（Node 托管盘）。
  quarkNode('quarkNode', '夸克Node', 'Cookie'),

  /// 百度网盘。
  baidu('baidu', '百度网盘', '完整 Cookie / BDUSS+STOKEN'),

  /// 百度网盘（Node 托管盘）。
  baiduNode('baiduNode', '百度网盘Node', 'Cookie / BDUSS+STOKEN'),

  /// 115 网盘。
  one15('115', '115网盘', '完整 Cookie / CID'),

  /// UC 网盘。
  uc('uc', 'UC网盘', 'Cookie'),

  /// UC 网盘（Node 托管盘）。
  ucNode('ucNode', 'UC网盘Node', 'Cookie / TV Token'),

  /// 123 云盘。
  pan123('123pan', '123云盘', 'Cookie / Token'),

  /// 139 云盘。
  pan139('139pan', '139云盘', 'Cookie / Session'),

  /// 天翼云盘（189）。
  pan189('189pan', '天翼云盘', 'Cookie / 账号密码（短信验证）'),

  /// 迅雷云盘。
  xunlei('xunlei', '迅雷云盘', 'Cookie / 网页登录'),

  /// 光鸭网盘。
  guangya('guangya', '光鸭网盘', 'Token'),

  /// 蜗牛网盘。
  woniu4k('woniu4k', '蜗牛网盘', '账号 / 密码'),

  /// 哔哩哔哩。
  bilibili('bilibili', '哔哩哔哩', 'Cookie');

  const CloudDriveType(this.id, this.displayName, this.tokenLabel);

  /// 契约字符串值（对齐 iOS `rawValue`）。
  final String id;

  /// 中文显示名（对齐 iOS `displayName`）。
  final String displayName;

  /// 凭据字段提示（对齐 iOS `tokenLabel`）。
  final String tokenLabel;

  /// 详情页默认显示顺序（对齐 iOS `CloudDriveSortManager.defaultOrder`）。
  static const List<CloudDriveType> defaultSortOrder = <CloudDriveType>[
    quark,
    uc,
    baidu,
    ali,
    one15,
    pan123,
    pan139,
    pan189,
  ];

  /// 派生盘：详情页位置恒定跟随其原生盘，不参与独立排序。
  ///
  /// 对齐 iOS `CloudDriveSortManager.sortableOrder` 的排除项
  /// （夸克Node / UC网盘Node / 百度网盘Node）。
  bool get isNodeDerived =>
      this == quarkNode || this == ucNode || this == baiduNode;

  /// 由契约字符串解析（未知 / 空返回 null）。
  static CloudDriveType? fromId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final CloudDriveType type in values) {
      if (type.id == id) return type;
    }
    return null;
  }

  /// 由中文显示名解析（对齐 iOS `driveType(forDisplayName:)`）。
  static CloudDriveType? fromDisplayName(String? name) {
    if (name == null || name.isEmpty) return null;
    for (final CloudDriveType type in values) {
      if (type.displayName == name) return type;
    }
    return null;
  }

  /// 由分享链接识别网盘类型（对齐 iOS 播放器 `handleDriveUrl` 的域名判定；
  /// 域名清单与 `PushPlayStore.detectType` / iOS `cloudPatterns` 一致）。
  ///
  /// 无法识别返回 null。Node 派生盘不参与判定 —— 是否走 Node 链路
  /// 由 `NodePanRouting.isNodeManaged` 在运行期决定。
  static CloudDriveType? fromShareUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final String lower = url.toLowerCase();
    for (final MapEntry<String, CloudDriveType> entry
        in _shareUrlPatterns.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    return null;
  }

  /// 分享链接域名片段 → 网盘类型（先特异后通用，顺序即优先级）。
  static const Map<String, CloudDriveType> _shareUrlPatterns =
      <String, CloudDriveType>{
    'alipan.com': ali,
    'aliyundrive.com': ali,
    'pan.quark.cn': quark,
    'quark.cn': quark,
    'pan.baidu.com': baidu,
    'yun.baidu.com': baidu,
    'baidu.com': baidu,
    '115cdn.com': one15,
    '115.com': one15,
    'drive.uc.cn': uc,
    'uc.cn': uc,
    '123pan.com': pan123,
    'caiyun.139.com': pan139,
    '139.com': pan139,
    'cloud.189.cn': pan189,
    '189.cn': pan189,
    'pan.xunlei.com': xunlei,
    'xunlei.com': xunlei,
    'bilibili.com': bilibili,
  };
}

/// 登录方式（对齐 iOS `CloudDriveAuthType`）。
enum CloudDriveAuthType {
  /// 手动粘贴。
  manual('manual'),

  /// 扫码。
  qr('qr'),

  /// 网页兜底（Token WebView）。
  webView('webView'),

  /// OAuth。
  oauth('oauth');

  const CloudDriveAuthType(this.id);

  /// 契约字符串值。
  final String id;

  /// 由契约字符串解析（未知 / 空回退 [manual]）。
  static CloudDriveAuthType fromId(String? id) {
    for (final CloudDriveAuthType type in values) {
      if (type.id == id) return type;
    }
    return manual;
  }
}

/// 授权状态（对齐 iOS `CloudDriveAuthState`）。
enum CloudDriveAuthState {
  /// 未授权。
  notAuthorized('notAuthorized', '未授权'),

  /// 正常。
  valid('valid', '正常'),

  /// 即将过期。
  expiringSoon('expiringSoon', '即将过期'),

  /// 已过期。
  expired('expired', '已过期'),

  /// 授权失效。
  invalid('invalid', '授权失效'),

  /// 未检测。
  unknown('unknown', '未检测');

  const CloudDriveAuthState(this.id, this.displayText);

  /// 契约字符串值。
  final String id;

  /// 中文显示文本（对齐 iOS `displayText`）。
  final String displayText;

  /// 是否就绪（对齐 iOS `isAuthorized` 判定：仅 `valid` 为真）。
  bool get isReady => this == valid;

  /// 由契约字符串解析（未知 / 空回退 [unknown]）。
  static CloudDriveAuthState fromId(String? id) {
    for (final CloudDriveAuthState state in values) {
      if (state.id == id) return state;
    }
    return unknown;
  }
}

/// 网盘授权凭据（对齐 iOS `CloudDriveCredential`）。
///
/// 落盘位置：Keychain 账号 `cloud_drive_credentials_v1`（契约 `storage: keychain`），
/// 序列化形态为 `{ "<driveType>": <credential> }` 的 JSON 对象字符串。
class CloudDriveCredential {
  /// 构造。
  const CloudDriveCredential({
    required this.driveType,
    required this.updatedAt,
    this.authType = CloudDriveAuthType.manual,
    this.accessToken,
    this.refreshToken,
    this.cookie,
    this.driveId,
    this.userId,
    this.userName,
    this.avatar,
    this.expiresAt,
    this.lastCheckedAt,
    this.state = CloudDriveAuthState.unknown,
    this.statusMessage,
    this.extra = const <String, String>{},
  });

  /// 契约字符串值（对应 [CloudDriveType.id]）。
  final String driveType;

  /// 登录方式。
  final CloudDriveAuthType authType;

  /// 访问令牌。
  final String? accessToken;

  /// 刷新令牌。
  final String? refreshToken;

  /// Cookie。
  final String? cookie;

  /// 网盘侧用户 ID。
  final String? driveId;

  /// 用户 ID。
  final String? userId;

  /// 用户名（显示名优先取它）。
  final String? userName;

  /// 头像。
  final String? avatar;

  /// 凭据过期时间。
  final DateTime? expiresAt;

  /// 最近更新时间。
  final DateTime updatedAt;

  /// 最近校验时间。
  final DateTime? lastCheckedAt;

  /// 授权状态。
  final CloudDriveAuthState state;

  /// 状态说明。
  final String? statusMessage;

  /// 扩展字段（对齐 iOS `extra`）。
  final Map<String, String> extra;

  /// 对应的网盘类型（契约值非法时为 null）。
  CloudDriveType? get type => CloudDriveType.fromId(driveType);

  /// 显示名（对齐 iOS `displayName`）：优先 `userName`，否则「已授权账号」。
  String get displayName =>
      (userName != null && userName!.isNotEmpty) ? userName! : '已授权账号';

  /// 主密钥（对齐 iOS `primarySecret`）：refreshToken → cookie → accessToken。
  String? get primarySecret {
    if (refreshToken != null && refreshToken!.isNotEmpty) return refreshToken;
    if (cookie != null && cookie!.isNotEmpty) return cookie;
    if (accessToken != null && accessToken!.isNotEmpty) return accessToken;
    return null;
  }

  /// 是否已持有可用密钥。
  bool get hasSecret => primarySecret != null;

  /// 是否就绪（状态 `valid` 且持有密钥）。
  bool get isReady => state.isReady && hasSecret;

  /// 复制并覆盖部分字段。
  CloudDriveCredential copyWith({
    CloudDriveAuthType? authType,
    String? accessToken,
    String? refreshToken,
    String? cookie,
    String? driveId,
    String? userId,
    String? userName,
    String? avatar,
    DateTime? expiresAt,
    DateTime? updatedAt,
    DateTime? lastCheckedAt,
    CloudDriveAuthState? state,
    String? statusMessage,
    Map<String, String>? extra,
  }) {
    return CloudDriveCredential(
      driveType: driveType,
      authType: authType ?? this.authType,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      cookie: cookie ?? this.cookie,
      driveId: driveId ?? this.driveId,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      avatar: avatar ?? this.avatar,
      expiresAt: expiresAt ?? this.expiresAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      state: state ?? this.state,
      statusMessage: statusMessage ?? this.statusMessage,
      extra: extra ?? this.extra,
    );
  }

  /// 反序列化（字段缺失按 iOS `Codable` 语义回退缺省值）。
  factory CloudDriveCredential.fromJson(Map<String, dynamic> json) {
    return CloudDriveCredential(
      driveType: (json['driveType'] as String?) ?? '',
      authType: CloudDriveAuthType.fromId(json['authType'] as String?),
      accessToken: json['accessToken'] as String?,
      refreshToken: json['refreshToken'] as String?,
      cookie: json['cookie'] as String?,
      driveId: json['driveId'] as String?,
      userId: json['userId'] as String?,
      userName: json['userName'] as String?,
      avatar: json['avatar'] as String?,
      expiresAt: _parseDate(json['expiresAt']),
      updatedAt: _parseDate(json['updatedAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      lastCheckedAt: _parseDate(json['lastCheckedAt']),
      state: CloudDriveAuthState.fromId(json['state'] as String?),
      statusMessage: json['statusMessage'] as String?,
      extra: _parseStringMap(json['extra']),
    );
  }

  /// 序列化（日期按 ISO-8601 字符串）。
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'driveType': driveType,
      'authType': authType.id,
      if (accessToken != null) 'accessToken': accessToken,
      if (refreshToken != null) 'refreshToken': refreshToken,
      if (cookie != null) 'cookie': cookie,
      if (driveId != null) 'driveId': driveId,
      if (userId != null) 'userId': userId,
      if (userName != null) 'userName': userName,
      if (avatar != null) 'avatar': avatar,
      if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      if (lastCheckedAt != null) 'lastCheckedAt': lastCheckedAt!.toIso8601String(),
      'state': state.id,
      if (statusMessage != null) 'statusMessage': statusMessage,
      'extra': extra,
    };
  }

  static DateTime? _parseDate(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  static Map<String, String> _parseStringMap(Object? value) {
    if (value is! Map) return const <String, String>{};
    return <String, String>{
      for (final MapEntry<Object?, Object?> e in value.entries)
        if (e.key != null && e.value != null) e.key.toString(): e.value.toString(),
    };
  }
}

/// 手动保存的网盘 Token / Cookie（对齐 iOS `DriveToken`）。
///
/// 落盘位置：Keychain 账号 `saved_drive_tokens_v1`（契约 `storage: keychain`），
/// 序列化形态为 `[DriveToken]` JSON 数组；[type] 为 [CloudDriveType.id]。
///
/// 与 [CloudDriveCredential] 的关系对齐 iOS：凭据对象存「授权中心扫码 / OAuth」
/// 的账号态，本向量存「设置页手动粘贴」的原始 Token（百度 Web / PCS 双份）。
class DriveToken {
  /// 构造。
  const DriveToken({
    required this.type,
    required this.name,
    required this.value,
  });

  /// 网盘类型契约值（对应 [CloudDriveType.id]）。
  final String type;

  /// 备注名（对齐 iOS `name`；同盘同名视为同一槽位）。
  final String name;

  /// 密钥值（对齐 iOS `value`）。
  final String value;

  /// 反序列化（字段缺失回退空串，对齐 iOS `Codable` 缺省）。
  factory DriveToken.fromJson(Map<String, dynamic> json) => DriveToken(
        type: (json['type'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        value: (json['value'] as String?) ?? '',
      );

  /// 序列化（对齐 iOS `DriveToken` 三字段）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'name': name,
        'value': value,
      };
}

/// 百度双 Token 配对（对齐 iOS `CloudDriveManager.baiduTokenPair()`）。
class BaiduTokenPair {
  /// 构造。
  const BaiduTokenPair({required this.web, this.pcs});

  /// Web Cookie（BDUSS + STOKEN，主路链必需）。
  final DriveToken web;

  /// PCS 高速 Cookie（可选，取自授权中心 `extra["pcs_cookie"]`）。
  final DriveToken? pcs;
}

/// 百度账号 Web Cookie 判定（同时含 `BDUSS=` 与 `STOKEN=`）。
///
/// 对齐 iOS `CloudDriveManager.isBaiduAccountWebCookie`。
bool isBaiduAccountWebCookie(String? value) {
  final String lower = (value ?? '').toLowerCase();
  return lower.contains('bduss=') && lower.contains('stoken=');
}

/// 百度 PCS 高速 Cookie 判定。
///
/// 对齐 iOS `CloudDriveManager.isBaiduPCSCookie`。
bool isBaiduPcsCookie(String? value) {
  final String lower = (value ?? '').toLowerCase();
  return lower.contains('panpsc=') ||
      lower.contains('ptoken=') ||
      lower.contains('ptoken_bfess=') ||
      lower.contains('ndut_fmt=') ||
      lower.contains('nd_ftid=');
}

/// 百度 PCS 高速 Token 判定（名称特征或值形态，对齐 iOS `isBaiduPCSToken`）。
bool isBaiduPcsToken(DriveToken token) {
  final String name = token.name.toLowerCase();
  if (name.contains('pcs') ||
      name.contains('下载') ||
      name.contains('直链') ||
      name.contains('locatedownload')) {
    return true;
  }
  return isBaiduPcsCookie(token.value);
}

/// 百度账号 Web Token 判定（对齐 iOS `isBaiduAccountWebToken`）。
bool isBaiduAccountWebToken(DriveToken token) =>
    isBaiduAccountWebCookie(token.value);

/// Node 常驻系统运行状态（对齐 iOS `NodeRuntimeManager` 状态面）。
enum NodeRuntimeState {
  /// 未知。
  unknown('未知'),

  /// 未启动。
  stopped('未启动'),

  /// 启动中。
  starting('启动中'),

  /// 就绪。
  ready('就绪'),

  /// 内存告警（Node 仍可用）。
  memoryWarning('内存告警'),

  /// 失败。
  failed('失败'),

  /// 崩溃。
  crashed('崩溃');

  const NodeRuntimeState(this.displayText);

  /// 中文显示文本。
  final String displayText;

  /// 是否就绪。
  bool get isReady => this == ready;

  /// 是否异常（失败 / 崩溃）。
  bool get isError => this == failed || this == crashed;

  /// 是否过渡态（未启动 / 启动中）。
  bool get isPending => this == stopped || this == starting;
}

/// Node 常驻系统状态快照（授权中心顶部横幅数据源）。
class NodeRuntimeStatus {
  /// 构造。
  const NodeRuntimeStatus({
    this.state = NodeRuntimeState.unknown,
    this.port = 0,
    this.detail = '',
  });

  /// 状态。
  final NodeRuntimeState state;

  /// 就绪时的活动端口（iOS 默认 58080）。
  final int port;

  /// 补充说明（失败原因等）。
  final String detail;

  /// 横幅正文（对齐 iOS `nodeRuntimeStatusInfo` 的 detail 口径）。
  String get detailText => switch (state) {
        NodeRuntimeState.ready => '端口 $port · 网盘解析链路可用',
        NodeRuntimeState.memoryWarning => 'Node 仍可用，建议重启 App 释放内存',
        NodeRuntimeState.failed => detail.isEmpty ? 'Node 服务启动失败' : detail,
        NodeRuntimeState.crashed => 'Node 服务已停止，请重启 App 恢复',
        NodeRuntimeState.starting => 'Node 引擎正在拉起，请稍候…',
        NodeRuntimeState.stopped => '等待启动（App 启动后自动拉起）',
        NodeRuntimeState.unknown => detail.isEmpty ? '状态：未知' : '状态：$detail',
      };
}
