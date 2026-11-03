/// 平台层：转封装代理（批次 C · C-07）。
///
/// 本地 HTTP 代理，**默认端口 18081**：把 MKV / FLV / TS 等复杂封装
/// 转为 fMP4（**只换容器，不重编码**，`-c copy`），使 Media3 等直连后端
/// 也能播放（对齐 iOS 转封装代理语义）。
///
/// 端点：`GET http://127.0.0.1:{port}/remux?src=<上游URL>&fmt=fmp4`
///  - `fmt=fmp4`    强制转封装（上游按 [RemuxPlan] 判定需转封装时默认即此）
///  - `fmt=passthrough` 强制透传（HEAD/Range 透传 + 流式转发）
///
/// **鉴权头承载（P-芯3）**：需要 Cookie/Referer 等上游鉴权头的流，先经
/// [RemuxProxy.registerStream] 注册（url + headers）拿到 `id`，再用
/// `GET /remux?id=<id>` 请求——对齐 iOS `RemuxProxyServer.registerStream` 的
/// id 注册模型；`src=` 直连形态保留（无 headers，兼容旧调用）。
///
/// 依赖注入：`client`（上游 HTTP，测试用 MockClient）与 `remuxer`
/// （转封装实现；生产默认 [FfmpegRemuxer]，测试可注入假实现）。
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 转封装输出格式。
enum RemuxFormat {
  /// 分片 MP4（fragmented MP4，仅换容器）。
  fmp4,

  /// 透传（不转换）。
  passthrough;
}

/// 转封装计划（C-07）：由上游 URL 特征判定是否需要转封装。
class RemuxPlan {
  /// 构造。
  const RemuxPlan({
    required this.upstreamUrl,
    required this.format,
    this.upstreamHeaders = const <String, String>{},
  });

  /// 上游媒体地址。
  final String upstreamUrl;

  /// 输出格式。
  final RemuxFormat format;

  /// 上游请求头。
  final Map<String, String> upstreamHeaders;

  /// 是否需要转封装。
  bool get needsRemux => format == RemuxFormat.fmp4;

  /// 由 URL 判定计划。
  ///
  /// 复杂封装（MKV / FLV / TS / M2TS / RMVB / AVI / WMV）→ fMP4；
  /// MP4 / M4V / HLS(m3u8) 等已兼容 → 透传。
  static RemuxPlan decide(
    String url, {
    Map<String, String>? headers,
    RemuxFormat? overrideFormat,
  }) {
    final String u = url.toLowerCase();
    const List<String> complexContainers = <String>[
      '.mkv', '.flv', '.ts', '.m2ts', '.rmvb', '.avi', '.wmv', '.webm',
    ];
    bool needs = false;
    for (final String ext in complexContainers) {
      if (u.contains(ext)) {
        needs = true;
        break;
      }
    }
    final RemuxFormat format = overrideFormat ??
        (needs ? RemuxFormat.fmp4 : RemuxFormat.passthrough);
    return RemuxPlan(
      upstreamUrl: url,
      format: format,
      upstreamHeaders: headers ?? const <String, String>{},
    );
  }

  /// 复制并覆盖格式。
  RemuxPlan withFormat(RemuxFormat f) => RemuxPlan(
        upstreamUrl: upstreamUrl,
        format: f,
        upstreamHeaders: upstreamHeaders,
      );
}

/// 转封装器：上游字节流 → fMP4 字节流（仅换容器）。
abstract class Remuxer {
  /// 转换 [upstream] 为 fMP4 输出；转换失败抛 [RemuxException]。
  Stream<List<int>> remux({
    required Stream<List<int>> upstream,
    required RemuxPlan plan,
  });
}

/// 透传转封装器：原样转发（格式已兼容时使用）。
class PassthroughRemuxer implements Remuxer {
  const PassthroughRemuxer();

  @override
  Stream<List<int>> remux({
    required Stream<List<int>> upstream,
    required RemuxPlan plan,
  }) =>
      upstream;
}

/// 转封装异常。
class RemuxException implements Exception {
  RemuxException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'RemuxException: $message';
}

/// ffmpeg 转封装器：`-c copy` 只换容器，写 fMP4 到 stdout。
///
/// 上游流经 stdin 喂入（`-i pipe:0`），避免临时文件；`-movflags
/// frag_keyframe+empty_moov+default_base_moof` 产出渐进式 fMP4。
class FfmpegRemuxer implements Remuxer {
  /// 构造（[executable] 可注入 ffmpeg 路径）。
  FfmpegRemuxer({this.executable = 'ffmpeg'});

  /// ffmpeg 可执行文件。
  final String executable;

