/// 推送播放页（批次 G · G-03）。
///
/// 唯一真相源：iOS `vbox/Views/PushPlayView.swift`
///   · 空态：类型图标 + 「暂无推送链接」+ 引导文案 + 「添加链接」按钮；
///   · 列表卡片：类型图标（50×50 主色 15% 底圆角 10）+ 标题 / URL /
///     类型徽标 + 集数 + 右侧播放按钮；滑动 / 长按删除
///     （对齐 iOS `swipeActions` + `contextMenu`）；
///   · 编辑模式：左上「全选」/ 右上「完成」，底部「删除选中 (n)」
///     （对齐 iOS `bottomBar`）；
///   · 更多菜单：批量删除 / 清空全部（清空带确认弹窗）；
///   · 添加 sheet（[PushPlayAddSheet]）：类型三段选择 + 标题（可选）+
///     URL 多行输入 + 自动识别 + 示例说明 + 校验（对齐 iOS `AddPushPlayLinkView`）。
///
/// 播放：点击播放 → [PushPlayDetailPage]（对齐 iOS `makeVodItem` +
/// `fullScreenCover VideoDetailView` 的本地数据模式）。
library;

import 'package:flutter/material.dart';

import '../../../data/datasources/local/push_play_store.dart';
import '../../../domain/entities/push/push_play.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import 'push_play_detail_page.dart';

/// 推送播放播放回调（url + 标题 → 打开并播放；测试注入）。
typedef PushPlayHandler = Future<void> Function(String url, String title);

/// 推送播放页。
class PushPlayPage extends StatefulWidget {
  /// 构造（[store] / [onPlay] 可注入，便于单测）。
  const PushPlayPage({super.key, this.store, this.onPlay});

  /// 存储（null → [PushPlayStore.shared]）。
  final PushPlayStore? store;

  /// 播放回调（null → 缺省进 [PushPlayDetailPage]）。
  final PushPlayHandler? onPlay;

  @override
  State<PushPlayPage> createState() => _PushPlayPageState();
}

