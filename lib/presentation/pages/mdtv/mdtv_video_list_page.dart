/// 麻豆平台（MDTV）视频列表页（批次 E · E-05）。
///
/// 对齐 iOS `MDTVVideoListView`：分类/标签进入的 2 列视频网格 + 分页加载。
/// 标题取 `category?.name ?? tag?.name`；加载按 `category?.cateId` 过滤
/// （对齐 iOS：Tag 分支不传分类，返回全部视频）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/mdtv/mdtv.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import 'mdtv_controller.dart';
import 'mdtv_video_detail_page.dart';
import 'mdtv_widgets.dart';

/// 视频列表页（分类 / 标签）。
class MdtvVideoListPage extends StatefulWidget {
  /// 构造（[category] / [tag] 二选一，至少一个非空）。
  const MdtvVideoListPage({
    super.key,
    required this.controller,
    this.category,
    this.tag,
    this.onPlay,
  }) : assert(category != null || tag != null, 'category 与 tag 至少其一非空');

  /// 分类（null → 按 [tag] 展示）。
  final MdtvCategory? category;

  /// 标签（null → 按 [category] 展示）。
  final MdtvTag? tag;

  /// 控制器。
  final MdtvController controller;

  /// 播放回调（透传详情页）。
  final MdtvPlayHandler? onPlay;

  @override
  State<MdtvVideoListPage> createState() => _MdtvVideoListPageState();
}

class _MdtvVideoListPageState extends State<MdtvVideoListPage> {
  List<MdtvVideoItem> _videos = const <MdtvVideoItem>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;

  String get _title =>
      widget.category?.name ?? widget.tag?.name ?? '视频列表';

  String? get _categoryId => widget.category?.cateId;

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
      final List<MdtvVideoItem> result =
          await widget.controller.fetchVideos(categoryId: _categoryId, page: 1);
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
      final List<MdtvVideoItem> result = await widget.controller
          .fetchVideos(categoryId: _categoryId, page: _page + 1);
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

  void _openVideo(MdtvVideoItem video) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext context) => MdtvVideoDetailPage(
        video: video,
        controller: widget.controller,
        onPlay: widget.onPlay,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_loading && _videos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _videos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(VboxSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline,
                  size: VboxTypography.s28, color: scheme.error),
              const SizedBox(height: VboxSpacing.md),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: VboxSpacing.md),
              FilledButton.tonal(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_videos.isEmpty) {
      return const MdtvEmptyHint(text: '暂无视频');
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
        onOpenVideo: _openVideo,
      ),
    );
  }
}