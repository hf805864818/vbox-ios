/// 表现层：今日看料原生专用页（UI-C1e）。
///
/// 唯一真相源：iOS `vbox/Views/KanliaoHomeView.swift`
///   · `KanliaoHomeView`（L5-L70）：进入即 `fetchCategories()`；加载中白进度圈 /
///     分类为空 → `antenna...slash`（40）+「暂无可用分类」（15, secondary）；
///     有分类 → 横向分类 Tab + 分割线 + 视频网格；
///   · `categoryTabs`（L48-L63）：横向滚动 + 文字按钮（13，选中 semibold + 主色，
///     未选中 regular + secondary；内边距 h14 / v7）；
///   · `KanliaoVideoGrid`（L74-L141）：2 列 `LazyVGrid`（列间距 10 / 行间距 14，
///     内边距 12）+ 无限滚动（末 4 项触发 `loadMore`）+ 「已加载全部」（12）；
///   · `KanliaoVideoCard`（L145-L186）：封面固定高 88 + 底部渐变（0 → 0.55）+
///     右下 `play.circle.fill`（18，白 0.85）+ 标题（12 medium，两行）。
///
/// 播放接入对齐 iOS `KanliaoPlayerView.loadPlayURL` → `VideoPlayerViewV2`：
/// 点击卡片 → [WelfareVideoBridgePage]（先经服务 `fetchDetail` 解析播放地址，
/// 再进入全屏播放页），与 `FuliPlatformMainView.videoCard` 同口径。
///
/// 与 iOS 的差异（如实登记）：
///   · iOS `KanliaoHomeView` 无分类二级 / 搜索 Tab（Flutter 亦保持同布局）；
///   · 无限滚动触发：iOS 按末 4 项 `onAppear`，Flutter 用滚动接近底部触发
///     （结果等价，避免列表构建期回调）；
///   · 封面占位：iOS `AsyncImage` 的 `play.rectangle.fill` 占位由
///     [PlatformAsyncImage] 统一兜底（含防盗链 Referer / SSL 绕过）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/welfare/welfare.dart';
import '../../../domain/services/fuli_base_service.dart';
import '../../../domain/services/kanliao_service.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import 'welfare_video_bridge_page.dart';

/// 今日看料原生专用页（分类横向 Tab + 2 列视频网格）。
class KanliaoHomePage extends StatefulWidget {
  /// 构造（[service] 供测试注入替身；缺省取共享实例）。
  const KanliaoHomePage({super.key, this.service});

  /// 今日看料服务。
  final KanliaoFuliService? service;

  @override
  State<KanliaoHomePage> createState() => _KanliaoHomePageState();
}

class _KanliaoHomePageState extends State<KanliaoHomePage> {
  late final KanliaoFuliService _service =
      widget.service ?? KanliaoFuliService.serviceFor();

  List<FuliCategory> _categories = <FuliCategory>[];
  int _selectedIdx = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // 对齐 iOS `onAppear { loadCategories() }`。
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final List<FuliCategory> result = await _service.fetchCategories();
    if (!mounted) return;
    setState(() {
      _categories = result;
      _isLoading = false;
      _selectedIdx = 0;
    });
  }

  void _openVideo(FuliVideo video) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            WelfareVideoBridgePage(service: _service, video: video),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('今日看料'), centerTitle: true),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_categories.isEmpty) {
      return _emptyState(context);
    }
    final FuliCategory selected = _categories[_selectedIdx];
    return Column(
      children: <Widget>[
        _categoryTabs(context),
        const Divider(height: 1),
        Expanded(
          child: _KanliaoVideoGrid(
            // 分类切换 → 重建网格（对齐 iOS 视图身份随 `cid` 变化重置 `@State`）。
            key: ValueKey<String>('kanliao-grid-${selected.typeId}'),
            service: _service,
            category: selected,
            onVideoTap: _openVideo,
          ),
        ),
      ],
    );
  }

  /// 空态（对齐 iOS：`antenna...slash` 40 + 「暂无可用分类」15, secondary）。
  Widget _emptyState(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.podcasts, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: VboxSpacing.md),
          Text(
            '暂无可用分类',
            style: TextStyle(
              fontSize: VboxTypography.s15,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 横向分类 Tab（对齐 iOS `categoryTabs`）。
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
                onTap: () => setState(() => _selectedIdx = i),
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

/// 2 列视频网格（对齐 iOS `KanliaoVideoGrid`）。
class _KanliaoVideoGrid extends StatefulWidget {
  const _KanliaoVideoGrid({
    super.key,
    required this.service,
    required this.category,
    required this.onVideoTap,
  });

  final FuliBaseService service;
  final FuliCategory category;
  final ValueChanged<FuliVideo> onVideoTap;

  @override
  State<_KanliaoVideoGrid> createState() => _KanliaoVideoGridState();
}

class _KanliaoVideoGridState extends State<_KanliaoVideoGrid> {
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
                (BuildContext context, int index) => _KanliaoVideoCard(
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

  /// 2 列网格（列间距 10 / 行间距 14；卡高 = 封面 88 + 间距 6 + 两行标题）。
  SliverGridDelegate get _gridDelegate =>
      const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: VboxSpacing.rowVertical,
        mainAxisExtent: 128,
      );
}

/// 视频卡片（对齐 iOS `KanliaoVideoCard`）。
class _KanliaoVideoCard extends StatelessWidget {
  const _KanliaoVideoCard({required this.video, required this.onTap});

  final FuliVideo video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
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
                  PlatformAsyncImage(
                    url: video.vodPic,
                    fit: BoxFit.cover,
                  ),
                  // 底部渐变（对齐 iOS 0 → 0.55）。
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
                  Positioned(
                    right: VboxSpacing.compact,
                    bottom: VboxSpacing.compact,
                    child: Icon(
                      Icons.play_circle_fill,
                      size: VboxTypography.s18,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: VboxSpacing.compact),
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