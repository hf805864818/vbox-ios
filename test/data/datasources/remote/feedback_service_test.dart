/// 数据层单测：Bug 反馈服务（批次 G · G-09）。
///
/// 唯一真相源：iOS `vbox/Services/FeedbackService.swift`。
///   · 状态机（标题空校验 / 提交中并发忽略 / 成功 / 失败 / reset）；
///   · fullBody 附带设备信息；
///   · GitHub 传输（URL / 头 / payload 对齐 iOS，非 2xx 抛异常）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/data/datasources/remote/feedback_service.dart';

/// 记录提交调用的假传输。
class _RecordingTransport implements FeedbackSubmitTransport {
  String? title;
  String? body;
  Object? error;
  int calls = 0;
  Completer<void>? gate;

  @override
  Future<void> submit({required String title, required String body}) async {
    calls++;
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    this.title = title;
    this.body = body;
    final Object? e = error;
    if (e != null) throw e;
  }
}

void main() {
  group('FeedbackService 状态机', () {
    test('标题为空：置错误、不进入提交、不触传输', () async {
      final _RecordingTransport transport = _RecordingTransport();
      final FeedbackService service = FeedbackService(transport: transport);
      await service.submit(title: '   ', body: '描述');
      expect(service.submitError, '请输入问题标题');
      expect(service.isSubmitting, isFalse);
      expect(service.submitSuccess, isFalse);
      expect(transport.calls, 0);
    });

    test('提交成功：isSubmitting 生命周期 + submitSuccess', () async {
      final _RecordingTransport transport = _RecordingTransport();
      final FeedbackService service = FeedbackService(transport: transport);
      bool submittedWhilePending = false;
      service.addListener(() {
        if (service.isSubmitting) submittedWhilePending = true;
      });
      await service.submit(title: '  标题  ', body: '描述');
      expect(submittedWhilePending, isTrue);
      expect(transport.title, '标题');
      expect(service.submitSuccess, isTrue);
      expect(service.submitError, isNull);
      expect(service.isSubmitting, isFalse);
    });

    test('fullBody 附带设备信息（对齐 iOS 拼接形态）', () async {
      final _RecordingTransport transport = _RecordingTransport();
      final FeedbackService service = FeedbackService(
        transport: transport,
        deviceInfo: () => const FeedbackDeviceInfo(
          appVersion: 'v1.0.0 (1)',
          systemVersion: '15.0',
          deviceModel: 'iPhone',
        ),
      );
      await service.submit(title: '标题', body: '描述');
      expect(transport.body, startsWith('描述\n\n---'));
      expect(transport.body, contains('**设备信息**'));
      expect(transport.body, contains('- App 版本：v1.0.0 (1)'));
      expect(transport.body, contains('- 系统版本：15.0'));
      expect(transport.body, contains('- 设备型号：iPhone'));
    });

    test('提交失败：submitError 置为异常信息', () async {
      final _RecordingTransport transport = _RecordingTransport()
        ..error = const FeedbackSubmitException('提交失败 (HTTP 422)');
      final FeedbackService service = FeedbackService(transport: transport);
      await service.submit(title: '标题', body: '描述');
      expect(service.submitError, '提交失败 (HTTP 422)');
      expect(service.submitSuccess, isFalse);
      expect(service.isSubmitting, isFalse);
    });

    test('提交中并发调用被忽略（防重复提交）', () async {
      final Completer<void> gate = Completer<void>();
      final _RecordingTransport transport = _RecordingTransport()..gate = gate;
      final FeedbackService service = FeedbackService(transport: transport);
      final Future<void> first = service.submit(title: 'a', body: 'b');
      expect(service.isSubmitting, isTrue);
      await service.submit(title: 'c', body: 'd');
      gate.complete();
      await first;
      expect(transport.calls, 1);
      expect(transport.title, 'a');
    });

    test('reset 清除错误 / 成功态', () async {
      final _RecordingTransport transport = _RecordingTransport();
      final FeedbackService service = FeedbackService(transport: transport);
      await service.submit(title: '标题', body: '描述');
      expect(service.submitSuccess, isTrue);
      service.reset();
      expect(service.submitSuccess, isFalse);
      expect(service.submitError, isNull);
      expect(service.isSubmitting, isFalse);
    });
  });

  group('GithubFeedbackTransport', () {
    test('POST 到 /repos/vbox-Ai/feedback/issues，头 / payload 对齐 iOS', () async {
      late http.Request captured;
      final MockClient mock = MockClient((http.Request req) async {
        captured = req;
        return http.Response('{"id": 1}', 201);
      });
      final GithubFeedbackTransport transport = GithubFeedbackTransport(
        client: HttpClient(inner: mock, retryBaseDelay: Duration.zero),
        token: 'test-token',
      );
      await transport.submit(title: '标题', body: '正文');
      expect(
        captured.url.toString(),
        'https://api.github.com/repos/vbox-Ai/feedback/issues',
      );
      expect(captured.method, 'POST');
      expect(captured.headers['authorization'], 'Bearer test-token');
      expect(captured.headers['accept'], 'application/vnd.github+json');
      expect(captured.headers['user-agent'], 'vbox-flutter-feedback');
      final Map<String, dynamic> payload =
          jsonDecode(captured.body) as Map<String, dynamic>;
      expect(payload['title'], '标题');
      expect(payload['body'], '正文');
      expect(payload['labels'], <String>['bug', '用户反馈']);
    });

    test('非 2xx：抛 FeedbackSubmitException', () async {
      final MockClient mock = MockClient(
        (http.Request req) async => http.Response('bad request', 422),
      );
      final GithubFeedbackTransport transport = GithubFeedbackTransport(
        client: HttpClient(inner: mock, retryBaseDelay: Duration.zero),
        token: 'test-token',
      );
      expect(
        () => transport.submit(title: '标题', body: '正文'),
        throwsA(isA<FeedbackSubmitException>()),
      );
    });

    test('默认 token：反转拼接生成（请求头非明文、payload 无原始片段）', () async {
      late http.Request captured;
      final MockClient mock = MockClient((http.Request req) async {
        captured = req;
        return http.Response('{}', 201);
      });
      final GithubFeedbackTransport transport = GithubFeedbackTransport(
        client: HttpClient(inner: mock, retryBaseDelay: Duration.zero),
      );
      await transport.submit(title: 't', body: 'b');
      expect(captured.headers['authorization'], startsWith('Bearer github_pat_'));
      expect(captured.body, isNot(contains('OYT0ITIAFJC11')));
      expect(captured.body, isNot(contains('rLCwG8qQDFReu')));
      expect(captured.body, isNot(contains('8As7nJLqsINKAfY4')));
    });
  });
}
