/// One 平台（YBox）视频详情页（批次 G · G-05）。
///
/// 对齐 iOS `OneVideoDetailView`：16:9 封面（点击播放 / 加载 / 错误三态）
/// + 标题 + 信息行（时长 / 播放量 / 评分）+ 播放线路选择 + 标签 + 简介。
/// 播放经 [OnePlayHandler] 接入，缺省进入全屏播放页 [PlayerPage]（Wave A · R-渲2）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/one_platform/one_platform.dart';
import '../../../domain/entities/player/player.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import '../player/player_page.dart';
import 'one_platform_controller.dart';
import 'one_platform_widgets.dart';

/// One 平台播放回调（url → 打开并播放）。
typedef OnePlayHandler = Future<void> Function(String url);

/// 视频详情页。
class OnePlatformVideoDetailPage extends StatefulWidget {
  /// 构造。
  const OnePlatformVideoDetailPage({
    super.key,
    required this.video,
    required this.controller,
    this.onPlay,
  });

  /// 视频条目（列表传入的摘要信息，封面/标题/标签即时展示）。
  final OneVideoItem video;

  /// 控制器。
  final OnePlatformController controller;

  /// 播放回调（null → [PlayerController.instance]）。
  final OnePlayHandler? onPlay;

  @override
  State<OnePlatformVideoDetailPage> createState() =>
      _OnePlatformVideoDetailPageState();
}

class _OnePlatformVideoDetailPageState
    extends State<OnePlatformVideoDetailPage> {
  OneVideoDetail? _detail;
  String? _playUrl;
  bool _loading = true;
  bool _playing = false;
  String? _error;
  int _selectedLine = 0;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // 先取详情，再取播放地址（对齐 iOS loadDetail 顺序）。
    final OneVideoDetail? detail =
        await widget.controller.fetchVideoDetail(widget.video.articleId);
    final String? url =
        await widget.controller.fetchPlayURL(widget.video.articleId);
    if (!mounted) return;
    setState(() {
      _detail = detail;
      if (url != null && url.isNotEmpty) {
        _playUrl = url;
      } else if (detail != null &&
          detail.playUrls.isNotEmpty &&
          detail.playUrls.first.url.isNotEmpty) {
        _playUrl = detail.playUrls.first.url;
        _selectedLine = 0;
      } else {
        _error = '无法获取播放地址';
      }
      _loading = false;
    });
  }

  Future<void> _play() async {
    final String? url = _playUrl;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无可用播放地址')),
      );
      return;
    }
    if (_playing) return;
    setState(() => _playing = true);
    try {
      final OnePlayHandler handler = widget.onPlay ?? _defaultPlay;
      await handler(url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('播放失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  Future<void> _defaultPlay(String url) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => PlayerPage(
          source: PlayerSource(url: url, title: widget.video.title),
          title: widget.video.title,
        ),
      ),
    );
  }

  void _selectLine(int index) {
    final List<OnePlaySource>? sources = _detail?.playUrls;
    if (sources == null || index >= sources.length) return;
    setState(() {
      _selectedLine = index;
      _playUrl = sources[index].url;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final OneVideoItem video = widget.video;
    final OneVideoDetail? detail = _detail;
    return Scaffold(
      appBar: AppBar(title: const Text('视频详情')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: VboxSpacing.xxl),
        children: <Widget>[
          _cover(scheme),
          Padding(
            padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SizedBox(height: VboxSpacing.lg),
                Text(
                  video.title,
                  style: TextStyle(
                    fontSize: VboxTypography.s18,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: VboxSpacing.sm),
                _infoRow(scheme, video),
                if (detail != null && detail.playUrls.isNotEmpty) ...<Widget>[
                  const SizedBox(height: VboxSpacing.lg),
                  Text(
                    '播放线路',
                    style: TextStyle(
                      fontSize: VboxTypography.s14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (detail != null && detail.playUrls.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: VboxSpacing.sm),
              child: OneLineChips(
                sources: detail.playUrls,
                selectedIndex: _selectedLine,
                onTap: _selectLine,
              ),
            ),
          Padding(
            padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (video.tags.isNotEmpty) ...<Widget>[
                  const SizedBox(height: VboxSpacing.lg),
                  Text(
                    '标签',
                    style: TextStyle(
                      fontSize: VboxTypography.s14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: VboxSpacing.sm),
                  OneTagChips(tags: video.tags),
                ],
                if (detail != null && detail.description.isNotEmpty) ...<Widget>[
                  const SizedBox(height: VboxSpacing.lg),
                  Text(
                    '简介',
                    style: TextStyle(
                      fontSize: VboxTypography.s14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: VboxSpacing.sm),
                  Text(
                    detail.description,
                    style: TextStyle(
                      fontSize: VboxTypography.s13,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cover(ColorScheme scheme) {
    final String coverUrl = widget.controller.imageURL(widget.video.cover);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: GestureDetector(
        onTap: _play,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Container(color: Colors.black),
            if (coverUrl.isNotEmpty)
              PlatformAsyncImage(
                url: coverUrl,
                fit: BoxFit.cover,
                placeholderColor: Colors.black,
                placeholder: const SizedBox.shrink(),
              ),
            Center(child: _overlay(scheme)),
          ],
        ),
      ),
    );
  }

  Widget _overlay(ColorScheme scheme) {
    if (_loading) {
      return const CircularProgressIndicator(color: Colors.white);
    }
    if (_playUrl != null && _playUrl!.isNotEmpty) {
      return Icon(
        Icons.play_circle_fill,
        size: VboxTypography.s28 + 32,
        color: Colors.white.withValues(alpha: 0.90),
        shadows: const <Shadow>[Shadow(color: Colors.black45, blurRadius: 10)],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.warning_amber_rounded, size: 36, color: Colors.orange),
        const SizedBox(height: VboxSpacing.sm),
        Text(
          _error ?? '无法获取播放地址',
          style: const TextStyle(fontSize: VboxTypography.s13, color: Colors.white),
        ),
      ],
    );
  }

  Widget _infoRow(ColorScheme scheme, OneVideoItem video) {
    Widget item(IconData icon, String text, {Color? color}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon,
                size: VboxTypography.s13,
                color: color ?? scheme.onSurfaceVariant),
            const SizedBox(width: VboxSpacing.xs),
            Text(
              text,
              style: TextStyle(
                fontSize: VboxTypography.s13,
                color: color ?? scheme.onSurfaceVariant,
              ),
            ),
          ],
        );

    final String? rating = video.rating;
    return Wrap(
      spacing: VboxSpacing.md,
      runSpacing: VboxSpacing.sm,
      children: <Widget>[
        if (video.duration.isNotEmpty)
          item(Icons.access_time, video.duration),
        item(Icons.remove_red_eye_outlined, formatOneCount(video.views)),
        if (rating != null && rating.isNotEmpty)
          item(Icons.star, rating, color: Colors.orange),
      ],
    );
  }
}