  @override
  Stream<List<int>> remux({
    required Stream<List<int>> upstream,
    required RemuxPlan plan,
  }) async* {
    late Process proc;
    try {
      proc = await Process.start(executable, <String>[
        '-i', 'pipe:0',
        '-c', 'copy', // 只换容器，不重编码
        '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
        '-f', 'mp4',
        'pipe:1',
      ]);
    } on ProcessException catch (e) {
      throw RemuxException('无法启动 ffmpeg（$executable）：${e.message}', cause: e);
    }
    // 异步喂入上游并关闭 stdin（EOF 结束输入）；不 await，避免管道阻塞。
    unawaited(_feedStdin(proc, upstream));
    // 排空 stderr（ffmpeg 日志量可能很大）。
    unawaited(proc.stderr.drain<void>());
    try {
      await for (final List<int> chunk in proc.stdout) {
        yield chunk;
      }
    } on Exception catch (e) {
      proc.kill();
      throw RemuxException('ffmpeg 输出中断：$e', cause: e);
    }
    final int code = await proc.exitCode;
    if (code != 0) {
      throw RemuxException('ffmpeg 退出码 $code（$executable）');
    }
  }

  Future<void> _feedStdin(Process proc, Stream<List<int>> upstream) async {
    try {
      await proc.stdin.addStream(upstream);
    } catch (_) {
      // 输入侧失败：终止进程，避免悬挂。
      proc.kill();
      return;
    }
    await proc.stdin.close();
  }
}

/// 转封装代理：本地 HTTP 服务（默认 127.0.0.1:18081，C-07）。
class RemuxProxy {
  /// 构造（[client] 上游 HTTP 客户端；[remuxer] 转封装实现；[port] 0 = 随机）。
  RemuxProxy({
    this.port = kDefaultPort,
    this.bindAddress = '127.0.0.1',
    http.Client? client,
    Remuxer? remuxer,
  })  : _client = client ?? http.Client(),
        _remuxer = remuxer ?? FfmpegRemuxer();

  /// 默认端口（C-07 契约：18081）。
  static const int kDefaultPort = 18081;

  /// 绑定地址。
  final String bindAddress;

  /// 请求端口（start 后为实际绑定端口；若请求 0 则为系统分配值）。
  final int port;

  final http.Client _client;
  final Remuxer _remuxer;

  HttpServer? _server;

  /// 已注册的上游流（`id → (url, headers)`，P-芯3）。
  final Map<String, ({String url, Map<String, String> headers})> _streams =
      <String, ({String url, Map<String, String> headers})>{};
  int _nextStreamId = 0;

  /// 注册带鉴权头的上游流，返回其 `id`（供 `/remux?id=` 使用）。
  ///
  /// 对齐 iOS `RemuxProxyServer.registerStream(url:headers:provider:)`：URL 里
  /// 不放鉴权信息，代理按 id 取流并在上游请求中逐头注入。
  String registerStream({
    required String url,
    Map<String, String>? headers,
  }) {
    final String id = 's${++_nextStreamId}';
    _streams[id] = (
      url: url,
      headers: headers ?? const <String, String>{},
    );
    return id;
  }

  /// 注销已注册流（幂等）。
  void unregisterStream(String id) {
    _streams.remove(id);
  }

  /// 清空全部注册流。
  void clearStreams() {
    _streams.clear();
  }

  /// 是否已启动。
  bool get isRunning => _server != null;

  /// 实际监听端口（start 后有效）。
  int get boundPort => _server?.port ?? port;

  /// 代理基础地址。
  String get baseUrl => 'http://$bindAddress:$boundPort';

