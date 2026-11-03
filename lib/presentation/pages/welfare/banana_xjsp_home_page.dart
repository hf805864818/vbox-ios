/// 表现层：香蕉秀 XJSP 原生专用页（UI-C1a）。
///
/// 唯一真相源：iOS `vbox/Views/WelfareSubViews.swift`
///   · `YBoxXjspMainView`（L16-L56）：「首页 / 短视频 / 演员」三段顶部 Tab
///     （文字 15，选中 bold + 主色 / 未选中 regular + secondary；下方 24×3 胶囊
///     指示条，内边距 top 8 / horizontal 8）+ 分割线 + `.page` 分页容器；
///   · `YBoxBananaHomeTab`（L60-L221）：分类横向滚动（13，选中 semibold + 主色，
///     h14 / v7，间距 8）+ 子分类行（12 主色）+ 分割线 + 2 列网格（列间距 10 /
///     行间距 14，内边距 12）+ 无限滚动（结果 ≥ 16 视为还有下一页）+
///     「已加载全部」；不可达 → `antenna…slash`(50) + 文案(15 medium) +「重试」；
///     分类为空 →「暂时无法连接服务器」；
///   · `YBoxBananaVideoGrid`（L225-L294）：子分类页（仅网格 + 分页）；
///   · `YBoxBananaShortVideoTab`（L298-L363）+ `YBoxBananaShortPlayerView`
///     （L367-L818）：短视频入口页 + 抖音式竖屏全屏播放器；
///   · `YBoxBananaActorTab`（L823-L910）：演员双列网格（封面高 120 + 右下「N部」
///     角标 + 名称 13 两行）；
///   · `YBoxBananaSpecialVideoList`（L913-L1002）：专题头部（封面 70×90 +
///     名称 18 bold + 「共 N 部作品」13）+ 2 列视频网格；
///   · `BananaVideoCard`（L1007-L1067）：封面高 88 + 圆角 10 + 底部渐变
///     （黑 0 → 黑 0.55）+ 左下标签胶囊（评分 · 地区 · 时长，10 bold，白字 /
///     黑 0.45 底，内边距 h8 / v4）+ 标题 12 medium 两行。
///
/// 播放接入对齐 iOS（`YBoxBananaPlayerView.loadPlayURL` → `VideoPlayerViewV2`）：
/// 点卡片 → [WelfareVideoBridgePage]（服务 `fetchDetail` → `fetchPlayerURL`
/// 现取 `reqplay` 地址 → 全屏播放页），与每日大乱斗 / 今日看料同口径。
///
/// 与 iOS 的差异（如实登记）：
///   · **短视频 Tab**：对齐 iOS 形态 —— 黑底入口页（「短视频」+「开始浏览」）→
///     push 全屏竖屏播放器 [BananaShortPlayerPage]（上下滑切换 / 预加载 /
///     失败自动跳过 / 只读进度条 + 倍速）；播放器自身与 iOS 的差异详见该文件头；
///   · iOS 顶部 Tab 用 `TabView(.page)`，Flutter 用 `PageView`（等价：可左右
///     滑动 + 指示条联动）；
///   · 无限滚动触发：iOS 按末 4 项 `onAppear`，Flutter 用滚动接近底部触发
///     （结果等价，避免列表构建期回调）；
///   · 子分类行仅在接口返回 `subcates` 时渲染（iOS 该接口恒回空，等价于不渲染）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/welfare/welfare.dart';
import '../../../domain/services/banana_xjsp_service.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import 'banana_short_player_page.dart';
import 'welfare_video_bridge_page.dart';

/// 香蕉秀 XJSP 原生专用页（首页 / 短视频 / 演员 三 Tab）。
class BananaXjspHomePage extends StatefulWidget {
  /// 构造（[service] 由路由按平台解析后注入）。
  const BananaXjspHomePage({super.key, required this.service});

  /// 香蕉秀服务。
  final BananaXjspFuliService service;

  @override
  State<BananaXjspHomePage> createState() => _BananaXjspHomePageState();
}

class _BananaXjspHomePageState extends State<BananaXjspHomePage> {
  static const List<String> _tabs = <String>['首页', '短视频', '演员'];

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
                _BananaHomeTab(service: widget.service),
                _BananaMiniTab(service: widget.service),
                _BananaActorTab(service: widget.service),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部三段 Tab（对齐 iOS：文字 15 + 24×3 指示条）。
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

// ─────────────── 首页 Tab：分类 → 视频网格 ───────────────

/// 首页 Tab（对齐 iOS `YBoxBananaHomeTab`）。
class _BananaHomeTab extends StatefulWidget {
  const _BananaHomeTab({required this.service});

