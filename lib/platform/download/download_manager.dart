/// 平台层：下载管理器（G-02 服务层）。
///
/// 对齐 iOS `DownloadManager.swift`：
///   ① 入队：写库 → 查回 id → 胶囊提示 → 并发上限 2 / FIFO 队列；
///   ② 状态机：pending → downloading → completed | failed | paused；
///   ③ directFile：`openStream` 流式写盘，0.5s 进度写回；
///   ④ m3u8：master 解析 → 分片下载（AES-128 解密）→ 按序号合并为 .ts；
///   ⑤ 暂停/继续/取消/重试/清空已完成。
///
/// 全部磁盘/网络/存储操作走可注入接缝（[DownloadTransport] /
/// [DownloadFileSystem] / [DownloadStore] / [DownloadUrlResolver]），
/// 便于单测注入内存假件（对齐各批次「接缝注入」约定）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/api.dart' as pc;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';

import '../../core/storage/storage_paths.dart';
import '../../data/models/download.dart';
import 'download_file_system.dart';
import 'download_store.dart';
import 'download_transport.dart';
import 'm3u8_parser.dart';

/// 胶囊通知类型（对齐 iOS `DownloadCapsuleMessage.CapsuleType`）。
enum DownloadCapsuleType { info, success, failure, network }

/// 胶囊通知消息（对齐 iOS `DownloadCapsuleMessage`）。
class DownloadCapsuleMessage {
  /// 构造。
  const DownloadCapsuleMessage({
    required this.text,
    required this.icon,
    required this.type,
  });

  /// 文案。
  final String text;

  /// SF Symbol 图标名（与 iOS 一致，UI 端自行映射）。
  final String icon;

  /// 类型（决定 UI 颜色）。
  final DownloadCapsuleType type;
}

/// 已解析的真实下载地址（对齐 iOS `resolveDownloadURL` 返回值三元组）。
class ResolvedDownloadUrl {
  /// 构造。
  const ResolvedDownloadUrl({
    required this.url,
    required this.headers,
    required this.type,
  });

  /// 真实地址（空串 = 无法解析）。
  final String url;

  /// 自定义请求头。
  final Map<String, String> headers;

  /// 下载类型。
  final DownloadType type;
}

/// 下载地址解析接缝（对齐 iOS `resolveDownloadURL`）。
///
/// 生产默认 [DefaultDownloadUrlResolver]（直链判定 + 可选蜘蛛委托）；
/// 测试注入内存假件返回固定地址。
abstract class DownloadUrlResolver {
  /// 解析 [record] 的真实下载地址。
  Future<ResolvedDownloadUrl> resolve(Download record);
}

/// 默认地址解析器（对齐 iOS `resolveNormalURL` 步骤 1）。
///
/// 直链媒体（含 `__fuli_welfare__` 福利资源）直接返回；其余非直链交给
/// [delegate]（接线时注入蜘蛛 playerContent 解析，对应 iOS 步骤 2/3）。
class DefaultDownloadUrlResolver implements DownloadUrlResolver {
  /// 构造（[delegate] 可空——为空时非直链直接判 unsupported）。
  DefaultDownloadUrlResolver({this.delegate});

  /// 非直链时委托的解析器（蜘蛛链路）。
  final DownloadUrlResolver? delegate;

  @override
  Future<ResolvedDownloadUrl> resolve(Download record) async {
    final String url = record.playurl;
    final Map<String, String> savedHeaders = _decodeHeaders(record.headers);

    if (M3u8Parser.isDirectMediaUrl(url)) {
      return ResolvedDownloadUrl(
        url: url,
        headers: savedHeaders,
        type: DownloadType.fromUrl(url),
      );
    }

    final DownloadUrlResolver? d = delegate;
    if (d != null) {
      final ResolvedDownloadUrl r = await d.resolve(record);
      if (r.url.isNotEmpty) return r;
    }

    return const ResolvedDownloadUrl(
      url: '',
      headers: <String, String>{},
      type: DownloadType.unsupported,
    );
  }
}