class _PushPlayPageState extends State<PushPlayPage> {
  late final PushPlayStore _store;
  bool _editMode = false;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? PushPlayStore.shared;
    _store.load();
  }

  PushPlayStore get _resolvedStore => _store;

  // ─────────────── 编辑操作（对齐 iOS）───────────────

  void _enterEditMode() {
    setState(() {
      _editMode = true;
      _selected.clear();
    });
  }

  void _exitEditMode() {
    setState(() {
      _editMode = false;
      _selected.clear();
    });
  }

  void _toggleSelection(PushPlayItem item) {
    setState(() {
      if (_selected.contains(item.id)) {
        _selected.remove(item.id);
      } else {
        _selected.add(item.id);
      }
    });
  }

  void _toggleSelectAll(List<PushPlayItem> items) {
    setState(() {
      if (_selected.length == items.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(items.map((PushPlayItem e) => e.id));
      }
    });
  }

  void _deleteSelected() {
    for (final PushPlayItem item in _resolvedStore.items) {
      if (_selected.contains(item.id)) {
        _resolvedStore.removeItem(item);
      }
    }
    _selected.clear();
    if (_resolvedStore.items.isEmpty) {
      _editMode = false;
    }
    setState(() {});
  }

  Future<void> _confirmClearAll() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('确认清空'),
        content: Text('确定要清空所有 ${_resolvedStore.items.length} 条推送链接吗？此操作不可撤销。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      _resolvedStore.removeAll();
      if (_editMode) {
        setState(() {
          _editMode = false;
          _selected.clear();
        });
      }
    }
  }

  // ─────────────── 播放（对齐 iOS `playItem` → `makeVodItem`）───────────────

  /// 打开添加链接 sheet（对齐 iOS `showAddSheet` → `AddPushPlayLinkView`）。
  Future<void> _openAddSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext _) => PushPlayAddSheet(store: _resolvedStore),
    );
  }

  Future<void> _playItem(PushPlayItem item) async {
    final PushPlayHandler? handler = widget.onPlay;
    if (handler != null) {
      await handler(item.url, item.title);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => PushPlayDetailPage(item: item),
      ),
    );
  }

  // ─────────────── 构建 ───────────────

  @override
  Widget build(BuildContext context) {
    // 监听 store：添加 / 删除 / 清空后 UI 自动刷新（对齐 iOS `@StateObject`
    // 自动重建；Flutter 以 ListenableBuilder 承接）。
    return ListenableBuilder(
      listenable: _resolvedStore,
      builder: (BuildContext context, Widget? child) {
        final ColorScheme scheme = Theme.of(context).colorScheme;
        final List<PushPlayItem> items = _resolvedStore.items;

        return Scaffold(
      appBar: AppBar(
        title: const Text('推送播放'),
        centerTitle: true,
        leading: _editMode
            ? TextButton(
                onPressed: () => _toggleSelectAll(items),
                child: Text(
                  '全选',
                  style: TextStyle(fontSize: VboxTypography.s15, color: scheme.primary),
                ),
              )
            : TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  '关闭',
                  style: TextStyle(fontSize: VboxTypography.s15, color: scheme.primary),
                ),
              ),
        actions: <Widget>[
          if (items.isNotEmpty) ...<Widget>[
            if (_editMode)
              TextButton(
                onPressed: _exitEditMode,
                child: Text(
                  '完成',
                  style: TextStyle(fontSize: VboxTypography.s15, color: scheme.primary),
                ),
              )
            else
              PopupMenuButton<String>(
                icon: Icon(Icons.more_horiz, color: scheme.primary),
                onSelected: (String value) {
                  if (value == 'batch') {
                    _enterEditMode();
                  } else if (value == 'clear') {
                    _confirmClearAll();
                  }
                },
                itemBuilder: (BuildContext ctx) => const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'batch',
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.check_circle_outline, size: 18),
                        SizedBox(width: VboxSpacing.sm),
                        Text('批量删除'),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'clear',
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.delete_outline, size: 18),
                        SizedBox(width: VboxSpacing.sm),
                        Text('清空全部'),
                      ],
                    ),
                  ),
                ],
              ),
          ],
          if (!_editMode)
            IconButton(
              tooltip: '添加链接',
              onPressed: _openAddSheet,
              icon: Icon(Icons.add_circle, size: 24, color: scheme.primary),
            ),
        ],
      ),
      body: items.isEmpty ? _emptyState(scheme) : _listView(items, scheme),
      bottomNavigationBar: _editMode
          ? SafeArea(
              child: Padding(
                padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg, vertical: VboxSpacing.sm),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _selected.isEmpty ? null : _deleteSelected,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text('删除选中 (${_selected.length})'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _selected.isEmpty
                          ? scheme.onSurfaceVariant
                          : scheme.error,
                      disabledForegroundColor: scheme.onSurfaceVariant,
                      textStyle: const TextStyle(
                        fontSize: VboxTypography.s15,
                        fontWeight: FontWeight.w600,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
            )
          : null,
        );
      },
    );
  }

  // ─────────────── 空态（对齐 iOS `emptyStateView`）───────────────

  Widget _emptyState(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.play_circle_outline,
            size: 60,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: VboxSpacing.xl),
          Text(
            '暂无推送链接',
            style: TextStyle(
              fontSize: VboxTypography.s18,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: VboxSpacing.sm),
          Text(
            '点击右上角 + 添加网盘或播放链接',
            style: TextStyle(
              fontSize: VboxTypography.s14,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: VboxSpacing.xl),
          FilledButton.icon(
            onPressed: _openAddSheet,
            icon: const Icon(Icons.add_circle, size: 18),
            label: const Text('添加链接'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              textStyle: const TextStyle(
                fontSize: VboxTypography.s16,
                fontWeight: FontWeight.w600,
              ),
              padding: VboxSpacing.symmetric(horizontal: VboxSpacing.xl, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────── 列表（对齐 iOS `listView`）───────────────

  Widget _listView(List<PushPlayItem> items, ColorScheme scheme) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        VboxSpacing.lg,
        VboxSpacing.md,
        VboxSpacing.lg,
        VboxSpacing.xxl,
      ),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final PushPlayItem item = items[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: VboxSpacing.md),
          child: _editMode
              ? _editItemCard(item, scheme)
              : Dismissible(
                  key: ValueKey<String>('push-${item.id}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
                    decoration: BoxDecoration(
                      color: scheme.error,
                      borderRadius: BorderRadius.circular(VboxRadii.r12),
                    ),
                    child: Icon(Icons.delete_outline, color: scheme.onError),
                  ),
                  onDismissed: (_) => _resolvedStore.removeItem(item),
                  child: _itemCard(item, scheme),
                ),
        );
      },
    );
  }

  // ─────────────── 普通卡片（对齐 iOS `itemCard`）───────────────

  Widget _itemCard(PushPlayItem item, ColorScheme scheme) {
    final List<PushPlayEpisode>? episodes = item.episodes;
    return GestureDetector(
      onLongPress: () => _confirmRemoveOne(item),
      child: Container(
        padding: const EdgeInsets.all(VboxSpacing.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(VboxRadii.r12),
        ),
        child: Row(
          children: <Widget>[
            _typeIconBox(scheme, item.type, 50),
            const SizedBox(width: VboxSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s15,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Container(
                        padding: VboxSpacing.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          item.type.displayName,
                          style: TextStyle(
                            fontSize: VboxTypography.s11,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                      if (episodes != null && episodes.isNotEmpty) ...<Widget>[
                        const SizedBox(width: VboxSpacing.sm),
                        Text(
                          '${episodes.length} 集',
                          style: TextStyle(
                            fontSize: VboxTypography.s11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: VboxSpacing.sm),
            IconButton(
              tooltip: '播放',
              iconSize: 32,
              onPressed: () => _playItem(item),
              icon: Icon(Icons.play_circle_fill, color: scheme.primary),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────── 编辑模式卡片（对齐 iOS `editItemCard`）───────────────

  Widget _editItemCard(PushPlayItem item, ColorScheme scheme) {
    final bool isSelected = _selected.contains(item.id);
    return GestureDetector(
      onTap: () => _toggleSelection(item),
      child: Container(
        padding: const EdgeInsets.all(VboxSpacing.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(VboxRadii.r12),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              isSelected ? Icons.check_circle : Icons.circle_outlined,
              size: 22,
              color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: VboxSpacing.md),
            _typeIconBox(scheme, item.type, 44),
            const SizedBox(width: VboxSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s14,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.type.displayName,
                    style: TextStyle(
                      fontSize: VboxTypography.s11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 类型图标容器（对齐 iOS `RoundedRectangle(10) 50×50` 主色 15% 底）。
  Widget _typeIconBox(ColorScheme scheme, PushPlayLinkType type, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(VboxRadii.r10),
      ),
      child: Icon(
        _typeIcon(type),
        size: size * 0.44,
        color: scheme.primary,
      ),
    );
  }

  IconData _typeIcon(PushPlayLinkType type) => switch (type) {
        PushPlayLinkType.cloud => Icons.cloud,
        PushPlayLinkType.direct => Icons.play_circle_fill,
        PushPlayLinkType.web => Icons.language,
      };

  /// 长按删除确认（对齐 iOS `contextMenu` 删除）。
  Future<void> _confirmRemoveOne(PushPlayItem item) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除推送链接'),
        content: Text('确定删除「${item.title}」吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      _resolvedStore.removeItem(item);
    }
  }
}

/// 添加推送链接 sheet（对齐 iOS `AddPushPlayLinkView`）。
///
/// 类型三段选择（网盘 / 直链 / 网页解析）+ 标题（可选）+ URL 多行输入 +
/// 「自动识别类型」按钮 + 支持格式示例 + 校验错误提示 + 取消 / 添加。
class PushPlayAddSheet extends StatefulWidget {
  /// 构造。
  const PushPlayAddSheet({super.key, required this.store});

  /// 存储（添加成功后回调）。
  final PushPlayStore store;

  @override
  State<PushPlayAddSheet> createState() => _PushPlayAddSheetState();
}

class _PushPlayAddSheetState extends State<PushPlayAddSheet> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _url = TextEditingController();
  PushPlayLinkType _selectedType = PushPlayLinkType.cloud;
  bool _showError = false;
  String _errorMessage = '';

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    super.dispose();
  }

  /// 自动识别类型（对齐 iOS `autoDetectType`）。
  void _autoDetectType() {
    final String url = _url.text.trim();
    if (url.isEmpty) return;
    setState(() => _selectedType = PushPlayStore.detectType(url));
  }

  /// 保存并关闭（对齐 iOS `saveAndDismiss`：校验 → 入存储 → dismiss）。
  void _saveAndDismiss() {
    final String url = _url.text.trim();
    final String title = _title.text.trim();

    if (url.isEmpty) {
      setState(() {
        _errorMessage = '请输入链接地址';
        _showError = true;
      });
      return;
    }

    if (Uri.tryParse(url) == null) {
      setState(() {
        _errorMessage = '链接格式不正确';
        _showError = true;
      });
      return;
    }

    widget.store.addItem(title: title, url: url, type: _selectedType);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: VboxSpacing.lg,
          right: VboxSpacing.lg,
          top: VboxSpacing.sm,
          bottom: VboxSpacing.xxl +
              MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 头部提示（对齐 iOS `info.circle.fill`）。
            Row(
              children: <Widget>[
                Icon(Icons.info_outline, size: 16, color: scheme.primary),
                const SizedBox(width: VboxSpacing.xs),
                Expanded(
                  child: Text(
                    '支持网盘链接、直链播放地址、网页视频地址',
                    style: TextStyle(
                      fontSize: VboxTypography.s13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: VboxSpacing.lg),

            // 链接类型选择（对齐 iOS 三段 chips）。
            Text(
              '链接类型',
              style: TextStyle(
                fontSize: VboxTypography.s14,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: VboxSpacing.sm),
            Row(
              children: <Widget>[
                for (final PushPlayLinkType type in PushPlayLinkType.values)
                  _typeChip(scheme, type),
              ],
            ),
            const SizedBox(height: VboxSpacing.lg),

            // 标题输入（可选）。
            Text(
              '标题（可选）',
              style: TextStyle(
                fontSize: VboxTypography.s14,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: VboxSpacing.sm),
            TextField(
              controller: _title,
              decoration: InputDecoration(
                hintText: '自动识别，可自定义',
                hintStyle: TextStyle(
                  fontSize: VboxTypography.s15,
                  color: scheme.onSurfaceVariant,
                ),
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(VboxRadii.r10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: VboxSpacing.lg,
                  vertical: VboxSpacing.md,
                ),
              ),
              style: TextStyle(
                fontSize: VboxTypography.s15,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: VboxSpacing.lg),

            // URL 输入。
            Text(
              '链接地址',
              style: TextStyle(
                fontSize: VboxTypography.s14,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: VboxSpacing.sm),
            TextField(
              controller: _url,
              maxLines: 4,
              minLines: 3,
              decoration: InputDecoration(
                hintText: '粘贴网盘或视频链接',
                hintStyle: TextStyle(
                  fontSize: VboxTypography.s14,
                  color: scheme.onSurfaceVariant,
                ),
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(VboxRadii.r10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(VboxSpacing.md),
              ),
              style: TextStyle(
                fontSize: VboxTypography.s14,
                color: scheme.onSurface,
              ),
            ),
            if (_showError) ...<Widget>[
              const SizedBox(height: VboxSpacing.sm),
              Text(
                _errorMessage,
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.error,
                ),
              ),
            ],

            // 自动识别按钮（对齐 iOS `wand.and.stars`）。
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _autoDetectType,
                icon: const Icon(Icons.auto_fix_high, size: 16),
                label: const Text('自动识别类型'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.primary,
                  textStyle: const TextStyle(fontSize: VboxTypography.s13),
                ),
              ),
            ),

            // 快捷示例。
            Text(
              '支持格式示例：',
              style: TextStyle(
                fontSize: VboxTypography.s12,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '• 网盘：阿里云盘、夸克、百度网盘、115等分享链接',
              style: TextStyle(
                fontSize: VboxTypography.s11,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '• 直链：.m3u8 / .mp4 / .flv 等视频地址',
              style: TextStyle(
                fontSize: VboxTypography.s11,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '• 网页：视频详情页URL（将自动解析）',
              style: TextStyle(
                fontSize: VboxTypography.s11,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: VboxSpacing.lg),

            // 底部操作：取消 / 添加（对齐 iOS toolbar）。
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: VboxSpacing.md),
                Expanded(
                  child: FilledButton(
                    onPressed: _saveAndDismiss,
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                    ),
                    child: const Text('添加'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 类型选择 chip（对齐 iOS `selectedType == type` 高亮）。
  Widget _typeChip(ColorScheme scheme, PushPlayLinkType type) {
    final bool selected = _selectedType == type;
    return Padding(
      padding: const EdgeInsets.only(right: VboxSpacing.sm),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.20)
            : scheme.onSurface.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(VboxRadii.r8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _selectedType = type),
          child: Padding(
            padding: VboxSpacing.symmetric(
              horizontal: VboxSpacing.md,
              vertical: 8,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  _chipIcon(type),
                  size: 12,
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
                const SizedBox(width: 4),
                Text(
                  type.displayName,
                  style: TextStyle(
                    fontSize: VboxTypography.s13,
                    color: selected ? scheme.primary : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _chipIcon(PushPlayLinkType type) => switch (type) {
        PushPlayLinkType.cloud => Icons.cloud,
        PushPlayLinkType.direct => Icons.play_circle_fill,
        PushPlayLinkType.web => Icons.language,
      };
}