  final BananaXjspFuliService service;

  @override
  State<_BananaHomeTab> createState() => _BananaHomeTabState();
}

class _BananaHomeTabState extends State<_BananaHomeTab> {
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
    // 探测后仍未就绪 → 候选域名均不可达（对齐 iOS 文案）。
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

  void _openSubCategory(FuliCategory sub) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => _BananaCategoryVideoPage(
          service: widget.service,
          cateId: sub.typeId,
          title: sub.typeName,
        ),
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
    final List<FuliCategory> subs =
        selected.subCategories ?? const <FuliCategory>[];
    return Column(
      children: <Widget>[
        _categoryTabs(context),
        if (subs.isNotEmpty) _subCategoryRow(context, subs),
        const Divider(height: 1),
        Expanded(
          child: _BananaPagedGrid(
            // 分类切换 → 重建网格（对齐 iOS 视图身份随分类变化重置 @State）。
            key: ValueKey<String>('banana-grid-${selected.typeId}'),
            loader: (int page) =>
                widget.service.fetchVideos(cateId: selected.typeId, page: page),
            pageSize: 16,
            emptyText: '暂无内容',
            onVideoTap: _openVideo,
          ),
        ),
      ],
    );
  }

  /// 错误态（对齐 iOS：`antenna…slash` 50 + 文案 15 medium +「重试」）。
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