/// 解析 JSON 编码的请求头（对齐 iOS `JSONDecoder().decode([String:String])`）。
Map<String, String> _decodeHeaders(String? json) {
  if (json == null || json.isEmpty) return <String, String>{};
  try {
    final Object? decoded = jsonDecode(json);
    if (decoded is Map<String, Object?>) {
      return <String, String>{
        for (final MapEntry<String, Object?> e in decoded.entries)
          e.key: e.value?.toString() ?? '',
      };
    }
    if (decoded is Map) {
      return <String, String>{
        for (final MapEntry<Object?, Object?> e in decoded.entries)
          e.key.toString(): e.value?.toString() ?? '',
      };
    }
    return <String, String>{};
  } on FormatException {
    return <String, String>{};
  }
}

/// 下载管理器（对齐 iOS `DownloadManager` + Combine @Published → ChangeNotifier）。
class DownloadManager extends ChangeNotifier {
  /// 构造（依赖全部可注入）。
  DownloadManager({
    DownloadStore? store,
    DownloadTransport? transport,
    DownloadFileSystem? fileSystem,
    DownloadUrlResolver? urlResolver,
    String? downloadsDirectory,
    this.maxConcurrent = 2,
    this.progressInterval = const Duration(milliseconds: 500),
  })  : _store = store ?? DatabaseDownloadStore(),
        _transport = transport ?? DartIoDownloadTransport(),
        _fileSystem = fileSystem ?? const DartIoDownloadFileSystem(),
        _urlResolver = urlResolver ?? DefaultDownloadUrlResolver(),
        _downloadsDirectory = downloadsDirectory ?? StoragePaths.downloadDir;

  final DownloadStore _store;
  final DownloadTransport _transport;
  final DownloadFileSystem _fileSystem;
  final DownloadUrlResolver _urlResolver;
  final String _downloadsDirectory;

  /// 最大并发下载数（对齐 iOS `maxConcurrent = 2`）。
  final int maxConcurrent;

  /// 进度写回间隔（对齐 iOS 0.5 秒）。
  final Duration progressInterval;

  /// 活跃下载记录（全量，按 addedAt 倒序；对齐 iOS `activeDownloads`）。
  List<Download> activeDownloads = <Download>[];

  /// 胶囊通知消息（UI 端统一 5 秒自动消失）。
  DownloadCapsuleMessage? capsuleMessage;

  /// 用户手动隐藏悬浮按键。
  bool isFloatingButtonManuallyHidden = false;

  /// 手动隐藏悬浮按键（对齐 iOS「关闭悬浮」→ 赋值 `isFloatingButtonManuallyHidden`）。
  void hideFloatingButton() {
    isFloatingButtonManuallyHidden = true;
    notifyListeners();
  }

  /// 恢复悬浮按键显示。
  void showFloatingButton() {
    isFloatingButtonManuallyHidden = false;
    notifyListeners();
  }

  /// 已暂停的下载 ID（对齐 iOS `pausedDownloadIds`）。
  final Set<int> pausedDownloadIds = <int>{};

  /// 运行中任务：recordId → Future（控制并发上限）。
  final Map<int, Future<void>> _tasks = <int, Future<void>>{};

  /// 各任务取消令牌（recordId → 取消器）。
  final Map<int, _DownloadCancellation> _cancellations = <int, _DownloadCancellation>{};

  /// 状态跟踪：recordId → 旧状态（胶囊通知「状态变化」判定）。
  final Map<int, String> _lastStatusMap = <int, String>{};

  /// FIFO 等待队列（对齐 iOS `pendingQueue`）。
  final List<Download> _pendingQueue = <Download>[];

  /// 是否已有运行中的任务。
  bool get hasActiveTasks => _tasks.isNotEmpty;

  // ─────────────────────── 入队 ───────────────────────

