/// 推送播放详情页（批次 G · G-03）。
///
/// 唯一真相源：iOS `PushPlayView.swift` `makeVodItem` + `fullScreenCover
/// VideoDetailView` 的**本地数据模式**（不经过网络详情加载）：
///   · 16:9 封面占位（主色渐变 + 类型图标，推送条目无图）；
///   · 标题 + 类型备注徽标（`☁️网盘` / `🎬 直链播放` / `🌐 网页解析`）；
///   · 剧集：已解析（episodes）→ 选集宫格，点击即播；未解析 → 单集直播；
///   · 播放：缺省进入全屏播放页 [PlayerPage]（Wave A · R-渲2；有剧集时页内宫格选播）；
///     网盘条目 → 「展开选集」进入 [CloudDriveFilesPage] 分享模式
///     （E-12 收敛：对齐 iOS 播放器 `handleDriveUrl`「打开网盘链接时展开选集」）。
///
/// 差异登记：
///   · iOS `VideoDetailView` 是通用详情页（支持本地 `VodItem`）；Flutter 既有
///     [DetailPage] 走站点 `loadDetail` 拉取，无法承载本地数据，故以本轻量页
///     承接（对齐 MDTV / 福利中转页的既有播放模式）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../../domain/entities/player/player.dart';
import '../../../domain/entities/push/push_play.dart';
import '../../../platform/player/pan_player.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../cloud/files.dart';
import '../player/player_page.dart';

/// 推送播放回调（url + 标题 → 打开并播放；测试注入）。
typedef PushPlayDetailHandler = Future<void> Function(String url, String title);

/// 网盘分享展开回调（网盘类型 + 分享链接；测试注入）。
typedef PushPlayCloudHandler = Future<void> Function(
  CloudDriveType type,
  String url,
);

/// 推送播放详情页（本地数据模式）。
class PushPlayDetailPage extends StatefulWidget {
  /// 构造（[onPlay] / [onOpenCloudFiles] 可注入，便于单测）。
  const PushPlayDetailPage({
    super.key,
    required this.item,
    this.onPlay,
    this.onOpenCloudFiles,
  });

  /// 推送链接条目。
  final PushPlayItem item;

  /// 播放回调（null → [PlayerController.instance]）。
  final PushPlayDetailHandler? onPlay;

  /// 网盘分享展开回调（null → 打开 [CloudDriveFilesPage] 分享模式；
  /// 对齐 iOS 播放器 `handleDriveUrl`「打开网盘链接时展开选集」）。
  final PushPlayCloudHandler? onOpenCloudFiles;

  @override
  State<PushPlayDetailPage> createState() => _PushPlayDetailPageState();
}

class _PushPlayDetailPageState extends State<PushPlayDetailPage> {
  PushPlayEpisode? _selected;

  List<PushPlayEpisode> get _episodes => widget.item.episodes ?? const <PushPlayEpisode>[];

  /// 网盘条目可识别的分享链接类型（null → 不可展开，回退直接播放）。
  ///
  /// 对齐 iOS 播放器 `handleDriveUrl`：打开网盘链接时展开选集。
  CloudDriveType? get _cloudType =>
      widget.item.type == PushPlayLinkType.cloud
          ? CloudDriveType.fromShareUrl(widget.item.url)
          : null;

  String get _remarks => switch (widget.item.type) {
        PushPlayLinkType.cloud => '☁️网盘 - ${widget.item.title}',
        PushPlayLinkType.direct => '🎬 直链播放',
        PushPlayLinkType.web => '🌐 网页解析',
      };

  @override
  void initState() {
    super.initState();
    _selected = _episodes.isEmpty ? null : _episodes.first;
  }

