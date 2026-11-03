/// 麻豆平台（MDTV）首页（批次 E · E-05）。
///
/// 对齐 iOS `MDTVHomeView`：顶部动态 Tab（推荐/分类/标签 + 远程下发的未知 Tab）
/// + 横向 `PageView` 内容切换 + 右上角设置入口。进入页面后台刷新远程 Tab 配置，
/// 并触发一次分类拉取以探测加密密钥（对齐 iOS `onAppear`）。
///
/// 数据由 [MdtvController] 提供；播放回调 [MdtvPlayHandler] 供测试注入，
/// 缺省走 [PlayerController.instance]（见 [MdtvVideoDetailPage]）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/entities/mdtv/mdtv.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import 'mdtv_controller.dart';
import 'mdtv_settings_page.dart';
import 'mdtv_video_detail_page.dart';
import 'mdtv_video_list_page.dart';
import 'mdtv_widgets.dart';

/// 麻豆平台首页（动态 Tab + 内容页）。
class MdtvHomePage extends StatefulWidget {
  /// 构造（[controller] 供测试注入；缺省自建并自管生命周期）。
  const MdtvHomePage({super.key, this.controller, this.onPlay});

  /// 外部注入的控制器（null → 页面自建）。
  final MdtvController? controller;

  /// 播放回调（null → [MdtvVideoDetailPage] 内默认接入播放器）。
  final MdtvPlayHandler? onPlay;

  @override
  State<MdtvHomePage> createState() => _MdtvHomePageState();
}

