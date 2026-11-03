/// One 平台（YBox）首页（批次 G · G-05）。
///
/// 对齐 iOS `OnePlatformHomeView`：顶部 Tab（发现 / 每日推荐 / 专辑）+
/// 横向 `PageView` 内容切换 + 右上角设置入口。进入页面后台自动注册
/// （游客模式，不阻塞界面，对齐 iOS `onAppear`）。
///
/// 数据由 [OnePlatformController] 提供；播放回调 [OnePlayHandler] 供测试注入，
/// 缺省走 [PlayerController.instance]（见 [OnePlatformVideoDetailPage]）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/entities/one_platform/one_platform.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import 'one_platform_album_detail_page.dart';
import 'one_platform_controller.dart';
import 'one_platform_settings_page.dart';
import 'one_platform_video_detail_page.dart';
import 'one_platform_widgets.dart';

/// One 平台首页（三 Tab：发现 / 每日推荐 / 专辑）。
class OnePlatformHomePage extends StatefulWidget {
  /// 构造（[controller] 供测试注入；缺省自建并自管生命周期）。
  const OnePlatformHomePage({super.key, this.controller, this.onPlay});

  /// 外部注入的控制器（null → 页面自建）。
  final OnePlatformController? controller;

  /// 播放回调（null → [OnePlatformVideoDetailPage] 内默认接入播放器）。
  final OnePlayHandler? onPlay;

  @override
  State<OnePlatformHomePage> createState() => _OnePlatformHomePageState();
}

class _OnePlatformHomePageState extends State<OnePlatformHomePage> {
  /// 顶部 Tab（对齐 iOS `tabs`）。
  static const List<String> tabs = <String>['发现', '每日推荐', '专辑'];