  Future<void> _play(String url, String title) async {
    final PushPlayDetailHandler? handler = widget.onPlay;
    if (handler != null) {
      await handler(url, title);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => PlayerPage(
          source: PlayerSource(url: url, title: title),
          title: title,
        ),
      ),
    );
  }

  void _playEpisode(PushPlayEpisode ep) {
    setState(() => _selected = ep);
    _play(ep.url, '${widget.item.title} ${ep.name}'.trim());
  }

  Future<void> _playSingle() => _play(widget.item.url, widget.item.title);

  /// 展开网盘分享选集（对齐 iOS 播放器 `handleDriveUrl` 打开网盘链接时展开选集）。
  ///
  /// 域名无法识别时回退直接播放（保持既有行为）。
  Future<void> _openCloudFiles() async {
    final CloudDriveType? type = _cloudType;
    if (type == null) {
      await _playSingle();
      return;
    }
    final PushPlayCloudHandler? handler = widget.onOpenCloudFiles;
    if (handler != null) {
      await handler(type, widget.item.url);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => CloudDriveFilesPage(
          driveType: type,
          shareUrl: widget.item.url,
          panPlayer: PanPlayer(),
        ),
      ),
    );
  }

  Future<void> _playCloud() async {
    final CloudDriveType? type = _cloudType;
    if (type == null) {
      await _playSingle();
    } else {
      await _openCloudFiles();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<PushPlayEpisode> episodes = _episodes;
    final bool hasEpisodes = episodes.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.only(
          top: VboxSpacing.xl,
          bottom: VboxSpacing.xxl,
        ),
        children: <Widget>[
          _cover(scheme),
          const SizedBox(height: VboxSpacing.lg),
          Padding(
            padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
            child: Text(
              widget.item.title,
              style: TextStyle(
                fontSize: VboxTypography.s18,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: VboxSpacing.sm),
          Padding(
            padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
            child: Row(
              children: <Widget>[
                Container(
                  padding: VboxSpacing.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(VboxRadii.r6),
                  ),
                  child: Text(
                    _remarks,
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      fontWeight: FontWeight.w500,
                      color: scheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: VboxSpacing.sm),
                Expanded(
                  child: Text(
                    widget.item.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: VboxSpacing.xl),
          if (hasEpisodes)
            _episodeGrid(scheme, episodes)
          else
            _singlePlayButton(scheme),
        ],
      ),
    );
  }

  // ─────────────── 封面占位（16:9，主色渐变 + 类型图标）───────────────

  Widget _cover(ColorScheme scheme) {
    return Padding(
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(VboxRadii.r12),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  scheme.primary.withValues(alpha: 0.85),
                  scheme.primary.withValues(alpha: 0.45),
                ],
              ),
            ),
            child: Center(
              child: Icon(
                _typeIcon(widget.item.type),
                size: 56,
                color: scheme.onPrimary.withValues(alpha: 0.9),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────── 选集宫格（对齐 iOS `VideoDetailView` 剧集宫格）───────────────

  Widget _episodeGrid(ColorScheme scheme, List<PushPlayEpisode> episodes) {
    return Padding(
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '剧集列表',
            style: TextStyle(
              fontSize: VboxTypography.s15,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: VboxSpacing.md),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: VboxSpacing.sm,
              crossAxisSpacing: VboxSpacing.sm,
              childAspectRatio: 2.4,
            ),
            itemCount: episodes.length,
            itemBuilder: (BuildContext context, int index) {
              final PushPlayEpisode ep = episodes[index];
              final bool selected = _selected?.url == ep.url;
              return Material(
                color: selected
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(VboxRadii.r8),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _playEpisode(ep),
                  child: Center(
                    child: Padding(
                      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.xs),
                      child: Text(
                        ep.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: VboxTypography.s13,
                          fontWeight: FontWeight.w500,
                          color: selected ? Colors.white : scheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: VboxSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                final PushPlayEpisode? ep = _selected;
                if (ep != null) _playEpisode(ep);
              },
              icon: const Icon(Icons.play_arrow_rounded, size: 22),
              label: Text(
                '播放${_selected?.name ?? ''}'.trim(),
                style: const TextStyle(
                  fontSize: VboxTypography.s16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────── 单集直播（未解析剧集；网盘条目改为「展开选集」）───────────────

  Widget _singlePlayButton(ColorScheme scheme) {
    final bool isCloud = _cloudType != null;
    return Padding(
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _playCloud,
          icon: Icon(
            isCloud ? Icons.folder_open : Icons.play_arrow_rounded,
            size: 22,
          ),
          label: Text(
            isCloud ? '展开选集' : '立即播放',
            style: const TextStyle(
              fontSize: VboxTypography.s16,
              fontWeight: FontWeight.w600,
            ),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    );
  }

  IconData _typeIcon(PushPlayLinkType type) => switch (type) {
        PushPlayLinkType.cloud => Icons.cloud,
        PushPlayLinkType.direct => Icons.play_circle_fill,
        PushPlayLinkType.web => Icons.language,
      };
}
