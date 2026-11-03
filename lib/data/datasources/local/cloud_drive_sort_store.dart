/// 数据层：网盘排序持久化（批次 F · F-06）。
///
/// 对齐 iOS `CloudDriveSortManager`（`vbox/Services/CloudDriveSortManager.swift`）：
/// - 存储键 **`cloud_drive_sort_order_v1`**（契约 `storage: userdefaults`，类型 string）
/// - `defaultOrder` / `sortableOrder`（排除 Node 派生盘）/ 归一化补全缺失项
/// - iOS 侧以 `String[]` 落 UserDefaults；Flutter 端按契约类型 `string`
///   存 JSON 数组字符串（[PrefsManager.setJsonList]）
library;

import '../../../domain/entities/cloud/cloud_drive.dart';
import 'prefs_manager.dart';

/// 网盘显示顺序存储。
class CloudDriveSortStore {
  /// 构造（注入契约偏好管理器）。
  CloudDriveSortStore(this._prefs);

  final PrefsManager _prefs;

  /// 契约存储键（`prefs_keys_v1.json` → `_group_cloud`）。
  static const String storageKey = 'cloud_drive_sort_order_v1';

  /// 完整显示顺序（含 Node 派生盘；对齐 iOS `displayOrder`）。
  Future<List<CloudDriveType>> order() async {
    final List<dynamic> saved = await _prefs.getJsonList(storageKey);
    final List<CloudDriveType> parsed = <CloudDriveType>[];
    for (final dynamic id in saved) {
      final CloudDriveType? type = CloudDriveType.fromId(id?.toString());
      if (type != null && !parsed.contains(type)) {
        parsed.add(type);
      }
    }
    // 对齐 iOS `normalizedOrder()`：无已存顺序时基底为 `defaultOrder`，
    // 而非枚举声明序（否则首启展示顺序与 iOS 不一致）。
    final List<CloudDriveType> base =
        parsed.isEmpty ? CloudDriveType.defaultSortOrder : parsed;
    return _normalize(base);
  }

  /// 弹窗可排序列表（排除 Node 派生盘；对齐 iOS `sortableOrder`）。
  Future<List<CloudDriveType>> sortableOrder() async {
    final List<CloudDriveType> full = await order();
    return full.where((CloudDriveType t) => !t.isNodeDerived).toList();
  }

  /// 拖拽重排（索引语义对齐 Flutter `ReorderableListView.onReorderItem`
  /// —— 向下拖时 `newIndex` 已按「移除 oldIndex 项后」校正，与 iOS
  /// `IndexSet.move` 语义一致，本方法不再二次校正）。
  Future<void> move(int oldIndex, int newIndex) async {
    final List<CloudDriveType> current = await sortableOrder();
    if (oldIndex < 0 || oldIndex >= current.length) return;
    final CloudDriveType item = current.removeAt(oldIndex);
    current.insert(newIndex.clamp(0, current.length), item);
    await _save(current);
  }

  /// 恢复默认顺序（对齐 iOS `resetToDefault`）。
  Future<void> resetToDefault() async =>
      _save(CloudDriveType.defaultSortOrder);

  /// 某网盘的显示位次（未登记返回列表长度，语义 = 排最后）。
  Future<int> orderIndex(CloudDriveType type) async {
    final List<CloudDriveType> list = await order();
    final int index = list.indexOf(type);
    return index < 0 ? list.length : index;
  }

  /// 顺序是否已偏离默认（弹窗可据此提示/禁用「恢复默认」）。
  Future<bool> isCustomized() async {
    final List<CloudDriveType> current = await order();
    final List<CloudDriveType> defaults = _normalize(
      CloudDriveType.defaultSortOrder,
    );
    if (current.length != defaults.length) return true;
    for (int i = 0; i < current.length; i++) {
      if (current[i] != defaults[i]) return true;
    }
    return false;
  }

  Future<void> _save(List<CloudDriveType> types) async {
    final List<CloudDriveType> normalized = _normalize(types);
    await _prefs.setJsonList(
      storageKey,
      normalized.map((CloudDriveType t) => t.id).toList(),
    );
  }

  /// 归一化（对齐 iOS `normalize`）：去重 → 按枚举声明顺序补全缺失项。
  List<CloudDriveType> _normalize(List<CloudDriveType> types) {
    final List<CloudDriveType> out = <CloudDriveType>[];
    for (final CloudDriveType type in types) {
      if (!out.contains(type)) out.add(type);
    }
    for (final CloudDriveType type in CloudDriveType.values) {
      if (!out.contains(type)) out.add(type);
    }
    return out;
  }
}