  /// 新增下载任务（对齐 iOS `enqueueDownload`）。
  Future<void> enqueue(Download record) async {
    final int addedId = await _store.add(record);
    await reloadActiveDownloads();

    // add 按值传递 id 不回填；以「名称 + 播放地址」匹配查回数据库分配的 id
    Download? saved;
    for (final Download d in activeDownloads) {
      if (d.name == record.name && d.playurl == record.playurl) {
        saved = d;
        break;
      }
    }
    saved ??= (addedId > 0 ? record.copyWith(id: addedId) : record);

    postCapsule(
      text: '已添加「${saved.name}」到下载',
      icon: 'arrow.down.circle.fill',
      type: DownloadCapsuleType.info,
    );

    // 新任务入队时恢复悬浮按键显示
    isFloatingButtonManuallyHidden = false;
    notifyListeners();

    if (_tasks.length < maxConcurrent) {
      _startDownload(saved);
    } else {
      _pendingQueue.add(saved);
    }
  }

  // ─────────────────────── 胶囊通知 ───────────────────────

  /// 发送胶囊通知（UI 组件统一管理自动消失，此处只负责设置消息）。
  void postCapsule({
    required String text,
    required String icon,
    required DownloadCapsuleType type,
  }) {
    capsuleMessage = DownloadCapsuleMessage(
      text: text,
      icon: icon,
      type: type,
    );
    notifyListeners();
  }

  // ─────────────────────── 刷新列表 ───────────────────────

  /// 全量刷新活跃下载（对齐 iOS `reloadActiveDownloads`）。
  Future<void> reloadActiveDownloads() async {
    activeDownloads = await _store.all();
    _checkStatusChanges();
    notifyListeners();
  }

  /// 检测状态变化，自动发送胶囊通知（对齐 iOS `checkStatusChanges`）。
  void _checkStatusChanges() {
    for (final Download record in activeDownloads) {
      final int? recordId = record.id;
      if (recordId == null) continue;
      final String? oldStatus = _lastStatusMap[recordId];
      final String newStatus = record.status.toDb();

      // 状态未变化或首次记录（跳过首次，避免初始化时误报）
      if (oldStatus == newStatus) continue;
      if (oldStatus == null) {
        _lastStatusMap[recordId] = newStatus;
        continue;
      }

      switch (newStatus) {
        case 'completed':
          postCapsule(
            text: '「${record.name}」下载完成',
            icon: 'checkmark.circle.fill',
            type: DownloadCapsuleType.success,
          );
        case 'failed':
          // 区分网络失败和普通失败
          final bool isNetworkError = record.downloadedSize == 0;
          postCapsule(
            text: '「${record.name}」${isNetworkError ? '网络失败' : '下载失败'}',
            icon: isNetworkError ? 'wifi.slash' : 'xmark.circle.fill',
            type: isNetworkError
                ? DownloadCapsuleType.network
                : DownloadCapsuleType.failure,
          );
        default:
          break;
      }

      _lastStatusMap[recordId] = newStatus;
    }

    // 清理已删除记录的状态跟踪
    final Set<int> currentIds = activeDownloads
        .map((Download d) => d.id)
        .whereType<int>()
        .toSet();
    _lastStatusMap.removeWhere(
      (int k, String v) => !currentIds.contains(k),
    );
  }

  // ─────────────────────── 启动下载 ───────────────────────

  void _startDownload(Download record) {
    final int taskId = record.id ?? 0;
    if (taskId <= 0) return;

    final _DownloadCancellation cancel =
        _cancellations.putIfAbsent(taskId, _DownloadCancellation.new);

    final Future<void> task = _executeDownload(record, cancel).whenComplete(() {
      _tasks.remove(taskId);
      _startNextPending();
    });
    _tasks[taskId] = task;
  }

  /// 任务结束后启动队列中下一个（FIFO）。
  void _startNextPending() {
    if (_tasks.length >= maxConcurrent || _pendingQueue.isEmpty) return;
    final Download next = _pendingQueue.removeAt(0);
    _startDownload(next);
  }

  // ─────────────────────── 核心执行 ───────────────────────

  Future<void> _executeDownload(
    Download record,
    _DownloadCancellation cancel,
  ) async {
    final int recordId = record.id ?? 0;
    if (recordId <= 0) return;

    // 步骤 1：置为 downloading
    await _store.updateStatus(recordId, 'downloading');
    await reloadActiveDownloads();

    // 步骤 2：解析真实下载地址
    final ResolvedDownloadUrl resolved = await _urlResolver.resolve(record);
    if (cancel.isCancelled) return;

    switch (resolved.type) {
      case DownloadType.m3u8:
        await _downloadM3u8(record, resolved, cancel);
      case DownloadType.directFile:
        await _downloadDirectFile(record, resolved, cancel);
      case DownloadType.unsupported:
        if (!cancel.isCancelled) {
          await _store.updateStatus(recordId, 'failed');
          await reloadActiveDownloads();
        }
    }
  }

