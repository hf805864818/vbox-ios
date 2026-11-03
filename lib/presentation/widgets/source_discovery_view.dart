/// 源发现（单源分类浏览）视图（批次 D · D-07）。
///
/// 对齐 iOS `SourceDiscoveryView`（`vbox/Views/SourceDiscoveryView.swift`）：
///   · 顶栏：返回 + 源名下拉按钮（17pt semibold + chevron.down）+ 右侧
///     类型徽标胶囊（分类色，对齐 `categoryBadgeColor`）；
///   · 选源浮层：左上角小竖长条（复用 [showVboxSourceSheet]，对齐 iOS
///     `sourceDropdownOverlay` 同款设计，分组固定顺序 网盘→API→站源→JS→论坛）；
///   · 分类滑动栏：「推荐」+ 源分类；分类为空但有推荐 → 回退「全部」
///     （`__all__`，对齐 `displayCategories`）；
///   · 自适应筛选栏：选中具体分类才显示（`shouldShowFilterBar`），维度从
///     当前分类数据自适应提取（`extractAdaptiveFilters`），选择后带筛选
///     重载第 1 页（`reloadCategoryWithFilters`）；
///   · 内容网格：卡片 = 2:3 封面（备注角标右下角）+ 标题 2 行 + 年份行，
///     掉落回弹入场（同行 1→2→3 错峰，对齐 `SourceVideoCard.fallDelay`）；
///   · 分页：滚动接近底部自动 + 「加载更多」footer；分类空态区分
///     「该分类暂无数据」/「暂无推荐内容」+ 搜索引导文案。
///
/// 数据通路：`ContentBrowseUseCases.listSites` / `homeContent`（推荐） /
/// `categoryContent`（分类 + 分页 + 筛选），模式分流 CMS / Spider 在用例层完成。
/// 筛选实际生效面与 iOS 一致：仅 JSON API（CMS）链路生效（iOS `fetchSingleSourceCategoryContent`
/// 中 Spider 引擎仍传 `extend: "{}"`、HTML 分类页不拼筛选参数）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/failures.dart';
import '../../core/utils/result.dart';
import '../../domain/entities/spider/spider.dart';
import '../../domain/usecases/usecases.dart';
import '../theme/tokens/colors.dart';
import '../theme/tokens/radii.dart';
import '../theme/tokens/spacing.dart';
import '../theme/tokens/typography.dart';
import '../ui_mode/ui_mode.dart';
import 'adaptive/responsive_grid.dart';
import 'detail_page.dart';
import 'fall_in_card.dart';
import '../pages/home/source_sheet.dart';
import 'platform_async_image.dart';
import 'vbox/vbox.dart';

/// 「全部」回退分类 ID（对齐 iOS `displayCategories` 的 `"__all__"`）。
const String _kAllCategoryId = '__all__';

/// 源发现视图（首页站点态覆盖层 / 「远程源」页的「源发现」标签）。
class SourceDiscoveryView extends StatefulWidget {
  /// 构造。
  const SourceDiscoveryView({
    super.key,
    this.initialSiteKey,
    this.onDismiss,
    this.active = true,
  });

  /// 首次进入要选中的站点 key（缺省选首个可用站点）。
  ///
  /// 首页切入站点态时传入当前选中的源；值变化（用户在首页再次切换源）
  /// 由 [State.didUpdateWidget] 驱动换源。
  final String? initialSiteKey;

  /// 返回回调（非空时左上加返回按钮，用于嵌入首页站点态返回豆瓣）。
  final VoidCallback? onDismiss;

  /// 是否激活（可见）。
  ///
  /// 首页 `IndexedStack` 中站点态常驻但不参与绘制：`active: false` 时**不发起
  /// 任何加载**（对其 iOS「未选中源时不创建 `SourceDiscoveryView`」的等价实现），
  /// 由豆瓣态切到站点态（`active` 转 true）时才按需加载。
  final bool active;

  /// 排序值 → 显示名（对齐 iOS `sortDisplayValue`）。
  static String sortDisplayValue(String value) => switch (value) {
        '全部' => '默认',
        'hits' => '热播',
        'addtime' => '最新',
        'score' => '高分',
        'rand' => '随机',
        _ => value,
      };

  @override
  State<SourceDiscoveryView> createState() => _SourceDiscoveryViewState();
}

class _SourceDiscoveryViewState extends State<SourceDiscoveryView> {
  /// 分页满页判定阈值（对齐卫生契约 §6 默认每页 20）。
  static const int _pageSizeHint = 20;

  late final ContentBrowseUseCases _uc;
  final ScrollController _scroll = ScrollController();

