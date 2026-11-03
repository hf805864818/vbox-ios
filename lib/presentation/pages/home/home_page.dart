/// 首页（豆瓣推荐 + 站点态源发现）。
///
/// 唯一真相源：iOS `MainViews.swift HomeView`（L230-L372）：
///   · 豆瓣首页始终存活（zIndex 0）；选中源后以 `SourceDiscoveryView` **覆盖展示**
///     （zIndex 1，本页用 [IndexedStack] 等价常驻保活）；
///   · 选中源即切换到源发现页（分类滑动栏 + 三列网格），**不等待网络请求**
///     —— 加载态由 `SourceDiscoveryView` 自身渐进呈现（对齐 iOS
///     `SourceDiscoveryView.isLoading` 分支，不是豆瓣大封面 + 推荐行）；
///   · **无可用源时不报错**，保持豆瓣默认内容。
///
/// A9 口径（R-11）：首页**默认内容 = 豆瓣**；源（Spider / CMS）经顶部「切换源」
/// 浮层选中后进入并覆盖展示，**不是**首页默认内容。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/result.dart';
import '../../../domain/entities/douban/douban_models.dart';
import '../../../domain/entities/spider/spider.dart';
import '../../../domain/usecases/usecases.dart';
import '../../lifecycle/vbox_lifecycle_mixin.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/library_views.dart';
import '../../widgets/source_discovery_view.dart';
import '../../widgets/vbox/vbox.dart';
import '../douban/douban_home_page.dart';
import '../douban/douban_ranking_page.dart';
import '../search/search_page.dart';
import 'source_sheet.dart';

/// 首页（内容浏览）。默认展示豆瓣推荐；切换源后覆盖展示对应站点源发现页。
class VboxHomePage extends StatefulWidget {
  /// 构造。
  const VboxHomePage({super.key});

  @override
  State<VboxHomePage> createState() => _VboxHomePageState();
}

class _VboxHomePageState extends State<VboxHomePage> with VboxLifecycleMixin {
  /// 站点清单进程级缓存（对齐 iOS `HomeView` 的 `allSources` 预载 + onChange
  /// 刷新口径）：tab 切换重建本页时直接复用，不再重复请求站点列表。
  static List<SiteConfig>? _cachedSites;

  late final ContentBrowseUseCases _uc;

  List<SiteConfig> _sites = const <SiteConfig>[];
  String? _siteKey;
  bool _loadingSites = false;

  @override
  void initState() {
    super.initState();
    _uc = context.read<ContentBrowseUseCases>();
    // 对齐 iOS `HomeView.onAppear`：有缓存先恢复，无缓存才加载（不阻塞首屏）。
    final List<SiteConfig>? cachedSites = _cachedSites;
    if (cachedSites != null) {
      _sites = cachedSites;
    } else {
      unawaited(_loadSites());
    }
  }

  /// 加载站点清单（仅供「切换源」使用；失败 / 为空**不报错**，保持豆瓣默认内容）。
  Future<void> _loadSites() async {
    if (_loadingSites) return;
    _loadingSites = true;
    final Result<List<SiteConfig>> result = await _uc.listSites();
    _loadingSites = false;
    if (!mounted) return;
    final List<SiteConfig> sites = result.valueOrNull ?? const <SiteConfig>[];
    _cachedSites = sites;
    setState(() => _sites = sites);
  }

  /// 回前台补拉站点清单（UI-E4）：有缓存则静默复用，不重复请求。
  @override
  void onAppResumed() {
    if (_sites.isEmpty && !_loadingSites) {
      unawaited(_loadSites());
    }
  }

  /// 回到豆瓣默认内容（A9）。
  void _backToDouban() => setState(() => _siteKey = null);

  Future<void> _switchSource() async {
    if (_sites.isEmpty) {
      await _loadSites();
      if (!mounted) return;
      if (_sites.isEmpty) {
        VboxToast.show(context, '暂无可用站点，当前为豆瓣推荐');
        return;
      }
    }
    final String? picked = await showVboxSourceSheet(
      context,
      sites: _sites,
      selectedKey: _siteKey,
    );
    if (picked == null || !mounted || picked == _siteKey) return;
    // 选中源 → **立即**切到站点态（对齐 iOS `selectedSource = item` 即覆盖展示
    // `SourceDiscoveryView`）：加载态与分类栏由源发现页自身渐进呈现，
    // 不等待网络请求、不白屏、不残留豆瓣首页。
    setState(() => _siteKey = picked);
  }