  // ─────────────────────── 直链文件下载 ───────────────────────

  /// 文件名清理（对齐 iOS 正则替换 `[/\:*?"<>|]`）。
  String _safeName(String name) =>
      name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');

  Future<void> _downloadDirectFile(
    Download record,
    ResolvedDownloadUrl resolved,
    _DownloadCancellation cancel,
  ) async {
    final int recordId = record.id ?? 0;
    final Uri? uri = Uri.tryParse(resolved.url);
    if (uri == null || resolved.url.isEmpty) {
      if (!cancel.isCancelled) {
        await _store.updateStatus(recordId, 'failed');
        await reloadActiveDownloads();
      }
      return;
    }

    await _fileSystem.createDirectory(_downloadsDirectory);

    final String safeName = _safeName(record.name);
    final String ext = _extensionOf(uri).isEmpty ? 'mp4' : _extensionOf(uri);
    final String outputPath = '$_downloadsDirectory/$safeName.$ext';
    final String tempPath = '$_downloadsDirectory/${safeName}_temp.$ext';

    await _fileSystem.deleteFile(outputPath);
    await _fileSystem.deleteFile(tempPath);

    int downloadedSize = 0;
    try {
      final DownloadStreamResponse? response =
          await _transport.openStream(uri, resolved.headers);
      if (response == null) throw const _DownloadIoException('流式响应失败');

      final DownloadFileSink sink =
          await _fileSystem.openSink(tempPath, overwrite: true);

      final int? totalBytes =
          response.totalBytes > 0 ? response.totalBytes : null;
      final Stopwatch sw = Stopwatch()..start();

      try {
        await _consumeStream(
          response.bytes,
          sink,
          cancel,
          onChunk: (Uint8List chunk) {
            downloadedSize += chunk.length;
            if (sw.elapsed >= progressInterval) {
              sw.reset();
              final double progress = totalBytes != null && totalBytes > 0
                  ? (downloadedSize / totalBytes).clamp(0.0, 1.0)
                  : 0.0;
              unawaited(_writeProgress(recordId, progress, downloadedSize));
            }
          },
        );
      } finally {
        await sink.close();
      }

      if (cancel.isCancelled) {
        await _fileSystem.deleteFile(tempPath);
        return;
      }

      // 下载完成：重命名临时文件为最终文件
      await _fileSystem.moveFile(tempPath, outputPath);
      final int fileSize = await _fileSystem.fileSize(outputPath);
      await _store.updatePath(recordId, outputPath, fileSize, 'completed');
      await reloadActiveDownloads();
    } on Object {
      if (cancel.isCancelled) return;
      await _fileSystem.deleteFile(tempPath);
      // 失败前写回已下载大小：>0 → 普通失败胶囊，=0 → 网络失败胶囊
      // （对齐 iOS 失败时保留实际已下载字节数）。
      if (downloadedSize > 0) {
        await _store.updateProgress(recordId, 0.0, downloadedSize, 'failed');
      } else {
        await _store.updateStatus(recordId, 'failed');
      }
      await reloadActiveDownloads();
    }
  }

  // ─────────────────────── M3U8 下载 ───────────────────────

