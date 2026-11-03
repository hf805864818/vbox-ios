/// 平台层：Spider HTTP 桥（第 2 轮批次 B · B-09）。
///
/// 唯一真相源：`contract/docs/abi_v1.md` §4（HTTP 回调协议）——
/// 来源为 iOS `vbox/Services/JSHTTPBridge.swift`，本文件为其 Dart 移植：
/// - **5 级编码链**（契约 §4.2「必须复刻」）：**复用核心层唯一实现**
///   `core/network/http_body_decoder.dart` 的 [decodeResponseBody]
///   （消除契约逻辑双份漂移）；本层只做接线——
///   **注入 GBK/Big5 真实码表**（[SpiderCharsetTables]，G-03 码表注入，
///   `enough_convert` 严格解码转译注册表，见 `core/utils/charset.dart` 头注释）；
/// - **超时**（契约 §6）：默认 15s（+5s 缓冲对齐 iOS semaphore 保护）；
///   超时返回 `ok=false, status=0`，content 为「请求超时」；
/// - **sslBypass**（契约 §4.3）：`badCertificateCallback` 接受任意证书，
///   **仅福利模块启用**（每个 bridge 实例独立 HttpClient，不污染全局）；
/// - **cookie**（契约 §4.4）：按域名分组内存存储（iOS 声明了 cookieStore
///   但未接线；Dart 侧补全：Set-Cookie 收集 + 请求回带 + 域隔离）；
/// - 结果形状对齐 iOS `syncRequest` 字典：`ok/status/content/url/headers`。
///
/// 与 iOS 的对齐偏差（登记）：
/// - POST 不注入默认 Content-Type（iOS 亦不设置，由 transport 层自决）；
/// - GB18030 四字节扩展序列不在码表（iOS CF 为 GB_18030_2000 超集），
///   含该类字符的页面按契约链回退 latin1，不致乱码扩散。
///
/// 消费方：引擎 `loadScriptFromURL`（脚本拉取）、B-10 容错解码、
/// B-11 站源原生搜索（Dart HTML 解析）、后续 JS `req()` 宿主桥。
///
/// 可测设计：[SpiderHttpTransport] 抽象注入 —— 编码链 / cookie / 超时 /
/// 结果组装全部离线单测（GBK/Big5 负向用例，B-09 验收口径）；
/// [IoSpiderHttpTransport] 为 dart:io 真实现。
library;

import 'dart:async' show TimeoutException;
import 'dart:convert' show Encoding, utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:enough_convert/enough_convert.dart';

import '../../core/network/http_body_decoder.dart' show decodeResponseBody;
import '../../core/utils/charset.dart'
    show charsetFromContentType, registerCharsetTables;

// ─────────────── 多字节码表安装器（G-03 · B-09 接线） ───────────────

/// GBK / Big5 码表安装器（核心层注册式码表的平台层注入方）。
///
/// 核心层 `charset.dart` 未注入码表时 gbk/big5 解码返回 null（探测链
/// 继续下探）——本类把 `enough_convert` 的 [GbkCodec] / [Big5Codec]
/// 严格解码能力（拒绝的对抛 FormatException）转译为码表注入：
/// - **GBK**：双字节区 lead 0x81–0xFE × trail 0x40–0x7E / 0x80–0xFE
///   （0x7F 除外，契约 §4.2 的 gbk/gb2312/gb18030 统一映射到此区）；
/// - **Big5**：lead 0x81–0xFE × trail 0x40–0x7E / 0xA1–0xFE
///   （以 codec 实际接受域为准，保留区自动排除）；
/// - **严格语义**：codec 拒绝对不入表 → 核心层解码为 null →
///   探测链按契约逐级回退（负向不吞字节、不产出替换字符）。
///
/// 建表成本一次性（首请求前懒加载）：lead 整行批量解码快路径 +
/// 行内含非法对时逐对探测慢路径；lead 整行不可用（Big5 保留区）经
/// 8 点探针短路跳过。
class SpiderCharsetTables {
  SpiderCharsetTables._();

