/// 网盘登录领域模型（批次 F · F-02）。
///
/// 对齐 iOS 授权中心的动作分档（`SettingsViews.swift` `authButtonLabel` /
/// `providerAccountCard` / `nodeManagedAccountCard`）与两种登录态机：
/// - 扫码态机 `qrLoginState`（`NativeCloudQRLoginView` `SettingsViews.swift:4391`、
///   `BiliQrLoginView`）；
/// - 短信态机（`NodeGuangyaSMSLoginView` `NodeLoginViews.swift:123`）。
///
/// 本文件只承载**纯领域**语义（方式 / 阶段 / 配色档），不含任何 Flutter 依赖，
/// 具体色值与图标由表现层按令牌层映射。
library;

import 'cloud_drive.dart';

/// 网盘登录方式（授权中心动作按钮 → 登录链分派）。
enum CloudDriveLoginMode {
  /// 原生扫码（阿里 / UC / 百度 / B站 / 夸克 等「原生」档）。
  nativeQr('native_qr', '原生扫码', '扫码授权'),

  /// Node 常驻系统扫码（115 / 百度 Node 等）。
  nodeQr('node_qr', 'Node 扫码登录', '扫码授权'),

  /// Node 常驻系统短信验证码登录（光鸭 / 139 / 189 / 迅雷 等）。
  nodeSms('node_sms', '验证码登录', '验证码登录'),

  /// Node 常驻系统账号登录（123 / 蜗牛 等）。
  nodeAccount('node_account', '账号登录', '账号登录'),

  /// 网页登录兜底（WKWebView 承载，回写 Cookie）。
  webFallback('web_fallback', '网页登录兜底', '网页兜底'),

  /// PG 阿里云盘扫码登录（extscreen 链路，`AliyunPgQrLoginView`）。
  pgQr('pg_qr', 'PG 扫码登录', '扫码授权');

  const CloudDriveLoginMode(this.id, this.title, this.sheetTitle);

  /// 契约 / 日志用稳定标识。
  final String id;

  /// 动作按钮文案（授权中心展示）。
  final String title;

  /// 登录 Sheet 顶栏标题（对齐 iOS `navigationTitle("扫码授权")` 等）。
  final String sheetTitle;

  /// 是否走 Node 常驻系统（决定「未就绪」提示文案与网关分支）。
  bool get usesNode => switch (this) {
        CloudDriveLoginMode.nodeQr ||
        CloudDriveLoginMode.nodeSms ||
        CloudDriveLoginMode.nodeAccount =>
          true,
        CloudDriveLoginMode.nativeQr ||
        CloudDriveLoginMode.webFallback ||
        CloudDriveLoginMode.pgQr =>
          false,
      };

  /// 是否扫码类（展示 220×220 二维码卡片）。
  bool get isQr => switch (this) {
        CloudDriveLoginMode.nativeQr ||
        CloudDriveLoginMode.nodeQr ||
        CloudDriveLoginMode.pgQr =>
          true,
        CloudDriveLoginMode.nodeSms ||
        CloudDriveLoginMode.nodeAccount ||
        CloudDriveLoginMode.webFallback =>
          false,
      };

  /// 是否短信验证码类（展示手机号 + 验证码表单）。
  bool get isSms => this == CloudDriveLoginMode.nodeSms;

  /// 是否网页兜底类（WebView 承载）。
  bool get isWeb => this == CloudDriveLoginMode.webFallback;

  /// 由授权中心动作按钮文案解析登录方式（见 `cloudDriveAuthActions`）。
  ///
  /// 未知文案回退 [nativeQr]（对齐 iOS 默认「原生扫码」档）。
  static CloudDriveLoginMode fromActionLabel(String label) => switch (label) {
        '原生扫码' || '扫码授权' || '扫码登录' => CloudDriveLoginMode.nativeQr,
        'Node扫码登录' => CloudDriveLoginMode.nodeQr,
        'Node账号登录' || '账号登录' => CloudDriveLoginMode.nodeAccount,
        'Node验证码登录' || '手机验证码登录' => CloudDriveLoginMode.nodeSms,
        '网页登录兜底' || '网页兜底' => CloudDriveLoginMode.webFallback,
        'PG扫码登录' => CloudDriveLoginMode.pgQr,
        _ => CloudDriveLoginMode.nativeQr,
      };
}

/// 登录会话阶段（对齐 iOS `qrLoginState` 的档位与显示文案）。
enum CloudDriveLoginPhase {
  /// 空闲（尚未发起，按钮文案取「生成二维码」）。
  idle('准备生成二维码'),

  /// 正在生成 / 加载。
  loading('正在生成二维码…'),

  /// 等待扫码。
  waitingScan('等待扫码'),

  /// 已扫码，等待手机确认。
  scanned('已扫码，请在手机上确认'),

  /// 正在确认登录（换取凭据）。
  exchanging('正在确认登录…'),

  /// 正在保存凭据 / 回收 Cookie。
  saving('正在保存凭据…'),

  /// 成功。
  success('登录成功'),

  /// 失败。
  failed('登录失败');

  const CloudDriveLoginPhase(this.displayText);

  /// 状态文案（对齐 iOS `qrLoginState.displayText`）。
  final String displayText;

