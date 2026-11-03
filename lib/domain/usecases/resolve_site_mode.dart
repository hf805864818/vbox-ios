/// 领域层用例：站点模式判定 + Node 站点识别（第 2 轮批次 B · B-04）。
///
/// 唯一真相源：iOS `vbox/Services/SpiderManager.swift`
///   - `resolveSiteMode(site:)`（L119-177，双模式开关 + type 分流）
///   - `isNodeSite(_:)`（L185-201，Node 双保险识别）
///   - `registerNodeEngine(for:)` 的 lx 分流（L208-214，A2：`engineType == "lxMusic"`
///     或 `LXBridgeEngine.lxKeyMap` 白名单命中 → NodeLX）
///   - `NodeSpiderEngine.lxKeyMap`（L319-322）
///
/// 与实体层的关系：`SiteConfig.isNodeSite` / `SiteConfig.resolveSiteMode`
/// 第 1 轮已移植核心分流（契约 §1.1）；本用例补齐 iOS 差集——
///   ① `enableDualMode` 双模式开关（type=3 关闭时回到旧逻辑分支）；
///   ② lx-music 白名单式 NodeLX 分流（实体 `resolveEngineType` 的
///      `api.contains('lx')` 与 iOS 白名单语义不一致，本用例以 iOS 为准）；
///   ③ 输出统一结果（mode + engineType + isNodeHosted），供 B-05 引擎映射复用。
library;

import '../entities/spider/engine_type.dart';
import '../entities/spider/site_config.dart';

/// 站点模式判定结果。
class ResolvedSiteMode {
  const ResolvedSiteMode({
    required this.mode,
    required this.isNodeHosted,
    this.engineType,
  });

  /// 站点工作模式。
  final SiteMode mode;

  /// 是否为 Node 托管蜘蛛（含 NodeLX）。
  final bool isNodeHosted;

  /// 该站点应使用的主引擎（null = 非脚本引擎：API / 站源 / 不支持）。
  ///
  /// JS 站点按 D6 映射到 JSC 主引擎；JSC 不可用时的 QuickJS
  /// 自动降级属 B-05（引擎映射）职责，本用例不感知。
  final SpiderEngineType? engineType;
}

/// 站点模式判定用例（纯函数，无副作用）。
class ResolveSiteModeUseCase {
  const ResolveSiteModeUseCase();

  /// 已知 lx 音乐源 key 白名单（对齐 iOS `NodeSpiderEngine.lxKeyMap` 的键集，
  /// 白名单式识别防误判；value 为插件 key，引擎侧使用）。
  static const Map<String, String> lxMusicKeyMap = <String, String>{
    'nodejs_musicaidaxe': 'daxe',
    'nodejs_musicainianxin': 'nianxin',
  };

  /// 判定站点工作模式与引擎分流。
  ///
  /// [enableDualMode] 对齐 iOS `SpiderManager.enableDualMode`（默认开）：
  /// 关闭时 type=3 全部回到旧逻辑（不做「HTTP 非 .js → API」细分），
  /// 100% 兼容改造前行为。
  ResolvedSiteMode call(SiteConfig site, {bool enableDualMode = true}) {
    // ① Node 托管蜘蛛（优先判断，独立于 type 分支）
    if (site.isNodeSite) {
      final bool isLx = (site.engineType?.toLowerCase() == 'lxmusic') ||
          lxMusicKeyMap.containsKey(site.key);
      final SpiderEngineType engine =
          isLx ? SpiderEngineType.nodeLX : SpiderEngineType.node;
      return ResolvedSiteMode(
        mode: SiteMode.node,
        isNodeHosted: true,
        engineType: engine,
      );
    }

    // ② 双模式开关关闭：type=3 回到旧逻辑（对齐 iOS `!enableDualMode` 分支）
    if (!enableDualMode && site.type == 3) {
      final String a = site.api ?? '';
      final bool legacyLoadable = a.startsWith('http://') ||
          a.startsWith('https://') ||
          a.startsWith('./') ||
          a.endsWith('.js');
      if (!legacyLoadable || a.toLowerCase().contains('.jar')) {
        return const ResolvedSiteMode(
          mode: SiteMode.unsupported,
          isNodeHosted: false,
        );
      }
      return const ResolvedSiteMode(
        mode: SiteMode.jsSpider,
        isNodeHosted: false,
        engineType: SpiderEngineType.javaScriptCore,
      );
    }

    // ③ 常规分流（type 0/1 → API；2 → 站源；3 → 细分；其余 → 不支持）
    final SiteMode mode = site.resolveSiteMode();
    return ResolvedSiteMode(
      mode: mode,
      isNodeHosted: false,
      engineType: _engineFor(mode),
    );
  }

  SpiderEngineType? _engineFor(SiteMode mode) => switch (mode) {
        SiteMode.jsSpider => SpiderEngineType.javaScriptCore,
        SiteMode.pythonSpider => SpiderEngineType.python,
        SiteMode.node || SiteMode.apiEndpoint || SiteMode.zhanyuan || SiteMode.unsupported => null,
      };
}