  static bool _installed = false;

  /// 是否已注入（幂等标记；核心层 `hasMultibyteTables` 另有全局视角）。
  static bool get isInstalled => _installed;

  /// 幂等注入（[SpiderHttpBridge] 首个请求前调用）。
  static void ensureInstalled() {
    if (_installed) return;
    registerCharsetTables(
      gbk: _buildTable(const GbkCodec(allowInvalid: false), const <List<int>>[
        <int>[0x40, 0x7E],
        <int>[0x80, 0xFE],
      ]),
      big5: _buildTable(const Big5Codec(allowInvalid: false), const <List<int>>[
        <int>[0x40, 0x7E],
        <int>[0xA1, 0xFE],
      ]),
    );
    _installed = true;
  }

  /// lead 0x81–0xFE × [trailSegments] 全量探测建表。
  static Map<int, String> _buildTable(
    Encoding codec,
    List<List<int>> trailSegments,
  ) {
    final Map<int, String> table = <int, String>{};
    for (int lead = 0x81; lead <= 0xFE; lead++) {
      for (final List<int> seg in trailSegments) {
        final int lo = seg[0];
        final int hi = seg[1];
        if (!_rowViable(codec, lead, lo, hi)) continue; // 整行不可用 → 跳过
        // 快路径：整行一次解码（GBK 双字节区全域指派，几乎全部命中）
        final Uint8List row = _rowBytes(lead, lo, hi);
        final String? rowText = _tryDecode(codec, row);
        if (rowText != null && rowText.length == row.length ~/ 2) {
          for (int i = 0; i < rowText.length; i++) {
            table[(lead << 8) | (lo + i)] = rowText[i];
          }
          continue;
        }
        // 慢路径：行内存在 codec 拒绝对 → 逐对严格探测
        for (int trail = lo; trail <= hi; trail++) {
          final String? ch =
              _tryDecode(codec, Uint8List.fromList(<int>[lead, trail]));
          if (ch != null && ch.length == 1) {
            table[(lead << 8) | trail] = ch;
          }
        }
      }
    }
    return table;
  }

  /// 8 点探针：等距抽测 8 对全失败 → 判定该 lead 整行超出 codec 定义域
  /// （Big5 保留 lead 区），跳过逐对空跑。
  static bool _rowViable(Encoding codec, int lead, int lo, int hi) {
    final int span = hi - lo;
    for (int k = 0; k < 8; k++) {
      final int trail = lo + (span * k) ~/ 7;
      final String? ch =
          _tryDecode(codec, Uint8List.fromList(<int>[lead, trail]));
      if (ch != null && ch.length == 1) return true;
    }
    return false;
  }

  /// `[lead, lo], [lead, lo+1], …, [lead, hi]` 的拼接字节行。
  static Uint8List _rowBytes(int lead, int lo, int hi) {
    final Uint8List row = Uint8List((hi - lo + 1) * 2);
    int w = 0;
    for (int t = lo; t <= hi; t++) {
      row[w++] = lead;
      row[w++] = t;
    }
    return row;
  }

  static String? _tryDecode(Encoding codec, Uint8List bytes) {
    try {
      return codec.decode(bytes);
    } on FormatException {
      return null;
    }
  }
}

// ─────────────── Cookie 存储（契约 §4.4） ───────────────

/// 按域名分组的内存 Cookie 存储（iOS 声明 `cookieStore: [String: [String: String]]`）。
///
/// 补全 iOS 未接线的部分：Set-Cookie 收集 + 同域请求回带 + 域隔离。
/// 仅内存态（契约 §4.4「建议内存 + 可选持久化」，持久化待 B-10 接入偏好层）。
class SpiderCookieStore {
  final Map<String, Map<String, String>> _store = <String, Map<String, String>>{};

