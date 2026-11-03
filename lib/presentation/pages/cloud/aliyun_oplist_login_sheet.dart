/// 阿里云盘 OpenList 授权页登录 Sheet（对齐 iOS `AliOpenListQrLoginHelper`，
/// `CloudDriveAuthManager.swift:2244-2384` + `NativeCloudQRLoginView(.ali)`）。
///
/// iOS「原生扫码」的真实形态 = 可见 WKWebView 加载 OpenList 授权页
/// （`https://api.oplist.org/?driver=alicloud&driver_txt=alicloud_qr&server_use=true&server_set=true`）
/// → 页面加载完 2s 后注入 JS monitor（MutationObserver + 3s 定时轮询扫描
/// input/textarea/data-token/页面文本中的 refresh_token）→ `aliTokenHandler`
/// postMessage 回收 → `saveAliCredentialIfNew`（同 refreshToken 去重）落库。
///
/// Flutter 侧以 `flutter_inappwebview` 承载同款流程：
/// - JS 回收通道 = `window.flutter_inappwebview.callHandler('aliTokenHandler', ...)`
///   （对齐 iOS `window.webkit.messageHandlers.aliTokenHandler.postMessage`）；
/// - UA / 注入时机 / 提取规则 / 状态文案 / 落库字段均逐项对齐 iOS。
///
/// 平台可用性：与 [InAppWebViewBridge] 一致（Android / iOS / macOS / Windows）；
/// 不支持平台展示引导文案（回退「网页登录兜底」）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../data/datasources/local/cloud_drive_credential_store.dart';
import '../../../data/datasources/local/prefs_manager.dart';
import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../../platform/webview/in_app_webview_bridge.dart';

/// OpenList 授权页地址（对齐 iOS `startLogin`，`CloudDriveAuthManager.swift:2267`）。
const String kAliyunOpenListStartUrl =
    'https://api.oplist.org/?driver=alicloud&driver_txt=alicloud_qr'
    '&server_use=true&server_set=true';

/// 阿里云盘 OpenList 授权页登录 Sheet。
class AliyunOpenListLoginSheet extends StatefulWidget {
  /// 构造（[credentialStore] 供测试注入）。
  const AliyunOpenListLoginSheet({super.key, this.credentialStore});

  /// 凭据存储（测试注入；缺省契约安全存储 `cloud_drive_credentials_v1`）。
  final CloudDriveCredentialStore? credentialStore;

  /// 当前平台是否承载内嵌 WebView（与 [InAppWebViewBridge] 同判据）。
  static bool get isSupported => InAppWebViewBridge().isAvailable;

  @override
  State<AliyunOpenListLoginSheet> createState() =>
      _AliyunOpenListLoginSheetState();
}

class _AliyunOpenListLoginSheetState extends State<AliyunOpenListLoginSheet> {
  /// 移动端 UA（对齐 iOS `customUserAgent`，`CloudDriveAuthManager.swift:2259`）。
  static const String _openListUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15';

  bool _monitorInjected = false;
  bool _loggedIn = false;
  String _statusText = '正在加载 OpenList 授权页面...';
  String? _error;

  /// token 回收（对齐 iOS `userContentController` 消息处理，:2299-2313）。
  Future<Object?> _onToken(List<Object?> args) async {
    if (args.isEmpty || _loggedIn) return null;
    final Object? first = args.first;
    if (first is! Map) return null;
    final Map<String, Object?> body = first.cast<String, Object?>();
    final String refreshToken = _asString(body['refresh_token'] ??
        body['refreshToken'] ??
        body['refresh_token'.toUpperCase()]);
    if (refreshToken.isEmpty) return null;
    final String accessToken = _asString(body['access_token'] ?? body['accessToken']);
    await _saveAliCredentialIfNew(
      refreshToken: refreshToken,
      accessToken: accessToken,
    );
    if (!mounted) return null;
    setState(() {
      _loggedIn = true;
      _statusText = '阿里云盘登录成功';
    });
    return null;
  }