class _MdtvHomePageState extends State<MdtvHomePage> {
  late final MdtvController _controller;
  late final bool _ownsController;
  final PageController _pageController = PageController();
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? MdtvController();
    _bootstrap();
  }

  @override
  void dispose() {
    _pageController.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (_ownsController) await _controller.init();
    // 后台刷新远程 Tab 配置 + 触发密钥探测（对齐 iOS onAppear）。
    unawaited(_refreshRemote());
  }

  Future<void> _refreshRemote() async {
    await _controller.fetchTabConfig();
    if (!_controller.isKeyFound) {
      try {
        await _controller.fetchCategories();
      } catch (_) {
        // 密钥探测失败静默：由各内容页错误态提示重试。
      }
    }
  }

  void _selectTab(int index) {
    if (_controller.homeTabs.length <= index) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext context) => MdtvSettingsPage(controller: _controller),
    ));
  }

  void _openVideo(MdtvVideoItem video) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext context) => MdtvVideoDetailPage(
        video: video,
        controller: _controller,
        onPlay: widget.onPlay,
      ),
    ));
  }

  void _openCategory(MdtvCategory category) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext context) => MdtvVideoListPage(
        category: category,
        controller: _controller,
        onPlay: widget.onPlay,
      ),
    ));
  }

  void _openTag(MdtvTag tag) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext context) => MdtvVideoListPage(
        tag: tag,
        controller: _controller,
        onPlay: widget.onPlay,
      ),
    ));
  }

  Widget _tabContent(int index) {
    final List<String> tabs = _controller.homeTabs;
    if (index >= tabs.length) return const SizedBox.shrink();
    switch (tabs[index]) {
      case '推荐':
        return _RecommendTab(controller: _controller, onOpenVideo: _openVideo);
      case '分类':
        return _CategoryTab(
            controller: _controller, onOpenCategory: _openCategory);
      case '标签':
        return _TagTab(controller: _controller, onOpenTag: _openTag);
      default:
        return _CustomTab(tabName: tabs[index]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('麻豆平台'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (BuildContext context, Widget? _) {
          final List<String> tabs = _controller.homeTabs;
          return Column(
            children: <Widget>[
              _TabBar(
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
                  itemBuilder: (BuildContext context, int index) =>
                      _tabContent(index),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 顶部 Tab 条（对齐 iOS 顶部按钮组：选中加粗 + 主色下划线胶囊）。
class _TabBar extends StatelessWidget {
  const _TabBar({
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

/// 推荐 Tab（视频网格 + 骨架加载 + 加载更多）。
class _RecommendTab extends StatefulWidget {
  const _RecommendTab({required this.controller, required this.onOpenVideo});

  final MdtvController controller;
  final void Function(MdtvVideoItem video) onOpenVideo;

  @override
  State<_RecommendTab> createState() => _RecommendTabState();
}

class _RecommendTabState extends State<_RecommendTab> {
  List<MdtvVideoItem> _videos = const <MdtvVideoItem>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<MdtvVideoItem> result =
          await widget.controller.fetchVideos(page: 1);
      if (!mounted) return;
      setState(() {
        _videos = result;
        _page = 1;
        _hasMore = result.isNotEmpty;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final List<MdtvVideoItem> result =
          await widget.controller.fetchVideos(page: _page + 1);
      if (!mounted) return;
      setState(() {
        if (result.isEmpty) {
          _hasMore = false;
        } else {
          _videos = <MdtvVideoItem>[..._videos, ...result];
          _page += 1;
        }
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _videos.isEmpty) {
      return MdtvVideoGrid(
        videos: _placeholderVideos(),
        imageResolver: widget.controller.imageURL,
        placeholder: true,
      );
    }
    if (_error != null && _videos.isEmpty) {
      return MdtvErrorRetry(
        message: _error!,
        onRetry: _refresh,
        hint: widget.controller.isKeyFound ? null : '提示：正在自动探测加密密钥，请稍候...',
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification n) {
        if (n.metrics.extentAfter < 300) _loadMore();
        return false;
      },
      child: MdtvVideoGrid(
        videos: _videos,
        imageResolver: widget.controller.imageURL,
        showFooter: _loadingMore,
        onOpenVideo: widget.onOpenVideo,
      ),
    );
  }
}

/// 分类 Tab（3 列分类网格 + 骨架加载）。
class _CategoryTab extends StatefulWidget {
  const _CategoryTab({required this.controller, required this.onOpenCategory});

  final MdtvController controller;
  final void Function(MdtvCategory category) onOpenCategory;

  @override
  State<_CategoryTab> createState() => _CategoryTabState();
}

class _CategoryTabState extends State<_CategoryTab> {
  List<MdtvCategory> _categories = const <MdtvCategory>[];
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
    try {
      final List<MdtvCategory> result = await widget.controller.fetchCategories();
      if (!mounted) return;
      setState(() {
        _categories = result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return GridView.builder(
        padding: const EdgeInsets.all(VboxSpacing.md),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: VboxSpacing.md,
          crossAxisSpacing: VboxSpacing.md,
          childAspectRatio: 0.72,
        ),
        itemCount: 9,
        itemBuilder: (BuildContext context, int index) =>
            const MdtvCategoryCard(name: '', placeholder: true),
      );
    }
    if (_error != null && _categories.isEmpty) {
      return MdtvErrorRetry(message: _error!, onRetry: _load);
    }
    if (_categories.isEmpty) {
      return const MdtvEmptyHint(text: '暂无分类');
    }
    return GridView.builder(
      padding: const EdgeInsets.all(VboxSpacing.md),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: VboxSpacing.md,
        crossAxisSpacing: VboxSpacing.md,
        childAspectRatio: 0.72,
      ),
      itemCount: _categories.length,
      itemBuilder: (BuildContext context, int index) {
        final MdtvCategory c = _categories[index];
        return MdtvCategoryCard(
          name: c.name,
          onTap: () => widget.onOpenCategory(c),
        );
      },
    );
  }
}

/// 标签 Tab（标签云）。
class _TagTab extends StatefulWidget {
  const _TagTab({required this.controller, required this.onOpenTag});

  final MdtvController controller;
  final void Function(MdtvTag tag) onOpenTag;

  @override
  State<_TagTab> createState() => _TagTabState();
}

class _TagTabState extends State<_TagTab> {
  List<MdtvTag> _tags = const <MdtvTag>[];
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
    try {
      final List<MdtvTag> result = await widget.controller.fetchTags();
      if (!mounted) return;
      setState(() {
        _tags = result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _tags.isEmpty) {
      return MdtvErrorRetry(message: _error!, onRetry: _load);
    }
    if (_tags.isEmpty) {
      return const MdtvEmptyHint(text: '暂无标签');
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(VboxSpacing.lg),
      child: MdtvTagCloud(tags: _tags, onTap: widget.onOpenTag),
    );
  }
}

/// 未知远程 Tab 内容（对齐 iOS `MDTVCustomTab`）。
class _CustomTab extends StatelessWidget {
  const _CustomTab({required this.tabName});

  final String tabName;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.view_in_ar_outlined,
            size: VboxTypography.s28,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: VboxSpacing.lg),
          Text(
            '$tabName 页面',
            style: TextStyle(
              fontSize: VboxTypography.s18,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: VboxSpacing.sm),
          Text(
            '该 Tab 尚未配置具体内容',
            style: TextStyle(
              fontSize: VboxTypography.s14,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 推荐页骨架占位数据。
List<MdtvVideoItem> _placeholderVideos() => <MdtvVideoItem>[
      for (int i = 0; i < 12; i++)
        MdtvVideoItem(
          videoId: 'placeholder_$i',
          title: '加载中...',
          cover: '',
          duration: '00:00',
          views: 0,
          likes: 0,
          categoryId: '',
        ),
    ];