  /// 从响应 `Set-Cookie` 头收集（`k=v; Path=/; Domain=...` 取 `k=v`）。
  void storeFromResponse(Uri uri, List<String> setCookieHeaders) {
    if (setCookieHeaders.isEmpty) return;
    final String host = uri.host.toLowerCase();
    final Map<String, String> jar = _store.putIfAbsent(host, () => <String, String>{});
    for (final String raw in setCookieHeaders) {
      final String firstPair = raw.split(';').first.trim();
      final int eq = firstPair.indexOf('=');
      if (eq <= 0) continue;
      final String name = firstPair.substring(0, eq).trim();
      final String value = firstPair.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      jar[name] = value;
    }
  }

  /// 组装该域的 `Cookie` 请求头（无 cookie 返回 null）。
  String? cookieHeaderFor(Uri uri) {
    final String host = uri.host.toLowerCase();
    final Map<String, String>? jar = _store[host];
    if (jar == null || jar.isEmpty) return null;
    return jar.entries.map((MapEntry<String, String> e) => '${e.key}=${e.value}').join('; ');
  }

  /// 该域 cookie 数（测试/排障用）。
  int countFor(Uri uri) => _store[uri.host.toLowerCase()]?.length ?? 0;
}

// ─────────────── 请求选项 / 结果（iOS options 字典 → 结果字典） ───────────────

/// 显式 `Cookie` 头与 cookie jar 的合并策略（问题 2 修复 A）。
///
/// 历史缺陷：请求组装时 jar 结果**无条件覆盖**调用方显式传入的 `Cookie`
/// （如 UC `_commonHeaders(cookie)` 携带的登录态），导致 create 请求以 guest
/// 身份发出 → `code=31001 require login [guest]`。
enum SpiderCookieMode {
  /// 显式优先、jar 补充显式 Cookie 中缺失的键（默认）。
  merge,

  /// 显式 Cookie 完全优先；仅在调用方未提供 `Cookie` 时才回带 jar。
  explicitWins,

  /// jar 完全覆盖显式 Cookie（旧行为，仅为兼容保留）。
  jarWins,
}

/// HTTP 请求选项（契约 §4.1：headers/method/data/timeout；iOS 补 referer）。
class SpiderHttpOptions {
  const SpiderHttpOptions({
    this.method = 'GET',
    this.headers,
    this.data,
    this.timeout = const Duration(seconds: 15),
    this.referer,
    this.followRedirects = true,
    this.cookieMode = SpiderCookieMode.merge,
  });

  /// HTTP 方法（GET / POST，小写传入自动归一大写）。
  final String method;

  /// 自定义请求头。
  final Map<String, String>? headers;

  /// POST 请求体（字符串，UTF-8 编码发出）。
  final String? data;

  /// 超时（契约 §6 默认 15s）。
  final Duration timeout;

  /// Referer 头（iOS `options.referer` 直传）。
  final String? referer;

  /// 是否自动跟随 3xx 重定向（缺省 `true`）。
  ///
  /// 原生登录（百度 `qrbdusslogin` 等）需**手动**逐跳跟随以收集各跳
  /// `Set-Cookie`，故置 `false` 并读取响应头 `location`。
  final bool followRedirects;

  /// 显式 `Cookie` 头与 cookie jar 的合并策略（默认 [SpiderCookieMode.merge]）。
  final SpiderCookieMode cookieMode;

  /// 从 JS `options` 对象构造（B-05a `normalizeHttpOptions` 的 Map 归一输出）。
  ///
  /// 容错：字段缺省 / 类型不符 → 取契约默认（不抛异常，对齐 iOS as? 转型）。
  factory SpiderHttpOptions.fromMap(Map<String, Object?>? map) {
    if (map == null) return const SpiderHttpOptions();
    final Object? method = map['method'];
    final Object? headers = map['headers'];
    final Object? data = map['data'];
    final Object? timeout = map['timeout'];
    final Object? referer = map['referer'];
    return SpiderHttpOptions(
      method: method is String ? method : 'GET',
      headers: headers is Map
          ? headers.map((Object? k, Object? v) => MapEntry(k.toString(), v.toString()))
          : null,
      data: data is String ? data : null,
      timeout: timeout is num
          ? Duration(milliseconds: (timeout * 1000).round())
          : const Duration(seconds: 15),
      referer: referer is String ? referer : null,
    );
  }
}

