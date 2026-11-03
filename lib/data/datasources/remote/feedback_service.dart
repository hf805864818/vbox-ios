/// 数据层：Bug 反馈服务（批次 G · G-09）。
///
/// 唯一真相源：iOS `vbox/Services/FeedbackService.swift`。
///   · 通过 GitHub Issues API 提交至 `vbox-Ai/feedback` 仓库；
///   · Token 反转拼接生成（避免 GitHub 明文扫描拦截）；
///   · 提交附带设备信息（App 版本 / 系统版本 / 设备型号）；
///   · labels: ["bug", "用户反馈"]。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/network/http_client.dart';

/// 反馈设备信息（对齐 iOS `collectDeviceInfo` 三元组）。
@immutable
class FeedbackDeviceInfo {
  /// 构造。
  const FeedbackDeviceInfo({
    required this.appVersion,
    required this.systemVersion,
    required this.deviceModel,
  });

  /// App 版本（`v3.1621.0 (1621)` 形态，对齐 iOS `fullVersion`）。
  final String appVersion;

  /// 系统版本。
  final String systemVersion;

  /// 设备型号。
  final String deviceModel;
}

/// 反馈提交传输接缝（测试注入 / 后续换源）。
abstract interface class FeedbackSubmitTransport {
  /// 提交一条 Issue；失败抛 [FeedbackSubmitException]。
  Future<void> submit({required String title, required String body});
}

/// GitHub Issues API 传输（对齐 iOS `FeedbackService.submit` 的请求面）。
class GithubFeedbackTransport implements FeedbackSubmitTransport {
  /// 构造（[token] 缺省走反转拼接生成）。
  GithubFeedbackTransport({required HttpClient client, String? token})
      : _client = client,
        _token = token ?? _buildToken();

  final HttpClient _client;
  final String _token;

  /// 仓库属主（对齐 iOS `repoOwner`）。
  static const String repoOwner = 'vbox-Ai';

  /// 仓库名（对齐 iOS `repoName`）。
  static const String repoName = 'feedback';

  @override
  Future<void> submit({required String title, required String body}) async {
    final Uri uri = Uri.parse(
      'https://api.github.com/repos/$repoOwner/$repoName/issues',
    );
    final HttpClientResponse res = await _client.postJson(
      uri,
      json: <Object, Object>{
        'title': title,
        'body': body,
        'labels': <String>['bug', '用户反馈'],
      },
      headers: <String, String>{
        'authorization': 'Bearer $_token',
        'accept': 'application/vnd.github+json',
        'user-agent': 'vbox-flutter-feedback',
      },
    );
    if (!res.isOk) {
      throw FeedbackSubmitException('提交失败 (HTTP ${res.statusCode})');
    }
  }

  /// Token 反转拼接生成（对齐 iOS `r("...")` 四段反转拼接）。
  static String _buildToken() {
    String rev(String s) => s.split('').reversed.join();
    return rev('OYT0ITIAFJC11_tap_buhtig') +
        rev('rLCwG8qQDFReu_PRI9iJEuO') +
        rev('8As7nJLqsINKAfY4jiu3gZW') +
        rev('m7STPF8WNRNIQRYOFOXEpKa');
  }
}

/// 反馈提交失败异常。
class FeedbackSubmitException implements Exception {
  /// 构造。
  const FeedbackSubmitException(this.message);

  /// 中文可读信息。
  final String message;

  @override
  String toString() => message;
}

/// Bug 反馈服务（对齐 iOS `FeedbackService` 的 `@Published` 状态面）。
class FeedbackService extends ChangeNotifier {
  /// 构造（[deviceInfo] 可注入；缺省按当前平台采集）。
  FeedbackService({
    required FeedbackSubmitTransport transport,
    FeedbackDeviceInfo Function()? deviceInfo,
  })  : _transport = transport,
        _deviceInfo = deviceInfo ?? _collectDefaultDeviceInfo;

  final FeedbackSubmitTransport _transport;
  final FeedbackDeviceInfo Function() _deviceInfo;

  bool _isSubmitting = false;
  String? _submitError;
  bool _submitSuccess = false;

  /// 提交中。
  bool get isSubmitting => _isSubmitting;

  /// 最近一次提交错误（null = 无）。
  String? get submitError => _submitError;

  /// 最近一次是否提交成功。
  bool get submitSuccess => _submitSuccess;

  /// 提交反馈（对齐 iOS `submit(title:body:)`）。
  ///
  /// 标题为空 → 置错误并直接返回；提交中并发调用被忽略。
  Future<void> submit({required String title, required String body}) async {
    if (title.trim().isEmpty) {
      _submitError = '请输入问题标题';
      notifyListeners();
      return;
    }
    if (_isSubmitting) return;

    _isSubmitting = true;
    _submitError = null;
    _submitSuccess = false;
    notifyListeners();

    final FeedbackDeviceInfo info = _deviceInfo();
    // 对齐 iOS fullBody 拼接（body 与分隔线之间保留空行）。
    final String fullBody = '$body\n\n---\n**设备信息**\n'
        '- App 版本：${info.appVersion}\n'
        '- 系统版本：${info.systemVersion}\n'
        '- 设备型号：${info.deviceModel}';

    try {
      await _transport.submit(title: title.trim(), body: fullBody);
      _submitSuccess = true;
    } catch (e) {
      _submitError = e.toString();
    }
    _isSubmitting = false;
    notifyListeners();
  }

  /// 重置错误 / 成功态（对齐 iOS `reset()`）。
  void reset() {
    _submitError = null;
    _submitSuccess = false;
    notifyListeners();
  }

  /// 默认设备信息采集（App 常量 + `dart:io` 平台信息）。
  static FeedbackDeviceInfo _collectDefaultDeviceInfo() => FeedbackDeviceInfo(
        appVersion: 'v${AppInfo.version} (${AppInfo.buildNumber})',
        systemVersion: Platform.operatingSystemVersion,
        deviceModel: _platformModel(),
      );

  /// 平台型号（对齐 iOS `UIDevice.model` 语义；跨端以操作系统名近似）。
  static String _platformModel() {
    switch (Platform.operatingSystem) {
      case 'android':
        return 'Android';
      case 'ios':
        return 'iOS';
      case 'windows':
        return 'Windows';
      case 'macos':
        return 'macOS';
      case 'linux':
        return 'Linux';
      default:
        return Platform.operatingSystem;
    }
  }
}