  /// 子分类行（对齐 iOS：12 主色，间距 6，内边距 h12 / bottom 6）。
  Widget _subCategoryRow(BuildContext context, List<FuliCategory> subs) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(
        left: VboxSpacing.md,
        right: VboxSpacing.md,
        bottom: 6,
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < subs.length; i++)
            Padding(
              padding: EdgeInsets.only(
                left: i == 0 ? 0 : VboxSpacing.compact,
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(VboxRadii.r8),
                onTap: () => _openSubCategory(subs[i]),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: VboxSpacing.compact,
                    vertical: VboxSpacing.xs,
                  ),
                  child: Text(
                    subs[i].typeName,
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      color: scheme.primary,
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

// ─────────────── 短视频 Tab ───────────────

/// 短视频 Tab（对齐 iOS `YBoxBananaShortVideoTab`：黑底入口页 → 全屏竖屏播放器）。
class _BananaMiniTab extends StatefulWidget {
  const _BananaMiniTab({required this.service});

  final BananaXjspFuliService service;

  @override
  State<_BananaMiniTab> createState() => _BananaMiniTabState();
}

class _BananaMiniTabState extends State<_BananaMiniTab> {
  bool _isChecking = true;
  String? _apiError;

  @override
  void initState() {
    super.initState();
    _checkAPI();
  }

  /// 探测短视频 API 是否可用（对齐 iOS `checkAPI`：结果为空 → 错误态）。
  Future<void> _checkAPI() async {
    setState(() {
      _isChecking = true;
      _apiError = null;
    });
    final List<BananaMiniVideo> list =
        await widget.service.fetchMiniVideos(page: 1);
    if (!mounted) return;
    setState(() {
      _isChecking = false;
      if (list.isEmpty) _apiError = '暂无短视频数据';
    });
  }

  void _openPlayer() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (BuildContext context) =>
            BananaShortPlayerPage(service: widget.service),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Colors.black,
      child: _isChecking
          ? _loadingView()
          : (_apiError != null ? _errorView(scheme) : _entryView(scheme)),
    );
  }

  /// 加载中（对齐 iOS：白色转圈 + 「加载中...」）。
  Widget _loadingView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
          const SizedBox(height: VboxSpacing.lg),
          Text(
            '加载中...',
            // iOS 默认 body(~17) → 就近档位 s16。
            style: TextStyle(
              fontSize: VboxTypography.s16,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  /// 错误态（对齐 iOS：天线斜杠(50) + 文案 15 + 「重试」）。
  Widget _errorView(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(VboxSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.podcasts, size: 50, color: scheme.onSurfaceVariant),
            const SizedBox(height: VboxSpacing.lg),
            Text(
              _apiError!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: VboxTypography.s15,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: VboxSpacing.lg),
            TextButton.icon(
              onPressed: _checkAPI,
              icon: const Icon(Icons.refresh, size: VboxTypography.s16),
              label: const Text('重试', style: TextStyle(fontSize: VboxTypography.s14)),
            ),
          ],
        ),
      ),
    );
  }

  /// 入口（对齐 iOS：`play.rectangle.on.rectangle`(50) + 「短视频」(20 semibold)
  /// + 「开始浏览」按钮（`play.fill` + 16 medium，h40/v12，主色底，圆角 25））。
  Widget _entryView(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.play_circle_outline,
            size: 50,
            color: Colors.white.withValues(alpha: 0.6),
          ),
          const SizedBox(height: VboxSpacing.lg),
          const Text(
            '短视频',
            style: TextStyle(
              // iOS 20 semibold → 就近档位 s18。
              fontSize: VboxTypography.s18,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: VboxSpacing.xl),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openPlayer,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 40,
                vertical: VboxSpacing.md,
              ),
              decoration: BoxDecoration(
                color: scheme.primary,
                // iOS `cornerRadius(25)`（胶囊）→ 令牌 capsule。
                borderRadius: BorderRadius.circular(VboxRadii.capsule),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.play_arrow, size: 18, color: Colors.white),
                  SizedBox(width: VboxSpacing.sm),
                  Text(
                    '开始浏览',
                    style: TextStyle(
                      fontSize: VboxTypography.s16,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
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

// ─────────────── 演员 Tab ───────────────

/// 演员 Tab（对齐 iOS `YBoxBananaActorTab`）。
class _BananaActorTab extends StatefulWidget {
  const _BananaActorTab({required this.service});

  final BananaXjspFuliService service;

  @override
  State<_BananaActorTab> createState() => _BananaActorTabState();
}

class _BananaActorTabState extends State<_BananaActorTab> {
  List<BananaXjspSpecial> _actors = const <BananaXjspSpecial>[];
  bool _isLoading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadActors();
  }

  Future<void> _loadActors() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    final List<BananaXjspSpecial> actors =
        await widget.service.fetchActors(page: 1);
    if (!mounted) return;
    setState(() {
      _actors = actors;
      _isLoading = false;
      if (actors.isEmpty && !widget.service.isHostReady) {
        _loadError = '暂时无法连接服务器';
      }
    });
  }

  void _openSpecial(BananaXjspSpecial special) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => _BananaSpecialVideoPage(
          service: widget.service,
          special: special,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_isLoading && _actors.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_loadError != null && _actors.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(VboxSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.podcasts, size: 50, color: scheme.onSurfaceVariant),
              const SizedBox(height: VboxSpacing.md),
              Text(
                _loadError!,
                style: TextStyle(
                  fontSize: VboxTypography.s15,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: VboxSpacing.md),
              TextButton.icon(
                onPressed: _loadActors,
                icon: const Icon(Icons.refresh, size: VboxTypography.s16),
                label: const Text('重试', style: TextStyle(fontSize: 14)),
              ),
            ],
          ),
        ),
      );
    }
    if (_actors.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.people_outline, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: VboxSpacing.sm),
            Text(
              '暂无演员数据',
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
        crossAxisSpacing: VboxSpacing.md,
        mainAxisSpacing: VboxSpacing.rowVertical,
        // 封面 120 + 间距 6 + 名称 13 两行。
        mainAxisExtent: 168,
      ),
      itemCount: _actors.length,
      itemBuilder: (BuildContext context, int index) {
        final BananaXjspSpecial sp = _actors[index];
        return GestureDetector(
          onTap: () => _openSpecial(sp),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(VboxRadii.r12),
                child: SizedBox(
                  height: 120,
                  width: double.infinity,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      PlatformAsyncImage(url: sp.cover, fit: BoxFit.cover),
                      // 右下「N部」角标（对齐 iOS：10 白字 / 黑 0.5 底 / 圆角 4）。
                      if (sp.itemCount > 0)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(VboxRadii.r4),
                            ),
                            child: Text(
                              '${sp.itemCount}部',
                              style: const TextStyle(
                                fontSize: VboxTypography.s10,
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
                sp.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: VboxTypography.s13,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────── 子分类视频页 / 专题视频页 ───────────────

/// 子分类视频网格页（对齐 iOS `YBoxBananaVideoGrid`）。
class _BananaCategoryVideoPage extends StatelessWidget {
  const _BananaCategoryVideoPage({
    required this.service,
    required this.cateId,
    required this.title,
  });

  final BananaXjspFuliService service;
  final String cateId;
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title), centerTitle: true),
        body: _BananaPagedGrid(
          loader: (int page) => service.fetchVideos(cateId: cateId, page: page),
          pageSize: 16,
          emptyText: '暂无内容',
          onVideoTap: (FuliVideo video) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) =>
                  WelfareVideoBridgePage(service: service, video: video),
            ),
          ),
        ),
      );
}

