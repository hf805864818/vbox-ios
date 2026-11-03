/// 直播本地文件导入/导出/分享（批次 E · E-04）。
///
/// 对齐 iOS `LiveTVView` 的 `handleDocumentPick` / `exportCustomSource` /
/// `exportChannelsToFile` 与 `DocumentPickerView` / `ActivityShareSheet`。
/// 文件选择与系统分享经 [LiveFileBridge] 抽象接原生（MethodChannel
/// `com.vbox.live/file`，Android `LiveFilePlugin.kt`），单测注入 fake；
/// 纯解析复用 [LiveTvParser]，导出落盘复用 [FileStore] + [StoragePaths.cacheDir]。
///
/// 契约键（读写在 [LiveTvController]）：`live_tv_custom_sources` /
/// `live_tv_local_channels`。
library;

import 'package:flutter/services.dart';

import '../../../core/storage/file_store.dart';
import '../../../core/storage/storage_paths.dart';
import '../../../domain/entities/live/live.dart';

/// 文件选择结果（原生回传的内容快照）。
class SelectedLiveFile {
  const SelectedLiveFile({
    required this.name,
    required this.content,
    required this.path,
  });

  /// 文件名（去扩展名前缀，用于登记 `local://` 源名）。
  final String name;

  /// 文件文本内容（原生侧已做编码兜底）。
  final String content;

  /// 选择文件路径（仅展示 / 调试用途）。
  final String path;
}

/// 直播文件桥抽象（fake 与真实实现共用）。
abstract class LiveFileBridge {
  /// 打开系统文件选择器，返回所选文本内容；取消返回 null。
  Future<SelectedLiveFile?> pickTextFile();

  /// 分享本地文件（`path` 为临时文件绝对路径）。
  Future<void> shareFile(String path);
}

/// `MethodChannel` 实现：调用 Android `LiveFilePlugin`。
class MethodChannelLiveFileBridge implements LiveFileBridge {
  MethodChannelLiveFileBridge() : _channel = const MethodChannel(channelName);

  /// 通道名（与 Android 侧 `LiveFilePlugin` 一致）。
  static const String channelName = 'com.vbox.live/file';

  final MethodChannel _channel;

  @override
  Future<SelectedLiveFile?> pickTextFile() async {
    try {
      final Object? r = await _channel.invokeMethod('pickTextFile');
      if (r is! Map) return null;
      final String? name = r['name']?.toString();
      final String? content = r['content']?.toString();
      final String? path = r['path']?.toString();
      if (name == null || content == null) return null;
      return SelectedLiveFile(name: name, content: content, path: path ?? '');
    } on MissingPluginException {
      // 桌面 / 测试环境无原生插件 → 未选择。
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> shareFile(String path) async {
    try {
      await _channel.invokeMethod<void>(
          'shareFile', <String, Object?>{'path': path});
    } on MissingPluginException {
      // 桌面 / 测试环境无原生分享，静默忽略。
    } on PlatformException {
      // 用户取消分享等，忽略。
    }
  }
}

/// 导入/导出纯逻辑（无 IO，便于单测）。
abstract final class LiveSourceImportExport {
  /// 解析直播源文件内容（M3U/TXT 自动判定），空内容返回空列表。
  static List<SubscribeChannel> parseContent(String content) {
    final String trimmed = content.trim();
    if (trimmed.isEmpty) return const <SubscribeChannel>[];
    if (trimmed.startsWith('#EXTM3U')) return LiveTvParser.parseM3U(content);
    return LiveTvParser.parseTXT(content);
  }

  /// 生成安全的导出文件名（替换路径分隔符与空格）。
  static String exportFileName(String name, {required bool isM3U}) {
    final String safe =
        name.replaceAll('/', '_').replaceAll('\\', '_').replaceAll(' ', '_');
    return '$safe.${isM3U ? 'm3u' : 'txt'}';
  }

  /// 将导出内容写入缓存目录，返回文件绝对路径。
  static Future<String> writeExportFile(String fileName, String content) async {
    final String path = FileStore.join(StoragePaths.cacheDir, fileName);
    await FileStore.writeString(path, content);
    return path;
  }
}