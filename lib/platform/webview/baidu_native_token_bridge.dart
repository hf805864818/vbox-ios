// 原生 WebView2 bdstoken 桥（Windows 专属，C++ runner 直连）。
//
// 背景：普通百度网盘播放需要用户态 bdstoken，而 Dart HttpClient 的
// TLS/请求指纹被百度风控（errno=-6）。iOS 端经 WKWebView（系统网络栈）
// 天然可信；Windows 端此前用 Flutter 插件 WebView 先后引入闪退（3.1839
// 无头模式）与白屏（3.1844 根 Overlay 宿主），均已下线。本桥改由 runner
// 原生层直接承载 WebView2（隐藏子窗口 + 持久化 Jar + 页面上下文 fetch），
// 与登录网关同源的浏览器信任路径，结构上不经 Flutter 插件 WebView。
//
// 原生侧：windows/runner/baidu_token_bridge.cpp
// 通道：MethodChannel `com.vbox.player/cloud_bridge`
//   · getBdstoken {cookie: "k=v; k2=v2"} →
//     {errno: int, bdstoken: String, cookie: String, message: String}
//     errno=0 成功；cookie 为 WebView2 Jar 内全部 .baidu.com Cookie
//     （含 HttpOnly 与服务端新种指纹字段），调用方应合并回写凭据。
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// 原生 WebView2 bdstoken 桥客户端（Windows 专属）。
class BaiduNativeTokenBridge {
  BaiduNativeTokenBridge._();

  static const MethodChannel _channel = MethodChannel(
    'com.vbox.player/cloud_bridge',
  );

  /// 取 bdstoken。成功返回非空 token 与 Jar Cookie 串；
  /// 非 Windows / 桥不可用 / 失败返回空 token（errno/message 供日志留痕）。
  static Future<({String token, String cookie, int errno, String message})>
      fetchBdstoken(
    String cookieHeader, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (!Platform.isWindows) {
      return (token: '', cookie: '', errno: -1, message: '非 Windows 平台');
    }
    try {
      final Object? raw = await _channel
          .invokeMethod<dynamic>(
            'getBdstoken',
            <String, Object?>{'cookie': cookieHeader},
          )
          .timeout(timeout);
      if (raw is! Map) {
        return (token: '', cookie: '', errno: -1, message: '桥返回类型异常');
      }
      final int errno = (raw['errno'] as num?)?.toInt() ?? -1;
      final String token = raw['bdstoken'] as String? ?? '';
      final String jar = raw['cookie'] as String? ?? '';
      final String message = raw['message'] as String? ?? '';
      if (errno == 0 && token.isNotEmpty) {
        return (token: token, cookie: jar, errno: 0, message: message);
      }
      return (token: '', cookie: jar, errno: errno, message: message);
    } on TimeoutException {
      return (token: '', cookie: '', errno: -1, message: '原生桥调用超时');
    } catch (e) {
      return (token: '', cookie: '', errno: -1, message: '原生桥调用失败：$e');
    }
  }

  /// WinHTTP（Schannel 系统原生栈）直取 gettemplatevariable 的 bdstoken。
  ///
  /// 对齐 iOS 第 1 层 URLSession 的「系统网络栈」语义：不依赖 WebView2
  /// 运行时、无窗口、秒级完成。返回 errno=0 且 token 非空为成功；
  /// errno/message 供日志留痕（-6 = Schannel 指纹也被风控，需 WebView2 兜底）。
  static Future<({String token, String cookie, int errno, String message})>
      fetchBdstokenWinHttp(String cookieHeader) async {
    if (!Platform.isWindows) {
      return (token: '', cookie: '', errno: -1, message: '非 Windows 平台');
    }
    try {
      final Object? raw = await _channel
          .invokeMethod<dynamic>(
            'getBdstokenWinHttp',
            <String, Object?>{'cookie': cookieHeader},
          )
          .timeout(const Duration(seconds: 20));
      if (raw is! Map) {
        return (token: '', cookie: '', errno: -1, message: '桥返回类型异常');
      }
      final int errno = (raw['errno'] as num?)?.toInt() ?? -1;
      final String token = raw['bdstoken'] as String? ?? '';
      final String cookie = raw['cookie'] as String? ?? '';
      final String message = raw['message'] as String? ?? '';
      if (errno == 0 && token.isNotEmpty) {
        return (token: token, cookie: cookie, errno: 0, message: message);
      }
      return (token: '', cookie: cookie, errno: errno, message: message);
    } on TimeoutException {
      return (token: '', cookie: '', errno: -1, message: 'WinHTTP 调用超时');
    } catch (e) {
      return (token: '', cookie: '', errno: -1, message: 'WinHTTP 调用失败：$e');
    }
  }
}
