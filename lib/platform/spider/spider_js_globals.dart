/// 平台层：Spider JS 全局 API 桥（第 2 轮批次 B · B-05a，6 项，与引擎无关）。
///
/// 唯一真相源：iOS `vbox/Services/JSSpiderEngine.swift`（JSC 桥）与
/// `vbox/Libraries/QuickJSBridge.m`（QuickJS 桥）的能力差集（D6 复核 §10.2）：
///   1. `console`（log/info/warn/error）真实输出（接日志，对齐 iOS `__consoleLog`）
///   2. `print` 真实输出（接日志，对齐 iOS 宿主 `print` 注册）
///   3. `atob` —— Latin-1 二进制字符串语义；URL-safe（`-`/`_`）归一 + padding 补齐
///   4. `btoa` —— Latin-1 二进制字符串 → base64
///   5. `req` —— `http` 的全局别名（对齐 iOS `var req = http`）
///   6. 对象式 `options` 归一 —— 缺省/非对象 → `{}`；强制 `async=false`（同步请求）
///
/// 「与引擎无关」：6 项以「JS prelude（[prelude]）+ Dart 参考实现」双轨交付。
/// 任何能 eval JS 的引擎（QuickJS FFI / JSC / Node 桥 / Python 桥）在用户脚本
/// 之前 eval [prelude] 即获得全部能力，内置脚本零改动可跑（B-05a 验收）。
///
/// console/print 输出通道（两级）：
/// - 宿主已注册全局函数 `__vboxLog(level, text)` → 直发宿主（引擎自选实现）；
/// - 否则缓冲进 `__vboxLogs` 数组，引擎在每次操作后 eval [drainLogsScript]
///   取回 JSON 数组，经 [parseLogs] 归一后接日志（QuickJS FFI 走此通道，
///   不需要改动 C wrapper）。
library;

import 'dart:convert';

/// Spider JS 全局 API 桥（纯静态，无状态）。
class SpiderJsGlobals {
  SpiderJsGlobals._();

  /// prelude 版本标记（注入日志与排障用）。
  static const String preludeVersion = '__VBOX_JS_GLOBALS_V1__';

  /// JS 预置脚本：在任何用户脚本之前 eval。
  ///
  /// 幂等、无宿主强依赖：`http`/`__vboxLog` 不存在时各能力自动退化为
  /// 缓冲 / no-op 形态，不会抛异常（保证「内置脚本零改动可跑」）。
  static String prelude() => '''
// $preludeVersion
(function (g) {
  'use strict';
  // ① console / ② print：真实输出（宿主 __vboxLog 直发；否则缓冲 __vboxLogs）。
  //    调用时动态判定宿主通道 —— 宿主在 prelude 之后注册 __vboxLog 也能直发。
  var emit = function (level, text) {
    if (typeof g.__vboxLog === 'function') { g.__vboxLog(level, text); }
    else { (g.__vboxLogs = g.__vboxLogs || []).push(level + '|' + text); }
  };
  function fmt(args) {
    var out = [];
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      out.push(a === null ? 'null'
        : (a === undefined ? 'undefined'
        : (typeof a === 'object' ? JSON.stringify(a) : String(a))));
    }
    return out.join(' ');
  }
  g.console = {
    log: function () { emit('LOG', fmt(arguments)); },
    info: function () { emit('INFO', fmt(arguments)); },
    warn: function () { emit('WARN', fmt(arguments)); },
    error: function () { emit('ERROR', fmt(arguments)); }
  };
  g.print = function () { emit('LOG', fmt(arguments)); };
  // ③ atob / ④ btoa：标准 Web API 语义（Latin-1 二进制字符串）
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var B64_AT = {};
  for (var i = 0; i < B64.length; i++) { B64_AT[B64.charAt(i)] = i; }
  g.atob = function (s) {
    s = String(s).replace(/-/g, '+').replace(/_/g, '/');
    // 非法字符 / 尾部以外的 '=' → 空串（对齐 Dart 参考实现与浏览器语义）
    var body = s.replace(/=+\$/, '');
    if (body === '' || /[^A-Za-z0-9+\\/]/.test(body)) { return ''; }
    while (body.length % 4 !== 0) { body += '='; }
    s = body;
    var bytes = [];
    for (var i = 0; i < s.length; i += 4) {
      var n = ((B64_AT[s.charAt(i)] || 0) << 18)
            | ((B64_AT[s.charAt(i + 1)] || 0) << 12)
            | ((B64_AT[s.charAt(i + 2)] || 0) << 6)
            |  (B64_AT[s.charAt(i + 3)] || 0);
      bytes.push((n >> 16) & 0xff);
      if (s.charAt(i + 2) !== '=') { bytes.push((n >> 8) & 0xff); }
      if (s.charAt(i + 3) !== '=') { bytes.push(n & 0xff); }
    }
    var out = '';
    for (var j = 0; j < bytes.length; j++) { out += String.fromCharCode(bytes[j]); }
    return out;
  };
  g.btoa = function (s) {
    s = String(s);
    var out = '';
    for (var i = 0; i < s.length; i += 3) {
      var b0 = s.charCodeAt(i) & 0xff;
      var b1 = (i + 1 < s.length) ? s.charCodeAt(i + 1) & 0xff : -1;
      var b2 = (i + 2 < s.length) ? s.charCodeAt(i + 2) & 0xff : -1;
      out += B64.charAt(b0 >> 2);
      out += B64.charAt(((b0 & 3) << 4) | (b1 < 0 ? 0 : (b1 >> 4)));
      out += b1 < 0 ? '=' : B64.charAt(((b1 & 15) << 2) | (b2 < 0 ? 0 : (b2 >> 6)));
      out += b2 < 0 ? '=' : B64.charAt(b2 & 63);
    }
    return out;
  };
  // ⑥ 对象式 options 归一：缺省/非对象 → {}；强制同步（async=false）
  g.__vboxNormalizeOptions = function (o) {
    if (o === null || o === undefined || typeof o !== 'object') { o = {}; }
    o.async = false;
    return o;
  };
  // ⑤ req 别名 + http 归一包装（宿主已注册 http 时生效）
  if (typeof g.http === 'function') {
    var __vboxRawHttp = g.http;
    var __vboxHttp = function (url, options) {
      return __vboxRawHttp(url, g.__vboxNormalizeOptions(options));
    };
    g.http = __vboxHttp;
    if (typeof g.req === 'undefined') { g.req = __vboxHttp; }
  }
})(globalThis);
''';