  /// 是否已完成首次引导（避免 `active` 反复切换时重复加载）。
  bool _bootstrapped = false;

  // 源
  List<SiteConfig> _sites = const <SiteConfig>[];
  String? _siteKey;
  bool _loadingSites = false;
  Failure? _sitesError;

  // 推荐（homeContent）
  List<VodCategory> _categories = const <VodCategory>[];
  List<VodItem> _recommended = const <VodItem>[];

  // 分类内容（categoryContent，分页）
  String? _selectedTid;
  final List<VodItem> _items = <VodItem>[];
  int _page = 0;
  int? _pagecount;
  bool _lastBatchFull = true;

  bool _loading = false;
  bool _loadingMore = false;
  Failure? _error;

  // 自适应筛选（对齐 iOS `filterOptions` / `selectedClass/.../selectedSort`）。
  AdaptiveFilterOptions _filterOptions = const AdaptiveFilterOptions();
  String _selectedClass = '全部';
  String _selectedArea = '全部';
  String _selectedYear = '全部';
  String _selectedSort = '全部';

  @override
  void initState() {
    super.initState();
    _uc = context.read<ContentBrowseUseCases>();
    _scroll.addListener(_onScroll);
    if (widget.active) {
      _bootstrap();
    }
  }

  @override
  void didUpdateWidget(SourceDiscoveryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String? incoming = widget.initialSiteKey;
    if (!oldWidget.active && widget.active) {
      // 豆瓣态 → 站点态：首次则完整引导，已引导则按传入 key 换源。
      if (!_bootstrapped) {
        _bootstrap();
      } else if (incoming != null && incoming.isNotEmpty && incoming != _siteKey) {
        _selectSite(incoming);
      }
      return;
    }
    // 激活状态下传入 key 变化（首页再次切换源）。
    if (widget.active &&
        incoming != null &&
        incoming.isNotEmpty &&
        incoming != _siteKey) {
      _selectSite(incoming);
    }
  }

  /// 首次引导（对齐 iOS `SourceDiscoveryView.onAppear` → `loadData()`）。
  ///
  /// 渐进加载：先按 [SourceDiscoveryView.initialSiteKey] **立即**发起内容请求，
  /// 再并行拉源列表（源列表失败只影响下拉可选，不阻断内容）——避免
  /// 「等站点列表 → 再等内容」的串行白屏（对齐 iOS 先出分类栏再出数据的体感）。
  Future<void> _bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;

    final String? initial = widget.initialSiteKey;
    if (initial != null && initial.isNotEmpty) {
      _siteKey = initial;
      unawaited(_loadHome());
    }

