/// 表现层：网络音乐浏览页（批次 G · G-音1）。
///
/// 唯一真相源：iOS [MusicView.swift](../../../../vbox/Views/MusicView.swift)
///   · `MusicView`（L34-L819）：顶栏 / 播放源切换器 / 平台选择 / 内容类型 Tab /
///     分类标签栏 / 歌单广场 / 排行榜 / 搜索浮层 / 底部迷你播放条；
///   · `MusicViewModel`（L1599-L2130）：分类 / 歌单 / 榜单 / 搜索 / 播放编排。
///
/// 页面结构（自上而下，对齐 iOS）：
///   1. 顶栏：左关闭（xmark）· 标题「网络音乐」· 右搜索切换（magnifyingglass / xmark）；
///   2. 播放源切换器：横向 chip（来自 [MusicSourceRef]）；
///   3. 搜索浮层（[MusicHomePage] `searchMode` 为真时替代内容区）；
///   4. 平台选择：网易云 / QQ音乐 / 酷狗 / 酷我 / 咪咕；
///   5. 内容类型 Tab：歌单广场 / 排行榜；
///   6. 分类标签栏（仅歌单广场且有分类时展示）；
///   7. 内容区：歌单 2 列网格 / 榜单纵向列表；
///   8. 底部 [MiniPlayerBar] 悬浮条。
///
/// 落地差异（如实登记）：
///   · 播放源切换器仅做选中高亮：Flutter 侧无 lx 源注册表（`LXBridgeEngine`），
///     无法据引擎 Key 判定聚合 / 普通源，故不做源驱动的数据重载（`selectSource` 为
///     no-op），平台选择器恒展示（等价 iOS「聚合源」分支）；
///   · iOS 普通音乐源首页（`sourceHomeContent` 源自身分类 + 推荐歌曲）依赖
///     `SpiderManager`，Flutter 侧服务未暴露该能力，未移植；
///   · iOS「搜歌曲」为跨源 `SpiderManager.searchAllMusicSources`，Flutter 侧服务
///     只暴露歌单搜索 [MusicPlaylistService.searchPlaylists]，故搜歌曲 Tab 按空态处理；
///   · iOS 播放解析走 `SpiderManager` 并发竞速；Flutter 侧改为消费注入的
///     [MusicHomePage.onResolveSong] 回调，未注入或返回 null 时提示「该来源暂不支持播放」。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/datasources/remote/music_playlist_service.dart';
import '../../../domain/entities/music/music_playlist.dart';
import '../../../domain/entities/music/music_queue.dart';
import '../../../platform/player/music_player.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/music/mini_player.dart';
import '../../widgets/vbox/vbox.dart';
import 'music_player_page.dart';
import 'music_widgets.dart';

/// 内容区 Tab（对齐 iOS `MusicTab`）。
enum _MusicTab {
  /// 歌单广场。
  playlist('歌单广场'),

  /// 排行榜。
  ranking('排行榜');

  const _MusicTab(this.title);

  /// 展示名。
  final String title;
}

/// 搜索区 Tab（对齐 iOS `SearchTab`）。
enum _SearchTab {
  /// 搜歌曲。
  songs('搜歌曲'),

  /// 搜歌单。
  playlists('搜歌单');

  const _SearchTab(this.title);

  /// 展示名。
  final String title;
}

/// 播放源条目（对齐 iOS `SourceDisplayItem` 的展示子集）。
///
/// 落地差异：Flutter 侧无 lx 源注册表，仅保留展示与选中所需字段；[engineKey]
/// 不参与任何解析（解析由 [MusicHomePage.onResolveSong] 承担）。
class MusicSourceRef {
  /// 构造。
  const MusicSourceRef({
    required this.id,
    required this.name,
    this.engineKey,
  });

  /// 唯一 ID。
  final String id;

  /// 展示名。
  final String name;

  /// 引擎 Key（展示用，Flutter 侧无对应解析器）。
  final String? engineKey;
}

