/// 平台层单测：`download_manager.dart`（G-02 服务层）。
///
/// 对齐 iOS `DownloadManager.swift` 的行为，全部依赖注入内存假件：
///   ① 入队 + 并发上限 2 + FIFO 队列；
///   ② 状态机：pending → downloading → completed | failed | paused；
///   ③ directFile：流式写盘、0.5s 进度写回、暂停清理临时文件；
///   ④ m3u8：master 解析 → 分片下载 → 按序合并 .ts（含 AES-128 解密）；
///   ⑤ 暂停/继续/取消/重试/清空已完成 + 胶囊通知。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' as pc;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';
import 'package:vbox/data/models/download.dart';
import 'package:vbox/platform/download/download.dart';

// ─────────────────────── 测试假件 ───────────────────────

/// 内存下载存储（镜像 DatabaseDownloadStore 语义：addedAt 倒序）。
class _FakeDownloadStore implements DownloadStore {
  final List<Download> items = <Download>[];
  int _seq = 1;

  Download? byId(int id) {
    for (final Download d in items) {
      if (d.id == id) return d;
    }
    return null;
  }

  @override
  Future<int> add(Download d) async {
    final int id = _seq++;
    items.add(d.copyWith(id: id));
    return id;
  }

  @override
  Future<List<Download>> all() async {
    final List<Download> sorted = <Download>[...items]
      ..sort((Download a, Download b) => b.addedAt.compareTo(a.addedAt));
    return sorted;
  }

  @override
  Future<void> updateProgress(int id, double progress, int downloadedSize, String status) async {
    final int i = items.indexWhere((Download d) => d.id == id);
    if (i < 0) return;
    items[i] = items[i].copyWith(
      progress: progress,
      downloadedSize: downloadedSize,
      status: DownloadStatus.fromDb(status),
    );
  }

  @override
  Future<void> updatePath(int id, String path, int fileSize, String status) async {
    final int i = items.indexWhere((Download d) => d.id == id);
    if (i < 0) return;
    items[i] = items[i].copyWith(
      filePath: path,
      fileSize: fileSize,
      progress: 1.0,
      status: DownloadStatus.fromDb(status),
    );
  }

  @override
  Future<void> updateStatus(int id, String status) async {
    final int i = items.indexWhere((Download d) => d.id == id);
    if (i < 0) return;
    items[i] = items[i].copyWith(status: DownloadStatus.fromDb(status));
  }

  @override
  Future<void> delete(int id) async {
    items.removeWhere((Download d) => d.id == id);
  }

  @override
  Future<void> clear() async {
    items.clear();
  }
}

/// 内存文件系统（对齐 DownloadFileSystem 接缝；路径即 key）。
class _FakeDownloadFileSystem implements DownloadFileSystem {
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Set<String> dirs = <String>{};

  @override
  Future<void> createDirectory(String path) async {
    dirs.add(path);
  }

  @override
  Future<void> deleteFile(String path) async {
    files.remove(path);
  }

  @override
  bool exists(String path) => files.containsKey(path);

  @override
  Future<DownloadFileSink> openSink(String path, {bool overwrite = true}) async {
    if (overwrite) files.remove(path);
    return _MemorySink(this, path);
  }

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    files[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> readBytes(String path) async =>
      files[path] ?? Uint8List(0);

  @override
  Future<void> moveFile(String from, String to) async {
    final Uint8List? data = files[from];
    if (data != null) {
      files[to] = data;
      files.remove(from);
    }
  }

  @override
  Future<void> deleteDirectory(String path) async {
    files.removeWhere((String k, Uint8List v) => k.startsWith(path));
    dirs.remove(path);
  }

  @override
  Future<int> fileSize(String path) async => files[path]?.length ?? 0;

  @override
  Future<int> directorySize(String path) async {
    int total = 0;
    files.forEach((String k, Uint8List v) {
      if (k.startsWith(path)) total += v.length;
    });
    return total;
  }
}

class _MemorySink implements DownloadFileSink {
  _MemorySink(this.fs, this.path);

  final _FakeDownloadFileSystem fs;
  final String path;
  final BytesBuilder bb = BytesBuilder(copy: false);

  @override
  void add(List<int> bytes) => bb.add(bytes);