    setState(() {
      _loadingSites = true;
      _sitesError = null;
    });
    final Result<List<SiteConfig>> result = await _uc.listSites();
    if (!mounted) return;
    final Failure? failure = result.failureOrNull;
    if (failure != null) {
      setState(() {
        _loadingSites = false;
        _sitesError = failure;
      });
      return;
    }
    final List<SiteConfig> sites = result.valueOrNull ?? const <SiteConfig>[];
    if (sites.isEmpty) {
      setState(() {
        _loadingSites = false;
        _sitesError = const UnknownFailure('无可用站点');
      });
      return;
    }
    setState(() {
      _loadingSites = false;
      _sites = sites;
      _siteKey ??= sites.first.key;
    });
    if (initial == null || initial.isEmpty) {
      await _loadHome();
    }
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_isBrowsingCategory && _scroll.position.extentAfter < 240) {
      _loadMore();
    }
  }

  bool get _hasMore {
    final int? pc = _pagecount;
    if (pc != null) return _page < pc;
    return _lastBatchFull;
  }

  /// 展示分类列表（对齐 iOS `displayCategories`）：分类为空但有推荐 →
  /// 回退单一「全部」分类。
  List<VodCategory> get _displayCategories {
    if (_categories.isEmpty && _recommended.isNotEmpty) {
      return const <VodCategory>[
        VodCategory(typeId: _kAllCategoryId, typeName: '全部'),
      ];
    }
    return _categories;
  }

  /// 是否正在浏览具体分类（排除「推荐」与「全部」回退；对齐 iOS
  /// `shouldShowFilterBar` 与分页 footer 的判定口径）。
  bool get _isBrowsingCategory =>
      _selectedTid != null && _selectedTid != _kAllCategoryId;

  /// 展示条目（对齐 iOS `displayVideos`）：「全部」回退分类展示推荐内容
  /// （iOS 端 `__all__` 选中后 `categoryVideos = []` 呈现空网格系实现瑕疵，
  /// 按其意图回退推荐内容）；具体分类展示分类数据（空也显示分类态空页）。
  List<VodItem> get _displayItems {
    if (_selectedTid == null || _selectedTid == _kAllCategoryId) {
      return _recommended;
    }
    return _items;
  }

  /// 当前源显示名（加载/错误文案用，对齐 iOS `source.name`）。
  String get _currentSiteName {
    for (final SiteConfig s in _sites) {
      if (s.key == _siteKey) return s.name.isEmpty ? s.key : s.name;
    }
    return _siteKey ?? '';
  }

  // ─────────────── 数据加载 ───────────────

  /// 加载推荐（homeContent）。
  ///
  /// [silent] 下拉刷新模式（对齐 iOS `refreshContent` 推荐分支：不置整页
  /// loading、不清空现有内容，失败静默保持原内容）。
  Future<void> _loadHome({bool silent = false}) async {
    final String? siteKey = _siteKey;
    if (siteKey == null || _loading) return;
    setState(() {
      _loading = !silent;
      _error = null;
      if (!silent) {
        _selectedTid = null;
        _categories = const <VodCategory>[];
        _recommended = const <VodItem>[];
        _items.clear();
        _page = 0;
        _pagecount = null;
        _lastBatchFull = true;
      }
    });
    final Result<HomeContentResult> result = await _uc.homeContent(siteKey);
    if (!mounted) return;
    final Failure? failure = result.failureOrNull;
    if (failure != null) {
      setState(() {
        _loading = false;
        if (!silent) _error = failure;
      });
      return;
    }
    final HomeContentResult home =
        result.valueOrNull ?? const HomeContentResult();
    setState(() {
      _categories = home.classes ?? const <VodCategory>[];
      _recommended = home.list ?? const <VodItem>[];
      _loading = false;
    });
  }

  Future<void> _selectSite(String? siteKey) async {
    if (siteKey == null || siteKey == _siteKey) return;
    // 切换源重置（对齐 iOS `onChange(of: source.id)`）：分类/分页/筛选全复位。
    setState(() {
      _siteKey = siteKey;
      _selectedTid = null;
      _items.clear();
      _page = 0;
      _pagecount = null;
      _lastBatchFull = true;
      _resetFilters();
    });
    await _loadHome();
  }

  Future<void> _selectTid(String? tid) async {
    if (tid == _selectedTid) return;
    setState(() {
      _selectedTid = tid;
      _items.clear();
      _page = 0;
      _pagecount = null;
      _lastBatchFull = true;
      // 切分类重置筛选（对齐 iOS 分类 chip `onTapGesture` 的 `resetFilters()`）。
      _resetFilters();
    });
    if (tid == null || tid == _kAllCategoryId) return; // 推荐 / 全部复用 _recommended
    await _loadCategory();
  }

  /// 加载分类内容（首载 / 翻页 / 筛选重载共用）。
  ///
  /// [replace] 为 true 时覆盖现有条目并保留旧内容显示（下拉刷新，对齐 iOS
  /// `refreshContent` 分类分支：不清空 `categoryVideos`，数据到达后整体替换）。
  Future<void> _loadCategory({bool replace = false}) async {
    if (_loading || _loadingMore) return;
    final String? siteKey = _siteKey;
    final String? tid = _selectedTid;
    if (siteKey == null || tid == null || tid == _kAllCategoryId) return;

    final bool initial = replace || (_page == 0 && _items.isEmpty);
    setState(() {
      if (initial && _items.isEmpty) {
        // 首载（无旧内容）→ 整页加载态（对齐 iOS 清空后 ProgressView）。
        _loading = true;
        _error = null;
      } else {
        // 有旧内容 → 底部进度（数据保留，对齐 iOS isLoadingCategory 保留网格）。
        _loadingMore = true;
      }
    });

    final int nextPage = _page + 1;
    final Result<CategoryContentResult> result = await _uc.categoryContent(
      siteKey,
      tid: tid,
      page: nextPage,
      filters: _activeFilters,
    );
    if (!mounted) return;
    final Failure? failure = result.failureOrNull;
    if (failure != null) {
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (initial && _items.isEmpty) _error = failure;
      });
      if (!(_items.isNotEmpty)) _toast('加载失败：$failure');
      return;
    }
    final CategoryContentResult content =
        result.valueOrNull ?? const CategoryContentResult();
    final List<VodItem> batch = content.list ?? const <VodItem>[];
    setState(() {
      if (initial) {
        _items
          ..clear()
          ..addAll(batch);
      } else {
        _items.addAll(batch);
      }
      _page = nextPage;
      _pagecount = content.pagecount;
      _lastBatchFull = batch.length >= _pageSizeHint;
      _loading = false;
      _loadingMore = false;
    });
    // 首次进入分类 → 自适应提取筛选维度（对齐 iOS `loadCategoryContent`）。
    if (initial && !replace) {
      setState(() => _filterOptions = extractAdaptiveFilters(batch));
    }
  }

  /// 筛选选中后重载第 1 页（对齐 iOS `reloadCategoryWithFilters`：不重提取
  /// 筛选维度，置加载态并覆盖替换）。
  Future<void> _reloadCategoryWithFilters() async {
    if (!_isBrowsingCategory) return;
    setState(() {
      _items.clear();
      _page = 0;
      _pagecount = null;
      _lastBatchFull = true;
    });
    final String siteKey = _siteKey!;
    final String tid = _selectedTid!;
    setState(() {
      _loading = true;
      _error = null;
    });
    final Result<CategoryContentResult> result = await _uc.categoryContent(
      siteKey,
      tid: tid,
      page: 1,
      filters: _activeFilters,
    );
    if (!mounted) return;
    final Failure? failure = result.failureOrNull;
    if (failure != null) {
      setState(() {
        _loading = false;
        _error = failure;
      });
      return;
    }
    final CategoryContentResult content =
        result.valueOrNull ?? const CategoryContentResult();
    setState(() {
      _items
        ..clear()
        ..addAll(content.list ?? const <VodItem>[]);
      _page = 1;
      _pagecount = content.pagecount;
      _lastBatchFull = (content.list?.length ?? 0) >= _pageSizeHint;
      _loading = false;
    });
  }

  Future<void> _loadMore() async {
    if (!_isBrowsingCategory || !_hasMore || _loading || _loadingMore) return;
    await _loadCategory();
  }

  Future<void> _retry() async {
    if (_sitesError != null || _sites.isEmpty) {
      // 源列表失败 / 为空：重跑首次引导（解除引导幂等保护）。
      _bootstrapped = false;
      await _bootstrap();
      return;
    }
    if (_selectedTid == null || _selectedTid == _kAllCategoryId) {
      await _loadHome();
    } else {
      await _loadCategory();
    }
  }

  /// 下拉刷新（对齐 iOS `SourceDiscoveryView.refreshable`）：分类态保留旧
  /// 内容回第一页覆盖，推荐态静默重载首页内容；源列表失败态则重跑引导。
  Future<void> _refresh() async {
    if (_sitesError != null || _sites.isEmpty) {
      _bootstrapped = false;
      await _bootstrap();
      return;
    }
    if (_selectedTid == null || _selectedTid == _kAllCategoryId) {
      await _loadHome(silent: true);
      return;
    }
    _page = 0;
    _pagecount = null;
    _lastBatchFull = true;
    await _loadCategory(replace: true);
  }

  // ─────────────── 自适应筛选（对齐 iOS extractAdaptiveFilters 等） ───────────────

  /// 重置筛选（对齐 iOS `resetFilters`）。
  void _resetFilters() {
    _selectedClass = '全部';
    _selectedArea = '全部';
    _selectedYear = '全部';
    _selectedSort = '全部';
    _filterOptions = const AdaptiveFilterOptions();
  }

  /// 当前生效筛选参数（「全部」/ 空不传；对齐 iOS `buildFilterQuery` 跳过语义）。
  Map<String, String> get _activeFilters {
    final Map<String, String> f = <String, String>{};
    if (_selectedClass != '全部' && _selectedClass.isNotEmpty) {
      f['class'] = _selectedClass;
    }
    if (_selectedArea != '全部' && _selectedArea.isNotEmpty) {
      f['area'] = _selectedArea;
    }
    if (_selectedYear != '全部' && _selectedYear.isNotEmpty) {
      f['year'] = _selectedYear;
    }
    if (_selectedSort != '全部' && _selectedSort.isNotEmpty) {
      f['sort'] = _selectedSort;
    }
    return f;
  }

  /// 排序显示名走 [SourceDiscoveryView.sortDisplayValue]（对齐 iOS
  /// `sortDisplayValue`）。

  /// 筛选选择器（对齐 iOS `presentFilterPicker` 的 actionSheet：标题 + 选项
  /// （选中高亮）+ 取消）。
  Future<void> _pickFilter(
    BuildContext context,
    String title,
    List<String> options,
    String current,
    ValueChanged<String> onSelect,
  ) async {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  VboxSpacing.lg, VboxSpacing.lg, VboxSpacing.lg, VboxSpacing.xs),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: VboxTypography.s13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: VboxSpacing.xs),
                children: <Widget>[
                  for (final String opt in options)
                    ListTile(
                      dense: true,
                      title: Text(
                        title == '排序方式'
                            ? SourceDiscoveryView.sortDisplayValue(opt)
                            : opt,
                        style: TextStyle(
                          fontSize: VboxTypography.s14,
                          fontWeight: opt == current
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: opt == current
                              ? VboxColors.skinPrimaryRose
                              : scheme.onSurface,
                        ),
                      ),
                      trailing: opt == current
                          ? const Icon(Icons.check,
                              size: 16, color: VboxColors.skinPrimaryRose)
                          : null,
                      onTap: () => Navigator.of(sheetContext).pop(opt),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            ListTile(
              // 取消按钮居中（对齐 iOS actionSheet Cancel）。
              title: Center(
                child: Text(
                  '取消',
                  style: TextStyle(
                    fontSize: VboxTypography.s14,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              onTap: () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
    );
    if (picked == null || picked == current) return;
    onSelect(picked);
  }

  // ─────────────── UI ───────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildSourceBar(),
        _buildCategoryBar(),
        _buildFilterBar(),
        const SizedBox(height: VboxSpacing.xs),
        Expanded(child: _buildBody()),
      ],
    );
  }

  /// 顶栏（对齐 iOS `topBar`：返回 + 源名下拉按钮 + 右侧类型徽标胶囊）。
  Widget _buildSourceBar() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final SiteConfig? current = _sites
        .where((SiteConfig s) => s.key == _siteKey)
        .cast<SiteConfig?>()
        .firstWhere((SiteConfig? s) => s != null, orElse: () => null);
    final String label = current == null
        ? (_siteKey ?? '')
        : (current.name.isEmpty ? current.key : current.name);
    return Padding(
      padding: VboxSpacing.symmetric(
          horizontal: VboxSpacing.lg, vertical: VboxSpacing.compact + 4),
      child: Row(
        children: <Widget>[
          // 返回（仅嵌入首页站点态时显示；对齐 iOS `chevron.left` 返回）。
          if (widget.onDismiss != null) ...<Widget>[
            InkWell(
              onTap: widget.onDismiss,
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 32,
                height: 32,
                child: Icon(
                  Icons.chevron_left,
                  size: 22,
                  color: scheme.onSurface,
                ),
              ),
            ),
            const SizedBox(width: VboxSpacing.sm),
          ],
          // 源名下拉按钮（对齐 iOS：源名 17pt semibold + chevron.down）。
          Expanded(
            child: InkWell(
              onTap: _openSourceSheet,
              borderRadius: BorderRadius.circular(VboxRadii.chip.topLeft.x),
              child: Padding(
                padding: VboxSpacing.symmetric(vertical: VboxSpacing.xs),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          // iOS 17pt 不在字号档位（[10..28]），取最近档 18pt。
                          fontSize: VboxTypography.s18,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: VboxSpacing.compact),
                    Icon(Icons.expand_more,
                        size: VboxTypography.s10, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: VboxSpacing.sm),
          // 右侧类型徽标（对齐 iOS `source.category.displayName` 胶囊 + 分类色）。
          if (current != null) _buildCategoryBadge(current),
        ],
      ),
    );
  }

  /// 类型徽标胶囊（对齐 iOS `categoryBadgeColor` 分类色）。
  Widget _buildCategoryBadge(SiteConfig site) {
    final String label = site.categoryLabel;
    final Color color = _categoryBadgeColor(label);
    return Container(
      padding: VboxSpacing.symmetric(
          horizontal: VboxSpacing.sm, vertical: VboxSpacing.compact - 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(VboxRadii.capsule),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: VboxTypography.s11,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }

  /// 分类徽标色（对齐 iOS `categoryBadgeColor` 的系统色，经令牌取值）。
  static Color _categoryBadgeColor(String label) =>
      VboxColors.siteCategoryBadgeColors[label] ?? VboxColors.skinPrimaryRose;

  /// 打开左上角选源浮层（对齐 iOS `sourceDropdownOverlay` → `selectedSource`）。
  Future<void> _openSourceSheet() async {
    if (_sites.isEmpty) return;
    final String? key = await showVboxSourceSheet(
      context,
      sites: _sites,
      selectedKey: _siteKey,
    );
    if (key == null || key == _siteKey || !mounted) return;
    await _selectSite(key);
  }

  /// 分类滑动栏（对齐 iOS `categoryScrollBar`：「推荐」+ 分类；chip 粉红选中，
  /// 对齐 iOS `SourceCategoryChip` 的 `E11B48`）。
  Widget _buildCategoryBar() {
    final List<VodCategory> cats = _displayCategories;
    if (cats.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
        children: <Widget>[
          VboxChip(
            label: '推荐',
            selected: _selectedTid == null,
            selectedColor: VboxColors.skinPrimaryRose,
            onTap: () => _selectTid(null),
          ),
          for (int i = 0; i < cats.length; i++) ...<Widget>[
            const SizedBox(width: VboxSpacing.sm),
            VboxChip(
              label: cats[i].typeName,
              selected: _selectedTid == cats[i].typeId,
              selectedColor: VboxColors.skinPrimaryRose,
              onTap: () => _selectTid(cats[i].typeId),
            ),
          ],
        ],
      ),
    );
  }

  /// 自适应筛选栏（对齐 iOS `adaptiveFilterBar` + `shouldShowFilterBar`：
  /// 选中具体分类才显示；类型/地区/年份有选项才显示，排序始终显示）。
  Widget _buildFilterBar() {
    if (!_isBrowsingCategory) return const SizedBox.shrink();
    final List<Widget> chips = <Widget>[
      if (_filterOptions.classOptions.isNotEmpty)
        _FilterChip(
          title: '类型',
          value: _selectedClass,
          hasSelection: _selectedClass != '全部',
          onTap: () => _pickFilter(context, '选择类型', _filterOptions.classOptions,
              _selectedClass, (String v) {
            if (v == _selectedClass) return;
            setState(() => _selectedClass = v);
            _reloadCategoryWithFilters();
          }),
        ),
      if (_filterOptions.area.isNotEmpty)
        _FilterChip(
          title: '地区',
          value: _selectedArea,
          hasSelection: _selectedArea != '全部',
          onTap: () => _pickFilter(context, '选择地区', _filterOptions.area,
              _selectedArea, (String v) {
            if (v == _selectedArea) return;
            setState(() => _selectedArea = v);
            _reloadCategoryWithFilters();
          }),
        ),
      if (_filterOptions.year.isNotEmpty)
        _FilterChip(
          title: '年份',
          value: _selectedYear,
          hasSelection: _selectedYear != '全部',
          onTap: () => _pickFilter(context, '选择年份', _filterOptions.year,
              _selectedYear, (String v) {
            if (v == _selectedYear) return;
            setState(() => _selectedYear = v);
            _reloadCategoryWithFilters();
          }),
        ),
      _FilterChip(
        title: '排序',
        value: SourceDiscoveryView.sortDisplayValue(_selectedSort),
        hasSelection: _selectedSort != '全部',
        onTap: () => _pickFilter(context, '排序方式', _filterOptions.sort,
            _selectedSort, (String v) {
          if (v == _selectedSort) return;
          setState(() => _selectedSort = v);
          _reloadCategoryWithFilters();
        }),
      ),
    ];
    if (chips.length == 1 && _filterOptions.sort.length <= 1) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: VboxSpacing.symmetric(
            horizontal: VboxSpacing.lg, vertical: VboxSpacing.compact),
        children: <Widget>[
          for (int i = 0; i < chips.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: VboxSpacing.sm),
            chips[i],
          ],
        ],
      ),
    );
  }

  Widget _buildBody() {
    // 常驻 RefreshIndicator（对齐 iOS `.refreshable`）：即使加载 / 空态 / 失败态
    // 也保持下拉可用，且首页站点态常驻保活依赖它存在（见 home_keepalive 测试）。
    return RefreshIndicator(
      onRefresh: _refresh,
      child: _buildBodyContent(),
    );
  }

  Widget _buildBodyContent() {
    if (_loadingSites) {
      return _scrollableCenter(const CircularProgressIndicator());
    }
    final Failure? sitesError = _sitesError;
    if (sitesError != null) {
      return _scrollableCenter(
        _ErrorRetry(message: '$sitesError', onRetry: _retry),
      );
    }
    if (_sites.isEmpty) {
      return _scrollableCenter(
        const _EmptyState(message: '没有可浏览的站点\n请先在「订阅源」添加可用源'),
      );
    }
    // 加载态（对齐 iOS：ProgressView + 「正在加载 {源名}...」；有旧内容时不整页拦截）。
    if (_loading && _displayItems.isEmpty) {
      return _scrollableCenter(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: VboxSpacing.xl),
            Text(
              '正在加载 $_currentSiteName...',
              style: TextStyle(
                fontSize: VboxTypography.s14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    final Failure? error = _error;
    if (error != null && _displayItems.isEmpty) {
      // 错误态（对齐 iOS：wifi.slash 图标 + 统一文案 + 重试）。
      return _scrollableCenter(
        _ErrorRetry(
          message: '$_currentSiteName 暂无数据，请检查网络或切换其他源',
          onRetry: _retry,
        ),
      );
    }
    if (_displayItems.isEmpty) {
      // 空态（对齐 iOS：tray 图标 + 分类/推荐区分文案 + 搜索引导）。
      return _scrollableCenter(
        _EmptyState(
          message: _isBrowsingCategory ? '该分类暂无数据' : '暂无推荐内容',
          hint: '可前往搜索获取更多资源',
        ),
      );
    }
    return _buildGrid();
  }

  /// 将不可滚动的内容（加载 / 空态 / 失败态）包进可滚动视口，
  /// 保证 [RefreshIndicator] 始终有可下拉的 Scrollable。
  Widget _scrollableCenter(Widget child) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: <Widget>[
            SizedBox(
              height: constraints.maxHeight,
              width: constraints.maxWidth,
              child: Center(child: child),
            ),
          ],
        );
      },
    );
  }

  Widget _buildGrid() {
    final UiFormController formController = context.watch<UiFormController>();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final UiForm form = formController.resolveAt(
          size: MediaQuery.sizeOf(context),
          orientation: MediaQuery.orientationOf(context),
        );
        const double paddingH = VboxSpacing.lg;
        const double spacing = VboxSpacing.md;
        final double availWidth = constraints.maxWidth - paddingH * 2;
        final int columns = ResponsiveGrid.columnsFor(
          form: form,
          width: constraints.maxWidth,
        );
        final double cellWidth =
            (availWidth - spacing * (columns - 1)) / columns;
        // 卡片高：2:3 封面 + 标题 2 行 + 年份行（对齐 iOS SourceVideoCard 结构）。
        final double cellExtent = cellWidth * 1.5 + 60;

        final bool paging = _isBrowsingCategory;
        final bool showFooter = paging && _hasMore;
        return GridView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(paddingH, 12, paddingH, 100),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: cellExtent,
          ),
          itemCount: _displayItems.length + (showFooter ? 1 : 0),
          itemBuilder: (BuildContext context, int index) {
            if (index >= _displayItems.length) {
              return _buildLoadMoreFooter();
            }
            return _posterFromVod(_displayItems[index], index);
          },
        );
      },
    );
  }

  /// 「加载更多」footer（对齐 iOS `loadMoreFooter`：加载中显示进度，否则
  /// 显示可点按钮）。
  Widget _buildLoadMoreFooter() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_loadingMore) {
      return Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: VboxSpacing.xs),
            Text(
              '加载中...',
              style: TextStyle(
                fontSize: VboxTypography.s12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return Center(
      child: InkWell(
        onTap: _loadMore,
        borderRadius: BorderRadius.circular(VboxRadii.chip.topLeft.x),
        child: Padding(
          padding: VboxSpacing.symmetric(vertical: VboxSpacing.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.arrow_downward,
                  size: VboxTypography.s12, color: scheme.onSurfaceVariant),
              const SizedBox(width: VboxSpacing.xs),
              Text(
                '加载更多',
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _posterFromVod(VodItem vod, int index) {
    final String? remarks =
        (vod.vodRemarks?.isNotEmpty ?? false) ? vod.vodRemarks : null;
    final String? year = (vod.vodYear?.isNotEmpty ?? false) ? vod.vodYear : null;
    // 掉落回弹入场：同行卡片自左向右错峰（对齐 iOS `fallDelay = index % 3 * 0.12`）。
    return FallInCard(
      delay: (index % 3) * 0.12,
      child: _PosterCell(
        title: vod.vodName,
        imageUrl: vod.vodPic,
        remarks: remarks,
        year: year,
        onTap: () => _openDetail(vod),
      ),
    );
  }

  void _openDetail(VodItem vod) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => DetailPage(
          siteKey: _siteKey ?? '',
          vodId: vod.vodId,
          title: vod.vodName,
          // 源发现进入 → 沉浸式（隐藏 AppBar，对齐 iOS `isFromSourceDiscovery`）。
          isFromSourceDiscovery: true,
        ),
      ),
    );
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 自适应筛选维度（对齐 iOS `SpiderManager.AdaptiveFilterOptions`）。
class AdaptiveFilterOptions {
  /// 构造。
  const AdaptiveFilterOptions({
    this.classOptions = const <String>[],
    this.area = const <String>[],
    this.year = const <String>[],
    this.sort = const <String>['全部', 'hits', 'addtime', 'score', 'rand'],
  });

  /// 类型/题材选项（对齐 iOS 现状：`extractAdaptiveFilters` 未从数据提取
  /// class，恒为空 → 「类型」chip 不显示；参数保留供后续数据源支持）。
  final List<String> classOptions;

  /// 地区选项（升序，「全部」在首位）。
  final List<String> area;

  /// 年份选项（降序，「全部」在首位）。
  final List<String> year;

  /// 排序选项（固定）。
  final List<String> sort;
}

/// 从一组 [VodItem] 自适应提取筛选选项（对齐 iOS
/// `SpiderManager.extractAdaptiveFilters` L2045-L2083）：
///   · 地区：`vodArea` 按 `/ , ， 、` 拆分去重，升序；
///   · 年份：`vodYear` 提取前 4 位数字，去重降序；
///   · 类型：iOS 循环体仅填充 area/year（classSet 声明后未填充），对齐现状
///     恒空；各维度非空时加「全部」前缀。
AdaptiveFilterOptions extractAdaptiveFilters(List<VodItem> items) {
  final Set<String> areaSet = <String>{};
  final Set<String> yearSet = <String>{};

  for (final VodItem item in items) {
    final String? area = item.vodArea;
    if (area != null && area.isNotEmpty) {
      for (final String part in area.split(RegExp(r'[/,，、]'))) {
        final String t = part.trim();
        if (t.isNotEmpty) areaSet.add(t);
      }
    }
    final String? year = item.vodYear;
    if (year != null && year.isNotEmpty) {
      final String digits =
          year.split('').where((String c) => int.tryParse(c) != null).join();
      if (digits.length >= 4) yearSet.add(digits.substring(0, 4));
    }
  }

  final List<String> sortedAreas = areaSet.toList()..sort();
  final List<String> sortedYears = yearSet.toList()..sort((String a, String b) => b.compareTo(a));

  return AdaptiveFilterOptions(
    area: sortedAreas.isEmpty ? const <String>[] : <String>['全部', ...sortedAreas],
    year: sortedYears.isEmpty ? const <String>[] : <String>['全部', ...sortedYears],
  );
}

/// 网格海报单元（对齐 iOS `SourceVideoCard`：2:3 封面 + 右下备注角标 +
/// 标题 2 行 + 年份行）。
class _PosterCell extends StatelessWidget {
  const _PosterCell({
    required this.title,
    this.imageUrl,
    this.remarks,
    this.year,
    this.onTap,
  });

  final String title;
  final String? imageUrl;

  /// 备注角标文案（封面右下角，对齐 iOS `vodRemarks` 标签）。
  final String? remarks;

  /// 年份行（标题下方，对齐 iOS `vodYear` 行）。
  final String? year;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: VboxRadii.card,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  PlatformAsyncImage(
                    url: imageUrl,
                    fit: BoxFit.cover,
                    placeholderColor: scheme.surfaceContainerHighest,
                  ),
                  // 备注角标（对齐 iOS：右下角黑底 0.65 圆角 4 白字 10pt）。
                  if (remarks != null)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          remarks!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: VboxTypography.s10,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: VboxSpacing.compact),
          // 标题（2 行，对齐 iOS 13pt medium lineLimit 2）。
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
          if (year != null)
            Text(
              year!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: VboxTypography.s11,
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// 自适应筛选胶囊（对齐 iOS `AdaptiveFilterChip`：title 12pt secondary +
/// value 12pt medium（选中粉红）+ chevron.down；选中粉红 0.1 底 + 0.3 描边）。
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.title,
    required this.value,
    required this.hasSelection,
    required this.onTap,
  });

  final String title;
  final String value;
  final bool hasSelection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const Color rose = VboxColors.skinPrimaryRose;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VboxRadii.capsule),
      child: Container(
        padding: VboxSpacing.symmetric(
            horizontal: VboxSpacing.md, vertical: VboxSpacing.compact),
        decoration: BoxDecoration(
          color: hasSelection
              ? rose.withValues(alpha: 0.1)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(VboxRadii.capsule),
          border: Border.all(
            color: hasSelection
                ? rose.withValues(alpha: 0.3)
                : scheme.outlineVariant.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              title,
              style: TextStyle(
                fontSize: VboxTypography.s12,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: VboxSpacing.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 96),
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  fontWeight: FontWeight.w500,
                  color: hasSelection ? rose : scheme.onSurface,
                ),
              ),
            ),
            Icon(Icons.expand_more,
                size: VboxTypography.s12, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// 空态提示（对齐 iOS：tray 图标 + 主文案 + 可选搜索引导副文案）。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message, this.hint});

  final String message;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.inbox,
              size: 36,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: VboxSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: VboxTypography.s14,
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (hint != null) ...<Widget>[
              const SizedBox(height: VboxSpacing.sm),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 加载失败提示 + 重试（对齐 iOS：wifi.slash 40pt secondary 图标 + 文案 +
/// 重试按钮）。
class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.wifi_off,
              size: 40,
              color: Colors.grey,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