  /// 启动 HTTP 服务。
  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(bindAddress, port);
    _server!.listen(_onRequest);
  }

  /// 停止服务（幂等）。
  Future<void> stop() async {
    final HttpServer? s = _server;
    _server = null;
    _streams.clear(); // P-芯3：随服务停止清空注册流，避免悬挂。
    if (s != null) {
      await s.close(force: true);
    }
  }

  /// 停止并释放上游客户端。
  Future<void> dispose() async {
    await stop();
    _client.close();
  }

  void _onRequest(HttpRequest req) {
    // 统一异步处理，避免并发请求被单个未处理 Future 打断。
    unawaited(_handle(req));
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.method != 'GET' && req.method != 'HEAD') {
        await _error(req, HttpStatus.methodNotAllowed, '仅支持 GET/HEAD');
        return;
      }
      if (req.uri.path != '/remux') {
        await _error(req, HttpStatus.notFound, '未知端点');
        return;
      }
      final String? id = req.uri.queryParameters['id'];
      final String? srcParam = req.uri.queryParameters['src'];
      String? src;
      Map<String, String> headers = const <String, String>{};
      if (id != null && id.isNotEmpty) {
        // P-芯3：按注册 id 取流（携带上游鉴权头）。
        final ({String url, Map<String, String> headers})? entry = _streams[id];
        if (entry == null) {
          await _error(req, HttpStatus.notFound, '未知的流 id：$id');
          return;
        }
        src = entry.url;
        headers = entry.headers;
      } else if (srcParam != null) {
        src = srcParam;
      }
      if (src == null || src.trim().isEmpty) {
        await _error(req, HttpStatus.badRequest, '缺少 src 或 id 参数');
        return;
      }
      if (!src.startsWith('http://') && !src.startsWith('https://')) {
        await _error(req, HttpStatus.badRequest, 'src 必须是 http(s) 地址');
        return;
      }
      final String? fmt = req.uri.queryParameters['fmt'];
      final RemuxFormat format = fmt == 'passthrough'
          ? RemuxFormat.passthrough
          : fmt == 'fmp4'
              ? RemuxFormat.fmp4
              : RemuxFormat.passthrough;
      final RemuxPlan plan = RemuxPlan.decide(
        src,
        headers: headers,
        overrideFormat: fmt == null ? null : format,
      );
      await _stream(req, plan);
    } on RemuxException catch (e) {
      await _error(req, HttpStatus.badGateway, e.message);
    } on Exception catch (e) {
      await _error(req, HttpStatus.badGateway, '代理错误：$e');
    }
  }

  Future<void> _stream(HttpRequest req, RemuxPlan plan) async {
    final bool headOnly = req.method == 'HEAD';
    final String? range = req.headers.value(HttpHeaders.rangeHeader);

    if (!plan.needsRemux) {
      // ── 透传：转发 Range，流式转发上游响应 ──
      final http.StreamedResponse up = await _fetchUpstream(plan, range);
      req.response.statusCode = up.statusCode;
      _copyHeaders(req.response, up.headers);
      if (headOnly) {
        await req.response.close();
        return;
      }
      await for (final List<int> chunk in up.stream) {
        req.response.add(chunk);
      }
      await req.response.close();
      return;
    }

    // ── 转封装：取上游全量字节 → remuxer → fMP4 ──
    final http.StreamedResponse up = await _fetchUpstream(plan, 'bytes=0-');
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
    req.response.headers.set(HttpHeaders.transferEncodingHeader, 'chunked');
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'none');
    if (headOnly) {
      await req.response.close();
      return;
    }
    final Stream<List<int>> out = _remuxer.remux(
      upstream: up.stream,
      plan: plan,
    );
    await for (final List<int> chunk in out) {
      req.response.add(chunk);
    }
    await req.response.close();
  }

  Future<http.StreamedResponse> _fetchUpstream(RemuxPlan plan, String? range) async {
    final http.Request r = http.Request('GET', Uri.parse(plan.upstreamUrl));
    r.headers['User-Agent'] = 'vbox/3.1662 (remux-proxy)';
    r.headers.addAll(plan.upstreamHeaders);
    if (range != null && range.isNotEmpty) {
      r.headers[HttpHeaders.rangeHeader] = range;
    }
    final http.StreamedResponse resp = await _client.send(r).timeout(
      const Duration(seconds: 30),
    );
    if (resp.statusCode >= 400) {
      await resp.stream.drain<void>();
      throw RemuxException('上游返回 ${resp.statusCode}（${plan.upstreamUrl}）');
    }
    return resp;
  }

  void _copyHeaders(HttpResponse out, Map<String, String> headers) {
    for (final MapEntry<String, String> e in headers.entries) {
      final String name = e.key.toLowerCase();
      // 逐跳头不转发。
      if (name == 'transfer-encoding' ||
          name == 'connection' ||
          name == 'keep-alive' ||
          name == 'proxy-authenticate' ||
          name == 'proxy-authorization' ||
          name == 'te' ||
          name == 'trailer' ||
          name == 'upgrade') {
        continue;
      }
      out.headers.set(e.key, e.value);
    }
    out.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  }

  Future<void> _error(HttpRequest req, int status, String message) async {
    req.response.statusCode = status;
    req.response.headers.set(HttpHeaders.contentTypeHeader, 'text/plain; charset=utf-8');
    req.response.write(message);
    await req.response.close();
  }
}

/// 转封装代理注册表：进程内共享单例（对齐 iOS `RemuxProxyServer.shared`）。
///
/// 端口固定 18081，全局仅需一份；首个消费方懒创建并 `start()` 一次后复用，
/// 避免多页并发绑定同端口。
class RemuxProxyRegistry {
  RemuxProxyRegistry._();

  static RemuxProxy? _instance;

  /// 共享代理（懒创建）。
  static RemuxProxy get instance => _instance ??= RemuxProxy();

  /// 注入替身（测试 / 自定义端口）。
  static set instance(RemuxProxy value) => _instance = value;
}
