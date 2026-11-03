/// 平台层：保存到相册通道（批次 E · E1-1，Android 专用）。
///
/// 对齐 iOS `performSaveToPhotos` 语义：
///  - mp4/mov/m4v 直接入库；其余（.ts 等）原生 `MediaExtractor`+`MediaMuxer`
///    转封装（copy 编码）后入库 Movies/VBox；
///  - 转封装 / 入库失败抛 [GallerySaveException]，UI 层 toast「视频转换失败」。
///
/// 落地差异（登记）：桌面端无系统相册概念，保持 share 导出 `.ts`（方案 E1-1）；
/// API < 29 无存储权限时报 [GallerySaveException.code =
/// `PERMISSION_DENIED`]，不做运行时权限弹窗（登记）。
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/utils/logger.dart';

/// 保存到相册桥（Android）。
abstract final class GallerySaver {
  static const MethodChannel _channel =
      MethodChannel('com.vbox.player/gallery_save');

  /// 平台支持（仅 Android；桌面走 share 导出）。
  static bool get isSupported => Platform.isAndroid;

  /// 保存视频到系统相册（Movies/VBox）。
  ///
  /// [displayName] 为展示名（可含扩展名；原生侧统一落 `.mp4`）。
  /// 成功返回入库标识（URI / 路径）。
  static Future<String> save({
    required String filePath,
    required String displayName,
  }) async {
    try {
      final Object? saved = await _channel.invokeMethod<Object>(
        'save',
        <String, String>{'path': filePath, 'name': displayName},
      );
      return saved?.toString() ?? '';
    } on PlatformException catch (e) {
      AppLog.warn('gallery', '保存到相册失败: ${e.code} ${e.message}');
      throw GallerySaveException(e.code, e.message ?? '保存失败');
    }
  }
}

/// 保存失败（[code] 对齐原生错误码：`PERMISSION_DENIED` / `SAVE_FAILED`）。
class GallerySaveException implements Exception {
  /// 构造。
  const GallerySaveException(this.code, this.message);

  /// 原生错误码。
  final String code;

  /// 描述。
  final String message;

  @override
  String toString() => 'GallerySaveException($code, $message)';
}
