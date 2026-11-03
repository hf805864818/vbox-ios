/// 表现层：福利 Spider JS / Python 引擎执行页（批次 H · H-03 续段）。
///
/// 唯一真相源：iOS `vbox/Views/FuliPlatformMainView.swift`
///   · `FuliPlatformMainView`（L37-L175）：首次进入加载首页（分类 + 推荐），
///     加载中 / 加载失败（分类为空）→ 重试；成功 → 分类 Tab 栏 + 内容 TabView；
///   · `FuliCategoryTabBar`（同文件 L189-L243）：横向滚动分类 + 「搜索」Tab，
///     选中自动滚动定位，选中态 = 主色粗字 + 20×3 胶囊指示条；
///   · `FuliCategoryTabView`（L178-L369）：子分类胶囊栏（「全部」+ 二级）
///     + 2 列视频网格 + 加载更多 + 下拉刷新 + 错误重试；每 Tab 状态存于
///     `CategoryTabStateCache`（本页以父级 `Map<String, _CategoryTabState>` 对齐）；
///   · `FuliSearchTabView`（L372-L490）：搜索框 + 2 列结果网格 + 加载更多；
///   · `FuliCategoryNavigatorView`（`FuliCategoryNavigatorView.swift`）：
///     半透明背景 + 白圆角卡片（16）+ 4 列网格 + 分类 > 30 显示搜索框
///     + 二级分类展开；
///   · `FuliVideoCard`（L493-L540）：封面（≈16:9 全宽）+ 底部渐变 + 胶囊标签
///     + 标题 12 两行。
///
/// 与 iOS 的差异（如实登记）：
///   · 视频点击 → [WelfareVideoBridgePage]（线路/选集页面内呈现，底部面板交互归 H-06）；
///     漫画平台（`contentCategory == comic`）点击 → [WelfareComicReaderPage] 长卷
///     阅读器（UI-C1，对齐 iOS `ComicDirectReaderView` / `MangaReaderView`）；
///   · `FuliCategoryNavigatorView` 中 iOS 点击「有二级分类」仅切换展开动画
///     （展开内容未渲染，疑为 iOS 半成品），Flutter 补齐「展开二级分类区」，
///     选中子类回调对齐 iOS `onSelectSub`（设 `selectedSubId` + 刷新对应 Tab）；
///   · iOS `navigationTitle("")` 由 AppBar 平台名替代（与脚本状态页一致）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/welfare/welfare.dart';
import '../../../domain/services/fuli_base_service.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import 'welfare_comic_reader_page.dart';
import 'welfare_video_bridge_page.dart';

/// 福利 Spider 引擎执行页（`welfare_spider` + JS/Python 脚本平台）。
///
/// 由 [FuliBaseService] 驱动：首页分类 + 推荐 → 分类 Tab 页 + 搜索 Tab。
class WelfareSpiderMainPage extends StatefulWidget {
  /// 构造。
  const WelfareSpiderMainPage({
    super.key,
    required this.platform,
    required this.service,
  });

  /// 触发路由的平台元数据（标题 / 卡片展示）。
  final WelfarePlatform platform;

  /// 引擎服务（JS / Python Spider，均继承 [FuliBaseService]）。
  final FuliBaseService service;

  @override
  State<WelfareSpiderMainPage> createState() => _WelfareSpiderMainPageState();
}

/// 分类 Tab 页状态（对齐 iOS `CategoryTabStateCache.State`）。
class _CategoryTabState {
  List<FuliVideo> videos = <FuliVideo>[];
  bool isLoading = true;
  bool isLoadingMore = false;
  int currentPage = 1;
  bool hasMore = true;
  String? loadError;
  bool hasLoaded = false;
  String? selectedSubId;
}