  late final OnePlatformController _controller;
  late final bool _ownsController;
  final PageController _pageController = PageController();
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? OnePlatformController();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _pageController.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (_ownsController) await _controller.init();
    // 进入页面后台注册（对齐 iOS onAppear：不阻塞界面）。
    if (!_controller.isRegistered) {
      unawaited(_controller.ensureRegistered());
    }
  }

  void _selectTab(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext context) =>
          OnePlatformSettingsPage(controller: _controller),
    ));
  }

  void _openVideo(OneVideoItem video) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext context) => OnePlatformVideoDetailPage(
        video: video,
        controller: _controller,
        onPlay: widget.onPlay,
      ),
    ));
  }

  void _openAlbum(OneAlbum album) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext context) => OnePlatformAlbumDetailPage(
        album: album,
        controller: _controller,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('One 平台'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _OneTabBar(
            tabs: tabs,
            selectedIndex: _selectedTab,
            onTap: _selectTab,
          ),
          const Divider(height: 1),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: tabs.length,
              onPageChanged: (int i) => setState(() => _selectedTab = i),
              itemBuilder: (BuildContext context, int index) {
                switch (index) {
                  case 0:
                    return _DiscoveryTab(
                        controller: _controller, onOpenVideo: _openVideo);
                  case 1:
                    return _DailyTab(
                        controller: _controller, onOpenVideo: _openVideo);
                  default:
                    return _AlbumTab(
                        controller: _controller, onOpenAlbum: _openAlbum);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部 Tab 条（对齐 iOS 顶部按钮组：选中加粗 + 主色下划线胶囊）。
class _OneTabBar extends StatelessWidget {
  const _OneTabBar({
    required this.tabs,
    required this.selectedIndex,
    required this.onTap,
  });

  final List<String> tabs;
  final int selectedIndex;
  final void Function(int index) onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.xs),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < tabs.length; i++)
            Expanded(
              child: InkWell(
                onTap: () => onTap(i),
                child: Padding(
                  padding: const EdgeInsets.only(top: VboxSpacing.sm),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        tabs[i],
                        style: TextStyle(
                          fontSize: VboxTypography.s15,
                          fontWeight: selectedIndex == i
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: selectedIndex == i
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: VboxSpacing.sm),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: VboxTypography.s24,
                        height: 3,
                        decoration: BoxDecoration(
                          color: selectedIndex == i
                              ? scheme.primary
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(VboxRadii.r4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 发现 Tab（分类横滚 + 视频网格 + 加载更多）。
class _DiscoveryTab extends StatefulWidget {
  const _DiscoveryTab({required this.controller, required this.onOpenVideo});

  final OnePlatformController controller;
  final void Function(OneVideoItem video) onOpenVideo;

  @override
  State<_DiscoveryTab> createState() => _DiscoveryTabState();
}

class _DiscoveryTabState extends State<_DiscoveryTab> {
  List<OneCategory> _categories = const <OneCategory>[];
  int _selectedCateIdx = 0;
  List<OneVideoItem> _videos = const <OneVideoItem>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final List<OneCategory> cats = await widget.controller.fetchCategories();
    if (!mounted) return;
    setState(() {
      _categories = cats;
      _loading = false;
    });
    if (cats.isNotEmpty) await _refreshVideos();
  }

  Future<void> _refreshVideos() async {
    if (_selectedCateIdx >= _categories.length) return;
    final String cateId = _categories[_selectedCateIdx].cateId;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _hasMore = true;
      _page = 1;
      _videos = const <OneVideoItem>[];
      _error = null;
    });
    final OneVideoPage result =
        await widget.controller.fetchVideos(categoryId: cateId, page: 1);
    if (!mounted) return;
    setState(() {
      _videos = result.items;
      _hasMore = result.hasMore;
      _page = 1;
      _loading = false;
      if (result.items.isEmpty) _error = '暂无视频数据';
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    if (_selectedCateIdx >= _categories.length) return;
    setState(() => _loadingMore = true);
    final String cateId = _categories[_selectedCateIdx].cateId;
    final OneVideoPage result =
        await widget.controller.fetchVideos(categoryId: cateId, page: _page + 1);
    if (!mounted) return;
    setState(() {
      if (result.items.isNotEmpty) {
        _videos = <OneVideoItem>[..._videos, ...result.items];
        _page += 1;
        _hasMore = result.hasMore;
      } else {
        _hasMore = false;
      }
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_categories.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _videos.isEmpty) {
      return OneErrorRetry(
        message: _error!,
        icon: Icons.wifi_tethering_off,
        onRetry: _refreshVideos,
        hint: widget.controller.isKeyFound ? null : '提示：正在自动探测加密密钥，请稍候...',
      );
    }
    return Column(
      children: <Widget>[
        OneCategoryChips(
          categories: _categories,
          selectedIndex: _selectedCateIdx,
          onTap: (int index) {
            setState(() => _selectedCateIdx = index);
            _refreshVideos();
          },
        ),
        const Divider(height: 1),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (ScrollNotification n) {
              if (n.metrics.extentAfter < 300) _loadMore();
              return false;
            },
            child: OneVideoGrid(
              videos: _videos,
              imageResolver: widget.controller.imageURL,
              showFooter: _loadingMore,
              onOpenVideo: widget.onOpenVideo,
            ),
          ),
        ),
      ],
    );
  }
}

/// 每日推荐 Tab（2 列视频网格）。
class _DailyTab extends StatefulWidget {
  const _DailyTab({required this.controller, required this.onOpenVideo});

  final OnePlatformController controller;
  final void Function(OneVideoItem video) onOpenVideo;

  @override
  State<_DailyTab> createState() => _DailyTabState();
}

class _DailyTabState extends State<_DailyTab> {
  List<OneVideoItem> _videos = const <OneVideoItem>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final List<OneVideoItem> result =
        await widget.controller.fetchDailyRecommend();
    if (!mounted) return;
    setState(() {
      _videos = result;
      _loading = false;
      if (result.isEmpty) _error = '今日暂无推荐';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _videos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _videos.isEmpty) {
      return OneErrorRetry(
        message: _error!,
        icon: Icons.calendar_month_outlined,
        onRetry: _load,
      );
    }
    return OneVideoGrid(
      videos: _videos,
      imageResolver: widget.controller.imageURL,
      onOpenVideo: widget.onOpenVideo,
    );
  }
}

/// 专辑 Tab（3 列专辑网格 + 分页加载）。
class _AlbumTab extends StatefulWidget {
  const _AlbumTab({required this.controller, required this.onOpenAlbum});

  final OnePlatformController controller;
  final void Function(OneAlbum album) onOpenAlbum;

  @override
  State<_AlbumTab> createState() => _AlbumTabState();
}

class _AlbumTabState extends State<_AlbumTab> {
  List<OneAlbum> _albums = const <OneAlbum>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadingMore = false;
    });
    final List<OneAlbum> result = await widget.controller.fetchAlbums(page: 1);
    if (!mounted) return;
    setState(() {
      _albums = result;
      _page = 1;
      _hasMore = result.length >= 20;
      _loading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    final List<OneAlbum> result =
        await widget.controller.fetchAlbums(page: _page + 1);
    if (!mounted) return;
    setState(() {
      if (result.isNotEmpty) {
        _albums = <OneAlbum>[..._albums, ...result];
        _page += 1;
      } else {
        _hasMore = false;
      }
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _albums.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_albums.isEmpty) {
      return const OneEmptyHint(text: '暂无专辑');
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification n) {
        if (n.metrics.extentAfter < 300) _loadMore();
        return false;
      },
      child: OneAlbumGrid(
        albums: _albums,
        imageResolver: widget.controller.imageURL,
        showFooter: _loadingMore && _hasMore,
        onOpenAlbum: widget.onOpenAlbum,
      ),
    );
  }
}