  Future<void> _downloadM3u8(
    Download record,
    ResolvedDownloadUrl resolved,
    _DownloadCancellation cancel,
  ) async {
    final int recordId = record.id ?? 0;

    // 1. 下载 m3u8 播放列表
    final String? m3u8Content = await _fetchString(resolved.url, resolved.headers);
    if (m3u8Content == null) {
      if (!cancel.isCancelled) {
        await _store.updateStatus(recordId, 'failed');
        await reloadActiveDownloads();
      }
      return;
    }

    // 2. 处理 master playlist → 第一个 media playlist
    final String mediaPlaylistUrl = M3u8Parser.resolveMediaPlaylist(
      m3u8Content,
      resolved.url,
    );
    final String finalContent;
    final String finalBaseUrl;
    if (mediaPlaylistUrl != resolved.url) {
      final String? content =
          await _fetchString(mediaPlaylistUrl, resolved.headers);
      if (content == null) {
        if (!cancel.isCancelled) {
          await _store.updateStatus(recordId, 'failed');
          await reloadActiveDownloads();
        }
        return;
      }
      finalContent = content;
      finalBaseUrl = mediaPlaylistUrl;
    } else {
      finalContent = m3u8Content;
      finalBaseUrl = resolved.url;
    }
    if (cancel.isCancelled) return;

    // 3. 解析 TS 分片 URL 列表
    final List<String> tsUrls =
        M3u8Parser.parseSegments(finalContent, finalBaseUrl);
    if (tsUrls.isEmpty) {
      if (!cancel.isCancelled) {
        await _store.updateStatus(recordId, 'failed');
        await reloadActiveDownloads();
      }
      return;
    }

    // 4. 处理 AES-128 加密
    final AesKeyInfo? keyInfo =
        M3u8Parser.extractAesKey(finalContent, finalBaseUrl);
    Uint8List? aesKey;
    if (keyInfo?.url != null && keyInfo!.url!.isNotEmpty) {
      final Uri? keyUri = Uri.tryParse(keyInfo.url!);
      if (keyUri != null) {
        aesKey = await _transport.fetchData(keyUri, resolved.headers);
      }
    }
    if (cancel.isCancelled) return;

    // 5. 创建临时分片目录（清理旧数据，支持暂停后重新下载）
    final String tempDir = '$_downloadsDirectory/.tmp/vbox_dl_$recordId';
    await _fileSystem.deleteDirectory(tempDir);
    await _fileSystem.createDirectory(tempDir);

    // 6. 逐个下载 TS 分片
    for (int i = 0; i < tsUrls.length; i++) {
      if (cancel.isCancelled) return;
      final Uri? tsUri = Uri.tryParse(tsUrls[i]);
      if (tsUri == null) continue;

      Uint8List? tsData = await _transport.fetchData(tsUri, resolved.headers);
      if (tsData == null) continue;
      if (cancel.isCancelled) return;

      if (aesKey != null) {
        final Uint8List decrypted =
            await _decryptTs(tsData, aesKey, keyInfo?.iv, i);
        if (decrypted.isNotEmpty) tsData = decrypted;
      }

      await _fileSystem.writeBytes(
        '$tempDir/seg_${i.toString().padLeft(5, '0')}.ts',
        tsData,
      );

      // 7. 上报进度（对齐 iOS：每个分片完成即写回）
      final double progress = (i + 1) / tsUrls.length;
      final int currentSize = await _fileSystem.directorySize(tempDir);
      await _store.updateProgress(recordId, progress, currentSize, 'downloading');
      await reloadActiveDownloads();
    }
    if (cancel.isCancelled) return;

    // 8. 按序号合并分片为 .ts（Dart 端无 AVFoundation 转码，对齐 iOS 最终兜底）
    await _fileSystem.createDirectory(_downloadsDirectory);
    final String safeName = _safeName(record.name);
    final String outputPath = '$_downloadsDirectory/$safeName.ts';
    await _fileSystem.deleteFile(outputPath);

    try {
      await _mergeTsSegments(tempDir, tsUrls.length, outputPath);
    } on Object {
      if (cancel.isCancelled) return;
      await _fileSystem.deleteDirectory(tempDir);
      await _store.updateStatus(recordId, 'failed');
      await reloadActiveDownloads();
      return;
    }

    await _fileSystem.deleteDirectory(tempDir);
    final int fileSize = await _fileSystem.fileSize(outputPath);
    await _store.updatePath(recordId, outputPath, fileSize, 'completed');
    await reloadActiveDownloads();
  }

