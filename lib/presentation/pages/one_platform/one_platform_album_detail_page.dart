/// One 平台（YBox）专辑详情页（批次 G · G-05）。
///
/// 对齐 iOS `OneAlbumDetailView`：顶部信息（100×150 封面 + 标题 / 评分 /
/// 章数 / 简介）+ 分隔线 + 4 列章节目录网格（付费章节橙色标注）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/one_platform/one_platform.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import 'one_platform_controller.dart';
import 'one_platform_widgets.dart';

/// 专辑详情页（章节目录）。
class OnePlatformAlbumDetailPage extends StatefulWidget {
  /// 构造。
  const OnePlatformAlbumDetailPage({
    super.key,
    required this.album,
    required this.controller,
  });

  /// 专辑条目。
  final OneAlbum album;

  /// 控制器。
  final OnePlatformController controller;

  @override
  State<OnePlatformAlbumDetailPage> createState() =>
      _OnePlatformAlbumDetailPageState();
}

class _OnePlatformAlbumDetailPageState
    extends State<OnePlatformAlbumDetailPage> {
  List<OneChapter> _chapters = const <OneChapter>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final List<OneChapter> result =
        await widget.controller.fetchChapters(widget.album.albumId);
    if (!mounted) return;
    setState(() {
      _chapters = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final OneAlbum album = widget.album;
    return Scaffold(
      appBar: AppBar(title: const Text('专辑详情')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: VboxSpacing.xxl),
        children: <Widget>[
          Padding(
            padding: VboxSpacing.symmetric(
                horizontal: VboxSpacing.lg, vertical: VboxSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(VboxRadii.r8),
                  child: SizedBox(
                    width: 100,
                    height: 150,
                    child: album.cover.isEmpty
                        ? Container(color: scheme.surfaceContainerHighest)
                        : PlatformAsyncImage(
                            url: widget.controller.imageURL(album.cover),
                            fit: BoxFit.cover,
                            placeholderColor: scheme.surfaceContainerHighest,
                            placeholder: const SizedBox.shrink(),
                          ),
                  ),
                ),
                const SizedBox(width: VboxSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        album.title,
                        style: TextStyle(
                          fontSize: VboxTypography.s16,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      if (album.rating != null && album.rating!.isNotEmpty) ...<Widget>[
                        const SizedBox(height: VboxSpacing.compact),
                        Text(
                          '评分: ${album.rating}',
                          style: const TextStyle(
                            fontSize: VboxTypography.s13,
                            color: Colors.orange,
                          ),
                        ),
                      ],
                      const SizedBox(height: VboxSpacing.compact),
                      Text(
                        '共 ${album.itemCount} 章',
                        style: TextStyle(
                          fontSize: VboxTypography.s12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (album.description.isNotEmpty) ...<Widget>[
                        const SizedBox(height: VboxSpacing.compact),
                        Text(
                          album.description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: VboxTypography.s12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: VboxSpacing.symmetric(
                horizontal: VboxSpacing.lg, vertical: VboxSpacing.md),
            child: Text(
              '章节目录',
              style: TextStyle(
                fontSize: VboxTypography.s15,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: VboxSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_chapters.isEmpty)
            const OneEmptyHint(text: '暂无章节')
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: VboxSpacing.sm,
                crossAxisSpacing: VboxSpacing.sm,
                childAspectRatio: 2.4,
              ),
              itemCount: _chapters.length,
              itemBuilder: (BuildContext context, int index) {
                final OneChapter chap = _chapters[index];
                return Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(VboxRadii.r6),
                  ),
                  padding: VboxSpacing.symmetric(vertical: VboxSpacing.sm),
                  child: Text(
                    chap.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      color: chap.isPaid ? Colors.orange : scheme.onSurface,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}