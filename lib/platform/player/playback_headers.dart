/// 播放请求头集中层（第 4 批 F-P12）。
///
/// 唯一真相源：iOS `vbox/Views/PlayerViewsV2.swift` + `vbox/Services/AliyunPgPlayManager.swift`
///   - 缺省播放头（`initPlayer` L6446-6450）：`User-Agent`（iPhone Safari）/
///     `Accept: */*` / `Accept-Language: zh-CN,zh;q=0.9`；`Referer` 由 URL host
///     派生（除非 `noReferer` 重试模式）；
///   - 特例「转码 m3u8 不注入 UA/Referer」（`AliyunPgPlayManager.swift:306-323`）：
///     阿里转码 m3u8（host 含 `aliyun` + `video` 且 path 含 `/lt/` 或 `/qv/`）是
///     带签名的自鉴权 CDN 直链，注入 `api.alipan.com` Referer / 桌面 UA 会被视频
///     CDN 防盗链拒绝（-1102 没有访问权限），故**不注入**。
///
/// 收口目标：此前「播放请求头各客户端自拼、转码特例散落于阿里取链内部」，本层把
/// 转码特例固化为**单一判据**，由各盘取链与该特例的消费点共用。
library;

/// 播放请求头集中层。
abstract final class PlaybackHeaders {
  /// iOS 播放器缺省 UA（`initPlayer` L6447）。
  static const String defaultUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 '
      'Safari/604.1';

  /// iOS 缺省 `Accept`（`initPlayer` L6448）。
  static const String defaultAccept = '*/*';

  /// iOS 缺省 `Accept-Language`（`initPlayer` L6449）。
  static const String defaultAcceptLanguage = 'zh-CN,zh;q=0.9';

  /// 阿里直链缺省 Referer（`AliyunPgPlayManager.swift:321`）。
  static const String aliyunReferer = 'https://api.alipan.com';

  /// 阿里直链缺省 UA（`AliyunPgPlayManager.swift:318`；与
  /// `AliyunAdriveClient.desktopUA` 同值）。
  static const String aliyunDesktopUA =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36';

  /// 鉴权头名单（转码特例下不得注入；比对忽略大小写）。
  static const List<String> authHeaderNames = <String>['user-agent', 'referer'];

  /// 是否阿里转码 m3u8。
  ///
  /// 对齐 iOS 步骤7 `isAliTranscodeM3u8`：host 含 `aliyun` + `video` 且 path 含
  /// `/lt/` 或 `/qv/`（仅视频转码 CDN，排除阿里数据 CDN `*-data.aliyundrive.net`
  /// 与直链下载路径）。
  static bool isAliTranscodeM3u8(String url) {
    final Uri? u = Uri.tryParse(url);
    if (u == null) return false;
    final String host = u.host.toLowerCase();
    final String path = u.path.toLowerCase();
    return host.contains('aliyun') &&
        host.contains('video') &&
        (path.contains('/lt/') || path.contains('/qv/'));
  }

  /// 是否转码 m3u8 线路（当前仅阿里具备该特例判定）。
  static bool isTranscodeM3u8(String url) => isAliTranscodeM3u8(url);

  /// 剔除 UA / Referer（键比对忽略大小写）；空表原样返回。
  static Map<String, String> stripAuthHeaders(Map<String, String> headers) {
    if (headers.isEmpty) return headers;
    return <String, String>{
      for (final MapEntry<String, String> e in headers.entries)
        if (!authHeaderNames.contains(e.key.toLowerCase())) e.key: e.value,
    };
  }

  /// 转码 m3u8 不注入 UA/Referer（集中固化入口，对齐 iOS 步骤7 特例）。
  ///
  /// [forcedTranscode] 为调用方已确定的转码线路标记（如阿里取链时显式选中转码
  /// 线路、`transcodeUrl != null`），与非空 [url] 的 host/path 判据取「或」。
  /// 命中特例 → 返回**剔除 UA/Referer** 后的副本；否则原样返回。
  static Map<String, String> guardTranscode({
    required String url,
    required Map<String, String> headers,
    bool forcedTranscode = false,
  }) {
    if (!forcedTranscode && !isTranscodeM3u8(url)) return headers;
    return stripAuthHeaders(headers);
  }
}