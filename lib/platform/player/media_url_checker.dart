/// 平台层：MediaURLChecker（批次 C · C-12 播放前 URL 探测）+ MPV 后端矩阵。
///
/// - [MediaUrlChecker]：播放前探测 URL 可达性 / Content-Type / 重定向终址 /
///   状态码，供回退链与后端矩阵决策（对齐 iOS `MediaURLResponseChecker` 语义）。
/// - [MpvBackendMatrix]：桌面 MPV 后端矩阵（自动 / MPV / 自由度），把用户偏好
///   映射为 [PlayerBackend]（libmpv 主 / media3 回退）。
library;

import 'package:http/http.dart' as http;

import '../../domain/entities/player/player.dart';

/// URL 探测结果。
class MediaUrlCheckResult {
  /// 构造。
  const MediaUrlCheckResult({
    required this.reachable,
    this.statusCode,
    this.contentType,
    this.effectiveUrl,
    this.latency = Duration.zero,
    this.redirected = false,
  });

  /// 是否可达（HTTP 2xx / 206；或非 4xx 且具媒体特征）。
  final bool reachable;

  /// HTTP 状态码（请求失败为 null）。
  final int? statusCode;

  /// 响应 Content-Type（可能为 null）。
  final String? contentType;

  /// 重定向终址（未重定向为 null）。
  final String? effectiveUrl;

  /// 探测耗时。
  final Duration latency;

  /// 是否发生重定向。
  final bool redirected;

  /// 是否具媒体特征（video / audio / m3u8 / mp4 等）。
  bool get looksLikeMedia {
    final String ct = (contentType ?? '').toLowerCase();
    if (ct.startsWith('video/') || ct.startsWith('audio/')) return true;
    return ct.contains('mpegurl') ||
        ct.contains('mp4') ||
        ct.contains('matroska') ||
        ct.contains('octet-stream');
  }

  /// 是否应继续尝试播放（可达且具媒体特征；或 2xx/206 兜底）。
  bool get shouldAttemptPlay =>
      reachable && (looksLikeMedia || (statusCode != null && statusCode! >= 200 && statusCode! < 300));
}

/// 播放前 URL 探测（C-12）。
///
/// 探测策略：HEAD 优先（轻量），`405/501/403` 时回退 GET + `Range: bytes=0-0`；
/// 网络/连接错误记不可达，不抛异常。
class MediaUrlChecker {
  /// 构造（[client] 可注入，测试用 `package:http/testing.dart` 的 MockClient）。
  MediaUrlChecker({http.Client? client, this.timeout = const Duration(seconds: 8)})
      : _client = client ?? http.Client();

  final http.Client _client;

  /// 单次探测超时。
  final Duration timeout;

  /// 探测 URL。
  Future<MediaUrlCheckResult> check(
    String url, {
    Map<String, String>? headers,
  }) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return const MediaUrlCheckResult(reachable: false, statusCode: null);
    }

    final Map<String, String> merged = <String, String>{
      'User-Agent': 'vbox/3.1662 (media-url-checker)',
      ...?headers,
    };

    final Stopwatch sw = Stopwatch()..start();
    try {
      final http.Response head = await _client
          .head(uri, headers: merged)
          .timeout(timeout);
      if (head.statusCode != 405 && head.statusCode != 501) {
        return _resultFrom(uri, head, sw);
      }
      // HEAD 被拒 → GET + Range 探测。
      final http.Response get = await _client.get(
        uri,
        headers: <String, String>{...merged, 'Range': 'bytes=0-0'},
      ).timeout(timeout);
      return _resultFrom(uri, get, sw);
    } catch (_) {
      return const MediaUrlCheckResult(reachable: false);
    }
  }

  MediaUrlCheckResult _resultFrom(Uri uri, http.Response r, Stopwatch sw) {
    final String? location = _header(r, 'location');
    final String? effective = location == null || location.isEmpty
        ? null
        : uri.resolve(location).toString();
    return MediaUrlCheckResult(
      reachable: r.statusCode >= 200 && r.statusCode < 400,
      statusCode: r.statusCode,
      contentType: _header(r, 'content-type'),
      effectiveUrl: effective,
      latency: sw.elapsed,
      redirected: effective != null,
    );
  }

  /// 大小写不敏感地读取响应头（HTTP 头名不区分大小写；MockClient 等可能
  /// 原样返回大写键名，与 IOClient 统一小写的行为不同）。
  static String? _header(http.Response r, String name) {
    final String? exact = r.headers[name];
    if (exact != null) return exact;
    final String lower = name.toLowerCase();
    for (final MapEntry<String, String> e in r.headers.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return null;
  }

  /// 释放底层 client（应用退出时调用）。
  void dispose() => _client.close();
}

/// 桌面 MPV 后端偏好（C-12 后端矩阵，对齐 iOS「播放内核」三选）。
enum MpvBackendPreference {
  /// 自动（按源特征与能力矩阵选择）。
  auto,

  /// 强制 MPV（libmpv，媒体_kit）。
  mpv,

  /// 自由度（media3 直连，可配合转封装代理 C-07）。
  free,
}

/// MPV 后端矩阵：偏好 + 源特征 → 初始后端与降级链（C-12）。
class MpvBackendMatrix {
  MpvBackendMatrix._();

  /// 按偏好与源选择初始后端。
  ///
  /// - [MpvBackendPreference.mpv] → libmpv（链内存在时）；
  /// - [MpvBackendPreference.free] → media3（链内存在时）；
  /// - [MpvBackendPreference.auto] → 复杂封装走 libmpv，其余 media3。
  static PlayerBackend selectInitial(
    PlayerSource source,
    MpvBackendPreference preference,
    List<PlayerBackend> chain,
  ) {
    final bool hasMpv = chain.contains(PlayerBackend.libmpv);
    final bool hasMedia3 = chain.contains(PlayerBackend.media3);
    switch (preference) {
      case MpvBackendPreference.mpv:
        if (hasMpv) return PlayerBackend.libmpv;
        return chain.first;
      case MpvBackendPreference.free:
        if (hasMedia3) return PlayerBackend.media3;
        return chain.first;
      case MpvBackendPreference.auto:
        if (PlayerBackendSelector.needsFallback(source.url,
                resourceName: source.title) &&
            hasMpv) {
          return PlayerBackend.libmpv;
        }
        return hasMedia3 ? PlayerBackend.media3 : chain.first;
    }
  }
}