/// HTTP 请求结果（对齐 iOS `syncRequest` 返回字典：`ok/status/content/url/headers`；
/// 类名不取 `SpiderHttpResponse` 以避开域层同名模型 `domain/entities/spider/http_bridge.dart`）。
class SpiderHttpResult {
  const SpiderHttpResult({
    required this.ok,
    required this.status,
    required this.content,
    required this.url,
    this.headers = const <String, String>{},
    this.setCookies = const <String>[],
  });

  /// 2xx 语义（对齐 iOS `status >= 200 && status < 300`）。
  final bool ok;

  /// HTTP 状态码；网络失败 / 超时为 0（对齐 iOS 初始值）。
  final int status;

  /// 解码后的正文（契约 §4.2 探测链产物；超时为「请求超时」，失败为错误消息）。
  final String content;

  /// 最终请求地址。
  final String url;

  /// 响应头（小写键，多值以 `,` 连接）。
  final Map<String, String> headers;

  /// 原始响应 `Set-Cookie` 值（未拆属性），供业务层刷新回写
  /// （对齐 iOS `quarkMergeSetCookie`，问题 2 修复 B）。
  final List<String> setCookies;

  /// 超时 / 网络失败构造（对齐 iOS 超时分支的固定形状）。
  factory SpiderHttpResult.failure(String url, String message) =>
      SpiderHttpResult(ok: false, status: 0, content: message, url: url);
}

// ─────────────── 传输抽象（可注入，离线单测） ───────────────