  /// 按分片序号合并为单个 .ts（对齐 iOS `mergeTSSegments`；分片名 seg_%05d.ts）。
  Future<void> _mergeTsSegments(
    String tempDir,
    int segmentCount,
    String outputPath,
  ) async {
    final DownloadFileSink sink =
        await _fileSystem.openSink(outputPath, overwrite: true);
    try {
      for (int i = 0; i < segmentCount; i++) {
        final Uint8List data = await _fileSystem.readBytes(
          '$tempDir/seg_${i.toString().padLeft(5, '0')}.ts',
        );
        if (data.isNotEmpty) sink.add(data);
      }
    } finally {
      await sink.close();
    }
  }

  // ─────────────────────── 暂停/继续/取消/重试/清空 ───────────────────────

  /// 暂停下载：取消任务，标记状态为 paused（对齐 iOS `pauseDownload`）。
  void pause(int id) {
    _cancellations.remove(id)?.cancel();
    _tasks.remove(id);
    pausedDownloadIds.add(id);
    unawaited(_store.updateStatus(id, 'paused'));
    unawaited(reloadActiveDownloads());
    // 暂停后尝试启动队列中等待的任务
    _startNextPending();
  }

  /// 继续下载：状态置回 pending 重新入队（对齐 iOS `resumeDownload`）。
  void resume(int id) {
    Download? record;
    for (final Download d in activeDownloads) {
      if (d.id == id) {
        record = d;
        break;
      }
    }
    if (record == null) return;
    pausedDownloadIds.remove(id);
    unawaited(_store.updateStatus(id, 'pending'));
    unawaited(reloadActiveDownloads());
    if (_tasks.length < maxConcurrent) {
      _startDownload(record);
    } else {
      _pendingQueue.add(record);
    }
  }

  /// 取消下载：取消任务，标记状态为 failed（对齐 iOS `cancelDownload`）。
  void cancel(int id) {
    _cancellations.remove(id)?.cancel();
    _tasks.remove(id);
    pausedDownloadIds.remove(id);
    unawaited(_store.updateStatus(id, 'failed'));
    unawaited(reloadActiveDownloads());
  }

  /// 重试下载：进度清零重新下载（对齐 iOS `retryDownload`）。
  void retry(int id) {
    Download? record;
    for (final Download d in activeDownloads) {
      if (d.id == id) {
        record = d;
        break;
      }
    }
    if (record == null) return;
    unawaited(_store.updateStatus(id, 'pending'));
    unawaited(_store.updateProgress(id, 0, 0, 'pending'));
    unawaited(reloadActiveDownloads());
    _startDownload(record);
  }

  /// 清空已完成：删除文件与记录（对齐 iOS `clearCompleted`）。
  Future<void> clearCompleted() async {
    for (final Download record in activeDownloads) {
      if (record.status != DownloadStatus.completed) continue;
      if (record.filePath.isNotEmpty) {
        await _fileSystem.deleteFile(record.filePath);
      }
      await _store.delete(record.id ?? 0);
    }
    await reloadActiveDownloads();
  }

  /// 清空全部：取消所有任务并清空表（对齐 iOS「清空全部」→ `clearDownloads`）。
  ///
  /// 差异登记：iOS `clearDownloads` 仅清表不删文件；Flutter 此处取消进行中任务
  /// 并回收对应文件，避免孤儿残留（行为更完整，UI 表现一致）。
  Future<void> clearAll() async {
    for (final Download record in activeDownloads) {
      final int? id = record.id;
      if (id == null) continue;
      _cancellations.remove(id)?.cancel();
      _tasks.remove(id);
      if (record.filePath.isNotEmpty) {
        await _fileSystem.deleteFile(record.filePath);
      }
    }
    _pendingQueue.clear();
    pausedDownloadIds.clear();
    await _store.clear();
    await reloadActiveDownloads();
  }

  /// 删除单个记录（含下载中的任务取消；UI 删除用）。
  Future<void> deleteRecord(int id) async {
    _cancellations.remove(id)?.cancel();
    _tasks.remove(id);
    pausedDownloadIds.remove(id);
    await _store.delete(id);
    await reloadActiveDownloads();
  }

  // ─────────────────────── 内部辅助 ───────────────────────

  Future<void> _writeProgress(
    int recordId,
    double progress,
    int downloadedSize,
  ) async {
    await _store.updateProgress(recordId, progress, downloadedSize, 'downloading');
    await reloadActiveDownloads();
  }

