/// 领域层：福利平台三重隔离策略（批次 H · H-04）。
///
/// 唯一真相源：`contract/schema/welfare_v1.json` 的
/// `$comment_isolation` 五条规则 + iOS `vbox/WelfareRemote/WelfareSpiderLoader.swift`
/// `isAllowedWelfareScriptPath`（L129-L135）。
///
/// 隔离约束（发布要求）：
///   1. 福利 Spider 脚本只允许放在 `sources/welfare-js/`；
///   2. 福利平台只允许配置在 `welfare_platforms.json`；
///   3. 不得加入 `spider_sources.json`；
///   4. `welfare_spider` 平台的 `visibleInNormalSpider` / `visibleInGlobalSearch`
///      / `visibleInHome` 必须为 `false`（不进普通 Spider / 全局搜索 / 首页）；
///   5. 福利平台只使用 `domain_overrides.json` 做域名覆盖，不做远程源控制显示。
///
/// 本文件只提供**策略判定**（无 IO / 无 UI）；文件系统级越界扫描由守卫脚本
/// `scripts/check_welfare_isolation.py` 执行（CI 常驻）。
library;

import 'welfare_platform_config.dart';

/// 福利 Spider 专属脚本目录（对齐 iOS `isAllowedWelfareScriptPath` 语义）。
const String kWelfareScriptDir = 'sources/welfare-js/';

/// 相对根目录的脚本前缀（对齐 iOS `hasPrefix("welfare-js/")`）。
const String kWelfareScriptPrefix = 'welfare-js/';

/// 福利 Spider 服务类型（对齐契约 `serviceType == welfare_spider`）。
const String kWelfareSpiderServiceType = 'welfare_spider';

/// 福利 Python 蜘蛛服务类型（对齐 iOS `pythonSpider.rawValue`）。
const String kWelfarePythonServiceType = 'python_spider';

/// 福利平台三重隔离策略（纯静态，无状态）。
class WelfareIsolationPolicy {
  const WelfareIsolationPolicy._();

  /// 规范化脚本路径：反斜杠归一为正斜杠、剥离 `./` 前缀
  /// （对齐 iOS `isAllowedWelfareScriptPath` 的两步替换）。
  static String normalizeScriptPath(String path) {
    return path
        .replaceAll('\\', '/')
        .replaceAll('./', '');
  }

  /// 脚本路径是否落在福利专属目录（对齐 iOS：
  /// `normalized.contains("sources/welfare-js/") || normalized.hasPrefix("welfare-js/")`）。
  static bool isAllowedScriptPath(String? api) {
    if (api == null || api.trim().isEmpty) return false;
    final String normalized = normalizeScriptPath(api.trim());
    return normalized.contains(kWelfareScriptDir) ||
        normalized.startsWith(kWelfareScriptPrefix);
  }

  /// 是否为福利 Spider 平台（含 JS 与 Python，对齐 iOS
  /// `WelfarePlatform.isWelfareSpider`：`welfare_spider` / `python_spider`）。
  static bool isWelfareSpider(WelfarePlatform platform) {
    final String type = platform.serviceType.trim();
    return type == kWelfareSpiderServiceType ||
        type == kWelfarePythonServiceType;
  }

  /// 是否满足三重隔离（三个可见性字段必须均为 `false`）。
  ///
  /// 契约约束只作用于 `welfare_spider`（`allOf` 条件）；非福利 Spider 平台
  /// 不在此判定范围，一律视为合规。
  static bool satisfiesTripleIsolation(WelfarePlatform platform) {
    if (platform.serviceType.trim() != kWelfareSpiderServiceType) return true;
    return !platform.visibleInNormalSpider &&
        !platform.visibleInGlobalSearch &&
        !platform.visibleInHome;
  }

  /// 返回平台隔离违规说明（合规返回 `null`）。
  ///
  /// 校验维度（仅对 `welfare_spider` 生效）：
  ///   · 三重隔离三字段必须为 `false`（契约 `allOf` 强制）；
  ///   · `api` 若配置，路径必须落在 `sources/welfare-js/`（发布要求 ①）。
  static String? violationFor(WelfarePlatform platform) {
    if (platform.serviceType.trim() != kWelfareSpiderServiceType) return null;

    final List<String> fields = <String>[
      if (platform.visibleInNormalSpider) 'visibleInNormalSpider',
      if (platform.visibleInGlobalSearch) 'visibleInGlobalSearch',
      if (platform.visibleInHome) 'visibleInHome',
    ];
    if (fields.isNotEmpty) {
      return '福利 Spider 平台「${platform.platformKey}」三重隔离违规：${fields.join('/')} 必须为 false';
    }

    if (platform.api != null && !isAllowedScriptPath(platform.api)) {
      return '福利 Spider 平台「${platform.platformKey}」脚本路径越界：'
          '${platform.api}（只允许 $kWelfareScriptDir）';
    }

    return null;
  }

  /// 全量校验配置，返回全部违规说明（用于守卫 / 自检 / 批量拦截）。
  static List<String> violationsForAll(WelfarePlatformConfig config) {
    final List<String> out = <String>[];
    for (final WelfarePlatform p in config.platforms) {
      final String? violation = violationFor(p);
      if (violation != null) out.add(violation);
    }
    return out;
  }
}
