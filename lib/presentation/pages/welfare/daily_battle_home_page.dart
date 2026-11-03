/// 表现层：每日大乱斗 / 每日大赛原生专用页（UI-C1b）。
///
/// 唯一真相源：iOS `vbox/Views/DailyBattleMainView.swift`
///   · `DailyBattleMainView`（L6-L62）：「首页 / 搜索」两段顶部 Tab（文字 15，
///     选中 bold + 主色，未选中 regular + secondary；下方 24×3 胶囊指示条，
///     选中主色 / 未选中透明；内边距 top 8 / horizontal 8）+ 分割线 + 分页容器
///     （`.page` 样式，可左右滑动）；进入即 `probeHost`（未就绪时）。
///   · `DailyBattleHomeTab`（L66-L233）：分类横向滚动（13，选中 semibold + 主色，
///     h14 / v7，间距 8，内边距 h12 / v8）+ 分割线 + 2 列视频网格（列间距 10 /
///     行间距 14，内边距 12）+ 无限滚动（末 4 项触发 `loadMore`；结果数 ≥ 10
///     视为还有下一页）+「已加载全部」（12）；不可达 → `antenna...slash`（50）+
///     错误文案（15 medium）+「重试」；分类为空 →「暂时无法连接服务器」。
///   · `DailyBattleSearchTab`（L275-L364）：搜索框（占位「搜索<站点名>...」）+
///     搜索按钮；搜索中进度圈；无结果 → `magnifyingglass`（40）+「未找到相关内容」。
///   · `DailyBattleVideoCard`（L237-L271）：封面固定高 88 + 圆角 8 + 右下时长
///     标签（10 medium，白字 / 黑 0.7 底 / 圆角 4，内边距 4）+ 标题（13，两行）。
///
/// 播放接入对齐 iOS `DailyBattlePlayerView.loadPlayURL` → `VideoPlayerViewV2`：
/// 点击卡片 → [WelfareVideoBridgePage]（经服务 `fetchDetail` 解析播放地址，
/// 再进入全屏播放页），与 `FuliPlatformMainView.videoCard` 同口径。
///
/// 与 iOS 的差异（如实登记）：
///   · iOS 顶部 Tab 用 `TabView(.page)`，Flutter 用 `PageView`（等价可滑动 +
///     指示条联动）；
///   · 无限滚动触发：iOS 按末 4 项 `onAppear`，Flutter 用滚动接近底部触发
///     （结果等价，避免列表构建期回调）；
///   · 封面 AES 解密：iOS 走 `PlatformImageLoader` 的 `dailyBattle` 模式；
///     Flutter 用 [PlatformAsyncImage.imageDecoder] +
///     [decodeDailyBattleImageBytes]（同一密钥对与回退顺序）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/welfare/welfare.dart';
import '../../../domain/services/daily_battle_service.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import 'welfare_video_bridge_page.dart';

/// 每日大乱斗 / 每日大赛原生专用页（首页 / 搜索 双 Tab）。
class DailyBattleHomePage extends StatefulWidget {
  /// 构造（[service] 由路由按平台解析后注入）。
  const DailyBattleHomePage({super.key, required this.service});

  /// 每日大乱斗 / 每日大赛服务。
  final DailyBattleFuliService service;

  @override
  State<DailyBattleHomePage> createState() => _DailyBattleHomePageState();
}

class _DailyBattleHomePageState extends State<DailyBattleHomePage> {
  static const List<String> _tabs = <String>['首页', '搜索'];