  @override
  Future<void> close() async {
    fs.files[path] = bb.takeBytes();
  }
}

/// 可控传输：openStream 由测试显式 emit/close（确定性并发控制）。
class _ControlledTransport implements DownloadTransport {
  final Map<String, String> strings = <String, String>{};
  final Map<String, Uint8List> datas = <String, Uint8List>{};
  final Map<String, StreamController<Uint8List>> controllers =
      <String, StreamController<Uint8List>>{};
  final List<String> openedUrls = <String>[];

  @override
  Future<String?> fetchString(Uri uri, Map<String, String> headers) async =>
      strings[uri.toString()];

  @override
  Future<Uint8List?> fetchData(Uri uri, Map<String, String> headers) async =>
      datas[uri.toString()];

  @override
  Future<DownloadStreamResponse?> openStream(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final String key = uri.toString();
    openedUrls.add(key);
    final StreamController<Uint8List> c =
        StreamController<Uint8List>(sync: true);
    controllers[key] = c;
    return DownloadStreamResponse(
      statusCode: 200,
      totalBytes: -1,
      bytes: c.stream,
    );
  }

  void emit(String url, List<int> bytes) =>
      controllers[url]!.add(Uint8List.fromList(bytes));

  void close(String url) => controllers[url]!.close();

  void error(String url, Object e) => controllers[url]!.addError(e);

  void dispose() {
    for (final StreamController<Uint8List> c in controllers.values) {
      if (!c.isClosed) c.close();
    }
  }
}

/// 固定结果地址解析器。
class _FakeUrlResolver implements DownloadUrlResolver {
  _FakeUrlResolver(this.result);

  final ResolvedDownloadUrl result;

  @override
  Future<ResolvedDownloadUrl> resolve(Download record) async => result;
}

/// 按记录 playurl 解析（多 URL 用例：并发上限 / 清空已完成等）。
class _PlayUrlResolver implements DownloadUrlResolver {
  @override
  Future<ResolvedDownloadUrl> resolve(Download record) async =>
      ResolvedDownloadUrl(
        url: record.playurl,
        headers: const <String, String>{},
        type: DownloadType.directFile,
      );
}

// ─────────────────────── 工具 ───────────────────────

int _now = 1000000;

Download _directRecord(String name, String url, {int jishu = 1}) => Download(
      name: name,
      playurl: url,
      jishu: jishu,
      addedAt: _now++,
    );

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) {
      fail('waitUntil 超时（${timeout.inSeconds}s）');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Uint8List _aes128CbcEncrypt(Uint8List key, Uint8List iv, Uint8List plain) {
  final PaddedBlockCipherImpl padded = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  );
  padded.init(
    true,
    pc.PaddedBlockCipherParameters<pc.CipherParameters?, pc.CipherParameters?>(
      pc.ParametersWithIV<pc.KeyParameter>(pc.KeyParameter(key), iv),
      null,
    ),
  );
  return padded.process(plain);
}

/// 构造指定数量的字节块（内容可辨识）。
Uint8List _bytesOf(List<int> values) => Uint8List.fromList(values);

// ─────────────────────── 用例 ───────────────────────

