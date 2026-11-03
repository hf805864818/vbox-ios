/// 表现层：福利重播桥（批次 H 续段 · W-福2）。
///
/// 唯一真相源：iOS `vbox/Views/ProfileView.swift`
///   · `WelfareHistoryItem`（L9-L15）：福利记录携带的平台定位信息
///     （`platformKey` 从记录的 `detailua` 读取）；
///   · `WelfareBridgeContainer`（L18-L54）：按 `platformKey` 重建 Service
///     并直达视频详情；平台下线 → 明确「该福利平台已下线或不可用」提示；
///   · 分流判定（L392 / L1269 / L1445）：
///     `record.laiyuan.hasPrefix("[福利]") && !record.detailua.isEmpty`。
///
/// Flutter 侧福利平台记录在收藏 / 观看记录中 `laiyuan` 前缀 `[福利]`、
/// `detailua` 存 `platformKey`；点击时本桥从配置重建服务直达详情，
/// **不经过**通用详情页（不影响普通站点 / 网盘 / 短剧等既有链路）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../domain/entities/welfare/welfare.dart';
import 'welfare_platform_controller.dart';
import 'welfare_platform_router.dart';

/// 福利记录来源前缀（对齐 iOS `[福利]` 标记）。
const String welfareRecordPrefix = '[福利]';

/// 判断是否为福利记录（对齐 iOS：`laiyuan` 前缀 `[福利]` 且 `detailua` 非空）。
///
/// `detailua` 承载 `platformKey`；为空说明记录未携带平台定位信息，
/// 无法重建服务 → 不视为可重播的福利条目。
bool isWelfareReplayRecord({
  required String laiyuan,
  required String detailua,
}) =>
    laiyuan.startsWith(welfareRecordPrefix) && detailua.trim().isNotEmpty;

/// 打开福利重播桥：按记录的平台定位（`platformKey`，存于 `detailua`）
/// 重建 Service 并直达视频详情（对齐 iOS `WelfareBridgeContainer`）。
///
/// 返回 `true` 表示已成功进入播放中转页；平台已下线 / 未支持 / 页面未落地
/// → 提示「该福利平台已下线或不可用」并返回 `false`（**不兜底**）。
Future<bool> openWelfareReplayBridge(
  BuildContext context, {
  required String platformKey,
  required String vodId,
  required String vodName,
  required String vodPic,
}) async {
  final WelfarePlatform? platform = _findPlatform(context, platformKey);
  final Widget? view = platform == null
      ? null
      : WelfarePlatformRouter().makeVideoBridgeView(
          platform: platform,
          vodId: vodId,
          vodName: vodName,
          vodPic: vodPic,
        );
  if (view == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该福利平台已下线或不可用')),
      );
    }
    return false;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (BuildContext _) => view),
  );
  return true;
}

/// 从福利平台配置中按 `platformKey` 定位平台（缺失返回 `null`）。
WelfarePlatform? _findPlatform(BuildContext context, String platformKey) {
  final String key = platformKey.trim();
  if (key.isEmpty) return null;
  final WelfarePlatformController controller =
      context.read<WelfarePlatformController>();
  for (final WelfarePlatform p
      in controller.config?.platforms ?? const <WelfarePlatform>[]) {
    if (p.platformKey == key) return p;
  }
  return null;
}