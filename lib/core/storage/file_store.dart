/// 核心层：文件读写（原子写 + JSON 便捷方法）。
///
/// 用途：备份文件、日志落盘、蜘蛛脚本缓存、导出数据。
/// 失败统一抛 [StorageException]，不向调用方暴露 `dart:io` 细节。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors/exceptions.dart';

/// 文件工具。
abstract final class FileStore {
  /// 原子写文本：先写 `<path>.tmp`，再替换目标文件。
  ///
  /// Windows 下 `rename` 覆盖已存在文件会失败，故先删除目标（存在时）。
  static Future<void> writeString(String path, String content) async {
    try {
      final File target = File(path);
      await target.parent.create(recursive: true);
      final File tmp = File('$path.tmp');
      await tmp.writeAsString(content, flush: true);
      if (await target.exists()) {
        await target.delete();
      }
      await tmp.rename(path);
    } on FileSystemException catch (e) {
      throw StorageException('写入文件失败：$path', cause: e);
    }
  }

  /// 读文本（不存在返回 null）。
  static Future<String?> readString(String path) async {
    try {
      final File f = File(path);
      if (!await f.exists()) return null;
      return await f.readAsString();
    } on FileSystemException catch (e) {
      throw StorageException('读取文件失败：$path', cause: e);
    }
  }

  /// 原子写 JSON。
  static Future<void> writeJson(String path, Object? value) =>
      writeString(path, jsonEncode(value));

  /// 读 JSON 对象（不存在或非法返回 null）。
  static Future<Map<String, Object?>?> readJsonMap(String path) async {
    final String? text = await readString(path);
    if (text == null || text.trim().isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final Map<String, Object?> out = <String, Object?>{};
      decoded.forEach((Object? k, Object? v) {
        out['$k'] = v;
      });
      return out;
    } catch (_) {
      return null;
    }
  }

  /// 删除文件（不存在返回 false）。
  static Future<bool> delete(String path) async {
    try {
      final File f = File(path);
      if (!await f.exists()) return false;
      await f.delete();
      return true;
    } on FileSystemException catch (e) {
      throw StorageException('删除文件失败：$path', cause: e);
    }
  }

  /// 列出目录下的文件（`suffix` 为扩展名过滤，如 `.json`）。
  ///
  /// 目录不存在返回空列表。
  static Future<List<String>> list(String dir, {String? suffix}) async {
    final Directory d = Directory(dir);
    if (!await d.exists()) return const <String>[];
    final List<String> out = <String>[];
    await for (final FileSystemEntity e in d.list(followLinks: false)) {
      if (e is! File) continue;
      if (suffix != null && !e.path.endsWith(suffix)) continue;
      out.add(e.path);
    }
    out.sort();
    return out;
  }

  /// 文件大小（不存在返回 0）。
  static Future<int> sizeOf(String path) async {
    final File f = File(path);
    if (!await f.exists()) return 0;
    return f.length();
  }

  /// 拼接路径（统一走 `package:path`，避免各端分隔符差异）。
  static String join(String a, String b) => p.join(a, b);
}
