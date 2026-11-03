/// 领域层：版本分发清单（批次 K · K-05 / 更2）。
///
/// 对齐唯一真相源：
/// - 主方案 §S.7（版本分发渠道：GitHub Releases + 三级代理降级链）
/// - 主方案 §S.3（自动更新设计：check / compare / download / install）
/// - iOS `UpdateManager.checkForUpdate`（版本清洗 + `.numeric` 比较）
///
/// 清单结构（`version.json`，随分发仓库维护）：
/// ```json
/// {
///   "version": "3.1716.0",
///   "build": 1716,
///   "notes": ["修复 A", "新增 B"],
///   "releasePageUrl": "https://github.com/<owner>/<repo>/releases/tag/v3.1716",
///   "publishedAt": "2026-10-05T10:00:00Z",
///   "assets": [
///     { "platform": "android-arm64", "url": "https://.../vbox-arm64.apk",
///       "sha256": "<hex>", "size": 12345678 },
///     { "platform": "android-v7a",   "url": "https://.../vbox-v7a.apk" },
///     { "platform": "windows",       "url": "https://.../vbox-setup.exe" },
///     { "platform": "macos",         "url": "https://.../vbox.dmg" }
///   ]
/// }
/// ```
///
/// 兼容 GitHub Releases API：`UpdateManifest.fromGitHubRelease` 把 release JSON
/// 归一到同一模型（对齐 iOS 现有拉取口径，`assets[].browser_download_url`）。
library;

import 'dart:io' show Platform;

/// 分发平台（清单 `assets[].platform` 契约值）。
enum UpdatePlatform {
  /// Android arm64-v8a（主流设备）。
  androidArm64('android-arm64'),

  /// Android armeabi-v7a（老设备）。
  androidV7a('android-v7a'),

  /// Windows 安装器（EXE）。
  windows('windows'),

  /// macOS 分发包（DMG）。
  macos('macos');

  const UpdatePlatform(this.id);

  /// 契约字符串值（清单 `platform` 字段）。
  final String id;

  /// 解析契约值（未知返回 null）。
  static UpdatePlatform? fromId(String? id) {
    for (final UpdatePlatform p in values) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 当前运行平台对应的候选（桌面单值；Android 依 ABI 判定）。
  ///
  /// 非三端（如测试宿主 Linux）返回 null → 无可用资产，检查结果按「不支持」处理。
  static UpdatePlatform? current() {
    if (Platform.isWindows) return UpdatePlatform.windows;
    if (Platform.isMacOS) return UpdatePlatform.macos;
    if (Platform.isAndroid) return androidForAbi();
    return null;
  }

  /// Android ABI → 平台资产（非 arm 架构回退 v7a；判定失败回退 arm64）。
  static UpdatePlatform? androidForAbi() {
    // `Platform.version` 含内核 ABI 线索；arm64 设备报 aarch64。
    final String v = Platform.version.toLowerCase();
    if (v.contains('aarch64') || v.contains('arm64')) {
      return UpdatePlatform.androidArm64;
    }
    if (v.contains('armv7') || v.contains('arm')) {
      return UpdatePlatform.androidV7a;
    }
    return UpdatePlatform.androidArm64;
  }
}

/// 单个平台分发资产。
class UpdateAsset {
  /// 构造。
  const UpdateAsset({
    required this.platform,
    required this.url,
    this.sha256 = '',
    this.sizeBytes = 0,
  });

  /// 平台。
  final UpdatePlatform platform;

  /// 下载地址。
  final String url;

  /// 期望 SHA-256（十六进制小写；空串 = 不做校验）。
  final String sha256;

  /// 文件字节数（0 = 未知）。
  final int sizeBytes;

  /// 从清单节点解析（缺 `platform` / `url` 视为无效，返回 null）。
  static UpdateAsset? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final UpdatePlatform? platform =
        UpdatePlatform.fromId(raw['platform']?.toString());
    final String url = raw['url']?.toString() ?? '';
    if (platform == null || url.isEmpty) return null;
    return UpdateAsset(
      platform: platform,
      url: url,
      sha256: (raw['sha256']?.toString() ?? '').toLowerCase(),
      sizeBytes: _asInt(raw['size']),
    );
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

/// 版本分发清单（对齐 §S.7 清单字段）。
class UpdateManifest {
  /// 构造。
  const UpdateManifest({
    required this.version,
    this.build = 0,
    this.notes = const <String>[],
    this.releasePageUrl = '',
    this.publishedAt,
    this.assets = const <UpdateAsset>[],
  });

  /// 语义版本（已清洗，如 `3.1716.0`）。
  final String version;

  /// 构建号（0 = 未提供）。
  final int build;

  /// 更新说明条目（已按行拆条 + 去前缀，对齐 iOS `UpdateSheet.notes`）。
  final List<String> notes;

  /// Release 页面地址（浏览器兜底下载用）。
  final String releasePageUrl;

  /// 发布时间（缺失为 null）。
  final DateTime? publishedAt;

  /// 各平台资产。
  final List<UpdateAsset> assets;

  /// 解析 `version.json`（无 `version` 视为无效返回 null）。
  static UpdateManifest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String version = cleanVersion(raw['version']?.toString() ?? '');
    if (version.isEmpty) return null;
    final List<UpdateAsset> assets = <UpdateAsset>[];
    final Object? rawAssets = raw['assets'];
    if (rawAssets is List) {
      for (final Object? item in rawAssets) {
        final UpdateAsset? a = UpdateAsset.fromJson(item);
        if (a != null) assets.add(a);
      }
    }
    return UpdateManifest(
      version: version,
      build: UpdateAsset._asInt(raw['build']),
      notes: normalizeNotes(raw['notes'] ?? raw['body']),
      releasePageUrl: raw['releasePageUrl']?.toString() ??
          raw['html_url']?.toString() ??
          '',
      publishedAt: DateTime.tryParse(raw['publishedAt']?.toString() ?? ''),
      assets: assets,
    );
  }

