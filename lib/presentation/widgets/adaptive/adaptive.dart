/// 自适应框架导出（批次 A · A-07）。
///
/// 唯一真相源：`docs/第2轮开发计划_功能补全_v2.6.md` §3.3（布局适配模型）。
/// 四件套：[AdaptiveScaffold]（TabBar↔Rail）· [ResponsiveGrid]（列数）·
/// [ContentPanel]（分栏）· [AdaptiveDialog]（锚点）。
/// 全部**只消费令牌层与统一组件库**，以满足 UI 守卫 R-2 / R-3 / R-4。
library;

export 'adaptive_dialog.dart';
export 'adaptive_scaffold.dart';
export 'content_panel.dart';
export 'responsive_grid.dart';