class _WelfareSpiderMainPageState extends State<WelfareSpiderMainPage> {
  /// 各分类 Tab 状态（对齐 iOS `CategoryTabStateCache`，Tab 卸载不丢数据）。
  final Map<String, _CategoryTabState> _tabStates = <String, _CategoryTabState>{};

  /// 分类导航选中子类后的强制刷新信号（对齐 iOS NotificationCenter 通知）。
  final Map<String, int> _reloadTicks = <String, int>{};

  final PageController _pageController = PageController();

  List<FuliCategory> _categories = <FuliCategory>[];
  int _selectedTab = 0;
  bool _isLoading = true;
  String? _loadError;
  bool _hasLoadedHome = false;

  @override
  void initState() {
    super.initState();
    // 对齐 iOS `onAppear`：首次进入加载首页。
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadHome());
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  _CategoryTabState _stateFor(String cacheKey) =>
      _tabStates.putIfAbsent(cacheKey, _CategoryTabState.new);

  // ─────────────── 首页加载（对齐 iOS `loadHome`）───────────────

  void _loadHome() {
    if (_hasLoadedHome) return;
    _hasLoadedHome = true;
    _loadHomeInternal();
  }

  Future<void> _loadHomeInternal() async {
    final FuliHomeResult result = await widget.service.fetchHomeContent();
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _categories = result.categories;
      if (result.categories.isEmpty) {
        _loadError = '未能解析到分类，请检查域名或网络';
      } else {
        _loadError = null;
        _selectedTab = 0;
      }
    });
  }

  /// 重试（对齐 iOS：先重置域名就绪状态再重新探测）。
  void _retry() {
    widget.service.reprobe();
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    _loadHomeInternal();
  }

  // ─────────────── 交互 ───────────────

  void _selectTab(int index) {
    if (index == _selectedTab) return;
    setState(() => _selectedTab = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  void _openVideo(FuliVideo video) {
    // 漫画平台（`contentCategory == comic`）→ 长卷阅读器（UI-C1，对齐 iOS
    // `FuliPlatformMainView.videoCard` 的 `svc.contentCategory == .comic` 分支）；
    // 其余 → 视频播放中转页。
    final bool isComic =
        widget.service.contentCategory == FuliContentCategory.comic;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => isComic
            ? WelfareComicReaderPage(service: widget.service, video: video)
            : WelfareVideoBridgePage(service: widget.service, video: video),
      ),
    );
  }

  void _openCategoryNav() {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '全部分类',
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder:
          (BuildContext context, Animation<double> animation, Animation<double> secondary) =>
              _WelfareCategoryNavigator(
        categories: _categories,
        selectedIndex: _selectedTab,
        onSelect: _selectTab,
        onSelectSub: _onSelectSubFromNav,
        onDismiss: () => Navigator.of(context).pop(),
      ),
      transitionBuilder: (BuildContext context, Animation<double> animation,
              Animation<double> secondary, Widget child) =>
          FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.9, end: 1.0).animate(animation),
          child: child,
        ),
      ),
    );
  }

  /// 导航弹窗选中子类（对齐 iOS `onSelectSub`：设 `selectedSubId` + 刷新目标 Tab）。
  void _onSelectSubFromNav(int parentIdx, FuliCategory sub) {
    final FuliCategory parent = _categories[parentIdx];
    final _CategoryTabState state = _stateFor(parent.typeId);
    state.selectedSubId = sub.typeId;
    _reloadTicks[parent.typeId] = (_reloadTicks[parent.typeId] ?? 0) + 1;
    setState(() {});
  }

  // ─────────────── 构建 ───────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.platform.name),
        centerTitle: true,
        actions: <Widget>[
          IconButton(
            tooltip: '全部分类',
            icon: const Icon(Icons.grid_view_rounded),
            onPressed: _categories.isEmpty ? null : _openCategoryNav,
          ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _categories.isEmpty) {
      return _errorView(context);
    }
    return Column(
      children: <Widget>[
        _WelfareCategoryTabBar(
          categories: _categories,
          selectedTab: _selectedTab,
          onSelect: _selectTab,
        ),
        const Divider(height: 1),
        Expanded(
          child: PageView(
            controller: _pageController,
            onPageChanged: (int index) => setState(() => _selectedTab = index),
            children: <Widget>[
              for (final FuliCategory cat in _categories)
                _WelfareCategoryTabView(
                  key: ValueKey<String>('welfare-cat-${cat.typeId}'),
                  service: widget.service,
                  category: cat,
                  cacheKey: cat.typeId,
                  state: _stateFor(cat.typeId),
                  onStateChanged: () => setState(() {}),
                  onVideoTap: _openVideo,
                  reloadTick: _reloadTicks[cat.typeId] ?? 0,
                ),
              _WelfareSearchTabView(
                key: const ValueKey<String>('welfare-search-tab'),
                service: widget.service,
                onVideoTap: _openVideo,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _errorView(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(VboxSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.wifi_off_rounded, size: 50, color: scheme.outline),
            const SizedBox(height: VboxSpacing.lg),
            Text(
              _loadError ?? '加载失败',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: VboxTypography.s15,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: VboxSpacing.lg),
            FilledButton.tonalIcon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 横向分类 Tab 栏 + 「搜索」Tab（对齐 iOS `FuliCategoryTabBar`）。
class _WelfareCategoryTabBar extends StatefulWidget {
  const _WelfareCategoryTabBar({
    required this.categories,
    required this.selectedTab,
    required this.onSelect,
  });

  final List<FuliCategory> categories;
  final int selectedTab;
  final ValueChanged<int> onSelect;

  @override
  State<_WelfareCategoryTabBar> createState() => _WelfareCategoryTabBarState();
}

class _WelfareCategoryTabBarState extends State<_WelfareCategoryTabBar> {
  List<GlobalKey> _keys = <GlobalKey>[];

  @override
  void didUpdateWidget(covariant _WelfareCategoryTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedTab != widget.selectedTab) {
      _scrollToSelected();
    }
  }

  /// 选中变化时自动滚动定位（对齐 iOS `ScrollViewReader.scrollTo`）。
  void _scrollToSelected() {
    final int index = widget.selectedTab;
    if (index < 0 || index >= _keys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? keyContext = _keys[index].currentContext;
      if (keyContext == null || !mounted) return;
      Scrollable.ensureVisible(
        keyContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final int count = widget.categories.length + 1;
    if (_keys.length != count) {
      _keys = List<GlobalKey>.generate(count, (int _) => GlobalKey());
    }
    return SizedBox(
      height: 44,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.sm),
        child: Row(
          children: <Widget>[
            for (int i = 0; i < widget.categories.length; i++)
              _tabButton(
                key: _keys[i],
                title: widget.categories[i].typeName,
                isSelected: widget.selectedTab == i,
                onTap: () => widget.onSelect(i),
              ),
            _tabButton(
              key: _keys[widget.categories.length],
              title: '搜索',
              isSelected: widget.selectedTab == widget.categories.length,
              onTap: () => widget.onSelect(widget.categories.length),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabButton({
    required GlobalKey key,
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: key,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.md),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: VboxTypography.s14,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: 20,
              height: 3,
              decoration: BoxDecoration(
                color: isSelected ? scheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(VboxRadii.r4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分类 Tab 页：子分类胶囊栏 + 2 列视频网格 + 加载更多 + 下拉刷新 + 错误重试。
class _WelfareCategoryTabView extends StatefulWidget {
  const _WelfareCategoryTabView({
    super.key,
    required this.service,
    required this.category,
    required this.cacheKey,
    required this.state,
    required this.onStateChanged,
    required this.onVideoTap,
    this.reloadTick = 0,
  });

  final FuliBaseService service;
  final FuliCategory category;
  final String cacheKey;
  final _CategoryTabState state;
  final VoidCallback onStateChanged;
  final ValueChanged<FuliVideo> onVideoTap;
  final int reloadTick;

  @override
  State<_WelfareCategoryTabView> createState() => _WelfareCategoryTabViewState();
}

class _WelfareCategoryTabViewState extends State<_WelfareCategoryTabView> {
  @override
  void initState() {
    super.initState();
    _initialLoad();
  }

  @override
  void didUpdateWidget(covariant _WelfareCategoryTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 分类导航选中子类 → 强制刷新（对齐 iOS NotificationCenter 通知监听）。
    // 同样延迟到帧后：didUpdateWidget 处于构建期，同步 setState 会抛异常。
    if (widget.reloadTick != oldWidget.reloadTick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _refresh(force: true);
      });
    }
  }

  _CategoryTabState get _state => widget.state;

  FuliCategory? get _selectedSub {
    final String? subId = _state.selectedSubId;
    if (subId == null) return null;
    for (final FuliCategory sub
        in widget.category.subCategories ?? const <FuliCategory>[]) {
      if (sub.typeId == subId) return sub;
    }
    return null;
  }

  /// 首次进入（对齐 iOS `onAppear`：未加载过才触发）。
  ///
  /// 延迟到首帧后执行：`onStateChanged` / `_refresh` 内部会同步触发父级
  /// `setState`，若在 `initState`（PageView 构建子页期间）直接调用会触发
  /// "setState() or markNeedsBuild() called during build"。
  void _initialLoad() {
    if (_state.hasLoaded) return;
    _state.hasLoaded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onStateChanged();
      _refresh(force: false);
    });
  }

  Future<void> _refresh({bool force = false}) async {
    if (!force && _state.videos.isNotEmpty) return;
    _mutate((_CategoryTabState s) {
      s.currentPage = 1;
      s.hasMore = true;
      s.isLoading = true;
      s.loadError = null;
    });
    final FuliCategoryResult result = await widget.service.fetchCategoryContent(
      category: widget.category,
      subCategory: _selectedSub,
      page: 1,
    );
    if (!mounted) return;
    _mutate((_CategoryTabState s) {
      s.videos = result.videos;
      s.isLoading = false;
      s.hasMore = result.hasMore;
      if (result.videos.isEmpty) s.loadError = '暂无内容';
    });
  }

  Future<void> _loadMore() async {
    final _CategoryTabState s = _state;
    if (s.isLoadingMore || !s.hasMore || s.isLoading) return;
    _mutate((_CategoryTabState x) => x.isLoadingMore = true);
    final int next = s.currentPage + 1;
    final FuliCategoryResult result = await widget.service.fetchCategoryContent(
      category: widget.category,
      subCategory: _selectedSub,
      page: next,
    );
    if (!mounted) return;
    _mutate((_CategoryTabState x) {
      if (result.videos.isNotEmpty) {
        x.videos.addAll(result.videos);
        x.currentPage = next;
        x.hasMore = result.hasMore;
      } else {
        x.hasMore = false;
      }
      x.isLoadingMore = false;
    });
  }

  void _mutate(void Function(_CategoryTabState) fn) {
    fn(_state);
    widget.onStateChanged();
  }

  @override
  Widget build(BuildContext context) {
    final List<FuliCategory> subs = widget.category.subCategories ?? const <FuliCategory>[];
    return Column(
      children: <Widget>[
        if (subs.isNotEmpty) _subCategoryBar(subs),
        Expanded(child: _content(context)),
      ],
    );
  }

  // ────────────── 子分类胶囊栏（对齐 iOS `subCategoryBar`）──────────────

  Widget _subCategoryBar(List<FuliCategory> subs) {
    return Column(
      children: <Widget>[
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: VboxSpacing.md,
            vertical: VboxSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              _subButton(title: '全部', isSelected: _selectedSub == null, onTap: _selectAll),
              for (final FuliCategory sub in subs) ...<Widget>[
                const SizedBox(width: VboxSpacing.sm),
                _subButton(
                  title: sub.typeName,
                  isSelected: _selectedSub?.typeId == sub.typeId,
                  onTap: () => _selectSub(sub),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _subButton({
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(VboxRadii.r14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.md,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? scheme.primary
              : scheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(VboxRadii.r14),
        ),
        child: Text(
          title,
          style: TextStyle(
            fontSize: VboxTypography.s12,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            color: isSelected ? scheme.onPrimary : scheme.primary,
          ),
        ),
      ),
    );
  }

  void _selectSub(FuliCategory? sub) {
    _mutate((_CategoryTabState s) => s.selectedSubId = sub?.typeId);
    _refresh(force: true);
  }

  void _selectAll() => _selectSub(null);

  // ────────────── 内容区（对齐 iOS `contentArea`）──────────────

  Widget _content(BuildContext context) {
    if (_state.isLoading && _state.videos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_state.loadError != null && _state.videos.isEmpty) {
      final ColorScheme scheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              _state.loadError!,
              style: TextStyle(
                fontSize: VboxTypography.s14,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: VboxSpacing.sm),
            TextButton(
              onPressed: () => _refresh(force: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _refresh(force: true),
      child: _VideoGrid(
        videos: _state.videos,
        imageReferer: widget.service.imageReferer,
        imageSSLBypass: widget.service.imageSSLBypass,
        onVideoTap: widget.onVideoTap,
        onLoadMore: _loadMore,
        isLoadingMore: _state.isLoadingMore,
        hasMore: _state.hasMore,
      ),
    );
  }
}

/// 搜索 Tab（对齐 iOS `FuliSearchTabView`）。
class _WelfareSearchTabView extends StatefulWidget {
  const _WelfareSearchTabView({
    super.key,
    required this.service,
    required this.onVideoTap,
  });

  final FuliBaseService service;
  final ValueChanged<FuliVideo> onVideoTap;

  @override
  State<_WelfareSearchTabView> createState() => _WelfareSearchTabViewState();
}

class _WelfareSearchTabViewState extends State<_WelfareSearchTabView> {
  final TextEditingController _keywordController = TextEditingController();
  List<FuliVideo> _videos = <FuliVideo>[];
  bool _isLoading = false;
  int _currentPage = 1;
  bool _hasMore = false;

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final String keyword = _keywordController.text.trim();
    if (keyword.isEmpty) return;
    setState(() {
      _currentPage = 1;
      _hasMore = true;
      _isLoading = true;
      _videos = <FuliVideo>[];
    });
    final FuliSearchResult result =
        await widget.service.fetchSearch(keyword: keyword, page: 1);
    if (!mounted) return;
    setState(() {
      _videos = result.videos;
      _isLoading = false;
      _hasMore = result.hasMore;
    });
  }

  Future<void> _loadMore() async {
    if (_isLoading || !_hasMore) return;
    setState(() => _isLoading = true);
    final int next = _currentPage + 1;
    final String keyword = _keywordController.text.trim();
    final FuliSearchResult result =
        await widget.service.fetchSearch(keyword: keyword, page: next);
    if (!mounted) return;
    setState(() {
      if (result.videos.isNotEmpty) {
        _videos.addAll(result.videos);
        _currentPage = next;
        _hasMore = result.hasMore;
      } else {
        _hasMore = false;
      }
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _searchBar(context),
        Expanded(child: _content(context)),
      ],
    );
  }

  Widget _searchBar(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = theme.brightness == Brightness.dark
        ? VboxColors.secondaryLabelDark
        : VboxColors.secondaryLabelLight;
    return Padding(
      padding: const EdgeInsets.all(VboxSpacing.md),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.md,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: theme.brightness == Brightness.dark
              ? VboxColors.secondarySystemBackgroundDark
              : VboxColors.secondarySystemBackgroundLight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.search, size: VboxTypography.s14, color: secondary),
            const SizedBox(width: VboxSpacing.sm),
            Expanded(
              child: TextField(
                controller: _keywordController,
                style: const TextStyle(fontSize: VboxTypography.s14),
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: '搜索视频',
                  border: InputBorder.none,
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _search(),
              ),
            ),
            if (_keywordController.text.isNotEmpty)
              IconButton(
                icon: Icon(Icons.cancel, size: VboxTypography.s16, color: secondary),
                tooltip: '清空',
                onPressed: () => setState(() => _keywordController.clear()),
              ),
            TextButton(
              onPressed:
                  _keywordController.text.trim().isEmpty || _isLoading ? null : _search,
              child: const Text('搜索'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (_isLoading && _videos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return _VideoGrid(
      videos: _videos,
      imageReferer: widget.service.imageReferer,
      imageSSLBypass: widget.service.imageSSLBypass,
      onVideoTap: widget.onVideoTap,
      onLoadMore: _loadMore,
      isLoadingMore: _isLoading,
      hasMore: _hasMore,
    );
  }
}

/// 2 列视频网格（分类 / 搜索共用，对齐 iOS `videoGrid` / `searchResultGrid`）。
class _VideoGrid extends StatelessWidget {
  const _VideoGrid({
    required this.videos,
    required this.imageReferer,
    required this.imageSSLBypass,
    required this.onVideoTap,
    required this.onLoadMore,
    required this.isLoadingMore,
    required this.hasMore,
  });

  final List<FuliVideo> videos;
  final String? imageReferer;
  final bool imageSSLBypass;
  final ValueChanged<FuliVideo> onVideoTap;
  final VoidCallback onLoadMore;
  final bool isLoadingMore;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        // 接近底部自动加载更多（对齐 iOS `videoCard.onAppear` 的末 4 项触发）。
        if (notification.metrics.pixels >=
            notification.metrics.maxScrollExtent - 200) {
          onLoadMore();
        }
        return false;
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: <Widget>[
          SliverPadding(
            padding: const EdgeInsets.all(VboxSpacing.md),
            sliver: SliverGrid(
              gridDelegate: _gridDelegateFor(context),
              delegate: SliverChildBuilderDelegate(
                (BuildContext context, int index) {
                  final FuliVideo video = videos[index];
                  return WelfareVideoCard(
                    video: video,
                    imageReferer: imageReferer,
                    imageSSLBypass: imageSSLBypass,
                    onTap: () => onVideoTap(video),
                  );
                },
                childCount: videos.length,
              ),
            ),
          ),
          if (isLoadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: VboxSpacing.md),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              ),
            ),
          if (!hasMore && videos.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 4, bottom: VboxSpacing.xl),
                child: Center(
                  child: Text(
                    '已加载全部',
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 2 列网格布局（列宽随屏宽计算，卡片高 = 封面 + 间距 + 两行标题，杜绝溢出）。
SliverGridDelegateWithFixedCrossAxisCount _gridDelegateFor(
  BuildContext context,
) {
  final double width = MediaQuery.sizeOf(context).width;
  final double columnWidth = (width - VboxSpacing.lg * 2 - 10) / 2;
  final double extent = columnWidth / 1.9 + 6 + 34;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 2,
    crossAxisSpacing: 10,
    mainAxisSpacing: 14,
    mainAxisExtent: extent,
  );
}

/// 视频卡片（对齐 iOS `FuliVideoCard`：封面 ≈16:9 全宽 + 底部渐变
/// + 胶囊标签（评分 · 地区 · 时长）+ 标题 12 两行）。
class WelfareVideoCard extends StatelessWidget {
  /// 构造。
  const WelfareVideoCard({
    super.key,
    required this.video,
    this.imageReferer,
    this.imageSSLBypass = false,
    this.onTap,
  });

  /// 视频条目。
  final FuliVideo video;

  /// 封面防盗链 Referer（空则不附加请求头）。
  final String? imageReferer;

  /// 封面图是否绕过 SSL（对齐 iOS `imageSSLBypass`）。
  final bool imageSSLBypass;

  /// 点击回调。
  final VoidCallback? onTap;

  /// 底部胶囊标签（对齐 iOS `bottomLabel`：评分 · 地区 · 时长）。
  String get _bottomLabel {
    final List<String> parts = <String>[
      if (video.score != null && video.score!.isNotEmpty) video.score!,
      if (video.areaName != null && video.areaName!.isNotEmpty) video.areaName!,
      if (video.duration != null && video.duration!.isNotEmpty) video.duration!,
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String bottomLabel = _bottomLabel;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(VboxRadii.r10),
            child: AspectRatio(
              aspectRatio: 1.9,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  PlatformAsyncImage.sourceCover(
                    video.vodPic,
                    referer: imageReferer,
                    sslBypass: imageSSLBypass,
                    fit: BoxFit.cover,
                  ),
                  // 底部渐变（对齐 iOS `LinearGradient` 0 → 0.55）。
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.55),
                        ],
                      ),
                    ),
                  ),
                  if (bottomLabel.isNotEmpty)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.45),
                        shape: const StadiumBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: VboxSpacing.sm,
                            vertical: 4,
                          ),
                          child: Text(
                            bottomLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: VboxTypography.s10,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            video.vodName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: VboxTypography.s12,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// 分类导航悬浮弹窗（对齐 iOS `FuliCategoryNavigatorView`）。
///
/// 半透明背景 + 白圆角卡片（16，最大宽 520 / 高 55% 屏）+ 4 列网格；
/// 分类 > 30 显示搜索框；点击「有二级分类」展开二级分类区。
class _WelfareCategoryNavigator extends StatefulWidget {
  const _WelfareCategoryNavigator({
    required this.categories,
    required this.selectedIndex,
    required this.onSelect,
    required this.onSelectSub,
    required this.onDismiss,
  });

  final List<FuliCategory> categories;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final void Function(int parentIdx, FuliCategory sub) onSelectSub;
  final VoidCallback onDismiss;

  @override
  State<_WelfareCategoryNavigator> createState() =>
      _WelfareCategoryNavigatorState();
}

class _WelfareCategoryNavigatorState extends State<_WelfareCategoryNavigator> {
  String? _expandedTypeId;
  String _searchText = '';

  bool get _showSearch => widget.categories.length > 30;

  List<FuliCategory> get _filtered {
    if (_searchText.isEmpty) return widget.categories;
    final String lower = _searchText.toLowerCase();
    return widget.categories
        .where((FuliCategory c) => c.typeName.toLowerCase().contains(lower))
        .toList(growable: false);
  }

  int _originalIndex(FuliCategory category) =>
      widget.categories.indexWhere((FuliCategory c) => c.typeId == category.typeId);

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double width =
        (MediaQuery.sizeOf(context).width - 32).clamp(0.0, 520.0);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Container(
          width: width,
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(VboxRadii.r16),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.55,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _titleBar(context),
                if (_showSearch) _searchBar(context),
                const Divider(height: 1),
                Flexible(child: _content(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleBar(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.lg,
        vertical: VboxSpacing.rowVertical,
      ),
      child: Row(
        children: <Widget>[
          Text(
            '全部分类',
            style: TextStyle(
              fontSize: VboxTypography.s16,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              Icons.close,
              size: VboxTypography.s16,
              color: scheme.onSurfaceVariant,
            ),
            tooltip: '关闭',
            onPressed: widget.onDismiss,
          ),
        ],
      ),
    );
  }

  Widget _searchBar(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = theme.brightness == Brightness.dark
        ? VboxColors.secondaryLabelDark
        : VboxColors.secondaryLabelLight;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VboxSpacing.md,
        0,
        VboxSpacing.md,
        10,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.md,
          vertical: 9,
        ),
        decoration: BoxDecoration(
          color: theme.brightness == Brightness.dark
              ? VboxColors.secondarySystemBackgroundDark
              : VboxColors.secondarySystemBackgroundLight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.search, size: VboxTypography.s14, color: secondary),
            const SizedBox(width: VboxSpacing.sm),
            Expanded(
              child: TextField(
                style: const TextStyle(fontSize: VboxTypography.s14),
                decoration: const InputDecoration(
                  hintText: '搜索分类',
                  border: InputBorder.none,
                  isDense: true,
                ),
                onChanged: (String value) =>
                    setState(() => _searchText = value),
              ),
            ),
            if (_searchText.isNotEmpty)
              IconButton(
                icon: Icon(Icons.cancel, size: VboxTypography.s16, color: secondary),
                tooltip: '清空',
                onPressed: () => setState(() => _searchText = ''),
              ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(VboxSpacing.rowVertical),
      child: Column(
        children: <Widget>[
          GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            children: <Widget>[
              for (final FuliCategory cat in _filtered) _gridItem(context, cat),
            ],
          ),
          if (_expandedTypeId != null) _subSection(context, scheme),
        ],
      ),
    );
  }

  Widget _gridItem(BuildContext context, FuliCategory category) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int index = _originalIndex(category);
    final bool hasSub = (category.subCategories?.isNotEmpty ?? false);
    final bool isSelected = widget.selectedIndex == index;
    final bool isExpanded = _expandedTypeId == category.typeId;
    final Color background = isSelected
        ? scheme.primary.withValues(alpha: 0.12)
        : isExpanded
            ? scheme.primary.withValues(alpha: 0.06)
            : _secondaryBg(context);
    return InkWell(
      borderRadius: BorderRadius.circular(VboxRadii.r10),
      onTap: () {
        if (hasSub) {
          setState(() =>
              _expandedTypeId = isExpanded ? null : category.typeId);
        } else {
          widget.onSelect(index);
          widget.onDismiss();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 4,
          vertical: VboxSpacing.md,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(VboxRadii.r10),
          border: Border.all(
            color: isSelected
                ? scheme.primary.withValues(alpha: 0.3)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              category.typeName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? scheme.primary : scheme.onSurface,
              ),
            ),
            if (hasSub) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                '${category.subCategories!.length}子类',
                style: TextStyle(
                  fontSize: VboxTypography.s10,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _subSection(BuildContext context, ColorScheme scheme) {
    final FuliCategory? parent = widget.categories
        .where((FuliCategory c) => c.typeId == _expandedTypeId)
        .firstOrNull;
    if (parent == null) return const SizedBox.shrink();
    final int parentIndex = _originalIndex(parent);
    return Padding(
      padding: const EdgeInsets.only(top: VboxSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${parent.typeName} · 二级分类',
            style: TextStyle(
              fontSize: VboxTypography.s13,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: VboxSpacing.sm),
          Wrap(
            spacing: VboxSpacing.sm,
            runSpacing: VboxSpacing.sm,
            children: <Widget>[
              for (final FuliCategory sub in parent.subCategories!)
                _subChip(
                  context,
                  sub,
                  onTap: () {
                    widget.onSelectSub(parentIndex, sub);
                    widget.onDismiss();
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _subChip(BuildContext context, FuliCategory sub, {required VoidCallback onTap}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(VboxRadii.r14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.md,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(VboxRadii.r14),
        ),
        child: Text(
          sub.typeName,
          style: TextStyle(fontSize: VboxTypography.s12, color: scheme.primary),
        ),
      ),
    );
  }

  Color _secondaryBg(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? VboxColors.secondarySystemBackgroundDark
        : VboxColors.secondarySystemBackgroundLight;
  }
}