  /// 取走缓冲日志的 eval 脚本（返回 JSON 字符串数组）。
  static String drainLogsScript() =>
      'JSON.stringify((globalThis.__vboxLogs || []).splice(0))';

  /// 解析 [drainLogsScript] 取回的日志并按 iOS 语义加级别前缀。
  ///
  /// 容错：空串 / 非 JSON / 非数组 → 空列表（不阻断引擎操作）。
  static List<String> parseLogs(String raw) {
    final String t = raw.trim();
    if (t.isEmpty) return const <String>[];
    Object? decoded;
    try {
      decoded = jsonDecode(t);
    } catch (_) {
      return const <String>[];
    }
    if (decoded is! List) return const <String>[];
    final List<String> out = <String>[];
    for (final Object? e in decoded) {
      if (e == null) continue;
      final String line = e.toString();
      final int sep = line.indexOf('|');
      if (sep <= 0) {
        out.add(line);
        continue;
      }
      final String level = line.substring(0, sep);
      final String text = line.substring(sep + 1);
      switch (level) {
        case 'ERROR':
          out.add('ERROR: $text');
        case 'WARN':
          out.add('WARN: $text');
        case 'INFO':
          out.add('INFO: $text');
        default:
          out.add(text);
      }
    }
    return out;
  }

  /// `atob` 的 Dart 参考实现（与 prelude JS 版语义一致，供宿主双轨对拍）。
  ///
  /// 语义（对齐 iOS `JSSpiderEngine.atobFunc`）：
  /// - URL-safe 归一（`-`→`+`、`_`→`/`）+ padding 补齐；
  /// - 返回 Latin-1 二进制字符串（每个字符码位 = 一个字节）；
  /// - 非法输入返回空串（不抛异常）。
  static String atob(String b64) {
    String s = b64.replaceAll('-', '+').replaceAll('_', '/');
    while (s.length % 4 != 0) {
      s += '=';
    }
    try {
      final List<int> bytes = base64.decode(s);
      return String.fromCharCodes(bytes);
    } catch (_) {
      return '';
    }
  }

  /// `btoa` 的 Dart 参考实现：Latin-1 二进制字符串（码位 0-255）→ base64。
  static String btoa(String binary) {
    final List<int> bytes = List<int>.generate(
      binary.length,
      (int i) => binary.codeUnitAt(i) & 0xff,
    );
    return base64.encode(bytes);
  }

  /// 对象式 `options` 归一的 Dart 参考实现（与 prelude JS 版语义一致）。
  ///
  /// - `null` / 非对象 → `{}`；
  /// - 强制 `async = false`（iOS `http` 包装：`options.async = false`）。
  static Map<String, Object?> normalizeHttpOptions(Object? options) {
    if (options is Map) {
      final Map<String, Object?> o = Map<String, Object?>.from(options);
      o['async'] = false;
      return o;
    }
    return <String, Object?>{'async': false};
  }
}
