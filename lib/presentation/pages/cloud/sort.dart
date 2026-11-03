/// 网盘排序弹窗（批次 F · F-06，对齐 iOS UI 图 15）。
///
/// 对齐 iOS `CloudDriveSortPopup`（`vbox/Views/CloudDriveSortView.swift:3`）：
/// 标题「网盘排序」+ 副标题「长按拖动调整详情页网盘显示顺序」+ 右上关闭；
/// 可拖拽列表（**排除 Node 派生盘**，对齐 `CloudDriveSortManager.sortableOrder`）；
/// 底部「恢复默认」+「完成」胶囊按钮。
///
/// 顺序持久化契约键 `cloud_drive_sort_order_v1`（[CloudDriveSortStore]）。
library;

import 'package:flutter/material.dart';

import '../../../data/datasources/local/cloud_drive_sort_store.dart';
import '../../../data/datasources/local/prefs_manager.dart';
import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import 'cloud_drive_widgets.dart';

/// 网盘排序弹窗。
class CloudDriveSortPopup extends StatefulWidget {
  /// 构造（[store] 供测试注入；缺省走 [PrefsManager]）。
  const CloudDriveSortPopup({super.key, this.store});

  /// 顺序存储（null → 自建）。
  final CloudDriveSortStore? store;

  /// 以对话框方式弹出（对齐 iOS「我的」页宫格入口，见 ProfileView.swift:455）。
  static Future<void> show(BuildContext context, {CloudDriveSortStore? store}) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => CloudDriveSortPopup(store: store),
    );
  }

  @override
  State<CloudDriveSortPopup> createState() => _CloudDriveSortPopupState();
}

class _CloudDriveSortPopupState extends State<CloudDriveSortPopup> {
  late final CloudDriveSortStore _store;
  List<CloudDriveType> _order = const <CloudDriveType>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? CloudDriveSortStore(PrefsManager.instance);
    _load();
  }

  Future<void> _load() async {
    final List<CloudDriveType> order = await _store.sortableOrder();
    if (!mounted) return;
    setState(() {
      _order = order;
      _loading = false;
    });
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    await _store.move(oldIndex, newIndex);
    await _load();
  }

  Future<void> _reset() async {
    await _store.resetToDefault();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: VboxSpacing.xxl),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Material(
          color: scheme.surface,
          borderRadius: VboxRadii.panel,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(VboxSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _header(scheme),
                const SizedBox(height: VboxSpacing.md),
                Flexible(child: _list(scheme)),
                const SizedBox(height: VboxSpacing.md),
                _footer(scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '网盘排序',
                style: TextStyle(
                  fontSize: VboxTypography.s18,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: VboxSpacing.xs),
              Text(
                '长按拖动调整详情页网盘显示顺序',
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close),
          iconSize: VboxTypography.s16,
          color: scheme.onSurfaceVariant,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  Widget _list(ColorScheme scheme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(VboxSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 340),
      child: ReorderableListView.builder(
        shrinkWrap: true,
        buildDefaultDragHandles: true,
        itemCount: _order.length,
        onReorderItem: _onReorder,
        itemBuilder: (BuildContext context, int index) {
          final CloudDriveType type = _order[index];
          return Container(
            key: ValueKey<String>('cloud_sort_${type.id}'),
            padding: const EdgeInsets.symmetric(vertical: VboxSpacing.sm),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.drag_handle,
                  size: VboxTypography.s16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: VboxSpacing.sm),
                Icon(
                  cloudDriveIcon(type),
                  size: VboxTypography.s16,
                  color: VboxColors.selected,
                ),
                const SizedBox(width: VboxSpacing.sm),
                Expanded(
                  child: Text(
                    type.displayName,
                    style: TextStyle(
                      fontSize: VboxTypography.s14,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _footer(ColorScheme scheme) {
    return Row(
      children: <Widget>[
        TextButton(
          onPressed: _reset,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.sm),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            '恢复默认',
            style: TextStyle(
              fontSize: VboxTypography.s14,
              fontWeight: FontWeight.w500,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const Spacer(),
        Material(
          color: scheme.primary,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.of(context).maybePop(),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: VboxSpacing.lg,
                vertical: VboxSpacing.sm,
              ),
              child: Text(
                '完成',
                style: TextStyle(
                  fontSize: VboxTypography.s14,
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
