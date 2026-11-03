/// TG 频道管理页（批次 G · G-04）。
///
/// 唯一真相源：iOS `vbox/Views/TGChannelListView.swift`
///   · 空态（L14-L21）—— 「暂无自定义频道」居中提示；
///   · 自定义频道分组（L23-L46）—— 标题「自定义频道（N 个）」+ 拖动把手 + 名称/ID；
///   · 快捷添加（L50-L79）—— 「快捷添加常用频道」2 列网格，已添加项禁用；
///   · 添加 Sheet（L119-L182）—— 频道名称 + 频道 ID + 说明 + 取消/添加。
///
/// 规格（照 iOS 实测）：行名称 15pt medium · 频道 ID 12pt secondary ·
/// 分组标题 13pt semibold secondary · 空态 14pt secondary · 输入框 15pt；
/// 输入框 / 快捷按钮圆角 8，分组容器圆角 16。
///
/// 差异登记：iOS 由系统 `EditButton` 提供「编辑态（红色减号 + 拖动把手）」；
/// Flutter 以 AppBar actions 的「编辑/完成」切换（编辑态显示删除按钮 +
/// 拖动把手），非编辑态支持左滑删除；编辑按钮由 iOS 的 leading 移至 actions
/// （Flutter `AppBar` 的 leading 被返回键占用），交互能力等价。
library;

import 'package:flutter/material.dart';

import '../../../data/datasources/local/tg_search_config_store.dart';
import '../../../domain/entities/tg/tg_channel.dart';
import '../../theme/theme.dart';

/// TG 频道管理页。
class TGChannelListPage extends StatefulWidget {
  /// 构造（[store] 可注入；为 null 时消费全局单例，便于单测）。
  const TGChannelListPage({super.key, this.store});

  /// 配置存储（可注入）。
  final TGSearchConfigStore? store;

  @override
  State<TGChannelListPage> createState() => _TGChannelListPageState();
}

class _TGChannelListPageState extends State<TGChannelListPage> {
  bool _editing = false;