  @override
  Widget build(BuildContext context) {
    final bool doubanMode = _siteKey == null;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        // UI-A1 双态常驻：对齐 iOS ZStack 结构（MainViews.swift L301-L336）——
        // 豆瓣首页始终存活（zIndex 0），站点态覆盖其上，切换不销毁重建
        // （iOS 用 opacity + allowsHitTesting 控制；Flutter IndexedStack 等价：
        // 非活跃态保状态、不绘制、不命中）。
        child: IndexedStack(
          index: doubanMode ? 0 : 1,
          children: <Widget>[
            // 豆瓣态（zIndex 0）：顶栏 + 豆瓣推荐。
            Column(
              children: <Widget>[
                _buildTopBar(context),
                Expanded(
                  // 对齐 iOS `DoubanHomeView`：首页豆瓣条目点击即
                  // `triggerSearch(title)` 进入搜索页按标题搜索。
                  child: DoubanHomeView(
                    onSubjectTap: (DoubanSubject subject) =>
                        _openSearchForKey(subject.title),
                  ),
                ),
              ],
            ),
            // 站点态（zIndex 1，覆盖豆瓣态）：对齐 iOS `HomeView` 内嵌
            // `SourceDiscoveryView` —— 源名栏 + 分类滑动栏（推荐 + 分类）+
            // 三列海报网格 + 滚动分页，而非豆瓣的大封面轮播 + 推荐横排。
            // 非活跃（豆瓣态）时 `active: false` 常驻但不发起加载。
            SourceDiscoveryView(
              initialSiteKey: _siteKey,
              onDismiss: _backToDouban,
              active: !doubanMode,
            ),
          ],
        ),
      ),
    );
  }

  /// 首页顶栏（对齐 iOS `HomeSearchBar`）。
  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VboxSpacing.sm,
        VboxSpacing.sm,
        VboxSpacing.sm,
        VboxSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          // 多源选择（对齐 iOS `square.grid.2x2`）。
          _TopBarIcon(
            tooltip: '切换源',
            icon: Icons.grid_view_rounded,
            onPressed: _switchSource,
          ),
          Expanded(child: _buildSearchField(context)),
          // 排行榜（对齐 iOS `chart.bar.fill` → DoubanRankingView）。
          _TopBarIcon(
            tooltip: '豆瓣排行榜',
            icon: Icons.bar_chart_rounded,
            onPressed: _openRanking,
          ),
          // 观看历史（对齐 iOS `clock.arrow.circlepath` → WatchHistoryView）。
          _TopBarIcon(
            tooltip: '观看历史',
            icon: Icons.history,
            onPressed: _openHistory,
          ),
          // AI（对齐 iOS `sparkles` → 打开 Lobster-APP 仓库）。
          _TopBarIcon(
            tooltip: 'AI 推荐',
            icon: Icons.auto_awesome,
            color: VboxColors.topBarAiAccent,
            onPressed: _openAi,
          ),
        ],
      ),
    );
  }

  /// 顶栏搜索框（只读按钮，点击进入搜索页；对齐 iOS `HomeSearchBar` 搜索栏）。
  Widget _buildSearchField(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // UI-D4 辅助功能：搜索入口（可见文案即标签）。
    return Semantics(
      button: true,
      label: '搜索影片、剧集',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _openSearch,
        child: Container(
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: VboxSpacing.xs),
          padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.md),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.search, size: VboxTypography.s16, color: scheme.outline),
              const SizedBox(width: VboxSpacing.sm),
              Expanded(
                child: Text(
                  '搜索影片、剧集',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s15,
                    color: scheme.outline,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SearchPage(initialSiteKey: _siteKey),
      ),
    );
  }

  /// 以关键词进入搜索页并立即搜索（对齐 iOS `settings.triggerSearch(title)`）。
  void _openSearchForKey(String keyword) {
    final String kw = keyword.trim();
    if (kw.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SearchPage(initialKeyword: kw),
      ),
    );
  }

  void _openRanking() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DoubanRankingPage()),
    );
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => Scaffold(
          appBar: AppBar(title: const Text('观看历史')),
          body: const HistoryView(),
        ),
      ),
    );
  }

  Future<void> _openAi() async {
    await launchUrl(
      Uri.parse('https://github.com/vbox-Ai/Lobster-APP'),
      mode: LaunchMode.externalApplication,
    );
  }
}

/// 首页顶栏图标按钮。
///
/// 对齐 iOS `MainViews.swift HomeSearchBar`（L918-L997）：图标 18、无背景、
/// 可选高亮色（AI 蓝），点击区域紧凑排布。
class _TopBarIcon extends StatelessWidget {
  const _TopBarIcon({
    required this.tooltip,
    required this.icon,
    this.color,
    this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color? color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final Color resolved = color ?? Theme.of(context).colorScheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 18, color: resolved),
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(),
      ),
    );
  }
}