  /// 阿里凭据保存（对齐 iOS `saveAliCredentialIfNew`，:240-263）：
  /// 同 refreshToken 去重；全新凭据对象（authType=qr / state=valid）。
  Future<void> _saveAliCredentialIfNew({
    required String refreshToken,
    String? accessToken,
  }) async {
    final CloudDriveCredentialStore store = widget.credentialStore ??
        CloudDriveCredentialStore(PrefsManager.instance);
    try {
      final CloudDriveCredential? existing =
          await store.credential(CloudDriveType.ali);
      if (existing != null && existing.refreshToken == refreshToken) return;
    } catch (_) {
      // 读旧凭据失败不阻断保存（对齐 iOS 宽松语义）。
    }
    final DateTime now = DateTime.now();
    await store.save(CloudDriveCredential(
      driveType: CloudDriveType.ali.id,
      authType: CloudDriveAuthType.qr,
      accessToken: (accessToken == null || accessToken.isEmpty)
          ? null
          : accessToken,
      refreshToken: refreshToken,
      userName: '阿里云盘用户',
      updatedAt: now,
      lastCheckedAt: now,
      state: CloudDriveAuthState.valid,
      statusMessage: '阿里云盘 OpenList 扫码登录成功',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double height = MediaQuery.of(context).size.height * 0.85;
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '阿里云盘扫码登录',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _statusText,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: _loggedIn ? Colors.green.shade700 : scheme.primary,
                  ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                _error!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(child: _buildBody(context)),
            const SizedBox(height: 8),
            Text(
              '请使用阿里云盘 App 扫描页面中的二维码完成授权；'
              '授权成功后本页将自动保存登录凭据。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (!AliyunOpenListLoginSheet.isSupported) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '当前平台不支持内嵌登录页，请改用「网页登录兜底」或手动粘贴 refresh_token。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(kAliyunOpenListStartUrl)),
        initialSettings: InAppWebViewSettings(
          userAgent: _openListUserAgent,
          javaScriptEnabled: true,
        ),
        onWebViewCreated: (InAppWebViewController controller) {
          // token 回收通道（对齐 iOS `aliTokenHandler` message handler）。
          controller.addJavaScriptHandler(
            handlerName: 'aliTokenHandler',
            callback: (List<Object?> args) => _onToken(args),
          );
        },
        onLoadStop: (InAppWebViewController controller, WebUri? url) async {
          // 页面加载完 2s 后注入 monitor（对齐 iOS `didFinish` + sleep 2s，
          // `CloudDriveAuthManager.swift:2281-2288`）。
          if (!mounted) return;
          setState(() {
            _error = null;
            _statusText = '页面已加载，请使用阿里云盘 App 扫码';
          });
          if (_monitorInjected) return;
          _monitorInjected = true;
          await Future<void>.delayed(const Duration(seconds: 2));
          if (!mounted || _loggedIn) return;
          try {
            await controller.evaluateJavascript(source: _tokenMonitorScript);
          } catch (_) {
            // 注入失败静默：页面文本轮询等 JS 兜底可能仍可用，不阻断授权。
          }
        },
        onReceivedError: (
          InAppWebViewController controller,
          WebResourceRequest request,
          WebResourceError error,
        ) {
          // 仅主文档错误置状态（子资源 404 常态，忽略）。
          if (request.isForMainFrame != true || !mounted) return;
          setState(() {
            _error = '页面加载失败：${error.description}';
          });
        },
      ),
    );
  }

  static String _asString(Object? v) => v is String ? v.trim() : '';
}

/// token 监视脚本（对齐 iOS `injectTokenMonitor`，:2315-2374）。
///
/// 扫描 input/textarea/`[data-token]`/`[data-refresh-token]` 值与页面文本中
/// 「≥50 字符且含 `.`」的 refresh_token；MutationObserver + 3s 定时轮询。
/// 回收通道：iOS `window.webkit.messageHandlers.aliTokenHandler.postMessage`
/// → Flutter `window.flutter_inappwebview.callHandler('aliTokenHandler', ...)`。
const String _tokenMonitorScript = '''
(function() {
  function post(payload) {
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('aliTokenHandler', payload);
      return true;
    }
    return false;
  }
  function checkToken() {
    var inputs = document.querySelectorAll('input, textarea, [data-token], [data-refresh-token]');
    for (var i = 0; i < inputs.length; i++) {
      var el = inputs[i];
      var val = (el.value || el.textContent || el.getAttribute('data-token') ||
                 el.getAttribute('data-refresh-token') || '').trim();
      if (val.length > 50 && val.indexOf('.') !== -1) {
        return post({ refresh_token: val, source: 'input_' + i });
      }
    }
    var allText = document.body ? (document.body.innerText || '') : '';
    var patterns = ['refresh_token', 'refreshToken', 'Refresh Token', 'refresh token'];
    for (var p = 0; p < patterns.length; p++) {
      var idx = allText.indexOf(patterns[p]);
      if (idx !== -1) {
        var after = allText.substring(idx + patterns[p].length)
                          .replace(/[:\\s：]+/g, '').trim();
        var match = after.match(/^[A-Za-z0-9_\\-\\.]{50,}/);
        if (match) {
          return post({ refresh_token: match[0], source: 'text_' + patterns[p] });
        }
      }
    }
    return false;
  }
  if (checkToken()) return;
  var observer = new MutationObserver(function() {
    if (checkToken()) observer.disconnect();
  });
  if (document.body) {
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
  }
  window.__aliTokenInterval = setInterval(function() {
    if (checkToken()) {
      clearInterval(window.__aliTokenInterval);
      observer.disconnect();
    }
  }, 3000);
})();
''';