  /// 解析 GitHub Releases API 单条 release（对齐 iOS 现有拉取口径）。
  ///
  /// `assets[].browser_download_url` 按扩展名/文件名映射到平台；
  /// `digest`（`sha256:<hex>`）存在时作为校验哈希。
  static UpdateManifest? fromGitHubRelease(Object? raw) {
    if (raw is! Map) return null;
    final String version = cleanVersion(raw['tag_name']?.toString() ?? '');
    if (version.isEmpty) return null;
    final List<UpdateAsset> assets = <UpdateAsset>[];
    final Object? rawAssets = raw['assets'];
    if (rawAssets is List) {
      for (final Object? item in rawAssets) {
        if (item is! Map) continue;
        final String name = item['name']?.toString().toLowerCase() ?? '';
        final String url = item['browser_download_url']?.toString() ?? '';
        final UpdatePlatform? platform = _platformForAssetName(name);
        if (platform == null || url.isEmpty) continue;
        assets.add(UpdateAsset(
          platform: platform,
          url: url,
          sha256: _shaFromDigest(item['digest']?.toString()),
          sizeBytes: UpdateAsset._asInt(item['size']),
        ));
      }
    }
    return UpdateManifest(
      version: version,
      notes: normalizeNotes(raw['body']),
      releasePageUrl: raw['html_url']?.toString() ?? '',
      publishedAt: DateTime.tryParse(raw['published_at']?.toString() ?? ''),
      assets: assets,
    );
  }

  /// 按平台取资产（无匹配返回 null）。
  UpdateAsset? assetFor(UpdatePlatform platform) {
    for (final UpdateAsset a in assets) {
      if (a.platform == platform) return a;
    }
    return null;
  }

  /// 是否比当前 [localVersion] 更新。
  bool isNewerThan(String localVersion) =>
      compareVersions(version, localVersion) > 0;

  static UpdatePlatform? _platformForAssetName(String name) {
    if (name.endsWith('.apk')) {
      if (name.contains('v7a') || name.contains('armeabi')) {
        return UpdatePlatform.androidV7a;
      }
      return UpdatePlatform.androidArm64;
    }
    if (name.endsWith('.exe')) return UpdatePlatform.windows;
    if (name.endsWith('.dmg')) return UpdatePlatform.macos;
    return null;
  }

  static String _shaFromDigest(String? digest) {
    if (digest == null) return '';
    final String d = digest.toLowerCase();
    const String prefix = 'sha256:';
    return d.startsWith(prefix) ? d.substring(prefix.length) : d;
  }
}

/// 版本字符串清洗（对齐 iOS `UpdateManager.cleanVersion`）。
///
/// 去首 `v`、截断 `-` 预发布后缀、仅保留数字与点号。
String cleanVersion(String version) {
  String cleaned = version.trim();
  if (cleaned.startsWith('v') || cleaned.startsWith('V')) {
    cleaned = cleaned.substring(1);
  }
  final int dash = cleaned.indexOf('-');
  if (dash >= 0) cleaned = cleaned.substring(0, dash);
  final StringBuffer sb = StringBuffer();
  for (final int unit in cleaned.codeUnits) {
    final bool isDigit = unit >= 0x30 && unit <= 0x39;
    if (isDigit || unit == 0x2E) sb.writeCharCode(unit);
  }
  return sb.toString();
}

/// 数值化版本比较（对齐 iOS `.numeric`）：返回 `<0` / `0` / `>0`。
///
/// 逐段按整数比较（`3.10` > `3.9`，避免字符串比较误判）；缺失段按 0 补齐。
int compareVersions(String a, String b) {
  final List<int> pa = _segments(cleanVersion(a));
  final List<int> pb = _segments(cleanVersion(b));
  final int len = pa.length > pb.length ? pa.length : pb.length;
  for (int i = 0; i < len; i++) {
    final int va = i < pa.length ? pa[i] : 0;
    final int vb = i < pb.length ? pb[i] : 0;
    if (va != vb) return va < vb ? -1 : 1;
  }
  return 0;
}

List<int> _segments(String v) => v
    .split('.')
    .where((String s) => s.isNotEmpty)
    .map((String s) => int.tryParse(s) ?? 0)
    .toList(growable: false);

/// 更新说明归一：字符串按行拆分 / 列表直取，去掉空行、`##` 标题、`---` 分隔线
/// 与 `1、` `- ` `* ` 等前缀（对齐 iOS `UpdateSheet.notes`）。
List<String> normalizeNotes(Object? raw) {
  final List<String> lines = <String>[];
  if (raw is List) {
    for (final Object? item in raw) {
      lines.addAll(item.toString().split('\n'));
    }
  } else if (raw != null) {
    lines.addAll(raw.toString().split('\n'));
  }
  final List<String> out = <String>[];
  for (final String line in lines) {
    String s = line.trim();
    if (s.isEmpty || s.startsWith('##') || s.startsWith('---')) continue;
    s = s.replaceFirst(RegExp(r'^\d+[、.．]\s*'), '');
    if (s.startsWith('- ') || s.startsWith('* ')) s = s.substring(2);
    s = s.trim();
    if (s.isNotEmpty) out.add(s);
  }
  return out;
}