  /// 拉取 UTF-8 文本（m3u8 播放列表用）。
  Future<String?> _fetchString(String url, Map<String, String> headers) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return null;
    return _transport.fetchString(uri, headers);
  }

  /// 消费流式响应写入文件，支持取消（对齐 iOS `for try await byte in bytes`）。
  Future<void> _consumeStream(
    Stream<Uint8List> stream,
    DownloadFileSink sink,
    _DownloadCancellation cancel, {
    required void Function(Uint8List chunk) onChunk,
  }) async {
    final Completer<void> done = Completer<void>();
    late final StreamSubscription<Uint8List> sub;

    void finish() {
      if (!done.isCompleted) done.complete();
    }

    sub = stream.listen(
      (Uint8List chunk) {
        if (cancel.isCancelled) {
          unawaited(sub.cancel());
          finish();
          return;
        }
        sink.add(chunk);
        onChunk(chunk);
      },
      onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
      },
      onDone: finish,
      cancelOnError: true,
    );

    // 外部取消：终止订阅并提前完成
    unawaited(cancel.cancelled.then((void _) {
      unawaited(sub.cancel());
      finish();
    }));

    await done.future;
  }

  /// AES-128-CBC 解密 TS 分片（对齐 iOS `decryptTS`；失败返回原数据）。
  Future<Uint8List> _decryptTs(
    Uint8List data,
    Uint8List key,
    List<int>? explicitIv,
    int segmentIndex,
  ) async {
    try {
      final Uint8List iv = explicitIv == null
          ? Uint8List.fromList(<int>[
              ...List<int>.filled(8, 0),
              ..._bigEndianUint64(segmentIndex),
            ])
          : Uint8List.fromList(explicitIv);
      return _aes128CbcDecrypt(key, iv, data);
    } on Object {
      // 解密失败（缺块/填充错误等）→ 保留原始数据，对齐 iOS 返回 data
      return data;
    }
  }

  /// AES-128-CBC + PKCS7 解密（纯 Dart，等价 iOS CommonCrypto `CCCrypt`）。
  static Uint8List _aes128CbcDecrypt(
    Uint8List key,
    Uint8List iv,
    Uint8List ciphertext,
  ) {
    final PaddedBlockCipherImpl padded = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    padded.init(
      false, // 解密
      pc.PaddedBlockCipherParameters<pc.CipherParameters?, pc.CipherParameters?>(
        pc.ParametersWithIV<pc.KeyParameter>(pc.KeyParameter(key), iv),
        null,
      ),
    );
    // process() 内部对末块执行 doFinal（去除 PKCS7 填充），返回精确明文长度
    return padded.process(ciphertext);
  }

  /// URI 路径扩展名（对齐 iOS `URL.pathExtension`；无扩展名返回空串）。
  static String _extensionOf(Uri uri) {
    final String path = uri.path;
    final int dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    return path.substring(dot + 1);
  }

  /// 8 字节大端序号（对齐 iOS `UInt64(index).bigEndian`）。
  static Uint8List _bigEndianUint64(int value) {
    final ByteData bd = ByteData(8)..setUint64(0, value, Endian.big);
    return bd.buffer.asUint8List();
  }

  @override
  void dispose() {
    for (final _DownloadCancellation c in _cancellations.values) {
      c.cancel();
    }
    _cancellations.clear();
    _tasks.clear();
    _pendingQueue.clear();
    super.dispose();
  }
}

/// 下载任务取消令牌（对齐 iOS `Task.isCancelled`；Dart Future 不可强杀）。
class _DownloadCancellation {
  final Completer<void> _completer = Completer<void>();
  bool _cancelled = false;

  /// 是否已取消。
  bool get isCancelled => _cancelled;

  /// 取消完成信号（供流式消费提前结束）。
  Future<void> get cancelled => _completer.future;

  /// 触发取消。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// 下载内部异常标记。
class _DownloadIoException implements Exception {
  const _DownloadIoException(this.message);

  final String message;

  @override
  String toString() => '_DownloadIoException: $message';
}
