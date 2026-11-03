/// 平台层：media_kit / libmpv 起播调优档（对齐 iOS `PlaybackProfile`）。
///
/// 按源类型下发 demuxer 缓存 / 预读参数，复刻 uzVideo 逆向得到的起播调优基线：
/// 大容器增大 readahead 提升边播边下体验，直播 / HLS 压低起播延迟。
library;

import '../../domain/entities/player/player.dart';

/// media_kit 起播调优参数。
class MediaKitProfile {
  const MediaKitProfile({
    required this.demuxerMaxBytes,
    required this.demuxerReadaheadSecs,
  });

  /// libmpv `demuxer-max-bytes`：起播 / 边播边下缓存大小（字节）。
  final int demuxerMaxBytes;

  /// libmpv `demuxer-readahead-secs`：预读秒数。
  final double demuxerReadaheadSecs;

  /// 常规点播（默认）。
  static const MediaKitProfile onDemand = MediaKitProfile(
    demuxerMaxBytes: 64 * 1024 * 1024,
    demuxerReadaheadSecs: 60,
  );

  /// 大容器（MKV/TS/AVI/蓝光等复杂封装）—— 增大缓存与预读。
  static const MediaKitProfile largeContainer = MediaKitProfile(
    demuxerMaxBytes: 256 * 1024 * 1024,
    demuxerReadaheadSecs: 120,
  );

  /// 直播 / HLS —— 压低起播延迟。
  static const MediaKitProfile live = MediaKitProfile(
    demuxerMaxBytes: 32 * 1024 * 1024,
    demuxerReadaheadSecs: 10,
  );

  /// 按源特征分派。
  static MediaKitProfile forSource(PlayerSource source) {
    if (source.isLive || source.isHls) return live;
    if (PlayerBackendSelector.needsFallback(source.url,
        resourceName: source.title)) {
      return largeContainer;
    }
    return onDemand;
  }
}