/// 传输层请求（bridge 组装后的最终形状）。
class SpiderTransportRequest {
  const SpiderTransportRequest({
    required this.method,
    required this.url,
    required this.headers,
    this.body,
    required this.timeout,
    this.followRedirects = true,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;
  final Duration timeout;

  /// 是否自动跟随 3xx（见 [SpiderHttpOptions.followRedirects]）。
  final bool followRedirects;
}

/// 传输层响应（原始字节 + 分组头）。
class SpiderTransportResponse {
  const SpiderTransportResponse({
    required this.status,
    required this.headers,
    required this.bodyBytes,
    this.setCookies = const <String>[],
    this.finalUrl = '',
  });

  final int status;
  final Map<String, String> headers;
  final List<int> bodyBytes;
  final List<String> setCookies;

  /// 跟随重定向后的最终 URL（未发生重定向 / fake 传输未填时为空）。
  ///
  /// 供 `locatedownload` 等「302 后取 CDN 直链」场景读取最终落点。
  final String finalUrl;
}

/// HTTP 传输抽象：单测注入 fake（离线验证编码链 / cookie / 超时 / 组装）。
abstract class SpiderHttpTransport {
  Future<SpiderTransportResponse> send(SpiderTransportRequest request);
}

/// dart:io 真实现（超时 / sslBypass 在此落地）。
class IoSpiderHttpTransport implements SpiderHttpTransport {
  IoSpiderHttpTransport({this.sslBypass = false})
      : _client = HttpClient() {
    if (sslBypass) {
      // 契约 §4.3：仅福利模块启用（实例级隔离，不污染其它客户端）
      _client.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    }
  }

  /// SSL 证书绕过开关（福利自签名服务器）。
  final bool sslBypass;
  final HttpClient _client;

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async {
    _client.connectionTimeout = request.timeout;
    final HttpClientRequest ioRequest = await _client
        .openUrl(request.method, request.url)
        .timeout(request.timeout + const Duration(seconds: 5));
    ioRequest.followRedirects = request.followRedirects;
    request.headers.forEach((String k, String v) => ioRequest.headers.set(k, v));
    if (request.body != null) {
      ioRequest.headers.contentLength = utf8.encode(request.body!).length;
      ioRequest.write(request.body!);
    }
    final HttpClientResponse res =
        await ioRequest.close().timeout(request.timeout + const Duration(seconds: 5));
    final List<int> bytes = await res.fold<List<int>>(
      <int>[],
      (List<int> prev, List<int> chunk) => prev..addAll(chunk),
    );
    final Map<String, String> headers = <String, String>{};
    res.headers.forEach((String name, List<String> values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    return SpiderTransportResponse(
      status: res.statusCode,
      headers: headers,
      bodyBytes: bytes,
      setCookies: List<String>.from(res.headers[HttpHeaders.setCookieHeader] ?? <String>[]),
      // 跟随重定向后的最终 URL（无重定向时回落到请求 URL）。
      finalUrl: res.redirects.isNotEmpty
          ? res.redirects.last.location.toString()
          : request.url.toString(),
    );
  }

  /// 释放连接（按引擎生命周期调用）。
  Future<void> close() async => _client.close(force: true);
}

// ─────────────── HTTP 桥（组装 / cookie / 解码） ───────────────

/// Spider HTTP 桥（iOS `JSHTTPBridge.syncRequest` 的 Dart 移植，异步版）。
class SpiderHttpBridge {
  SpiderHttpBridge({
    SpiderHttpTransport? transport,
    SpiderCookieStore? cookieStore,
    this.sslBypass = false,
    this.defaultHeaders,
  })  : _transport = transport ?? IoSpiderHttpTransport(sslBypass: sslBypass),
        _cookieStore = cookieStore ?? SpiderCookieStore();

  /// 传输层（单测注入 fake）。
  final SpiderHttpTransport _transport;

  /// Cookie 存储（按域分组；跨请求保持）。
  final SpiderCookieStore _cookieStore;

  /// SSL 绕过（契约 §4.3，仅福利模块 true）。
  final bool sslBypass;

  /// 默认请求头（UA 等站点级配置）。
  final Map<String, String>? defaultHeaders;

  /// iOS 默认 UA（契约 §4 复刻，勿改 —— 蜘蛛站点按该 UA 返回移动端页面）。
  static const String defaultUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15';

  /// 释放底层传输资源（[IoSpiderHttpTransport] 持有 [HttpClient]）。
  ///
  /// 引擎侧临时自建实例用后即关；注入实例生命周期归调用方（自行决定是否调用）。
  Future<void> close() async {
    final SpiderHttpTransport t = _transport;
    if (t is IoSpiderHttpTransport) {
      await t.close();
    }
  }

  /// 执行请求（注入码表 → 组装 headers + cookie 回带 → transport →
  /// Set-Cookie 收集 → 契约 §4.2 探测链解码 → 结果形状对齐 iOS）。
  Future<SpiderHttpResult> request(
    String url, {
    SpiderHttpOptions? options,
  }) async {
    // G-03：首个请求前注入 GBK/Big5 码表（幂等，一次性建表）
    SpiderCharsetTables.ensureInstalled();
    final SpiderHttpOptions opt = options ?? const SpiderHttpOptions();
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return SpiderHttpResult.failure(url, '无效URL');
    }

    // 组装请求头：默认 UA → 站点默认头 → 自定义头 → referer → cookie
    //（iOS：UA 仅在调用方未提供时补默认，见 JSHTTPBridge.syncRequest）
    final Map<String, String> headers = <String, String>{
      'User-Agent': defaultUserAgent,
      ...?defaultHeaders,
      ...?opt.headers,
    };
    final String method = opt.method.toUpperCase();
    if (opt.referer != null) {
      headers['Referer'] = opt.referer!;
    }
    // Cookie 组装（问题 2 修复 A）：HTTP 头大小写不敏感，先归一提取调用方
    // 显式 `Cookie`（可能来自 defaultHeaders 或 opt.headers），移除原键，
    // 再按 cookieMode 与 jar 合并，最终只写回单个 `Cookie` 键。
    // 历史缺陷：jar 无条件覆盖显式 Cookie → UC create 以 guest 发出 → 31001。
    String? explicitCookie;
    headers.removeWhere((String k, String v) {
      if (k.toLowerCase() == HttpHeaders.cookieHeader) {
        explicitCookie =
            explicitCookie == null ? v : '$explicitCookie; $v';
        return true;
      }
      return false;
    });
    final String? jarCookie = _cookieStore.cookieHeaderFor(uri);
    final String? mergedCookie =
        _resolveCookie(opt.cookieMode, explicitCookie, jarCookie);
    if (mergedCookie != null && mergedCookie.isNotEmpty) {
      headers[HttpHeaders.cookieHeader] = mergedCookie;
    }

    // 超时：契约默认 15s（iOS 资源超时 +5s 缓冲在 transport 内实现）
    try {
      final SpiderTransportResponse res = await _transport.send(SpiderTransportRequest(
        method: method,
        url: uri,
        headers: headers,
        body: opt.data,
        timeout: opt.timeout,
        followRedirects: opt.followRedirects,
      ));
      _cookieStore.storeFromResponse(uri, res.setCookies);
      final Uint8List bodyBytes = res.bodyBytes is Uint8List
          ? res.bodyBytes as Uint8List
          : Uint8List.fromList(res.bodyBytes);
      // 契约 §4.2 唯一实现（core 层），本层只接线不实现
      final (String content, bool _) = decodeResponseBody(
        bodyBytes,
        contentTypeCharset: charsetFromContentType(res.headers['content-type']),
      );
      return SpiderHttpResult(
        ok: res.status >= 200 && res.status < 300,
        status: res.status,
        content: content,
        url: url,
        headers: res.headers,
        setCookies: res.setCookies,
      );
    } on TimeoutException {
      // 对齐 iOS 超时分支：ok=false / status=0 / content="请求超时"
      return SpiderHttpResult.failure(url, '请求超时');
    } on SocketException catch (e) {
      return SpiderHttpResult.failure(url, e.message);
    } on HandshakeException catch (e) {
      // TLS 握手失败（过期/自签名证书、代理拦截）：与 iOS 一致收敛为
      // ok=false（任何传输层失败都不冒泡给脚本加载方）。
      return SpiderHttpResult.failure(url, e.message);
    } on HttpException catch (e) {
      return SpiderHttpResult.failure(url, e.message);
    }
  }

  /// 按 [mode] 合并显式 Cookie 与 jar（问题 2 修复 A）。
  static String? _resolveCookie(
    SpiderCookieMode mode,
    String? explicit,
    String? jar,
  ) {
    final bool hasExplicit = explicit != null && explicit.trim().isNotEmpty;
    final bool hasJar = jar != null && jar.trim().isNotEmpty;
    switch (mode) {
      case SpiderCookieMode.jarWins:
        return hasJar ? jar : explicit;
      case SpiderCookieMode.explicitWins:
        return hasExplicit ? explicit : jar;
      case SpiderCookieMode.merge:
        if (!hasExplicit) return jar;
        if (!hasJar) return explicit;
        return _mergeCookieHeaders(explicit, jar);
    }
  }

  /// 合并两段 Cookie 串：显式优先，jar 仅补充显式中缺失的键。
  static String _mergeCookieHeaders(String explicit, String jar) {
    final Map<String, String> merged = <String, String>{};
    void ingest(String raw) {
      for (final String pair in raw.split(';')) {
        final String p = pair.trim();
        if (p.isEmpty) continue;
        final int eq = p.indexOf('=');
        if (eq <= 0) continue;
        merged.putIfAbsent(
          p.substring(0, eq).trim(),
          () => p.substring(eq + 1).trim(),
        );
      }
    }

    ingest(explicit);
    ingest(jar);
    return merged.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('; ');
  }
}
