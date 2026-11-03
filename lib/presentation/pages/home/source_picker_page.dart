/// 备用全屏「选择源」页（批次 E · E2-6）。
///
/// 唯一真相源：iOS `SourcePickerSheet.swift:5-105`（搜索框 + 分类分组 +
/// 类型徽标源行）。形态裁定（方案 E2-6）：首页切换源以小竖长条浮层为主形态
/// （对齐 `homeSourceDropdownOverlay`，见 `showVboxSourceSheet`），本页为
/// 浮层底部「全部源」次级入口的备用全屏形态。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/spider/spider.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/typography.dart';

/// 源分组固定顺序（对齐 iOS `SourcePickerSheet.groupedSources` 的 `order`）。
const List<String> _groupOrder = <String>['网盘', 'API', '站源', 'JS', '论坛'];

/// 推入备用全屏「选择源」页，返回选中的站点 key（取消返回 null）。
Future<String?> showVboxSourcePickerPage(
  BuildContext context, {
  required List<SiteConfig> sites,
  String? selectedKey,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      builder: (BuildContext context) => SourcePickerPage(
        sites: sites,
        selectedKey: selectedKey,
      ),
    ),
  );
}

/// 备用全屏「选择源」页。
class SourcePickerPage extends StatefulWidget {
  /// 构造。
  const SourcePickerPage({
    super.key,
    required this.sites,
    this.selectedKey,
  });

  /// 全部可选源。
  final List<SiteConfig> sites;

  /// 当前选中 key。
  final String? selectedKey;

  @override
  State<SourcePickerPage> createState() => _SourcePickerPageState();
}

class _SourcePickerPageState extends State<SourcePickerPage> {
  final TextEditingController _search = TextEditingController();

  String _keyword = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 过滤（对齐 iOS `filteredSources`：名称大小写不敏感包含）。
  List<SiteConfig> get _filtered {
    final String kw = _keyword.trim().toLowerCase();
    if (kw.isEmpty) return widget.sites;
    return widget.sites
        .where((SiteConfig s) =>
            (s.name.isEmpty ? s.key : s.name).toLowerCase().contains(kw))
        .toList();
  }

  /// 分组（对齐 iOS `groupedSources` 固定顺序，空组剔除）。
  Map<String, List<SiteConfig>> get _grouped {
    final Map<String, List<SiteConfig>> byCat = <String, List<SiteConfig>>{};
    for (final SiteConfig s in _filtered) {
      byCat.putIfAbsent(s.categoryLabel, () => <SiteConfig>[]).add(s);
    }
    return <String, List<SiteConfig>>{
      for (final String key in _groupOrder)
        if ((byCat[key] ?? const <SiteConfig>[]).isNotEmpty) key: byCat[key]!,
    };
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Map<String, List<SiteConfig>> groups = _grouped;

    return Scaffold(
      appBar: AppBar(title: const Text('选择源')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildSearchField(context),
          Expanded(
            child: groups.isEmpty
                ? Center(
                    child: Text(
                      '未找到匹配的源',
                      style: TextStyle(
                        fontSize: VboxTypography.s14,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView(
                    children: <Widget>[
                      for (final MapEntry<String, List<SiteConfig>> group
                          in groups.entries) ...<Widget>[
                        _buildGroupHeader(context, group.key, group.value),
                        for (final SiteConfig site in group.value)
                          _buildRow(context, site),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 搜索框（对齐 iOS L34-L54：放大镜 + 输入 + 清除按钮，圆角 10 灰底）。
  Widget _buildSearchField(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '搜索源...',
                  border: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 15),
                onChanged: (String v) => setState(() => _keyword = v),
              ),
            ),
            if (_keyword.isNotEmpty)
              GestureDetector(
                onTap: () {
                  _search.clear();
                  setState(() => _keyword = '');
                },
                child: Icon(Icons.cancel,
                    size: 18, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }

  /// 分组标题（对齐 iOS L77-L90：组名 + N 个，组背景色）。
  Widget _buildGroupHeader(
      BuildContext context, String title, List<SiteConfig> items) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            '${items.length} 个',
            style: TextStyle(
              fontSize: VboxTypography.s12,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 源行（对齐 iOS `SourceRow` L109-L178：类型图标底 + 名称 + 分类胶囊 +
  /// 选中 checkmark）。
  Widget _buildRow(BuildContext context, SiteConfig site) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool selected = site.key == widget.selectedKey;
    final String name = site.name.isEmpty ? site.key : site.name;
    final (Color categoryColor, IconData categoryIcon) =
        _categoryVisual(site.categoryLabel);

    return InkWell(
      onTap: () => Navigator.of(context).pop(site.key),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            // 类型图标（36×36 圆角 8，分类色 0.15 底）。
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: categoryColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(categoryIcon, size: 14, color: categoryColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s15,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: categoryColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(VboxRadii.capsule),
                    ),
                    child: Text(
                      site.categoryLabel,
                      style: TextStyle(
                          fontSize: VboxTypography.s11, color: categoryColor),
                    ),
                  ),
                ],
              ),
            ),
            if (selected) Icon(Icons.check, size: 16, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

/// 分类视觉（对齐 iOS `categoryColor` / `categoryIcon`；Flutter 侧无音乐
/// 分类来源，登记省略音乐项）。
(Color, IconData) _categoryVisual(String category) {
  const Map<String, Color> palette = VboxColors.siteCategoryBadgeColors;
  return switch (category) {
    '网盘' => (palette['网盘']!, Icons.cloud),
    'API' => (palette['API']!, Icons.settings_input_antenna),
    '站源' => (palette['站源']!, Icons.link),
    'JS' => (palette['JS']!, Icons.settings),
    '论坛' => (palette['论坛']!, Icons.forum),
    _ => (palette['API']!, Icons.settings_input_antenna),
  };
}