/// 专题 / 演员视频列表页（对齐 iOS `YBoxBananaSpecialVideoList`）。
class _BananaSpecialVideoPage extends StatelessWidget {
  const _BananaSpecialVideoPage({
    required this.service,
    required this.special,
  });

  final BananaXjspFuliService service;
  final BananaXjspSpecial special;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(special.name), centerTitle: true),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 头信息（对齐 iOS：封面 70×90 + 名称 18 bold + 「共 N 部作品」13）。
          Padding(
            padding: const EdgeInsets.only(
              left: VboxSpacing.md,
              right: VboxSpacing.md,
              top: VboxSpacing.sm,
            ),
            child: Row(
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(VboxRadii.r10),
                  child: SizedBox(
                    width: 70,
                    height: 90,
                    child: PlatformAsyncImage(
                      url: special.cover,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(width: VboxSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        special.name,
                        style: TextStyle(
                          fontSize: VboxTypography.s18,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: VboxSpacing.xs),
                      Text(
                        '共 ${special.itemCount} 部作品',
                        style: TextStyle(
                          fontSize: VboxTypography.s13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: VboxSpacing.xl),
          Expanded(
            child: _BananaPagedGrid(
              loader: (int page) => service.fetchSpecialVideos(
                spId: special.spId,
                page: page,
              ),
              pageSize: 16,
              emptyText: '暂无相关视频',
              onVideoTap: (FuliVideo video) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) =>
                      WelfareVideoBridgePage(service: service, video: video),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────── 通用分页网格 + 视频卡片 ───────────────

/// 单页加载器（页号 → 该页视频列表）。
typedef _BananaPageLoader = Future<List<FuliVideo>> Function(int page);

/// 2 列分页视频网格（对齐 iOS `LazyVGrid` + 触底加载）。
///
/// `hasMore` 由「本页条数 ≥ [pageSize]」判定（对齐 iOS 各 Tab 的口径）。
class _BananaPagedGrid extends StatefulWidget {
  const _BananaPagedGrid({
    super.key,
    required this.loader,
    required this.pageSize,
    required this.onVideoTap,
    required this.emptyText,
  });

  final _BananaPageLoader loader;
  final int pageSize;
  final ValueChanged<FuliVideo> onVideoTap;
  final String emptyText;

  @override
  State<_BananaPagedGrid> createState() => _BananaPagedGridState();
}

class _BananaPagedGridState extends State<_BananaPagedGrid> {
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
    final List<FuliVideo> videos = await widget.loader(1);
    if (!mounted) return;
    setState(() {
      _videos = videos;
      _isLoading = false;
      _hasMore = videos.length >= widget.pageSize;
    });
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore || _isLoading) return;
    setState(() => _isLoadingMore = true);
    final int next = _currentPage + 1;
    final List<FuliVideo> videos = await widget.loader(next);
    if (!mounted) return;
    setState(() {
      if (videos.isNotEmpty) {
        _videos = <FuliVideo>[..._videos, ...videos];
        _currentPage = next;
        _hasMore = videos.length >= widget.pageSize;
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
          widget.emptyText,
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
                (BuildContext context, int index) => _BananaVideoCard(
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

  /// 2 列网格（列间距 10 / 行间距 14；卡高 = 封面 88 + 间距 6 + 两行标题 12）。
  SliverGridDelegate get _gridDelegate =>
      const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: VboxSpacing.rowVertical,
        mainAxisExtent: 130,
      );
}

/// 视频卡片（对齐 iOS `BananaVideoCard`）。
///
/// 底部标签 = 评分 · 地区 · 时长（有点拼点，无则不显示）。
class _BananaVideoCard extends StatelessWidget {
  const _BananaVideoCard({required this.video, required this.onTap});

  final FuliVideo video;
  final VoidCallback onTap;

  /// 左下标签文案（对齐 iOS `bottomLabel`）。
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
    final String label = _bottomLabel;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(VboxRadii.r10),
            child: SizedBox(
              height: 88,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  PlatformAsyncImage(url: video.vodPic, fit: BoxFit.cover),
                  // 底部渐变（对齐 iOS：黑 0 → 黑 0.55，自上而下）。
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
                  // 左下标签胶囊（对齐 iOS：10 bold，白字 / 黑 0.45 底）。
                  if (label.isNotEmpty)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius:
                              BorderRadius.circular(VboxRadii.capsule),
                        ),
                        child: Text(
                          label,
                          style: const TextStyle(
                            fontSize: VboxTypography.s10,
                            fontWeight: FontWeight.w700,
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
