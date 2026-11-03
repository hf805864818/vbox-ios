/// 平台层：下载文件系统接缝（G-02）。
///
/// 把下载落盘操作抽象成可注入接缝（测试可用真实临时目录或内存假件），
/// 生产走 [DartIoDownloadFileSystem]（`dart:io`，三端可用）。
library;

import 'dart:io';
import 'dart:typed_data';

/// 文件系统接缝（下载用到的全部磁盘操作）。
abstract class DownloadFileSystem {
  /// 递归创建目录。
  Future<void> createDirectory(String path);

  /// 删除文件（不存在静默忽略）。
  Future<void> deleteFile(String path);

  /// 路径是否存在。
  bool exists(String path);

  /// 以追加/覆写方式打开一个字节写入流（[overwrite] 为 true 时先清空）。
  Future<DownloadFileSink> openSink(String path, {bool overwrite = true});

  /// 整块写入字节。
  Future<void> writeBytes(String path, Uint8List bytes);

  /// 整块读取字节（不存在返回空数组）。
  Future<Uint8List> readBytes(String path);

  /// 移动文件。
  Future<void> moveFile(String from, String to);

  /// 递归删除目录（不存在静默忽略）。
  Future<void> deleteDirectory(String path);

  /// 文件大小（字节）。
  Future<int> fileSize(String path);

  /// 目录内全部文件大小之和（分片下载进度用）。
  Future<int> directorySize(String path);
}

/// 可写入的字节流目标（对齐 iOS `FileHandle(forWritingTo:)`）。
abstract class DownloadFileSink {
  /// 追加写入。
  void add(List<int> bytes);

  /// 关闭（完成/失败后必须调用）。
  Future<void> close();
}

/// 默认实现：`dart:io`。
class DartIoDownloadFileSystem implements DownloadFileSystem {
  /// 构造。
  const DartIoDownloadFileSystem();

  @override
  Future<void> createDirectory(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  Future<void> deleteFile(String path) async {
    final File f = File(path);
    if (f.existsSync()) await f.delete();
  }

  @override
  bool exists(String path) => File(path).existsSync();

  @override
  Future<DownloadFileSink> openSink(String path,
      {bool overwrite = true}) async {
    final File f = File(path);
    if (overwrite && f.existsSync()) {
      await f.delete();
    }
    final IOSink sink = f.openWrite(mode: FileMode.append);
    return _DartIoFileSink(sink);
  }

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    await File(path).writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final File f = File(path);
    if (!f.existsSync()) return Uint8List(0);
    return await f.readAsBytes();
  }

  @override
  Future<void> moveFile(String from, String to) async {
    await File(from).rename(to);
  }

  @override
  Future<void> deleteDirectory(String path) async {
    final Directory d = Directory(path);
    if (!d.existsSync()) return;
    await d.delete(recursive: true);
  }

  @override
  Future<int> fileSize(String path) async {
    final File f = File(path);
    return f.existsSync() ? await f.length() : 0;
  }

  @override
  Future<int> directorySize(String path) async {
    final Directory d = Directory(path);
    if (!d.existsSync()) return 0;
    int total = 0;
    await for (final FileSystemEntity e in d.list(recursive: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }
}

class _DartIoFileSink implements DownloadFileSink {
  _DartIoFileSink(this._sink);

  final IOSink _sink;

  @override
  void add(List<int> bytes) => _sink.add(bytes);

  @override
  Future<void> close() => _sink.close();
}