  TGSearchConfigStore get _store => widget.store ?? TGSearchConfigStore.shared;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (BuildContext context, Widget? _) => _scaffold(context),
    );
  }

  Widget _scaffold(BuildContext context) {
    final bool hasChannels = _store.channels.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('TG频道管理'),
        actions: <Widget>[
          TextButton(
            onPressed: hasChannels ? () => setState(() => _editing = !_editing) : null,
            child: Text(_editing ? '完成' : '编辑'),
          ),
          IconButton(
            tooltip: '添加频道',
            icon: const Icon(Icons.add),
            onPressed: () => showTgAddChannelSheet(context, store: _store),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(
          top: VboxSpacing.lg,
          bottom: VboxSpacing.xxxl,
        ),
        children: <Widget>[
          if (hasChannels) ...<Widget>[
            _sectionTitle('自定义频道（${_store.channels.length} 个）'),
            _channelGroup(context),
          ] else
            _emptyHint(context),
          _sectionTitle('快捷添加常用频道'),
          _presetGrid(context),
        ],
      ),
    );
  }

  /// 分组标题（13pt semibold secondary，对齐设置页分组标题）。
  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(
        left: VboxSpacing.lg + VboxSpacing.xs,
        right: VboxSpacing.lg,
        top: VboxSpacing.sm,
        bottom: VboxSpacing.sm,
      ),
      child: Text(
        title,
        style: TextStyle(
          fontSize: VboxTypography.s13,
          fontWeight: FontWeight.w600,
          color: _palette(context).secondary,
        ),
      ),
    );
  }

  /// 空态（对齐 iOS：居中 · 14pt secondary · 垂直留白 20）。
  Widget _emptyHint(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.lg,
        vertical: VboxSpacing.xl,
      ),
      child: Text(
        '暂无自定义频道',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: VboxTypography.s14,
          color: _palette(context).secondary,
        ),
      ),
    );
  }

  /// 自定义频道分组（圆角容器 + 可拖动排序 + 删除）。
  Widget _channelGroup(BuildContext context) {
    final List<TGChannel> channels = _store.channels;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
      child: ClipRRect(
        borderRadius: VboxRadii.chip,
        child: ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: channels.length,
          // `onReorderItem` 已自动处理「移除后插入」的 newIndex 偏移
          // （对齐 Flutter 3.41+ 弃用 `onReorder` 的迁移口径），直接透传。
          onReorderItem: (int oldIndex, int newIndex) =>
              _store.moveChannel(from: oldIndex, to: newIndex),
          itemBuilder: (BuildContext context, int index) =>
              _channelRow(context, channels[index], index),
        ),
      ),
    );
  }

  /// 频道行（编辑态：删除按钮 + 拖动把手；非编辑态：左滑删除）。
  Widget _channelRow(BuildContext context, TGChannel channel, int index) {
    final _TgPalette p = _palette(context);
    final Widget content = Container(
      color: p.rowBackground,
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.lg,
        vertical: VboxSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          if (_editing) ...<Widget>[
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: VboxSpacing.xxl,
                minHeight: VboxSpacing.xxl,
              ),
              icon: const Icon(Icons.remove_circle, color: VboxColors.danger),
              onPressed: () => _store.removeChannelAt(index),
            ),
            const SizedBox(width: VboxSpacing.sm),
          ] else ...<Widget>[
            Icon(
              Icons.drag_indicator,
              size: VboxTypography.s18,
              color: p.secondary,
            ),
            const SizedBox(width: VboxSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  channel.name,
                  style: TextStyle(
                    fontSize: VboxTypography.s15,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  channel.channelId,
                  style: TextStyle(
                    fontSize: VboxTypography.s12,
                    color: p.secondary,
                  ),
                ),
              ],
            ),
          ),
          if (_editing)
            ReorderableDragStartListener(
              index: index,
              child: Icon(
                Icons.drag_handle,
                size: VboxTypography.s18,
                color: p.secondary,
              ),
            ),
        ],
      ),
    );

    // 非编辑态：左滑删除（对齐 iOS `onDelete` 滑动删除）。
    return Dismissible(
      key: ValueKey<String>(channel.channelId),
      direction:
          _editing ? DismissDirection.none : DismissDirection.endToStart,
      onDismissed: (DismissDirection _) => _store.removeChannelAt(index),
      background: Container(
        color: VboxColors.danger,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: VboxSpacing.lg),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      child: content,
    );
  }

  /// 快捷添加常用频道（2 列网格；已添加项禁用）。
  Widget _presetGrid(BuildContext context) {
    final _TgPalette p = _palette(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
      child: ClipRRect(
        borderRadius: VboxRadii.chip,
        child: Container(
          color: p.rowBackground,
          padding: const EdgeInsets.all(VboxSpacing.md),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: TGChannel.presetChannels.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: VboxSpacing.sm,
              crossAxisSpacing: VboxSpacing.sm,
              mainAxisExtent: 40,
            ),
            itemBuilder: (BuildContext context, int index) {
              final TGChannel preset = TGChannel.presetChannels[index];
              final bool added = _store.containsChannel(preset.channelId);
              return _presetButton(context, preset, added);
            },
          ),
        ),
      ),
    );
  }

  /// 预置频道按钮（加号 + 名称；已添加项降透明度并禁用）。
  Widget _presetButton(BuildContext context, TGChannel preset, bool added) {
    final Color primary = Theme.of(context).colorScheme.primary;
    return Opacity(
      opacity: added ? 0.45 : 1,
      child: Material(
        color: _palette(context).tertiary,
        borderRadius: VboxRadii.button,
        child: InkWell(
          borderRadius: VboxRadii.button,
          onTap: added
              ? null
              : () => _store.addChannel(
                    name: preset.name,
                    channelId: preset.channelId,
                  ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.add_circle, size: VboxTypography.s13, color: primary),
              const SizedBox(width: VboxSpacing.xs),
              Flexible(
                child: Text(
                  preset.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s13,
                    fontWeight: FontWeight.w500,
                    color: primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _TgPalette _palette(BuildContext context) => _TgPalette.of(context);
}

/// 添加频道 Sheet（对齐 iOS `AddChannelSheet`）。
Future<void> showTgAddChannelSheet(
  BuildContext context, {
  required TGSearchConfigStore store,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext _) => AddTgChannelSheet(store: store),
  );
}

/// 添加频道弹窗内容。
class AddTgChannelSheet extends StatefulWidget {
  /// 构造。
  const AddTgChannelSheet({super.key, required this.store});

  /// 配置存储。
  final TGSearchConfigStore store;

  @override
  State<AddTgChannelSheet> createState() => _AddTgChannelSheetState();
}

class _AddTgChannelSheetState extends State<AddTgChannelSheet> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _channelId = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 频道 ID 输入联动「添加」按钮可用态。
    _channelId.addListener(_onChanged);
  }

  @override
  void dispose() {
    _channelId.removeListener(_onChanged);
    _name.dispose();
    _channelId.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  bool get _canSubmit => _channelId.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final _TgPalette p = _TgPalette.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          VboxSpacing.xl,
          VboxSpacing.none,
          VboxSpacing.xl,
          VboxSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(context),
            const SizedBox(height: VboxSpacing.xxl),
            _field(
              context,
              label: '频道名称',
              hint: '如：UC夸克资源',
              controller: _name,
            ),
            const SizedBox(height: VboxSpacing.lg),
            _field(
              context,
              label: '频道 ID',
              hint: '如：ucquark',
              controller: _channelId,
            ),
            const SizedBox(height: VboxSpacing.sm),
            Text(
              '频道 ID 是 t.me/s/ 后面的名称，不含 @ 符号',
              style: TextStyle(
                fontSize: VboxTypography.s11,
                color: p.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部：取消 · 添加频道 · 添加（对齐 iOS toolbar 布局）。
  Widget _header(BuildContext context) {
    return Row(
      children: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        Expanded(
          child: Text(
            '添加频道',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: VboxTypography.s16,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        TextButton(
          onPressed: _canSubmit
              ? () {
                  widget.store.addChannel(
                    name: _name.text,
                    channelId: _channelId.text,
                  );
                  Navigator.of(context).pop();
                }
              : null,
          child: const Text('添加'),
        ),
      ],
    );
  }

  /// 表单字段（标签 13pt medium secondary + 输入框 15pt · 圆角 8 · tertiary 底）。
  Widget _field(
    BuildContext context, {
    required String label,
    required String hint,
    required TextEditingController controller,
  }) {
    final _TgPalette p = _TgPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: VboxTypography.s13,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: VboxSpacing.sm),
        TextField(
          controller: controller,
          autocorrect: false,
          textCapitalization: TextCapitalization.none,
          style: TextStyle(
            fontSize: VboxTypography.s15,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: p.tertiary,
            hintText: hint,
            hintStyle: TextStyle(fontSize: VboxTypography.s15, color: p.secondary),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: VboxSpacing.md,
              vertical: VboxSpacing.md,
            ),
            border: const OutlineInputBorder(
              borderRadius: VboxRadii.button,
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }
}

/// TG 页面配色（行底 / 三级底 / 次级文字）。
class _TgPalette {
  const _TgPalette({
    required this.rowBackground,
    required this.tertiary,
    required this.secondary,
  });

  /// 行底（`secondarySystemGroupedBackground` @70%，对齐设置页行底）。
  final Color rowBackground;

  /// 三级底（`tertiarySystemGroupedBackground`，输入框 / 快捷按钮底）。
  final Color tertiary;

  /// 次级文字（`.secondaryLabel`）。
  final Color secondary;

  static _TgPalette of(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return _TgPalette(
      rowBackground: (isDark
              ? VboxColors.secondarySystemGroupedBackgroundDark
              : VboxColors.secondarySystemGroupedBackgroundLight)
          .withValues(alpha: 0.7),
      tertiary: isDark
          ? VboxColors.tertiarySystemGroupedBackgroundDark
          : VboxColors.tertiarySystemGroupedBackgroundLight,
      secondary:
          isDark ? VboxColors.secondaryLabelDark : VboxColors.secondaryLabelLight,
    );
  }
}