/// 网络音乐浏览页。
class MusicHomePage extends StatefulWidget {
  /// 构造。
  const MusicHomePage({
    super.key,
    this.service,
    this.controller,
    this.musicSources = const <MusicSourceRef>[],
    this.onResolveSong,
  });

  /// 歌单服务（缺省 [MusicPlaylistService]）。
  final MusicPlaylistService? service;

  /// 播放控制器（缺省 [MusicPlayerController.instance]）。
  final MusicPlayerController? controller;

  /// 可切换的播放源（空则展示 iOS 空态文案）。
  final List<MusicSourceRef> musicSources;

  /// 歌曲 → 可播放队列条目（未注入 / 返回 null → 「该来源暂不支持播放」）。
  final Future<MusicQueueItem?> Function(PlaylistSong song)? onResolveSong;

  @override
  State<MusicHomePage> createState() => _MusicHomePageState();
}

class _MusicHomePageState extends State<MusicHomePage> {
  late final _MusicHomeViewModel _vm;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _vm = _MusicHomeViewModel(
      service: widget.service ?? MusicPlaylistService(),
      sources: widget.musicSources,
    );
    unawaited(_vm.load());
  }

  @override
  void dispose() {
    _vm.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    final bool next = !_vm.searchMode;
    _vm.setSearchMode(next);
    if (next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    } else {
      _searchController.clear();
      _searchFocus.unfocus();
    }
  }

  void _cancelSearch() {
    _searchController.clear();
    _searchFocus.unfocus();
    _vm.setSearchMode(false);
  }

  void _applyKeyword(String keyword) {
    _searchController.text = keyword;
    _searchController.selection = TextSelection.collapsed(
      offset: keyword.length,
    );
    _vm.setSearchKeyword(keyword);
  }

  Future<void> _openPlaylist(PlaylistItem item) async {
    final PlaylistDetail? detail = await _vm.loadDetail(
      platform: item.platform,
      rawId: item.rawId,
      isRanking: false,
    );
    if (!mounted) return;
    if (detail == null) {
      VboxToast.show(context, '加载失败，请重试');
      return;
    }
    _pushDetail(detail);
  }

  Future<void> _openRanking(RankingItem item) async {
    final PlaylistDetail? detail = await _vm.loadDetail(
      platform: item.platform,
      rawId: item.rawId,
      isRanking: true,
    );
    if (!mounted) return;
    if (detail == null) {
      VboxToast.show(context, '加载失败，请重试');
      return;
    }
    _pushDetail(detail);
  }

  void _pushDetail(PlaylistDetail detail) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => PlaylistDetailPage(
          detail: detail,
          controller: widget.controller,
          onResolveSong: widget.onResolveSong,
        ),
      ),
    );
  }

  void _openPlayer() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            MusicPlayerPage(controller: widget.controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (BuildContext context, Widget? _) {
        final ColorScheme scheme = Theme.of(context).colorScheme;
        return Scaffold(
          backgroundColor: scheme.surface,
          appBar: AppBar(
            centerTitle: true,
            leading: IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(Icons.close, size: 20, color: scheme.primary),
            ),
            title: const Text(
              '网络音乐',
              style: TextStyle(
                fontSize: VboxTypography.s16,
                fontWeight: FontWeight.w600,
              ),
            ),
            actions: <Widget>[
              IconButton(
                tooltip: _vm.searchMode ? '退出搜索' : '搜索',
                onPressed: _toggleSearch,
                icon: Icon(
                  _vm.searchMode ? Icons.close : Icons.search,
                  size: 20,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          body: Stack(
            children: <Widget>[
              Column(
                children: <Widget>[
                  _sourceSwitcher(scheme),
                  Divider(height: 1, color: scheme.outlineVariant),
                  if (_vm.searchMode)
                    Expanded(child: _searchOverlay(scheme))
                  else
                    Expanded(child: _browseContent(scheme)),
                ],
              ),
              // 底部悬浮播放条（对齐 iOS `.overlay(alignment: .bottom)`）。
              Positioned.fill(
                child: MiniPlayerBar(
                  controller: widget.controller,
                  onExpand: _openPlayer,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ───────────────────────── 播放源切换器 ─────────────────────────

  Widget _sourceSwitcher(ColorScheme scheme) {
    final List<MusicSourceRef> sources = widget.musicSources;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
        children: <Widget>[
          if (sources.isEmpty)
            Center(
              child: Text(
                '未发现音乐源，将使用默认解析',
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final MusicSourceRef source in sources)
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: VboxSpacing.compact,
                  horizontal: VboxSpacing.xs,
                ),
                child: _sourceChip(scheme, source),
              ),
        ],
      ),
    );
  }

  Widget _sourceChip(ColorScheme scheme, MusicSourceRef source) {
    final bool isSelected = _vm.selectedSourceId == source.id;
    final Color accent = scheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(VboxRadii.r16),
      onTap: () => _vm.selectSource(source.id),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: VboxSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? accent.withValues(alpha: 0.15)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(VboxRadii.r16),
          border: Border.all(
            color: isSelected
                ? accent.withValues(alpha: 0.4)
                : Colors.transparent,
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.music_note,
              size: 12,
              color: isSelected ? accent : scheme.onSurface,
            ),
            const SizedBox(width: VboxSpacing.compact),
            Text(
              source.name,
              style: TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w500,
                color: isSelected ? accent : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────────── 浏览内容 ─────────────────────────

  Widget _browseContent(ColorScheme scheme) {
    return Column(
      children: <Widget>[
        _platformSelector(scheme),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.6)),
        _contentTypeTabs(scheme),
        if (_vm.selectedTab == _MusicTab.playlist && _vm.categories.isNotEmpty)
          _tagFilterBar(scheme),
        Expanded(
          child: _vm.selectedTab == _MusicTab.playlist
              ? _playlistGrid(scheme)
              : _rankingList(scheme),
        ),
      ],
    );
  }

  Widget _platformSelector(ColorScheme scheme) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
        children: <Widget>[
          for (final MusicPlatformType p in MusicPlatformType.values)
            Padding(
              padding: const EdgeInsets.only(right: VboxSpacing.xl),
              child: _platformButton(scheme, p),
            ),
        ],
      ),
    );
  }

  Widget _platformButton(ColorScheme scheme, MusicPlatformType platform) {
    final bool isSelected = _vm.selectedPlatform == platform;
    final Color accent = musicPlatformAccent(platform);
    return InkWell(
      onTap: () => _vm.selectPlatform(platform),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: VboxSpacing.compact),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              platform.displayName,
              style: TextStyle(
                fontSize: VboxTypography.s14,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? accent : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: VboxSpacing.xs),
            Container(
              width: 22,
              height: 3,
              decoration: BoxDecoration(
                color: isSelected ? accent : Colors.transparent,
                borderRadius: BorderRadius.circular(VboxRadii.capsule),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _contentTypeTabs(ColorScheme scheme) {
    final Color accent = scheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.lg,
        vertical: VboxSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          for (final _MusicTab tab in _MusicTab.values) ...<Widget>[
            Expanded(child: _contentTypeTab(scheme, accent, tab)),
            if (tab != _MusicTab.values.last)
              const SizedBox(width: VboxSpacing.sm),
          ],
        ],
      ),
    );
  }

  Widget _contentTypeTab(ColorScheme scheme, Color accent, _MusicTab tab) {
    final bool isSelected = _vm.selectedTab == tab;
    return InkWell(
      borderRadius: BorderRadius.circular(VboxRadii.r10),
      onTap: () => _vm.selectTab(tab),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: VboxSpacing.sm),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected
              ? accent.withValues(alpha: 0.15)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(VboxRadii.r10),
        ),
        child: Text(
          tab.title,
          style: TextStyle(
            fontSize: VboxTypography.s13,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            color: isSelected ? accent : scheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _tagFilterBar(ColorScheme scheme) {
    final Color accent = scheme.primary;
    final bool allSelected = _vm.selectedCategoryId == null;
    final List<PlaylistCategory> visible = _vm.categories
        .where((PlaylistCategory c) => c.name != '全部')
        .toList(growable: false);

    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
        children: <Widget>[
          _tagChip(scheme, accent, '全部', allSelected, () {
            _vm.selectCategory(null);
          }),
          for (final PlaylistCategory cat in visible)
            Padding(
              padding: const EdgeInsets.only(left: VboxSpacing.compact),
              child: _tagChip(
                scheme,
                accent,
                cat.name,
                _vm.selectedCategoryId == cat.id,
                () => _vm.selectCategory(cat.id),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tagChip(
    ColorScheme scheme,
    Color accent,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(VboxRadii.r12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.md,
          vertical: VboxSpacing.compact,
        ),
        margin: const EdgeInsets.symmetric(vertical: VboxSpacing.xs),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.16)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(VboxRadii.r12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: VboxTypography.s12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? accent : scheme.onSurface,
          ),
        ),
      ),
    );
  }

  // ───────────────────────── 歌单广场 / 排行榜 ─────────────────────────

  Widget _playlistGrid(ColorScheme scheme) {
    if (_vm.isLoadingPlaylists && _vm.playlists.isEmpty) {
      return _loading(scheme, '加载歌单中...');
    }
    if (_vm.playlists.isEmpty) {
      return _empty(scheme, Icons.layers_outlined, '暂无歌单');
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification n) {
        if (n.metrics.maxScrollExtent > 0 &&
            n.metrics.pixels >= n.metrics.maxScrollExtent - 240) {
          unawaited(_vm.loadMorePlaylists());
        }
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () => _vm.loadPlaylists(1),
        child: GridView.builder(
          padding: const EdgeInsets.fromLTRB(
            VboxSpacing.lg,
            VboxSpacing.sm,
            VboxSpacing.lg,
            96,
          ),
          physics: const AlwaysScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            mainAxisExtent: 206,
          ),
          itemCount: _vm.playlists.length,
          itemBuilder: (BuildContext context, int index) {
            final PlaylistItem item = _vm.playlists[index];
            return InkWell(
              onTap: () => _openPlaylist(item),
              child: PlaylistCard(playlist: item),
            );
          },
        ),
      ),
    );
  }

  Widget _rankingList(ColorScheme scheme) {
    if (_vm.isLoadingRankings && _vm.rankings.isEmpty) {
      return _loading(scheme, '加载榜单中...');
    }
    if (_vm.rankings.isEmpty) {
      return _empty(scheme, Icons.bar_chart, '暂无排行榜');
    }

    return RefreshIndicator(
      onRefresh: _vm.loadRankings,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 96),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _vm.rankings.length,
        separatorBuilder: (BuildContext context, int index) =>
            Divider(indent: 84, height: 1, color: scheme.outlineVariant),
        itemBuilder: (BuildContext context, int index) {
          final RankingItem item = _vm.rankings[index];
          return InkWell(
            onTap: () => _openRanking(item),
            child: RankingRow(ranking: item),
          );
        },
      ),
    );
  }

  // ───────────────────────── 搜索浮层 ─────────────────────────

  Widget _searchOverlay(ColorScheme scheme) {
    final Color accent = scheme.primary;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VboxSpacing.lg,
            vertical: VboxSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Expanded(child: _searchField(scheme)),
              const SizedBox(width: VboxSpacing.sm),
              TextButton(
                onPressed: _cancelSearch,
                child: Text(
                  '取消',
                  style: TextStyle(
                    fontSize: VboxTypography.s14,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
        ),
        _searchTypeTabs(scheme, accent),
        Expanded(child: _searchContent(scheme)),
      ],
    );
  }

  Widget _searchField(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VboxRadii.r10),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.search, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: VboxSpacing.sm),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              textInputAction: TextInputAction.search,
              autocorrect: false,
              onChanged: _vm.setSearchKeyword,
              style: const TextStyle(fontSize: VboxTypography.s14),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: _vm.searchTab == _SearchTab.songs
                    ? '搜索歌曲、歌手...'
                    : '搜索歌单...',
                hintStyle: TextStyle(
                  fontSize: VboxTypography.s14,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (_vm.searchKeyword.isNotEmpty)
            IconButton(
              onPressed: () => _applyKeyword(''),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: Icon(
                Icons.cancel,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _searchTypeTabs(ColorScheme scheme, Color accent) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
      child: Row(
        children: <Widget>[
          for (final _SearchTab tab in _SearchTab.values)
            Expanded(child: _searchTypeTab(scheme, accent, tab)),
        ],
      ),
    );
  }

  Widget _searchTypeTab(ColorScheme scheme, Color accent, _SearchTab tab) {
    final bool isSelected = _vm.searchTab == tab;
    return InkWell(
      onTap: () => _vm.selectSearchTab(tab),
      child: Padding(
        padding: const EdgeInsets.only(bottom: VboxSpacing.xs),
        child: Column(
          children: <Widget>[
            Text(
              tab.title,
              style: TextStyle(
                fontSize: VboxTypography.s14,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected ? accent : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: VboxSpacing.xs),
            Container(
              width: 20,
              height: 3,
              decoration: BoxDecoration(
                color: isSelected ? accent : Colors.transparent,
                borderRadius: BorderRadius.circular(VboxRadii.capsule),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchContent(ColorScheme scheme) {
    if (_vm.searchKeyword.trim().isEmpty) {
      return _hotKeywords(scheme);
    }
    if (_vm.searchTab == _SearchTab.songs) {
      // 落地差异：服务端无跨源歌曲搜索，搜歌曲恒空态。
      return _empty(scheme, Icons.mic_none, '未找到相关歌曲');
    }
    if (_vm.isSearching && _vm.playlistSearchResults.isEmpty) {
      return _loading(scheme, '搜索歌单中...');
    }
    if (_vm.playlistSearchResults.isEmpty) {
      return _empty(scheme, Icons.layers_outlined, '未找到相关歌单');
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        VboxSpacing.lg,
        VboxSpacing.sm,
        VboxSpacing.lg,
        96,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        mainAxisExtent: 206,
      ),
      itemCount: _vm.playlistSearchResults.length,
      itemBuilder: (BuildContext context, int index) {
        final PlaylistItem item = _vm.playlistSearchResults[index];
        return InkWell(
          onTap: () => _openPlaylist(item),
          child: PlaylistCard(playlist: item),
        );
      },
    );
  }

  Widget _hotKeywords(ColorScheme scheme) {
    return GridView.builder(
      padding: VboxSpacing.page,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 120,
        mainAxisExtent: 40,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _MusicHomeViewModel.hotKeywords.length + 1,
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Row(
              children: <Widget>[
                Text(
                  '热门搜索',
                  style: TextStyle(
                    fontSize: VboxTypography.s15,
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(width: VboxSpacing.sm),
                Text(
                  '点选即搜',
                  style: TextStyle(
                    fontSize: VboxTypography.s11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }
        final String keyword = _MusicHomeViewModel.hotKeywords[index - 1];
        return InkWell(
          borderRadius: BorderRadius.circular(VboxRadii.r10),
          onTap: () => _applyKeyword(keyword),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(VboxRadii.r10),
            ),
            child: Text(
              keyword,
              style: TextStyle(
                fontSize: VboxTypography.s13,
                color: scheme.onSurface,
              ),
            ),
          ),
        );
      },
    );
  }

  // ───────────────────────── 通用态 ─────────────────────────

  Widget _loading(ColorScheme scheme, String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CircularProgressIndicator(color: scheme.primary),
          const SizedBox(height: VboxSpacing.md),
          Text(
            text,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(ColorScheme scheme, IconData icon, String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            icon,
            size: 40,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: VboxSpacing.md),
          Text(
            text,
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

// ════════════════════════════════════════════════════════════════════════
// ViewModel
// ════════════════════════════════════════════════════════════════════════

/// 网络音乐浏览状态（对齐 iOS `MusicViewModel` L1599-L2130，按服务能力裁剪）。
class _MusicHomeViewModel extends ChangeNotifier {
  /// 构造。
  _MusicHomeViewModel({
    required MusicPlaylistService service,
    required List<MusicSourceRef> sources,
  })  : _service = service,
        selectedSourceId =
            sources.isNotEmpty ? sources.first.id : null;

  final MusicPlaylistService _service;

  /// 内置热搜关键词（对齐 iOS `MusicViewModel.hotKeywords`，L1713-L1717）。
  static const List<String> hotKeywords = <String>[
    '晴天',
    '稻香',
    '孤勇者',
    '罗刹海市',
    '晚风心里吹',
    '我记得',
    '起风了',
    '体面',
    '七里香',
    '告白气球',
    '浮夸',
    '海阔天空',
  ];

  /// 当前平台。
  MusicPlatformType selectedPlatform = MusicPlatformType.netease;

  /// 当前内容类型。
  _MusicTab selectedTab = _MusicTab.playlist;

  /// 分类标签。
  List<PlaylistCategory> categories = const <PlaylistCategory>[];

  /// 选中分类（null = 全部）。
  String? selectedCategoryId;

  /// 歌单广场数据。
  List<PlaylistItem> playlists = const <PlaylistItem>[];

  /// 排行榜数据。
  List<RankingItem> rankings = const <RankingItem>[];

  /// 歌单加载态。
  bool isLoadingPlaylists = false;

  /// 榜单加载态。
  bool isLoadingRankings = false;

  /// 搜索请求中。
  bool isSearching = false;

  /// 搜索模式（顶栏放大镜切换）。
  bool searchMode = false;

  /// 搜索关键词。
  String searchKeyword = '';

  /// 搜索类型。
  _SearchTab searchTab = _SearchTab.songs;

  /// 歌曲搜索结果（服务端无该能力，恒空；保留状态对齐 iOS）。
  List<PlaylistSong> songSearchResults = const <PlaylistSong>[];

  /// 歌单搜索结果。
  List<PlaylistItem> playlistSearchResults = const <PlaylistItem>[];

  /// 选中播放源 ID（仅高亮，无源驱动重载）。
  String? selectedSourceId;

  int _currentPlaylistPage = 1;
  bool _hasMorePlaylists = true;
  bool _disposed = false;
  Timer? _searchDebounce;

  // ── 启动 ──

  /// App 进入：加载分类 + 歌单第 1 页（对齐 iOS `.task` L125-L135）。
  Future<void> load() async {
    await loadCategories();
    if (_disposed) return;
    await loadPlaylists(1);
  }

  // ── 平台 / Tab / 分类 ──

  /// 切换平台 → 重载分类 + 歌单 / 榜单。
  Future<void> selectPlatform(MusicPlatformType platform) async {
    if (selectedPlatform == platform) return;
    selectedPlatform = platform;
    selectedCategoryId = null;
    notifyListeners();
    await loadCategories();
    if (_disposed) return;
    if (selectedTab == _MusicTab.playlist) {
      await loadPlaylists(1);
    } else {
      await loadRankings();
    }
  }

  /// 切换内容类型 → 空态时懒加载（对齐 iOS `selectTab` L1841-L1848）。
  Future<void> selectTab(_MusicTab tab) async {
    selectedTab = tab;
    notifyListeners();
    if (tab == _MusicTab.playlist) {
      if (playlists.isEmpty) await loadPlaylists(1);
    } else {
      if (rankings.isEmpty) await loadRankings();
    }
  }

  /// 切换分类 → 重载歌单第 1 页。
  Future<void> selectCategory(String? id) async {
    selectedCategoryId = id;
    notifyListeners();
    await loadPlaylists(1);
  }

  /// 切换播放源（仅高亮；Flutter 侧无 lx 源解析器）。
  void selectSource(String id) {
    if (selectedSourceId == id) return;
    selectedSourceId = id;
    notifyListeners();
  }

  // ── 加载 ──

  /// 加载分类标签（对齐 iOS `loadCategories` L1858-L1864）。
  Future<void> loadCategories() async {
    final List<PlaylistCategory> items =
        await _service.getPlaylistCategories(selectedPlatform);
    if (_disposed) return;
    categories = items;
    notifyListeners();
  }

  /// 加载歌单（分页，对齐 iOS `loadPlaylists` L1868-L1903）。
  Future<void> loadPlaylists(int page) async {
    final bool first = page <= 1;
    if (first) {
      isLoadingPlaylists = true;
      playlists = const <PlaylistItem>[];
      _currentPlaylistPage = 1;
      _hasMorePlaylists = true;
      notifyListeners();
    } else {
      if (!_hasMorePlaylists || isLoadingPlaylists) return;
      isLoadingPlaylists = true;
      notifyListeners();
    }

    final int target = page < 1 ? 1 : page;
    final List<PlaylistItem> items = await _service.getPlaylists(
      selectedPlatform,
      category: selectedCategoryId,
      page: target,
    );
    if (_disposed) return;

    playlists = first
        ? items
        : <PlaylistItem>[...playlists, ...items];
    _currentPlaylistPage = target;
    _hasMorePlaylists = items.isNotEmpty && items.length >= 15;
    isLoadingPlaylists = false;
    notifyListeners();
  }

  /// 滚动到底部分页加载（对齐 iOS `loadMorePlaylists`）。
  Future<void> loadMorePlaylists() async {
    if (!_hasMorePlaylists || isLoadingPlaylists) return;
    await loadPlaylists(_currentPlaylistPage + 1);
  }

  /// 加载排行榜（对齐 iOS `loadRankings` L1913-L1923）。
  Future<void> loadRankings() async {
    isLoadingRankings = true;
    notifyListeners();
    final List<RankingItem> items =
        await _service.getRankings(selectedPlatform);
    if (_disposed) return;
    rankings = items;
    isLoadingRankings = false;
    notifyListeners();
  }

  /// 加载详情（歌单 / 榜单），供推入 [PlaylistDetailPage] 前使用。
  Future<PlaylistDetail?> loadDetail({
    required MusicPlatformType platform,
    required String rawId,
    required bool isRanking,
  }) async {
    if (isRanking) {
      return _service.getRankingDetail(platform, rawId);
    }
    return _service.getPlaylistDetail(platform, rawId);
  }

  // ── 搜索 ──

  /// 进入 / 退出搜索模式（退出时清空输入与结果，对齐 iOS L104-L116）。
  void setSearchMode(bool on) {
    if (searchMode == on) return;
    searchMode = on;
    if (!on) {
      searchKeyword = '';
      _searchDebounce?.cancel();
      clearSearchResults();
      return;
    }
    notifyListeners();
  }

  /// 设置关键词：400ms 防抖后按当前搜索类型发起请求（对齐 iOS `.task(id:)` L552-L566）。
  void setSearchKeyword(String keyword) {
    searchKeyword = keyword;
    _searchDebounce?.cancel();
    notifyListeners();
    final String trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      clearSearchResults();
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (_disposed) return;
      if (searchTab == _SearchTab.playlists) {
        unawaited(searchPlaylists(trimmed));
      } else {
        // 落地差异：服务端无跨源歌曲搜索，恒空态。
        songSearchResults = const <PlaylistSong>[];
        notifyListeners();
      }
    });
  }

  /// 切换搜索类型并复用当前关键词重查。
  void selectSearchTab(_SearchTab tab) {
    if (searchTab == tab) return;
    searchTab = tab;
    notifyListeners();
    setSearchKeyword(searchKeyword);
  }

  /// 搜歌单（对齐 iOS `searchPlaylists` L1948-L1964）。
  Future<void> searchPlaylists(String keyword) async {
    isSearching = true;
    notifyListeners();
    final List<PlaylistItem> items = await _service.searchPlaylists(
      selectedPlatform,
      keyword,
      page: 1,
    );
    if (_disposed) return;
    playlistSearchResults = items;
    isSearching = false;
    notifyListeners();
  }

  /// 清空搜索结果。
  void clearSearchResults() {
    songSearchResults = const <PlaylistSong>[];
    playlistSearchResults = const <PlaylistItem>[];
    isSearching = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _searchDebounce?.cancel();
    super.dispose();
  }
}