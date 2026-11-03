/// 网盘资源下载地址解析器（D-01 / F-P08~P12 下载侧复用）。
///
/// 对齐 iOS `DownloadManager.resolveCloudDriveURL`
/// （DownloadManager.swift L238-L256）：`sourceType == "cloud"` 的记录在
/// **下载执行时**经 `CloudDriveManager.resolvePlayURL` 解析真实直链——
/// 分享链携带的定位 token 有时效性（F-P26：Node 每次 detail 重签 playToken），
/// 入队时不解析、执行时才取链。
///
/// Flutter 复用播放链路同款解析：[VboxFragmentCodec] 剥离定位 fragment →
/// [VboxFragmentCodec.resolveShareType] 识别盘别（含 `vbox_nd=1` Node 派生映射）→
/// [PanPlayer.prepare] 按盘取链（内部含 F-P26 Node 三级稳定匹配）→
/// 返回直链 + 鉴权头（F-P12 headers 统一层随 prepare 产出）。
/// 网盘直链多为 m3u8（夸克 / UC / 百度 / Node），交由现有 m3u8 分片
/// 下载 + AES-128 解密执行层处理。
library;

import '../../domain/entities/cloud/cloud_drive.dart';
import '../../domain/entities/cloud/cloud_play_item.dart';
import '../../domain/entities/cloud/node_pan.dart';
import '../../domain/entities/cloud/vbox_fragment.dart';
import '../../data/models/download.dart';
import '../player/pan_player.dart';
import 'download_manager.dart';
import 'm3u8_parser.dart';

/// 网盘取链接缝（签名对齐 [PanPlayer.prepare] 的 resolver 侧子集）。
///
/// 生产默认走懒初始化的共享 [PanPlayer]；单测注入内存假件。
typedef CloudPlayPrepare = Future<CloudPlayItem> Function({
  required CloudDriveType type,
  required String shareUrl,
  required NodePanEntry entry,
  String? sourceKey,
});

PanPlayer? _sharedPan;

/// 默认取链实现（共享 PanPlayer 实例，避免每次解析重建客户端）。
Future<CloudPlayItem> _defaultCloudPlayPrepare({
  required CloudDriveType type,
  required String shareUrl,
  required NodePanEntry entry,
  String? sourceKey,
}) {
  return (_sharedPan ??= PanPlayer()).prepare(
    type: type,
    shareUrl: shareUrl,
    entry: entry,
    sourceKey: sourceKey,
  );
}

/// 网盘下载地址解析器（对齐 iOS `resolveCloudDriveURL`）。
class CloudDownloadUrlResolver implements DownloadUrlResolver {
  /// 构造（[prepare] 可注入，便于测试）。
  CloudDownloadUrlResolver({CloudPlayPrepare? prepare})
      : _prepare = prepare ?? _defaultCloudPlayPrepare;

  final CloudPlayPrepare _prepare;

  @override
  Future<ResolvedDownloadUrl> resolve(Download record) async {
    // 仅处理网盘记录；其余记录交回默认解析链（返回空串 = 不负责）。
    if (record.sourceType != 'cloud') {
      return const ResolvedDownloadUrl(
        url: '',
        headers: <String, String>{},
        type: DownloadType.unsupported,
      );
    }
    final String url = record.playurl;
    final VboxFragmentSplit split = VboxFragmentCodec.split(url);
    final CloudDriveType? type = VboxFragmentCodec.resolveShareType(url);
    final String playID = split.params.locateValue;
    if (type == null || playID.isEmpty) {
      return const ResolvedDownloadUrl(
        url: '',
        headers: <String, String>{},
        type: DownloadType.unsupported,
      );
    }
    try {
      // 执行时取链（对齐 iOS L238-L256）：prepare 内部完成 F-P26 三级
      // 匹配 + 各盘 resolve + headers 统一层；失败抛异常 → 下载失败态
      // （对齐 iOS resolve 异常 → unsupported）。
      final CloudPlayItem item = await _prepare(
        type: type,
        shareUrl: split.baseUrl,
        entry: NodePanEntry(playID: playID, name: record.name),
        sourceKey: 'dl_${record.id ?? 0}',
      );
      final String playUrl = item.playURL ?? '';
      if (playUrl.isEmpty) {
        return const ResolvedDownloadUrl(
          url: '',
          headers: <String, String>{},
          type: DownloadType.unsupported,
        );
      }
      return ResolvedDownloadUrl(
        url: playUrl,
        headers: item.headers,
        type: DownloadType.fromUrl(playUrl),
      );
    } catch (_) {
      return const ResolvedDownloadUrl(
        url: '',
        headers: <String, String>{},
        type: DownloadType.unsupported,
      );
    }
  }
}
