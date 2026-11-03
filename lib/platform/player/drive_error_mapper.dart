/// 网盘播放错误集中映射层（F-P14）。
///
/// 各盘异质异常（[DriveError] / [PanPlayException] / [NodePanException]）在此
/// 归一为**统一展示文案**，供 [CloudDriveFilesController]（文件列表 / 分享解析 /
/// 取链）与详情页（展开线路 / 取链播放）等消费点复用，消除「同一失败在两处
/// 文案漂移」的既有问题（此前 `detail_page` 仅特判 [PanPlayException]，其余
/// 异常直接 `'$e'` 透出调试串）。
///
/// 各来源的 iOS 真相源：
/// - [DriveError] → 播放站点档 [DriveError.playbackMessage]（`PlayerViewsV2.swift:3669-3679`）；
/// - [PanPlayException] 携带分档时同上，否则直出 [PanPlayException.message]；
/// - [NodePanException] → iOS `NodePanError.errorDescription`（逐档已对齐，
///   [NodePanException.displayMessage] 即其文案）。
library;

import '../../domain/entities/cloud/node_pan.dart';
import 'drive_error.dart';
import 'pan_player.dart';

/// 集中映射层。
abstract final class DriveErrorMapper {
  /// 任意异常 → 统一展示文案。
  static String messageOf(Object error) {
    if (error is DriveError) return error.playbackMessage;
    if (error is PanPlayException) {
      return error.driveError?.playbackMessage ?? error.message;
    }
    if (error is NodePanException) return error.displayMessage;
    return '$error';
  }
}