  final PageController _pageController = PageController();
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // 对齐 iOS `onAppear { if !svc.isReady { await svc.probeHost() } }`。
    if (!widget.service.isHostReady) {
      widget.service.ensureHostReady();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _selectTab(int index) {
    if (_tab == index) return;
    setState(() => _tab = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.service.siteName), centerTitle: true),
      body: Column(
        children: <Widget>[
          _topTabs(context),
          const Divider(height: 1),
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (int index) => setState(() => _tab = index),
              children: <Widget>[
                _DailyBattleHomeTab(service: widget.service),
                _DailyBattleSearchTab(service: widget.service),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部两段 Tab（对齐 iOS：文字 15 + 24×3 指示条）。
  Widget _topTabs(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(
        top: VboxSpacing.sm,
        left: VboxSpacing.sm,
        right: VboxSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < _tabs.length; i++)
            Expanded(
              child: InkWell(
                onTap: () => _selectTab(i),
                child: Column(
                  children: <Widget>[
                    Text(
                      _tabs[i],
                      style: TextStyle(
                        fontSize: VboxTypography.s15,
                        fontWeight:
                            _tab == i ? FontWeight.w700 : FontWeight.w400,
                        color: _tab == i
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: 24,
                      height: 3,
                      decoration: BoxDecoration(
                        color: _tab == i
                            ? scheme.primary
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(VboxRadii.r4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 首页 Tab：分类 → 视频网格（对齐 iOS `DailyBattleHomeTab`）。
class _DailyBattleHomeTab extends StatefulWidget {
  const _DailyBattleHomeTab({required this.service});

  final DailyBattleFuliService service;

  @override
  State<_DailyBattleHomeTab> createState() => _DailyBattleHomeTabState();
}

class _DailyBattleHomeTabState extends State<_DailyBattleHomeTab> {
  List<FuliCategory> _categories = const <FuliCategory>[];
  int _selectedIdx = 0;
  bool _isLoading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    if (!widget.service.isHostReady) {
      await widget.service.ensureHostReady();
    }
    if (!mounted) return;
    // 探测后仍未就绪 → 所有域名不可达（对齐 iOS 同文案）。
    if (!widget.service.isHostReady) {
      setState(() {
        _isLoading = false;
        _loadError = '未能连接到服务器，请检查域名或网络';
      });
      return;
    }
    final FuliHomeResult result = await widget.service.fetchHomeContent();
    if (!mounted) return;
    setState(() {
      _categories = result.categories;
      _selectedIdx = 0;
      _isLoading = false;
      _loadError = result.categories.isEmpty ? '暂时无法连接服务器' : null;
    });
  }

  void _retry() {
    setState(() {
      _loadError = null;
      _isLoading = true;
    });
    // 错误态仅在「域名未就绪 / 分类为空」时出现；`ensureHostReady` 会重新探测。
    _loadCategories();
  }

  void _openVideo(FuliVideo video) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            WelfareVideoBridgePage(service: widget.service, video: video),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_loadError != null) {
      return _errorState(context, _loadError!);
    }
    final FuliCategory selected = _categories[_selectedIdx];
    return Column(
      children: <Widget>[
        _categoryTabs(context),
        const Divider(height: 1),
        Expanded(
          child: _DailyBattleVideoGrid(
            // 分类切换 → 重建网格（对齐 iOS 视图身份随分类变化重置 @State）。
            key: ValueKey<String>('daily-battle-grid-${selected.typeId}'),
            service: widget.service,
            category: selected,
            onVideoTap: _openVideo,
          ),
        ),
      ],
    );
  }

  /// 错误态（对齐 iOS：`antenna...slash` 50 + 文案 15 medium +「重试」）。
  Widget _errorState(BuildContext context, String message) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(VboxSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.podcasts, size: 50, color: scheme.onSurfaceVariant),
            const SizedBox(height: VboxSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: VboxTypography.s15,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: VboxSpacing.md),
            TextButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh, size: VboxTypography.s16),
              label: const Text('重试', style: TextStyle(fontSize: 14)),
            ),
          ],
        ),
      ),
    );
  }

  /// 横向分类 Tab（对齐 iOS：13，选中 semibold + 主色，h14 / v7）。
  Widget _categoryTabs(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.md,
        vertical: VboxSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < _categories.length; i++)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : VboxSpacing.sm),
              child: InkWell(
                borderRadius: BorderRadius.circular(VboxRadii.r8),
                onTap: () {
                  if (_selectedIdx == i) return;
                  setState(() => _selectedIdx = i);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: VboxSpacing.rowVertical,
                    vertical: 7,
                  ),
                  child: Text(
                    _categories[i].typeName,
                    style: TextStyle(
                      fontSize: VboxTypography.s13,
                      fontWeight: _selectedIdx == i
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: _selectedIdx == i
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
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

/// 2 列视频网格（对齐 iOS `DailyBattleHomeTab` 的 `LazyVGrid` + 无限滚动）。
class _DailyBattleVideoGrid extends StatefulWidget {
  const _DailyBattleVideoGrid({
    super.key,
    required this.service,
    required this.category,
    required this.onVideoTap,
  });

  final DailyBattleFuliService service;
  final FuliCategory category;
  final ValueChanged<FuliVideo> onVideoTap;

  @override
  State<_DailyBattleVideoGrid> createState() => _DailyBattleVideoGridState();
}

class _DailyBattleVideoGridState extends State<_DailyBattleVideoGrid> {
  List<FuliVideo> _videos = <FuliVideo>[];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  int _currentPage = 1;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _loadFirstPage();
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _isLoading = true;
      _currentPage = 1;
      _hasMore = true;
    });
    final FuliCategoryResult result = await widget.service.fetchCategoryContent(
      category: widget.category,
      page: 1,
    );
    if (!mounted) return;
    setState(() {
      _videos = result.videos;
      _isLoading = false;
      _hasMore = result.hasMore && result.videos.isNotEmpty;
    });
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore || _isLoading) return;
    setState(() => _isLoadingMore = true);
    final int next = _currentPage + 1;
    final FuliCategoryResult result = await widget.service.fetchCategoryContent(
      category: widget.category,
      page: next,
    );
    if (!mounted) return;
    setState(() {
      if (result.videos.isNotEmpty) {
        _videos = <FuliVideo>[..._videos, ...result.videos];
        _currentPage = next;
        _hasMore = result.hasMore;
      } else {
        _hasMore = false;
      }
      _isLoadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_videos.isEmpty && _isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_videos.isEmpty) {
      return Center(
        child: Text(
          '暂无内容',
          style: TextStyle(
            fontSize: VboxTypography.s15,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        // 接近底部 → 加载更多（对齐 iOS 末 4 项 `onAppear` 触发）。
        if (notification.metrics.pixels >=
            notification.metrics.maxScrollExtent - 200) {
          _loadMore();
        }
        return false;
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: <Widget>[
          SliverPadding(
            padding: const EdgeInsets.all(VboxSpacing.md),
            sliver: SliverGrid(
              gridDelegate: _gridDelegate,
              delegate: SliverChildBuilderDelegate(
                (BuildContext context, int index) => _DailyBattleVideoCard(
                  video: _videos[index],
                  onTap: () => widget.onVideoTap(_videos[index]),
                ),
                childCount: _videos.length,
              ),
            ),
          ),
          if (_isLoadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(VboxSpacing.md),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              ),
            ),
          if (!_hasMore && _videos.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: VboxSpacing.xl),
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

  /// 2 列网格（列间距 10 / 行间距 14；卡高 = 封面 88 + 间距 6 + 两行标题 13）。
  SliverGridDelegate get _gridDelegate =>
      const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: VboxSpacing.rowVertical,
        mainAxisExtent: 132,
      );
}

/// 搜索 Tab（对齐 iOS `DailyBattleSearchTab`）。
class _DailyBattleSearchTab extends StatefulWidget {
  const _DailyBattleSearchTab({required this.service});

  final DailyBattleFuliService service;

  @override
  State<_DailyBattleSearchTab> createState() => _DailyBattleSearchTabState();
}

class _DailyBattleSearchTabState extends State<_DailyBattleSearchTab> {
  final TextEditingController _controller = TextEditingController();

  List<FuliVideo> _results = <FuliVideo>[];
  bool _isSearching = false;
  bool _searched = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _performSearch() async {
    final String keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    setState(() {
      _isSearching = true;
      _searched = false;
    });
    final FuliSearchResult result =
        await widget.service.fetchSearch(keyword: keyword, page: 1);
    if (!mounted) return;
    setState(() {
      _results = result.videos;
      _isSearching = false;
      _searched = true;
    });
  }

  void _openVideo(FuliVideo video) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            WelfareVideoBridgePage(service: widget.service, video: video),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VboxSpacing.md,
            vertical: VboxSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _performSearch(),
                  decoration: InputDecoration(
                    hintText: '搜索${widget.service.siteName}...',
                    isDense: true,
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(VboxRadii.r10),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.all(VboxSpacing.md),
                  ),
                ),
              ),
              const SizedBox(width: VboxSpacing.sm),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (BuildContext context, TextEditingValue value, _) {
                  final bool enabled = value.text.trim().isNotEmpty;
                  return IconButton(
                    onPressed: enabled ? _performSearch : null,
                    icon: const Icon(Icons.search),
                    style: IconButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      padding: const EdgeInsets.all(VboxSpacing.md),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(VboxRadii.r10),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _searchBody(context)),
      ],
    );
  }

  Widget _searchBody(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_isSearching) {
      return const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_results.isEmpty && _searched) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.search, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: VboxSpacing.sm),
            Text(
              '未找到相关内容',
              style: TextStyle(
                fontSize: VboxTypography.s15,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(VboxSpacing.md),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: VboxSpacing.rowVertical,
        mainAxisExtent: 132,
      ),
      itemCount: _results.length,
      itemBuilder: (BuildContext context, int index) => _DailyBattleVideoCard(
        video: _results[index],
        onTap: () => _openVideo(_results[index]),
      ),
    );
  }
}

/// 视频卡片（对齐 iOS `DailyBattleVideoCard`）。
class _DailyBattleVideoCard extends StatelessWidget {
  const _DailyBattleVideoCard({required this.video, required this.onTap});

  final FuliVideo video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String remarks = video.vodRemarks ?? '';
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(VboxRadii.r8),
            child: SizedBox(
              height: 88,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  PlatformAsyncImage(
                    url: video.vodPic,
                    fit: BoxFit.cover,
                    // 每日大乱斗 / 每日大赛封面对齐 iOS `dailyBattle` 模式：
                    // AES 加密字节先解密（已是图片则原样）。
                    imageDecoder: decodeDailyBattleImageBytes,
                  ),
                  // 右下时长标签（对齐 iOS：10 medium，白字 / 黑 0.7 底 / 圆角 4）。
                  if (remarks.isNotEmpty)
                    Positioned(
                      right: VboxSpacing.xs,
                      bottom: VboxSpacing.xs,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(VboxRadii.r4),
                        ),
                        child: Text(
                          remarks,
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
          const SizedBox(height: 6),
          Text(
            video.vodName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}