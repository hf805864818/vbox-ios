/// 领域层单测：原生福利平台服务注册 + 域名探测（Fuli-S1）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/services/fuli_base_service.dart';
import 'package:vbox/domain/services/native_fuli_services.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';

/// 假传输：按 URL 判定可达（200 / 502）。
class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this.okPredicate);

  final bool Function(String url) okPredicate;

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async =>
      okPredicate(request.url.toString())
          ? const SpiderTransportResponse(
              status: 200,
              headers: <String, String>{
                'content-type': 'text/html; charset=utf-8',
              },
              bodyBytes: <int>[1],
            )
          : const SpiderTransportResponse(
              status: 502,
              headers: <String, String>{},
              bodyBytes: <int>[],
            );
}

SpiderHttpBridge _bridge(bool Function(String url) ok) =>
    SpiderHttpBridge(transport: _FakeTransport(ok));

void main() {
  test('注册原生福利服务：6 个 key（对齐 iOS 路由）', () {
    final FuliBaseServiceRegistry registry = FuliBaseServiceRegistry();
    registerNativeFuliServices(registry: registry);

    expect(registry.count, 6);
    for (final String key in <String>[
      'panda_video',
      'four_h_video',
      'full_hd',
      'banana_video',
      'aidan_video',
      'lusushequ',
    ]) {
      expect(registry.serviceFor(key), isNotNull, reason: key);
    }
    // 平台名与默认域名（对齐 iOS 子类）。
    expect(registry.serviceFor('full_hd')!.platformName, 'FullHD');
    expect(registry.serviceFor('aidan_video')!.defaultHosts.first,
        'https://www.lovedan.net');
  });

  test('域名探测：首个可达域名即就绪（自定义 → 默认顺序）', () async {
    final FourHFuliService service = FourHFuliService(
      bridge: _bridge((String url) => url.contains('4h04.cc')),
    );
    expect(service.isHostReady, isFalse);

    await service.probeHosts();

    expect(service.isHostReady, isTrue);
    expect(service.currentHost, contains('4h04.cc'));
  });

  test('域名探测：全部不可达 → 未就绪且回退首个默认域名展示', () async {
    final PandaFuliService service = PandaFuliService(
      bridge: _bridge((String url) => false),
    );

    await service.probeHosts();

    expect(service.isHostReady, isFalse);
    expect(service.currentHost, service.primaryHost);
    expect(service.primaryHost, 'https://spiderscloudcn2.51111666.com');
  });

  test('reprobe 为异步触发（不抛异常）', () {
    final FullHDFuliService service = FullHDFuliService(
      bridge: _bridge((String url) => false),
    );
    expect(service.reprobe, returnsNormally);
  });
}