  /// 是否轮询中（主按钮文案切「重新生成二维码」）。
  bool get isPolling => switch (this) {
        CloudDriveLoginPhase.loading ||
        CloudDriveLoginPhase.waitingScan ||
        CloudDriveLoginPhase.scanned ||
        CloudDriveLoginPhase.exchanging ||
        CloudDriveLoginPhase.saving =>
          true,
        CloudDriveLoginPhase.idle ||
        CloudDriveLoginPhase.success ||
        CloudDriveLoginPhase.failed =>
          false,
      };

  /// 是否可「取消」（对齐 iOS `waitingScan / scanned / exchanging` 档）。
  bool get canCancel => isPolling;

  /// 是否终态（轮询需停止）。
  bool get isTerminal =>
      this == CloudDriveLoginPhase.success || this == CloudDriveLoginPhase.failed;

  /// 配色档（表现层据此映射令牌色，域层不持有色值）。
  CloudDriveLoginTone get tone => switch (this) {
        CloudDriveLoginPhase.idle => CloudDriveLoginTone.neutral,
        CloudDriveLoginPhase.loading ||
        CloudDriveLoginPhase.exchanging ||
        CloudDriveLoginPhase.saving =>
          CloudDriveLoginTone.busy,
        CloudDriveLoginPhase.waitingScan => CloudDriveLoginTone.active,
        CloudDriveLoginPhase.scanned => CloudDriveLoginTone.pending,
        CloudDriveLoginPhase.success => CloudDriveLoginTone.ok,
        CloudDriveLoginPhase.failed => CloudDriveLoginTone.error,
      };
}

/// 登录状态配色档（对齐 iOS `statusColor` 分支语义）。
enum CloudDriveLoginTone {
  /// 中性（idle · 灰）。
  neutral,

  /// 进行中（loading · 橙）。
  busy,

  /// 等待扫码（waitingScan · 蓝）。
  active,

  /// 待确认（scanned · 黄）。
  pending,

  /// 成功（success · 绿）。
  ok,

  /// 失败（failed · 红）。
  error,
}

/// 网页登录兜底元数据（批次 F · F-02 余项）。
///
/// 对齐 iOS 各 `*LoginHelper.startLogin()` 的官方登录页地址
/// （`CloudDriveAuthManager.swift:2033` UC / `:2134` 115 / `:1565` 迅雷 /
/// `:1682` 天翼 / `:1840` 123 / `:1363` 139）：
/// 用户在系统浏览器完成网页登录后，把回收到的 **Token / Cookie** 粘贴回本 Sheet，
/// 由 `saveWebCredential` 写入契约安全存储 `cloud_drive_credentials_v1`。
///
/// 说明：iOS 侧内嵌 WKWebView 可直接读取 HttpOnly Cookie（`getAllCookies`）；
/// Flutter `webview_flutter` 只能拿到 `document.cookie`（不含 HttpOnly），
/// **无法可靠回收 BDUSS 等 HttpOnly 凭据**，故跨端统一采用
/// 「拉起系统浏览器 + 粘贴 Token/Cookie 兜底」这一 iOS 同源入口（
/// iOS 亦保留「复制粘贴 Token 兜底」高级入口）。
class CloudDriveWebLogin {
  const CloudDriveWebLogin._();

  /// 官方网页登录地址（逐档对齐 iOS `*LoginHelper` 的 URL 常量）。
  static const Map<CloudDriveType, String> urls = <CloudDriveType, String>{
    CloudDriveType.ali: 'https://api.oplist.org/?driver=alicloud'
        '&driver_txt=alicloud_qr&server_use=true&server_set=true',
    CloudDriveType.uc: 'https://drive.uc.cn/',
    CloudDriveType.ucNode: 'https://drive.uc.cn/',
    CloudDriveType.quark: 'https://pan.quark.cn/',
    CloudDriveType.quarkNode: 'https://pan.quark.cn/',
    CloudDriveType.baidu: 'https://pan.baidu.com/',
    CloudDriveType.baiduNode: 'https://pan.baidu.com/',
    CloudDriveType.one15: 'https://115.com/?ct=login',
    CloudDriveType.pan123: 'https://www.123pan.com/login',
    CloudDriveType.pan139: 'https://yun.139.com/w/',
    CloudDriveType.pan189: 'https://cloud.189.cn/web/login.html',
    CloudDriveType.xunlei: 'https://i.xunlei.com/xluser/login.html',
  };

  /// 该网盘是否提供网页兜底入口。
  ///
  /// 三张 Node 托管盘（光鸭 / 蜗牛 / B站）无网页兜底按钮，不登记地址。
  /// 阿里已补齐（对齐 iOS `TokenWebView` ali 分支：OpenList 授权页，
  /// 提取值写入 refreshToken 字段）。
  static bool supports(CloudDriveType type) => urls.containsKey(type);

  /// 官方网页登录地址（不支持返回 null）。
  static String? urlFor(CloudDriveType type) => urls[type];

  /// 粘贴框占位提示（Cookie 档提示 Cookie，Token 档提示 Token）。
  static String credentialHint(CloudDriveType type) =>
      type == CloudDriveType.uc || type == CloudDriveType.ucNode
          ? '粘贴网页登录后的 Cookie'
          : '粘贴网页登录后的 Cookie / Token';
}
