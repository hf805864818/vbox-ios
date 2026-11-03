/// 表现层：弹幕搜索面板（UI-F3）。
///
/// 对齐 iOS `DanmakuSearchPanel`
/// （[PlayerViewsV2.swift](../../../../vbox/Views/PlayerViewsV2.swift#L10272)）：
///  - 搜索框 + 「搜索」按钮；
///  - 四态：未搜索（引导）/ 搜索中 / 无结果 / 候选列表；
///  - 选中候选番剧 → 列出其分集 → 选定分集回调加载。
///
/// 数据获取经 [search] / [loadEpisodes] 注入（本组件不直接依赖
/// `DanmakuService`，便于单测与替换数据源）。
library;

import 'package:flutter/material.dart';

import '../../../../platform/player/danmaku/danmaku_service.dart';
import '../../../theme/tokens/colors.dart';
import '../../../theme/tokens/spacing.dart';
import '../../../theme/tokens/typography.dart';
import 'player_panel_container.dart';

/// 弹幕搜索面板（含壳）。
class DanmakuSearchPanel extends StatefulWidget {
  /// 构造。
  const DanmakuSearchPanel({
    super.key,
    required this.search,
    required this.loadEpisodes,
    this.onSelectEpisode,
    this.onClose,
  });

  /// 关键字 → 候选番剧列表。
  final Future<List<DanmakuAnimeMatch>> Function(String keyword) search;

  /// 番剧 id → 分集列表。
  final Future<List<DanmakuEpisodeInfo>> Function(int animeId) loadEpisodes;

  /// 选定分集回调（null 表示只读）。
  final ValueChanged<DanmakuEpisodeInfo>? onSelectEpisode;

  /// 关闭回调。
  final VoidCallback? onClose;

  @override
  State<DanmakuSearchPanel> createState() => _DanmakuSearchPanelState();
}

class _DanmakuSearchPanelState extends State<DanmakuSearchPanel> {
  final TextEditingController _keyword = TextEditingController();

  List<DanmakuAnimeMatch> _results = const <DanmakuAnimeMatch>[];
  List<DanmakuEpisodeInfo> _episodes = const <DanmakuEpisodeInfo>[];
  DanmakuAnimeMatch? _selected;
  bool _searching = false;
  bool _loadingEpisodes = false;
  bool _hasSearched = false;

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _performSearch() async {
    final String key = _keyword.text.trim();
    if (key.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _selected = null;
      _episodes = const <DanmakuEpisodeInfo>[];
    });
    final List<DanmakuAnimeMatch> list = await widget.search(key);
    if (!mounted) return;
    setState(() {
      _results = list;
      _searching = false;
      _hasSearched = true;
    });
  }

  Future<void> _openEpisodes(DanmakuAnimeMatch match) async {
    setState(() {
      _selected = match;
      _loadingEpisodes = true;
      _episodes = const <DanmakuEpisodeInfo>[];
    });
    final List<DanmakuEpisodeInfo> list = await widget.loadEpisodes(match.animeId);
    if (!mounted) return;
    setState(() {
      _episodes = list;
      _loadingEpisodes = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PlayerPanelContainer(
      title: '搜索弹幕',
      onClose: widget.onClose,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildSearchBar(),
          const SizedBox(height: VboxSpacing.md),
          _buildBody(),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: _keyword,
            style: const TextStyle(
              fontSize: VboxTypography.s13,
              color: Colors.white,
            ),
            decoration: InputDecoration(
              hintText: '输入资源名称',
              hintStyle: const TextStyle(
                fontSize: VboxTypography.s13,
                color: Colors.white38,
              ),
              isDense: true,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.08),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: VboxSpacing.md,
                vertical: VboxSpacing.sm,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) => _performSearch(),
          ),
        ),
        const SizedBox(width: VboxSpacing.sm),
        TextButton(
          onPressed: _searching ? null : _performSearch,
          style: TextButton.styleFrom(
            backgroundColor: VboxColors.playerAccentGreen,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(
              horizontal: VboxSpacing.lg,
              vertical: VboxSpacing.sm,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: const Text(
            '搜索',
            style: TextStyle(
              fontSize: VboxTypography.s13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_searching) return _hint(Icons.search_rounded, '搜索中...');
    if (!_hasSearched) return _hint(Icons.search_rounded, '输入资源名称搜索弹幕');
    if (_results.isEmpty) return _hint(Icons.error_outline_rounded, '未找到匹配的弹幕源');
    if (_selected != null) return _buildEpisodes();
    return _buildResults();
  }

  Widget _hint(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VboxSpacing.xl),
      child: Column(
        children: <Widget>[
          Icon(icon, size: 36, color: Colors.white38),
          const SizedBox(height: VboxSpacing.sm),
          Text(
            text,
            style: const TextStyle(
              fontSize: VboxTypography.s12,
              color: Colors.white54,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final DanmakuAnimeMatch m in _results)
          InkWell(
            onTap: () => _openEpisodes(m),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: VboxSpacing.sm,
                vertical: VboxSpacing.md,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          m.title.isEmpty ? '番剧 ${m.animeId}' : m.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: VboxTypography.s14,
                            color: Colors.white,
                          ),
                        ),
                        if (m.type.isNotEmpty)
                          Text(
                            m.type,
                            style: const TextStyle(
                              fontSize: VboxTypography.s12,
                              color: Colors.white54,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEpisodes() {
    if (_loadingEpisodes) return _hint(Icons.hourglass_empty_rounded, '加载分集...');
    if (_episodes.isEmpty) return _hint(Icons.error_outline_rounded, '该番剧暂无分集');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              onPressed: () => setState(() {
                _selected = null;
                _episodes = const <DanmakuEpisodeInfo>[];
              }),
              icon: const Icon(
                Icons.arrow_back_rounded,
                size: 18,
                color: Colors.white70,
              ),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
            Expanded(
              child: Text(
                _selected?.title ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: VboxTypography.s14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: VboxSpacing.sm),
        Wrap(
          spacing: VboxSpacing.sm,
          runSpacing: VboxSpacing.sm,
          children: <Widget>[
            for (final DanmakuEpisodeInfo e in _episodes)
              _EpisodeChip(
                label: e.episodeNumber > 0
                    ? '${e.episodeNumber}'
                    : (e.title.isEmpty ? '${e.episodeId}' : e.title),
                onTap: widget.onSelectEpisode == null
                    ? null
                    : () => widget.onSelectEpisode!(e),
              ),
          ],
        ),
      ],
    );
  }
}

/// 分集胶囊按钮。
class _EpisodeChip extends StatelessWidget {
  const _EpisodeChip({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.md,
          vertical: VboxSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: VboxTypography.s13,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
