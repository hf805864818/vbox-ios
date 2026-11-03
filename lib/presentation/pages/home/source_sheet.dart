/// 切换源浮层（批次 D · D-01）。
///
/// 唯一真相源：iOS `MainViews.swift` L504-L606 `homeSourceDropdownOverlay`：
///   · 左上角**小竖长条浮层**（非底部弹窗）：宽 `屏宽*0.4`、最大高 `屏高*0.5`、
///     左上 padding `top:52 / leading:12`、圆角 12、阴影；
///   · 半透明黑 0.3 遮罩，点击空白关闭；
///   · 标题栏「切换源」+ 源数量胶囊徽标（底色 `#E11B48` 透明度 0.15）；
///   · 按分类分组（固定顺序：网盘 → API → 站源 → JS → 论坛），
///     组头 + 组内每行（选中态 checkmark + 高亮色）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/spider/spider.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/remote_source/remote_source_status_bar.dart';
import 'source_picker_page.dart';

/// 源分组固定顺序（对齐 iOS `homeGroupedSources` 的 `order`）。
const List<String> _groupOrder = <String>['网盘', 'API', '站源', 'JS', '论坛'];

/// 弹出切换源浮层，返回选中的站点 key（取消返回 null）。
///
/// 形态对齐 iOS `homeSourceDropdownOverlay`：左上角悬浮小竖长条。
Future<String?> showVboxSourceSheet(
  BuildContext context, {
  required List<SiteConfig> sites,
  String? selectedKey,
}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '切换源',
    barrierColor: Colors.black.withValues(alpha: 0.3),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (BuildContext context, _, __) => _SourceOverlay(
      sites: sites,
      selectedKey: selectedKey,
    ),
    transitionBuilder: (
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
    ) {
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 52, left: 12),
          child: FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOut,
            ),
            child: child,
          ),
        ),
      );
    },
  );
}

/// 源分组条目（对齐 iOS `homeGroupedSources`）。
class _SourceGroup {
  const _SourceGroup(this.title, this.items);

  final String title;
  final List<SiteConfig> items;
}

/// 推导站点分类（对齐 iOS `SourceDisplayItem.category.displayName`）。
String _categoryOf(SiteConfig site) => site.categoryLabel;

/// 按分类分组（固定顺序，对齐 iOS `homeGroupedSources`）。
List<_SourceGroup> _groupSites(List<SiteConfig> sites) {
  final Map<String, List<SiteConfig>> grouped = <String, List<SiteConfig>>{};
  for (final SiteConfig site in sites) {
    grouped.putIfAbsent(_categoryOf(site), () => <SiteConfig>[]).add(site);
  }
  return <_SourceGroup>[
    for (final String key in _groupOrder)
      if ((grouped[key] ?? const <SiteConfig>[]).isNotEmpty)
        _SourceGroup(key, grouped[key]!),
  ];
}

/// 左上角悬浮小竖长条（对齐 iOS `homeSourceDropdownOverlay` 主体）。
class _SourceOverlay extends StatelessWidget {
  const _SourceOverlay({required this.sites, this.selectedKey});

  final List<SiteConfig> sites;
  final String? selectedKey;

  /// 高亮 / 徽标强调色（对齐 iOS `Color(hex: "E11B48")`）。
  static const Color _accent = VboxColors.skinPrimaryRose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Size screen = MediaQuery.sizeOf(context);
    final List<_SourceGroup> groups = _groupSites(sites);

    return SizedBox(
      width: screen.width * 0.4,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: screen.height * 0.5),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(12),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          // Material 仅作 InkWell 的水波纹宿主（透明，视觉仍由外层 Container 决定）。
          child: Material(
            type: MaterialType.transparency,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _buildHeader(context),
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                  Flexible(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      children: <Widget>[
                        for (final _SourceGroup group in groups) ...<Widget>[
                          _buildGroupHeader(context, group),
                          for (int i = 0;
                              i < group.items.length;
                              i++) ...<Widget>[
                            _buildRow(context, group.items[i]),
                            if (i < group.items.length - 1)
                              Divider(
                                height: 1,
                                thickness: 1,
                                indent: 38,
                                color: scheme.outlineVariant
                                    .withValues(alpha: 0.5),
                              ),
                          ],
                        ],
                        // E2-6：「全部源」次级入口 → 备用全屏选择源页
                        // （浮层保留为主形态，全屏页为备用形态）。
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: scheme.outlineVariant.withValues(alpha: 0.5),
                        ),
                        _buildAllSourcesEntry(context),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 标题栏（对齐 iOS「切换源」+ 数量胶囊）。
  Widget _buildHeader(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: <Widget>[
          Text(
            '切换源',
            style: TextStyle(
              fontSize: VboxTypography.s13,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const Spacer(),
          _CountBadge(count: sites.length, accent: _accent),
        ],
      ),
    );
  }

  /// 「全部源」次级入口（E2-6：→ 备用全屏选择源页；选中 key 透传回浮层）。
  Widget _buildAllSourcesEntry(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () async {
        final String? key = await showVboxSourcePickerPage(
          context,
          sites: sites,
          selectedKey: selectedKey,
        );
        if (key != null && context.mounted) {
          Navigator.of(context).pop(key);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.apps,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '全部源',
                style: TextStyle(
                  fontSize: VboxTypography.s13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// 分组标题（对齐 iOS 组头）。
  Widget _buildGroupHeader(BuildContext context, _SourceGroup group) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(
        children: <Widget>[
          Text(
            group.title,
            style: TextStyle(
              fontSize: VboxTypography.s11,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const Spacer(),
          _CountBadge(
              count: group.items.length, accent: _accent, compact: true),
        ],
      ),
    );
  }

  /// 源行（对齐 iOS 选中 checkmark + 高亮色）。
  Widget _buildRow(BuildContext context, SiteConfig site) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool selected = site.key == selectedKey;
    final String name = site.name.isEmpty ? site.key : site.name;
    // E5-3 Semantics 补点：切源条目（状态透传 selected）。
    return Semantics(
      button: true,
      selected: selected,
      label: '切换到源 $name',
      child: InkWell(
        onTap: () => Navigator.of(context).pop(site.key),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 16,
                child: selected
                    ? const Icon(Icons.check, size: 12, color: _accent)
                    : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                // E2-5：源名超宽 → 跑马灯（对齐 iOS `HomeSourceMarqueeText`）；
                // 未超宽保持静态省略号。
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final TextStyle style = TextStyle(
                      fontSize: VboxTypography.s14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? _accent : scheme.onSurface,
                    );
                    final TextPainter painter = TextPainter(
                      text: TextSpan(text: name, style: style),
                      maxLines: 1,
                      textDirection: Directionality.of(context),
                    )..layout();
                    final bool overflows = painter.width > constraints.maxWidth;
                    painter.dispose();
                    if (!overflows) {
                      return Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      );
                    }
                    return MarqueeText(
                      text: name,
                      maxWidth: constraints.maxWidth,
                      fontSize: VboxTypography.s14,
                      color: selected ? _accent : scheme.onSurface,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 数量徽标（对齐 iOS 标题栏 / 组头的 count 胶囊）。
class _CountBadge extends StatelessWidget {
  const _CountBadge({
    required this.count,
    required this.accent,
    this.compact = false,
  });

  final int count;
  final Color accent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5)
          : const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(VboxRadii.capsule),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: compact ? VboxTypography.s11 : VboxTypography.s11,
          fontWeight: FontWeight.w500,
          color: accent,
        ),
      ),
    );
  }
}
