/// PG 自动化领域模型（批次 F · F-09）。
///
/// 对齐 iOS（唯一行为基准）：
/// - `AliyunPgConfig`（`vbox/Services/AliyunPgConfig.swift`）——开关 / 画质 /
///   线程（含夜间自动切换）/ 转存目录 / 清理延迟 / 代理端口 / 凭据标记；
/// - `AliyunPgQrLoginView.PgPlayConfigSection`（`vbox/Views/AliyunPgQrLoginView.swift:158`）
///   ——「播放参数」UI 面（VIP 开关 + 并发线程 Stepper + 画质 Picker + 保存）；
/// - `AliyunPgPlayManager.scheduleCleanup`（步骤 8，`autoCleanup` / `cleanupDelay`）。
///
/// 存储契约键（`contract/schema/prefs_keys_v1.json` → `_group_quark_pg`）：
/// `pg_ali_enabled` / `pg_ali_is_vip` / `pg_ali_thread_limit` /
/// `pg_ali_thread_night` / `pg_ali_vod_flags` / `pg_ali_transfer_dir` /
/// `pg_ali_auto_cleanup` / `pg_ali_cleanup_delay` / `pg_ali_proxy_port`。
///
/// ⚠️ 契约与 iOS 源码存在两处已登记差异，本层按**冻结契约**取默认值（跨端
/// prefs 互通优先），差异在 [PgAutoRules] 中以「解析兜底」收敛：
/// 1. `pg_ali_cleanup_delay` 契约为 int（iOS 为 Double）；
/// 2. `pg_ali_thread_night` 契约为 int（iOS 为 `"19-23=32"` 字符串，含时段）——
///    Flutter 端按「夜间线程数」解释，夜间时段取 iOS 缺省窗口 19:00–23:00。
///   （bool / 画质 / 转存目录的 iOS 源码缺省改由 [PgAutoRules] 的解析兜底承载。）
library;

import 'cloud_drive.dart';

/// PG 播放画质（对齐 iOS `PgPlayConfigSection` 的 Picker tag）。
enum PgVodQuality {
  /// 原画 4K（转存 GO 原画，`4kz|auto`）。
  original4k('4kz|auto', '原画 4K'),

  /// 高清 FHD。
  fhd('fhd', '高清 FHD'),

  /// 高清 HD。
  hd('hd', '高清 HD'),

  /// 标清 SD。
  sd('sd', '标清 SD'),

  /// 流畅 LD。
  ld('ld', '流畅 LD');

  const PgVodQuality(this.id, this.displayName);

  /// 契约字符串值（写入 `pg_ali_vod_flags`）。
  final String id;

  /// 中文显示名（对齐 iOS Picker 文案）。
  final String displayName;

  /// 是否为 4kz 原画模式（对齐 iOS `is4kzMode`：`hasPrefix("4kz")`）。
  bool get is4kz => id.startsWith('4kz');

  /// 由 flags 字符串解析（含 `fhd|auto` 等带后缀写法；未知 / 空回退
  /// [original4k]，对齐 iOS 缺省 `"4kz|auto"`）。
  static PgVodQuality fromFlags(String? flags) {
    final String value = (flags ?? '').trim();
    if (value.isEmpty) return original4k;
    for (final PgVodQuality q in values) {
      if (value == q.id || value.startsWith('${q.id}|')) return q;
    }
    // `4ko|auto` 等 4k 前缀变体统一归入原画档（对齐 iOS `hasPrefix("4kz")` 之外
    // 的 4k 家族语义）。
    if (value.startsWith('4k')) return original4k;
    return original4k;
  }
}

/// PG 自动化配置（对齐 iOS `AliyunPgConfig` 的 9 个契约键）。
class PgAutoConfig {
  /// 构造。
  const PgAutoConfig({
    this.enabled = false,
    this.isVip = false,
    this.threadLimit = 3,
    this.threadNight = 5,
    this.vodFlags = '',
    this.transferDir = '',
    this.autoCleanup = false,
    this.cleanupDelaySeconds = 60,
    this.proxyPort = 58090,
  });

  /// 契约缺省配置（与 `prefs_keys_v1.json` 的 default 完全一致）。
  static const PgAutoConfig defaults = PgAutoConfig();

  /// PG 播放路链总开关（`pg_ali_enabled`）。
  final bool enabled;

  /// VIP 用户（`pg_ali_is_vip`）。
  final bool isVip;

  /// VIP 并发线程（`pg_ali_thread_limit`）。
  final int threadLimit;

  /// 夜间并发线程（`pg_ali_thread_night`）。
  final int threadNight;

  /// 画质 flags（`pg_ali_vod_flags`，空串走解析兜底）。
  final String vodFlags;

  /// 转存目标目录（`pg_ali_transfer_dir`，空串走解析兜底）。
  final String transferDir;

  /// 转存后自动清理（`pg_ali_auto_cleanup`）。
  final bool autoCleanup;

  /// 清理延迟秒（`pg_ali_cleanup_delay`）。
  final int cleanupDelaySeconds;

  /// 本地代理端口（`pg_ali_proxy_port`）。
  final int proxyPort;

