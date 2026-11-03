/// 平台层：m3u8 播放列表纯逻辑解析（G-02）。
///
/// 对齐 iOS `DownloadManager.swift` 的辅助方法：
/// `resolveMediaPlaylist` / `parseTSSegments` / `extractAESKeyInfo` /
/// `resolveURL` / `isDirectMediaURL`。纯函数、无 IO，便于单测。
library;

/// 下载类型（对齐 iOS `DownloadType`）。
enum DownloadType {
  m3u8,
  directFile,
  unsupported;

  /// 按 URL 是否含 m3u8 判定类型（对齐 iOS 各调用点）。
  static DownloadType fromUrl(String url) =>
      url.toLowerCase().contains('m3u8') ? DownloadType.m3u8 : DownloadType.directFile;
}

/// 已解析的 AES-128 密钥信息（对齐 iOS `AESKeyInfo`）。
class AesKeyInfo {
  /// 构造。
  const AesKeyInfo({this.url, this.iv});

  /// 密钥地址（可能为 null——缺省时用分片序号做 IV）。
  final String? url;

  /// 显式 IV（16 字节；来自 `IV=0x...`，可能为 null）。
  final List<int>? iv;
}

/// m3u8 解析工具（全部静态方法，对齐 iOS `DownloadManager` 辅助函数）。
abstract final class M3u8Parser {
  /// 相对地址解析：绝对 http(s) 原样返回，其余按 base 拼接（对齐 iOS `resolveURL`）。
  static String resolveUrl(String relative, String baseUrl) {
    final String trimmed = relative.trim();
    if (trimmed.toLowerCase().startsWith('http://') ||
        trimmed.toLowerCase().startsWith('https://')) {
      return trimmed;
    }
    final Uri? base = Uri.tryParse(baseUrl);
    if (base == null) return trimmed;
    final Uri? resolved = Uri.tryParse(trimmed);
    if (resolved == null) return trimmed;
    final Uri combined = base.resolveUri(resolved);
    if (combined != base) return combined.toString();
    return trimmed;
  }

  /// master playlist → 第一个 media playlist 地址（对齐 iOS `resolveMediaPlaylist`）。
  ///
  /// 无 `#EXT-X-STREAM-INF` 时返回 [baseUrl] 原样（即内容本身就是 media playlist）。
  static String resolveMediaPlaylist(String content, String baseUrl) {
    final List<String> lines = content.split(RegExp(r'\r?\n'));
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].contains('#EXT-X-STREAM-INF')) {
        if (i + 1 < lines.length) {
          return resolveUrl(lines[i + 1], baseUrl);
        }
      }
    }
    return baseUrl;
  }

  /// 解析 TS 分片 URL 列表（跳过空行与 `#` 注释行，对齐 iOS `parseTSSegments`）。
  static List<String> parseSegments(String content, String baseUrl) {
    final List<String> segments = <String>[];
    for (final String raw in content.split(RegExp(r'\r?\n'))) {
      final String line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      segments.add(resolveUrl(line, baseUrl));
    }
    return segments;
  }

  /// 提取 AES-128 密钥信息（对齐 iOS `extractAESKeyInfo`）。
  ///
  /// 解析 `#EXT-X-KEY:METHOD=AES-128,URI="...",IV=0x...`；找不到返回 null。
  static AesKeyInfo? extractAesKey(String content, String baseUrl) {
    for (final String raw in content.split(RegExp(r'\r?\n'))) {
      final String line = raw.trim();
      if (!line.contains('#EXT-X-KEY')) continue;

      String? keyUrl;
      final int uriStart = line.indexOf('URI="');
      if (uriStart >= 0) {
        final int valueStart = uriStart + 'URI="'.length;
        final int end = line.indexOf('"', valueStart);
        if (end > valueStart) {
          keyUrl = resolveUrl(line.substring(valueStart, end), baseUrl);
        }
      }

      List<int>? iv;
      final int ivStart = line.indexOf('IV=0x');
      if (ivStart >= 0) {
        final String hex =
            line.substring(ivStart + 'IV=0x'.length).trim();
        iv = _dataFromHex(hex);
      }

      return AesKeyInfo(url: keyUrl, iv: iv);
    }
    return null;
  }

  /// 直链媒体判定（对齐 iOS `isDirectMediaURL`）。
  ///
  /// 命中媒体扩展名，或 http(s) 直链且不含网盘域名时视为直链。
  static bool isDirectMediaUrl(String url) {
    final String lower = url.toLowerCase();
    const List<String> mediaExts = <String>[
      '.m3u8', '.mp4', '.mkv', '.flv', '.avi', '.mov', '.ts', '.m4a', '.mp3',
    ];
    if (mediaExts.any(lower.contains)) return true;
    if (lower.startsWith('http')) {
      const List<String> cloudDomains = <String>[
        'pan.baidu.com', 'pan.quark.cn', 'aliyundrive.com', 'alipan.com',
        'uc.cn', 'ucloud.cn', '115.com', '123pan.com', '123cloud.cn',
        'yun.139.com', '139.com', 'cloud.189.cn', '189.cn', 'pan.xunlei.com',
      ];
      if (!cloudDomains.any(lower.contains)) return true;
    }
    return false;
  }

  static List<int>? _dataFromHex(String hex) {
    final String cleaned = hex.replaceAll(' ', '');
    if (cleaned.isEmpty || cleaned.length.isOdd) return null;
    final List<int> bytes = <int>[];
    for (int i = 0; i < cleaned.length; i += 2) {
      final int? byte = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
      if (byte == null) return null;
      bytes.add(byte);
    }
    return bytes;
  }
}
