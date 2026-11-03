/// 豆瓣浏览页共享组件（批次 D · D-03）。
///
/// 跨三页（首页 / 榜单 / 分类）复用的海报卡与空态 / 错误态，避免三处重复实现。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/douban/douban_models.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../theme/vbox_haptics.dart';
import '../../widgets/fall_in_card.dart';
import '../../widgets/platform_async_image.dart';
import '../../widgets/skeleton_shimmer.dart';
import '../../widgets/vbox/vbox.dart';

/// 评分文案（无评分 → null）。
String? doubanRatingText(DoubanSubject subject) =>
    subject.hasRating ? subject.rating.toStringAsFixed(1) : null;

/// 副标题文案（年份 · 类型，均空 → null）。
String? doubanSubtitle(DoubanSubject subject) {
  final String text = <String?>[
    subject.year,
    if (subject.genreText.isNotEmpty) subject.genreText,
  ].whereType<String>().join(' · ');
  return text.isEmpty ? null : text;
}

/// 豆瓣条目海报卡（封面 + 标题 + 评分角标 + 副标题）。
class DoubanSubjectCard extends StatelessWidget {
  /// 构造。
  const DoubanSubjectCard({
    super.key,
    required this.subject,
    this.width = 120,
    this.onTap,
  });

  final DoubanSubject subject;
  final double width;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return VboxPosterCard(
      title: subject.title,
      imageUrl: subject.coverUrl,
      subtitle: doubanSubtitle(subject),
      rating: doubanRatingText(subject),
      width: width,
      onTap: onTap,
    );
  }
}

/// 空态提示。
class DoubanEmptyHint extends StatelessWidget {
  /// 构造。
  const DoubanEmptyHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      ),
    );
  }
}

/// 加载失败提示 + 重试。
class DoubanErrorRetry extends StatelessWidget {
  /// 构造。
  const DoubanErrorRetry(
      {super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: VboxSpacing.md),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: VboxSpacing.md),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// 豆瓣区块标题（左图标 + 标题 + 右侧 chevron）。
///
/// 对齐 iOS `MainViews.swift SectionHeader`（L1312-L1331）：`Label(title, icon)`
/// 加粗 16 + 尾部 chevron。SF Symbol 映射到 Material 图标由调用方传入 [icon]。
class DoubanSectionHeader extends StatelessWidget {
  /// 构造。
  const DoubanSectionHeader(
      {super.key, required this.title, required this.icon});

  /// 标题。
  final String title;

  /// 左侧图标。
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(
        left: VboxSpacing.lg,
        right: VboxSpacing.lg,
        top: VboxSpacing.md,
        bottom: VboxSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: VboxTypography.s16, color: scheme.onSurface),
          const SizedBox(width: VboxSpacing.xs),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: VboxTypography.s16,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ),
          Icon(Icons.chevron_right,
              size: VboxTypography.s12, color: scheme.outline),
        ],
      ),
    );
  }
}

/// 豆瓣横向海报行（左右滑动「跳动」动效）。
///
/// 对齐 iOS `DoubanHomeView.swift HorizontalSubjectRow` + `SubjectCard`
/// （L460-L623）：
///   · 卡片滚到屏幕中心时放大（`1.0 → 0.85`，中心最近最大），对齐 `targetScale`；
///   · 首次进入时自上方「掉落」回弹（`easeOutBack`，逐卡错峰 delay），对齐
///     `fallDelay` + `hasAppeared`。
class DoubanSubjectRow extends StatefulWidget {
  /// 构造。
  const DoubanSubjectRow({super.key, required this.items, this.onTap});

  /// 条目（横向顺序）。
  final List<DoubanSubject> items;

  /// 点击回调（对齐 iOS 触发搜索）。
  final void Function(DoubanSubject subject)? onTap;

  /// 卡片宽（对齐 iOS `frame(width: 120)`）。
  static const double cardWidth = 120;

  /// 卡片间距（对齐 iOS `spacing: 12`）。
  static const double cardSpacing = 12;

  /// 行高（对齐 iOS `frame(width: 120, height: 210)`）。
  static const double rowHeight = 210;

  @override
  State<DoubanSubjectRow> createState() => _DoubanSubjectRowState();
}

class _DoubanSubjectRowState extends State<DoubanSubjectRow> {
  /// 距屏幕中心 100pt 内开始缩放（对齐 iOS `maxDist = 100`）。
  static const double _maxDist = 100;

  final ScrollController _controller = ScrollController();
  double _offset = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted) return;
    setState(() => _offset = _controller.offset);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: DoubanSubjectRow.rowHeight,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double viewportCenter = constraints.maxWidth / 2;
          const double extent =
              DoubanSubjectRow.cardWidth + DoubanSubjectRow.cardSpacing;
          return ListView.separated(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
            itemCount: widget.items.length,
            separatorBuilder: (BuildContext context, int index) =>
                const SizedBox(width: DoubanSubjectRow.cardSpacing),
            itemBuilder: (BuildContext context, int index) {
              final double center = VboxSpacing.lg +
                  index * extent +
                  DoubanSubjectRow.cardWidth / 2 -
                  _offset;
              final double normalized =
                  ((center - viewportCenter).abs() / _maxDist).clamp(0.0, 1.0);
              final double scale = 1.0 - normalized * 0.15;
              final DoubanSubject subject = widget.items[index];
              return FallInCard(
                delay: index * 0.08,
                child: AnimatedScale(
                  scale: scale,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  child: _SubjectRowCard(
                    subject: subject,
                    onTap: () => widget.onTap?.call(subject),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 首页横向行的豆瓣卡片（对齐 iOS `SubjectCard`）。
///
/// 与 [DoubanSubjectCard] 的区别：iOS 首页卡片为**固定封面 120×160**（非 2:3），
/// 且**只有标题 + 右上角评分角标**（无副标题）；整卡限高 210（对齐
/// `DoubanHomeView.swift SubjectCard` L509-L547）。
class _SubjectRowCard extends StatelessWidget {
  const _SubjectRowCard({required this.subject, this.onTap});

  final DoubanSubject subject;
  final VoidCallback? onTap;

  /// 封面尺寸（对齐 iOS `frame(width: 120, height: 160)`）。
  static const double _coverWidth = 120;
  static const double _coverHeight = 160;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? rating = doubanRatingText(subject);
    return SizedBox(
      width: _coverWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          GestureDetector(
            onTap: () {
              // UI-B1 触感反馈：对齐 iOS `SubjectCard.hapticGenerator.selectionChanged()`。
              VboxHaptics.selection();
              onTap?.call();
            },
            child: SizedBox(
              width: _coverWidth,
              height: _coverHeight,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: PlatformAsyncImage(
                      url: subject.coverUrl,
                      fit: BoxFit.cover,
                      // UI-B3 骨架屏动效：静态占位 → 渐变扫光（保留影片图标，见 golden 像素契约）。
                      placeholder: ShimmerBox(
                        color: scheme.surfaceContainerHighest,
                        child: Center(
                          child: Icon(
                            Icons.movie_outlined,
                            size: VboxTypography.s24,
                            color: Colors.white.withValues(alpha: 0.40),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (rating != null)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const Icon(Icons.star,
                                size: 8, color: Colors.yellow),
                            const SizedBox(width: 2),
                            Text(
                              rating,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Colors.yellow,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subject.title,
            maxLines: 1,
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
