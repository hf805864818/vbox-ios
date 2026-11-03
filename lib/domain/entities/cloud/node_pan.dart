/// 网盘播放（pan 模式）领域模型（批次 F · F-08）。
///
/// 对齐 iOS（唯一契约来源）`vbox/Services/NodePanResolver.swift`：
/// - A1 接缝：Node 常驻系统解析分享链接
///   `POST /spider/push/4/detail`（分享 → 文件列表）
///   `POST /spider/push/4/play`（条目 → 播放地址）
/// - `vod_play_url` 形态 `名$<base64id>#名$<base64id>`（多播放组以 `$$$` 分隔，
///   仅取第一组主播放源）；`<base64id>` 解码出 `{providerId,shareId,fileId,name,…}`
///   取其 `name` 作展示名。
/// - Node 托管盘集合（对齐 iOS `resolvePlayURL` 的 Node 分支）：
///   115 / 123 / 139 / 189 / 迅雷 / 光鸭 / 蜗牛 / 夸克Node / UC网盘Node / 百度网盘Node。
library;

import 'dart:convert';

import 'cloud_drive.dart';

/// Node 常驻系统网盘解析挂载前缀（对齐 iOS `NodePanResolver`）。
abstract final class NodePanPaths {
  /// 分享链接 → 可播放条目列表。
  static const String detail = '/spider/push/4/detail';

  /// 条目 → 播放地址。
  static const String play = '/spider/push/4/play';
}

/// push spider detail 返回的单条可播放条目（对齐 iOS `NodePanEntry`）。
class NodePanEntry {
  /// 构造。
  const NodePanEntry({required this.playID, required this.name});

  /// base64 编码的 `{providerId,shareId,fileId,name,playToken,mode}`。
  final String playID;

  /// 展示文件名。
  final String name;
}

/// 分享链接解析结果（对齐 iOS `NodePanShareResult`）。
class NodePanShare {
  /// 构造。
  const NodePanShare({required this.title, required this.entries});

  /// 资源标题（`vod_name`，缺省「网盘资源」）。
  final String title;

  /// 可播放条目。
  final List<NodePanEntry> entries;
}

/// play 返回的播放信息（对齐 iOS `NodePanPlayResult`）。
class NodePanPlayData {
  /// 构造。
  const NodePanPlayData({
    required this.url,
    this.headers = const <String, String>{},
    this.format,
  });

  /// 播放地址（直链或 Node `/proxy` 绝对地址）。
  final String url;

  /// 请求头。
  final Map<String, String> headers;

  /// 容器格式（如 `m3u8`）。
  final String? format;
}

/// Node 解析失败原因（对齐 iOS `NodePanError`）。
enum NodePanErrorKind {
  /// Node 常驻系统未就绪 / 连接失败。
  nodeUnavailable,

  /// 分享链接格式无法识别。
  invalidShareURL,

  /// Node 侧返回的业务错误。
  nodeRejected,
}

/// Node 网盘解析异常。
class NodePanException implements Exception {
  /// 构造。
  const NodePanException(this.kind, [this.message = '']);

  /// 缺省「未就绪」异常（对齐 iOS `.nodeUnavailable`）。
  ///
  /// [message] 可选：附 Node 运行时管理的失败详情（如端口顶包的可操作文案），
  /// 展示时拼入 displayMessage，避免「重启电脑/结束进程」的指引被通用文案吞掉；
  /// 缺省保持 iOS 同口径文案。
  const NodePanException.nodeUnavailable([this.message = ''])
      : kind = NodePanErrorKind.nodeUnavailable;

  /// 原因。
  final NodePanErrorKind kind;

  /// 详情（业务错误时为 Node 侧文案）。
  final String message;

  /// 展示文案（逐档对齐 iOS `errorDescription`；`nodeUnavailable` 有详情时
  /// 拼接运行时管理给出的失败原因，指引可操作）。
  String get displayMessage => switch (kind) {
        NodePanErrorKind.nodeUnavailable => message.isEmpty
            ? 'Node 常驻系统未就绪，请稍后重试'
            : 'Node 常驻系统未就绪——$message',
        NodePanErrorKind.invalidShareURL => '无法识别的分享链接',
        NodePanErrorKind.nodeRejected =>
          message.isEmpty ? '网盘解析失败' : message,
      };

  @override
  String toString() => 'NodePanException(${kind.name}: $displayMessage)';
}

/// Node 托管盘判定与路由（对齐 iOS `resolvePlayURL` 的分支）。
abstract final class NodePanRouting {
  /// Node 托管盘（走 `/spider/push/4/detail` → `/play`）。
  static const Set<CloudDriveType> managedProviders = <CloudDriveType>{
    CloudDriveType.one15,
    CloudDriveType.pan123,
    CloudDriveType.pan139,
    CloudDriveType.pan189,
    CloudDriveType.xunlei,
    CloudDriveType.guangya,
    CloudDriveType.woniu4k,
    CloudDriveType.quarkNode,
    CloudDriveType.ucNode,
    CloudDriveType.baiduNode,
  };

  /// 是否 Node 托管盘。
  static bool isNodeManaged(CloudDriveType type) =>
      managedProviders.contains(type);
}

/// `vod_play_url` 解析（对齐 iOS `NodePanResolver.parsePlayURL`）。
abstract final class NodePanParser {
  /// 解析 `名$id#名$id`（多播放组 `$$$` 仅取第一组）。
  static List<NodePanEntry> parsePlayUrl(String raw) {
    if (raw.isEmpty) return const <NodePanEntry>[];
    final String primary = raw.split(r'$$$').first;
    final List<NodePanEntry> entries = <NodePanEntry>[];
    for (final String seg in primary.split('#')) {
      final List<String> parts = seg.split(r'$');
      if (parts.length < 2) continue;
      final String playID = parts.last;
      if (playID.isEmpty) continue;
      final String name = decodeName(playID) ??
          (parts.first.isEmpty ? '视频' : parts.first);
      entries.add(NodePanEntry(playID: playID, name: name));
    }
    return entries;
  }

  /// base64 JSON `{…,name}` → name（失败返回 null）。
  static String? decodeName(String playID) {
    try {
      final List<int> bytes = base64.decode(playID);
      final Object? obj = jsonDecode(utf8.decode(bytes));
      if (obj is! Map) return null;
      final Object? name = obj['name'];
      if (name is! String || name.isEmpty) return null;
      return name;
    } catch (_) {
      return null;
    }
  }
}