  /// 复制并覆盖部分字段。
  PgAutoConfig copyWith({
    bool? enabled,
    bool? isVip,
    int? threadLimit,
    int? threadNight,
    String? vodFlags,
    String? transferDir,
    bool? autoCleanup,
    int? cleanupDelaySeconds,
    int? proxyPort,
  }) {
    return PgAutoConfig(
      enabled: enabled ?? this.enabled,
      isVip: isVip ?? this.isVip,
      threadLimit: threadLimit ?? this.threadLimit,
      threadNight: threadNight ?? this.threadNight,
      vodFlags: vodFlags ?? this.vodFlags,
      transferDir: transferDir ?? this.transferDir,
      autoCleanup: autoCleanup ?? this.autoCleanup,
      cleanupDelaySeconds: cleanupDelaySeconds ?? this.cleanupDelaySeconds,
      proxyPort: proxyPort ?? this.proxyPort,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PgAutoConfig &&
      other.enabled == enabled &&
      other.isVip == isVip &&
      other.threadLimit == threadLimit &&
      other.threadNight == threadNight &&
      other.vodFlags == vodFlags &&
      other.transferDir == transferDir &&
      other.autoCleanup == autoCleanup &&
      other.cleanupDelaySeconds == cleanupDelaySeconds &&
      other.proxyPort == proxyPort;

  @override
  int get hashCode => Object.hash(
        enabled,
        isVip,
        threadLimit,
        threadNight,
        vodFlags,
        transferDir,
        autoCleanup,
        cleanupDelaySeconds,
        proxyPort,
      );
}

/// PG 规则（对齐 iOS `AliyunPgConfig` 的取值规则，全部为无副作用静态方法）。
abstract final class PgAutoRules {
  /// 夜间时段起始小时（对齐 iOS 缺省 `"19-23=32"` 的 19）。
  static const int nightStartHour = 19;

  /// 夜间时段结束小时（不含；对齐 iOS 缺省 `"19-23=32"` 的 23）。
  static const int nightEndHour = 23;

  /// 解析兜底画质（对齐 iOS 缺省 `"4kz|auto"`）。
  static const String defaultVodFlags = '4kz|auto';

  /// 解析兜底转存目录（对齐 iOS 缺省 `"vbox_pg_temp"`）。
  static const String defaultTransferDir = 'vbox_pg_temp';

  /// 非 VIP 并发线程（对齐 iOS `currentThreadLimit` 的 `guard isVip else { return 1 }`）。
  static const int nonVipThreadLimit = 1;

  /// 生效画质（空串 → [defaultVodFlags]）。
  static String resolvedVodFlags(PgAutoConfig config) =>
      config.vodFlags.trim().isEmpty ? defaultVodFlags : config.vodFlags.trim();

  /// 生效画质档位。
  static PgVodQuality vodQuality(PgAutoConfig config) =>
      PgVodQuality.fromFlags(config.vodFlags);

  /// 是否 4kz 原画模式（对齐 iOS `is4kzMode`）。
  static bool is4kz(PgAutoConfig config) => resolvedVodFlags(config).startsWith('4kz');

  /// 生效转存目录（空串 → [defaultTransferDir]）。
  static String resolvedTransferDir(PgAutoConfig config) {
    final String dir = config.transferDir.trim();
    return dir.isEmpty ? defaultTransferDir : dir;
  }

  /// 是否处于夜间时段（对齐 iOS `hour >= start && hour < end`）。
  static bool isNightWindow(
    DateTime now, {
    int startHour = nightStartHour,
    int endHour = nightEndHour,
  }) {
    final int hour = now.hour;
    return hour >= startHour && hour < endHour;
  }

  /// 当前并发线程（对齐 iOS `currentThreadLimit`）。
  ///
  /// - 非 VIP → [nonVipThreadLimit]（1）；
  /// - 夜间时段 → [PgAutoConfig.threadNight]；
  /// - 其余 → [PgAutoConfig.threadLimit]；
  /// - 结果下限 1（对齐 iOS Stepper `in: 1...64` 的下界）。
  static int currentThreadLimit(
    PgAutoConfig config, {
    required DateTime now,
    int startHour = nightStartHour,
    int endHour = nightEndHour,
  }) {
    if (!config.isVip) return nonVipThreadLimit;
    final int limit = isNightWindow(now, startHour: startHour, endHour: endHour)
        ? config.threadNight
        : config.threadLimit;
    return limit < 1 ? nonVipThreadLimit : limit;
  }

  /// 清理延迟（对齐 iOS `cleanupDelay`）。
  static Duration cleanupDelay(PgAutoConfig config) =>
      Duration(seconds: config.cleanupDelaySeconds < 0 ? 0 : config.cleanupDelaySeconds);

  /// 是否应注册转存清理（对齐 iOS 步骤 8：`isEnabled && autoCleanup`）。
  static bool shouldScheduleCleanup(PgAutoConfig config) =>
      config.enabled && config.autoCleanup;

  /// 本地代理地址（对齐 iOS `aliproxyUrl`）。
  static String proxyUrl(PgAutoConfig config) =>
      'http://127.0.0.1:${config.proxyPort}';
}

/// PG 凭据标记（对齐 iOS `AliyunPgConfig.pgSourceKey/pgSourceValue`）。
///
/// 契约键 `pg_source` / `qr_scan`（`storage: credential_extra`）——存于
/// [CloudDriveCredential.extra] 内，随凭据对象走 Keychain，**不落 UserDefaults**。
abstract final class PgCredentialMark {
  /// 标记键（对齐 iOS `pgSourceKey`）。
  static const String sourceKey = 'pg_source';

  /// 标记值（对齐 iOS `pgSourceValue`，扫码登录来源）。
  static const String sourceValue = 'qr_scan';

  /// 是否 PG 凭据（对齐 iOS `isPgCredential`：`extra[pg_source] != nil`）。
  static bool isPgCredential(Map<String, String> extra) =>
      extra.containsKey(sourceKey);

  /// 打上 PG 标记（返回新 extra，不修改入参）。
  static Map<String, String> mark(Map<String, String> extra) =>
      <String, String>{...extra, sourceKey: sourceValue};

  /// 判断凭据对象是否 PG 来源。
  static bool of(CloudDriveCredential credential) =>
      isPgCredential(credential.extra);
}
