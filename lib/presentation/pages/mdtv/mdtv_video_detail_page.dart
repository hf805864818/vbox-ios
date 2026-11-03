/// 麻豆平台（MDTV）视频详情页（批次 E · E-05）。
///
/// 对齐 iOS `MDTVVideoDetailView`：16:9 封面（点击播放）+ 标题 + 信息行
/// （播放量/点赞/时长/评分）+ 标签 + 简介。播放经 [MdtvPlayHandler] 接入，
/// 缺省进入全屏播放页 [PlayerPage]（Wave A · R-渲2）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/mdtv/mdtv.dart';
import '../../../domain/entities/player/player.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import '../player/player_page.dart';
import 'mdtv_controller.dart';

/// 麻豆播放回调（url → 打开并播放）。
typedef MdtvPlayHandler = Future<void> Function(String url);

/// 视频详情页。
class MdtvVideoDetailPage extends StatefulWidget {
  /// 构造。
  const MdtvVideoDetailPage({
    super.key,
    required this.video,
    required this.controller,
    this.onPlay,
  });

  /// 视频条目（列表传入的摘要信息，封面/标题/标签即时展示）。
  final MdtvVideoItem video;

  /// 控制器。
  final MdtvController controller;

  /// 播放回调（null → [PlayerController.instance]）。
  final MdtvPlayHandler? onPlay;

  @override
  State<MdtvVideoDetailPage> createState() => _MdtvVideoDetailPageState();
}

class _MdtvVideoDetailPageState extends State<MdtvVideoDetailPage> {
  MdtvVideoDetail? _detail;
  bool _loading = true;
  bool _playing = false;
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
      final MdtvVideoDetail? detail =
          await widget.controller.fetchVideoDetail(widget.video.videoId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
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

  Future<void> _play() async {
    if (_playing) return;
    setState(() => _playing = true);
    try {
      final String? url = await widget.controller.fetchPlayURL(widget.video.videoId);
      if (url == null || url.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('暂无可用播放地址')),
          );
        }
        return;
      }
      final MdtvPlayHandler handler = widget.onPlay ?? _defaultPlay;
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

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final MdtvVideoItem video = widget.video;
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
                const SizedBox(height: VboxSpacing.md),
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
                if (video.tags.isNotEmpty) ...<Widget>[
                  const SizedBox(height: VboxSpacing.md),
                  _tagRow(scheme, video.tags),
                ],
                const SizedBox(height: VboxSpacing.md),
                const Divider(height: 1),
                if (_loading) ...<Widget>[
                  const SizedBox(height: VboxSpacing.xl),
                  const Center(child: CircularProgressIndicator()),
                ] else if (_detail != null &&
                    _detail!.description.isNotEmpty) ...<Widget>[
                  const SizedBox(height: VboxSpacing.lg),
                  Text(
                    '简介',
                    style: TextStyle(
                      fontSize: VboxTypography.s15,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: VboxSpacing.sm),
                  Text(
                    _detail!.description,
                    style: TextStyle(
                      fontSize: VboxTypography.s14,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ] else if (_error != null) ...<Widget>[
                  const SizedBox(height: VboxSpacing.lg),
                  Text(
                    '加载失败：$_error',
                    style: TextStyle(
                      fontSize: VboxTypography.s14,
                      color: scheme.error,
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
            if (coverUrl.isEmpty)
              Container(
                color: scheme.surfaceContainerHighest,
              )
            else
              PlatformAsyncImage(
                url: coverUrl,
                fit: BoxFit.cover,
                placeholderColor: scheme.surfaceContainerHighest,
                placeholder: Icon(
                  Icons.movie_outlined,
                  size: VboxTypography.s28,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.40),
                ),
              ),
            Center(
              child: Icon(
                Icons.play_circle_fill,
                size: VboxTypography.s28 + 22,
                color: Colors.white.withValues(alpha: 0.90),
                shadows: const <Shadow>[
                  Shadow(color: Colors.black45, blurRadius: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(ColorScheme scheme, MdtvVideoItem video) {
    Widget item(IconData icon, String text, {Color? color}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: VboxTypography.s13, color: color ?? scheme.onSurfaceVariant),
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

    return Wrap(
      spacing: VboxSpacing.lg,
      runSpacing: VboxSpacing.sm,
      children: <Widget>[
        item(Icons.remove_red_eye_outlined, '${video.views}'),
        item(Icons.thumb_up_outlined, '${video.likes}'),
        item(Icons.access_time, video.duration),
        if (video.rating != null)
          item(Icons.star, video.rating!, color: Colors.amber.shade600),
      ],
    );
  }

  Widget _tagRow(ColorScheme scheme, List<String> tags) {
    return Wrap(
      spacing: VboxSpacing.sm,
      runSpacing: VboxSpacing.sm,
      children: <Widget>[
        for (final String tag in tags)
          Container(
            padding: VboxSpacing.symmetric(
                horizontal: VboxSpacing.md, vertical: VboxSpacing.xs),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: VboxRadii.badge,
            ),
            child: Text(
              tag,
              style: TextStyle(
                fontSize: VboxTypography.s12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}