void main() {
  group('入队与并发', () {
    test('并发上限 2，FIFO 队列补齐（对齐 iOS maxConcurrent=2）', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _ControlledTransport transport = _ControlledTransport();
      final DownloadManager manager = DownloadManager(
        store: store,
        transport: transport,
        fileSystem: _FakeDownloadFileSystem(),
        urlResolver: _PlayUrlResolver(),
        downloadsDirectory: '/dl',
      );
      addTearDown(manager.dispose);
      addTearDown(transport.dispose);

      await manager.enqueue(_directRecord('A', 'https://cdn.example.com/a.mp4'));
      await manager.enqueue(_directRecord('B', 'https://cdn.example.com/b.mp4'));
      await manager.enqueue(_directRecord('C', 'https://cdn.example.com/c.mp4'));

      // A、B 立即启动；C 进入等待队列
      await _waitUntil(() => transport.openedUrls.length >= 2);
      expect(transport.openedUrls, hasLength(2));
      expect(manager.activeDownloads.length, 3);

      // 完成 A → 队列中的 C 启动（FIFO）
      transport.close('https://cdn.example.com/a.mp4');
      await _waitUntil(() => transport.openedUrls.length >= 3);
      expect(transport.openedUrls.last, 'https://cdn.example.com/c.mp4');

      transport.close('https://cdn.example.com/b.mp4');
      transport.close('https://cdn.example.com/c.mp4');
      await _waitUntil(
        () => store.items.every(
          (Download d) => d.status == DownloadStatus.completed,
        ),
      );
      expect(manager.hasActiveTasks, isFalse);
    });

    test('入队胶囊提示 + 新任务恢复悬浮按键显示', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _ControlledTransport transport = _ControlledTransport();
      final DownloadManager manager = DownloadManager(
        store: store,
        transport: transport,
        fileSystem: _FakeDownloadFileSystem(),
        urlResolver: _FakeUrlResolver(
          const ResolvedDownloadUrl(
            url: 'https://cdn.example.com/a.mp4',
            headers: <String, String>{},
            type: DownloadType.directFile,
          ),
        ),
        downloadsDirectory: '/dl',
      );
      addTearDown(manager.dispose);
      addTearDown(transport.dispose);

      manager.isFloatingButtonManuallyHidden = true;
      await manager.enqueue(_directRecord('A', 'https://cdn.example.com/a.mp4'));

      expect(manager.capsuleMessage, isNotNull);
      expect(manager.capsuleMessage!.type, DownloadCapsuleType.info);
      expect(manager.capsuleMessage!.text, contains('A'));
      expect(manager.isFloatingButtonManuallyHidden, isFalse);

      // 等待流真正打开后再 close，避免与下载启动产生竞态
      await _waitUntil(() => transport.openedUrls.isNotEmpty);
      transport.close('https://cdn.example.com/a.mp4');
      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.completed);
    });
  });

  group('directFile 下载', () {
    test('流式写盘 + 完成状态 + 输出文件 + 完成胶囊', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _FakeDownloadFileSystem fs = _FakeDownloadFileSystem();
      final _ControlledTransport transport = _ControlledTransport();
      final DownloadManager manager = DownloadManager(
        store: store,
        transport: transport,
        fileSystem: fs,
        urlResolver: _FakeUrlResolver(
          const ResolvedDownloadUrl(
            url: 'https://cdn.example.com/movie.mp4',
            headers: <String, String>{'Referer': 'https://src.example.com/'},
            type: DownloadType.directFile,
          ),
        ),
        downloadsDirectory: '/dl',
      );
      addTearDown(manager.dispose);
      addTearDown(transport.dispose);

      await manager.enqueue(_directRecord('测试 电影', 'https://cdn.example.com/movie.mp4'));
      await _waitUntil(() => transport.openedUrls.isNotEmpty);
      expect(store.byId(1)!.status, DownloadStatus.downloading);

      transport.emit('https://cdn.example.com/movie.mp4', <int>[1, 2, 3]);
      transport.emit('https://cdn.example.com/movie.mp4', <int>[4, 5]);
      transport.close('https://cdn.example.com/movie.mp4');

      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.completed);
      final Download saved = store.byId(1)!;
      expect(saved.progress, 1.0);
      expect(saved.filePath, '/dl/测试 电影.mp4');
      expect(saved.fileSize, 5);
      // 临时文件已改名为最终文件
      expect(fs.files['/dl/测试 电影.mp4'], isNotNull);
      expect(fs.files.containsKey('/dl/测试 电影_temp.mp4'), isFalse);

      // 完成胶囊（success）
      expect(manager.capsuleMessage!.type, DownloadCapsuleType.success);
      expect(manager.capsuleMessage!.text, contains('测试 电影'));
    });

    test('0.5s 进度写回：进度 > 0 且 downloading 状态写库', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _FakeDownloadFileSystem fs = _FakeDownloadFileSystem();
      final _ControlledTransport transport = _ControlledTransport();
      final DownloadManager manager = DownloadManager(
        store: store,
        transport: transport,
        fileSystem: fs,
        urlResolver: _FakeUrlResolver(
          const ResolvedDownloadUrl(
            url: 'https://cdn.example.com/big.mp4',
            headers: <String, String>{},
            type: DownloadType.directFile,
          ),
        ),
        downloadsDirectory: '/dl',
        progressInterval: const Duration(milliseconds: 10),
      );
      addTearDown(manager.dispose);
      addTearDown(transport.dispose);

      await manager.enqueue(_directRecord('BIG', 'https://cdn.example.com/big.mp4'));
      await _waitUntil(() => transport.openedUrls.isNotEmpty);

      // 持续投递分块直到触达一次进度写回
      for (int i = 0; i < 40; i++) {
        transport.emit('https://cdn.example.com/big.mp4', List<int>.filled(64, i));
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await _waitUntil(() => store.byId(1)!.downloadedSize > 0);
      expect(store.byId(1)!.status, DownloadStatus.downloading);

      transport.close('https://cdn.example.com/big.mp4');
      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.completed);
      // 进度写回是异步尽力而为（最后一块可能与完成交错），
      // 落盘文件大小才是确定值：全部 40 块均已写入。
      expect(fs.files['/dl/BIG.mp4']!.length, 40 * 64);
    });

    test('流式错误 → failed 状态 + 失败胶囊（downloadedSize>0 → 普通失败）', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _ControlledTransport transport = _ControlledTransport();
      final DownloadManager manager = DownloadManager(
        store: store,
        transport: transport,
        fileSystem: _FakeDownloadFileSystem(),
        urlResolver: _FakeUrlResolver(
          const ResolvedDownloadUrl(
            url: 'https://cdn.example.com/err.mp4',
            headers: <String, String>{},
            type: DownloadType.directFile,
          ),
        ),
        downloadsDirectory: '/dl',
      );
      addTearDown(manager.dispose);
      addTearDown(transport.dispose);

      await manager.enqueue(_directRecord('ERR', 'https://cdn.example.com/err.mp4'));
      await _waitUntil(() => transport.openedUrls.isNotEmpty);

      transport.emit('https://cdn.example.com/err.mp4', <int>[9, 9, 9]);
      transport.error('https://cdn.example.com/err.mp4', StateError('网络中断'));

      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.failed);
      expect(manager.capsuleMessage!.type, DownloadCapsuleType.failure);
      expect(manager.capsuleMessage!.text, contains('下载失败'));
    });

    test('地址解析 unsupported → failed（downloadedSize==0 → 网络失败胶囊）', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _ControlledTransport transport = _ControlledTransport();
      final DownloadManager manager = DownloadManager(
        store: store,
        transport: transport,
        fileSystem: _FakeDownloadFileSystem(),
        urlResolver: _FakeUrlResolver(
          const ResolvedDownloadUrl(
            url: '',
            headers: <String, String>{},
            type: DownloadType.unsupported,
          ),
        ),
        downloadsDirectory: '/dl',
      );
      addTearDown(manager.dispose);
      addTearDown(transport.dispose);

      await manager.enqueue(_directRecord('NOPE', 'https://unknown.example.com/x'));
      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.failed);
      expect(manager.capsuleMessage!.type, DownloadCapsuleType.network);
      expect(manager.capsuleMessage!.text, contains('网络失败'));
    });
  });

  group('m3u8 下载', () {
    const String masterUrl = 'https://cdn.example.com/vod/play.m3u8';
    const String childUrl = 'https://cdn.example.com/vod/media/720/index.m3u8';

    String mediaPlaylist({String? keyLine}) => '''
#EXTM3U
#EXT-X-VERSION:3
$keyLine
#EXTINF:4.0,
https://cdn.example.com/vod/media/720/seg1.ts
#EXTINF:4.0,
https://cdn.example.com/vod/media/720/seg2.ts
#EXT-X-ENDLIST
''';

    DownloadManager buildM3u8Manager(
      _FakeDownloadStore store,
      _ControlledTransport transport,
      _FakeDownloadFileSystem fs,
      String url,
    ) =>
        DownloadManager(
          store: store,
          transport: transport,
          fileSystem: fs,
          urlResolver: _FakeUrlResolver(ResolvedDownloadUrl(
            url: url,
            headers: <String, String>{},
            type: DownloadType.m3u8,
          )),
          downloadsDirectory: '/dl',
        );

    test('master → media → 分片下载 → 合并 .ts + 临时目录清理', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _FakeDownloadFileSystem fs = _FakeDownloadFileSystem();
      final _ControlledTransport transport = _ControlledTransport();
      transport.strings[masterUrl] = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=720x1280
media/720/index.m3u8
''';
      transport.strings[childUrl] = mediaPlaylist();
      transport.datas['https://cdn.example.com/vod/media/720/seg1.ts'] =
          _bytesOf(<int>[1, 2, 3, 4]);
      transport.datas['https://cdn.example.com/vod/media/720/seg2.ts'] =
          _bytesOf(<int>[5, 6, 7]);
      final DownloadManager manager =
          buildM3u8Manager(store, transport, fs, masterUrl);
      addTearDown(manager.dispose);

      await manager.enqueue(_directRecord('剧集01', masterUrl));
      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.completed);

      final Download saved = store.byId(1)!;
      expect(saved.status, DownloadStatus.completed);
      expect(saved.filePath, '/dl/剧集01.ts');
      expect(saved.fileSize, 7);
      // 合并字节序 = seg1 + seg2
      expect(fs.files['/dl/剧集01.ts'], equals(_bytesOf(<int>[1, 2, 3, 4, 5, 6, 7])));
      // 临时分片目录已清理
      expect(fs.files.keys.any((String k) => k.contains('/.tmp/')), isFalse);
      expect(manager.capsuleMessage!.type, DownloadCapsuleType.success);
    });

    test('AES-128 显式 IV：分片解密后合并', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _FakeDownloadFileSystem fs = _FakeDownloadFileSystem();
      final _ControlledTransport transport = _ControlledTransport();
      transport.strings[childUrl] = mediaPlaylist(
        keyLine: '#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/vod/key.bin",IV=0x000102030405060708090a0b0c0d0e0f',
      );
      final Uint8List key = Uint8List.fromList(List<int>.generate(16, (int i) => i + 1));
      final Uint8List iv = Uint8List.fromList(List<int>.generate(16, (int i) => i));
      final Uint8List plain1 = Uint8List.fromList(List<int>.generate(32, (int i) => 100 + i));
      final Uint8List plain2 = Uint8List.fromList(List<int>.generate(32, (int i) => 200 + i));
      transport.datas['https://cdn.example.com/vod/key.bin'] = key;
      transport.datas['https://cdn.example.com/vod/media/720/seg1.ts'] =
          _aes128CbcEncrypt(key, iv, plain1);
      transport.datas['https://cdn.example.com/vod/media/720/seg2.ts'] =
          _aes128CbcEncrypt(key, iv, plain2);
      final DownloadManager manager =
          buildM3u8Manager(store, transport, fs, childUrl);
      addTearDown(manager.dispose);

      await manager.enqueue(_directRecord('加密剧', childUrl));
      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.completed);

      expect(fs.files['/dl/加密剧.ts'], equals(Uint8List.fromList(<int>[...plain1, ...plain2])));
    });

    test('AES-128 缺省 IV：按分片序号（8 字节 0 + 大端序号）解密', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _FakeDownloadFileSystem fs = _FakeDownloadFileSystem();
      final _ControlledTransport transport = _ControlledTransport();
      transport.strings[childUrl] = mediaPlaylist(
        keyLine: '#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/vod/key.bin"',
      );
      final Uint8List key = Uint8List.fromList(List<int>.generate(16, (int i) => 16 - i));
      final Uint8List plain0 = Uint8List.fromList(List<int>.generate(32, (int i) => i));
      final Uint8List plain1 = Uint8List.fromList(List<int>.generate(32, (int i) => 50 + i));
      // seg0 → IV = 16 个 0；seg1 → 8 个 0 + BE(1)
      final Uint8List iv0 = Uint8List(16);
      final Uint8List iv1 = Uint8List.fromList(<int>[
        ...List<int>.filled(8, 0),
        0, 0, 0, 0, 0, 0, 0, 1,
      ]);
      transport.datas['https://cdn.example.com/vod/key.bin'] = key;
      transport.datas['https://cdn.example.com/vod/media/720/seg1.ts'] =
          _aes128CbcEncrypt(key, iv0, plain0);
      transport.datas['https://cdn.example.com/vod/media/720/seg2.ts'] =
          _aes128CbcEncrypt(key, iv1, plain1);
      final DownloadManager manager =
          buildM3u8Manager(store, transport, fs, childUrl);
      addTearDown(manager.dispose);

      await manager.enqueue(_directRecord('缺省IV', childUrl));
      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.completed);

      expect(fs.files['/dl/缺省IV.ts'], equals(Uint8List.fromList(<int>[...plain0, ...plain1])));
    });

    test('播放列表拉取失败 → failed 状态', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _ControlledTransport transport = _ControlledTransport();
      final DownloadManager manager =
          buildM3u8Manager(store, transport, _FakeDownloadFileSystem(), masterUrl);
      addTearDown(manager.dispose);

      await manager.enqueue(_directRecord('断流', masterUrl));
      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.failed);
      expect(manager.capsuleMessage!.type, DownloadCapsuleType.network);
    });
  });

  group('暂停 / 继续 / 取消 / 重试 / 清空', () {
    test('暂停 → paused + 临时文件清理 + 队列补位；继续 → 重新下载至完成', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _FakeDownloadFileSystem fs = _FakeDownloadFileSystem();
      final _ControlledTransport transport = _ControlledTransport();
      final DownloadManager manager = DownloadManager(
        store: store,
        transport: transport,
        fileSystem: fs,
        urlResolver: _FakeUrlResolver(
          const ResolvedDownloadUrl(
            url: 'https://cdn.example.com/p.mp4',
            headers: <String, String>{},
            type: DownloadType.directFile,
          ),
        ),
        downloadsDirectory: '/dl',
        // 缩短进度写回间隔：单次 emit 无法触发写回（写回只在后续 chunk 上
        // 判定），这里 emit 两次 + 延时确保 downloadedSize 被写库。
        progressInterval: const Duration(milliseconds: 10),
      );
      addTearDown(manager.dispose);
      addTearDown(transport.dispose);

      await manager.enqueue(_directRecord('暂停剧', 'https://cdn.example.com/p.mp4'));
      await _waitUntil(() => transport.openedUrls.isNotEmpty);
      transport.emit('https://cdn.example.com/p.mp4', <int>[1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      transport.emit('https://cdn.example.com/p.mp4', <int>[4, 5]);
      await _waitUntil(() => store.byId(1)!.downloadedSize > 0);

      manager.pause(1);
      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.paused);
      expect(manager.pausedDownloadIds, contains(1));
      // 临时文件已清理
      await _waitUntil(() => fs.files.containsKey('/dl/暂停剧_temp.mp4') == false);

      // 继续 → 重新下载（resume 会重新 openStream，必须等新流打开后再
      // emit/close，否则数据会命中旧控制器被丢弃）
      manager.resume(1);
      await _waitUntil(() => transport.openedUrls.length >= 2);
      transport.emit('https://cdn.example.com/p.mp4', <int>[7, 8, 9]);
      transport.close('https://cdn.example.com/p.mp4');
      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.completed);
      expect(manager.pausedDownloadIds, isNot(contains(1)));
      expect(fs.files['/dl/暂停剧.mp4'], equals(_bytesOf(<int>[7, 8, 9])));
    });

    test('取消 → failed；重试 → 进度清零重新下载', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _FakeDownloadFileSystem fs = _FakeDownloadFileSystem();
      final _ControlledTransport transport = _ControlledTransport();
      final DownloadManager manager = DownloadManager(
        store: store,
        transport: transport,
        fileSystem: fs,
        urlResolver: _FakeUrlResolver(
          const ResolvedDownloadUrl(
            url: 'https://cdn.example.com/r.mp4',
            headers: <String, String>{},
            type: DownloadType.directFile,
          ),
        ),
        downloadsDirectory: '/dl',
      );
      addTearDown(manager.dispose);
      addTearDown(transport.dispose);

      await manager.enqueue(_directRecord('重试剧', 'https://cdn.example.com/r.mp4'));
      await _waitUntil(() => transport.openedUrls.isNotEmpty);
      transport.emit('https://cdn.example.com/r.mp4', <int>[1, 1, 1]);

      manager.cancel(1);
      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.failed);

      // 重试会重新 openStream，必须等新流打开后再 emit/close
      manager.retry(1);
      await _waitUntil(() => transport.openedUrls.length >= 2);
      transport.emit('https://cdn.example.com/r.mp4', <int>[2, 2, 2, 2]);
      transport.close('https://cdn.example.com/r.mp4');
      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.completed);
      expect(fs.files['/dl/重试剧.mp4'], equals(_bytesOf(<int>[2, 2, 2, 2])));
    });

    test('清空已完成：删除文件与记录，保留未完成', () async {
      final _FakeDownloadStore store = _FakeDownloadStore();
      final _FakeDownloadFileSystem fs = _FakeDownloadFileSystem();
      final _ControlledTransport transport = _ControlledTransport();
      final DownloadManager manager = DownloadManager(
        store: store,
        transport: transport,
        fileSystem: fs,
        urlResolver: _PlayUrlResolver(),
        downloadsDirectory: '/dl',
      );
      addTearDown(manager.dispose);
      addTearDown(transport.dispose);

      // 已完成一条 + 失败一条
      await manager.enqueue(_directRecord('完成剧', 'https://cdn.example.com/c.mp4'));
      await _waitUntil(() => transport.openedUrls.isNotEmpty);
      transport.emit('https://cdn.example.com/c.mp4', <int>[1]);
      transport.close('https://cdn.example.com/c.mp4');
      await _waitUntil(() => store.byId(1)!.status == DownloadStatus.completed);

      await manager.enqueue(_directRecord('失败剧', 'https://cdn.example.com/f.mp4'));
      await _waitUntil(() => transport.openedUrls.length >= 2);
      transport.error('https://cdn.example.com/f.mp4', StateError('x'));
      await _waitUntil(() => store.byId(2)!.status == DownloadStatus.failed);

      await manager.clearCompleted();
      expect(store.byId(1), isNull);
      expect(store.byId(2), isNotNull);
      expect(fs.files['/dl/完成剧.mp4'], isNull);
    });
  });

  group('默认地址解析器', () {
    test('直链 mp4 → directFile，headers JSON 原样透传', () async {
      final DefaultDownloadUrlResolver resolver = DefaultDownloadUrlResolver();
      final ResolvedDownloadUrl r = await resolver.resolve(const Download(
        name: 'x',
        playurl: 'https://cdn.example.com/v.mp4',
        headers: '{"Referer":"https://a.com/"}',
        addedAt: 1,
      ));
      expect(r.type, DownloadType.directFile);
      expect(r.url, 'https://cdn.example.com/v.mp4');
      expect(r.headers['Referer'], 'https://a.com/');
    });

    test('m3u8 直链 → m3u8 类型', () async {
      final DefaultDownloadUrlResolver resolver = DefaultDownloadUrlResolver();
      final ResolvedDownloadUrl r = await resolver.resolve(const Download(
        name: 'x',
        playurl: 'https://cdn.example.com/v/index.m3u8',
        addedAt: 1,
      ));
      expect(r.type, DownloadType.m3u8);
    });

    test('福利资源直链（__fuli_welfare__ engineKey）不二次解析', () async {
      final DefaultDownloadUrlResolver resolver = DefaultDownloadUrlResolver();
      final ResolvedDownloadUrl r = await resolver.resolve(const Download(
        name: 'x',
        playurl: 'https://fuli.example.com/play?u=1',
        engineKey: '__fuli_welfare__video-1',
        addedAt: 1,
      ));
      expect(r.type, DownloadType.directFile);
    });

    test('非直链无委托 → unsupported；有委托 → 委托结果', () async {
      final DefaultDownloadUrlResolver resolver = DefaultDownloadUrlResolver();
      final ResolvedDownloadUrl r = await resolver.resolve(const Download(
        name: 'x',
        playurl: 'https://pan.baidu.com/s/123',
        addedAt: 1,
      ));
      expect(r.type, DownloadType.unsupported);

      final DefaultDownloadUrlResolver delegated = DefaultDownloadUrlResolver(
        delegate: _FakeUrlResolver(
          const ResolvedDownloadUrl(
            url: 'https://resolved.example.com/v.m3u8',
            headers: <String, String>{},
            type: DownloadType.m3u8,
          ),
        ),
      );
      final ResolvedDownloadUrl r2 = await delegated.resolve(const Download(
        name: 'x',
        playurl: 'https://pan.baidu.com/s/123',
        addedAt: 1,
      ));
      expect(r2.type, DownloadType.m3u8);
      expect(r2.url, 'https://resolved.example.com/v.m3u8');
    });
  });
}
