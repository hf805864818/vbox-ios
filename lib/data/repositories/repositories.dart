/// 数据层：仓储实现 barrel。
///
/// 领域层只依赖 `lib/domain/repositories/` 的接口；
/// 应用启动时（`lib/app.dart`）在此选择具体实现并注入用例层。
library;

export 'favorite_repository_impl.dart';
export 'history_repository_impl.dart';
export 'remote_source_repository_impl.dart';
export 'search_history_repository_impl.dart';
export 'subscription_repository_impl.dart';