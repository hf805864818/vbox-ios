/// 输入适配层导出（批次 A · A-09）。
///
/// 唯一真相源：`docs/第2轮开发计划_功能补全_v2.6.md` §3.4（输入适配层）。
/// 四件套：焦点环 [FocusRing]（遥控）· 悬停 [HoverAffordance]（鼠标）·
/// 快捷键 [InputShortcuts]（键盘）· 十英尺缩放 [TenFootScaler]（TV）。
/// 原则：**只加反馈层，不改版式**；全部依赖 `UiFormController.modality` 门控。
library;

export 'focus_ring.dart';
export 'hover_affordance.dart';
export 'input_shortcuts.dart';
export 'ten_foot_scaler.dart';