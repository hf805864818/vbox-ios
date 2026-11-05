/// 数据层单测：TMDB 图片线路判定（批次 B）。
///
/// 对齐真相源：iOS `vbox/Services/TMDBService.swift` `resolveImageRoute`。
/// 覆盖：未配置代理 / 关闭开关 / 直连可用 / 缓存命中 / TTL 过期 / 强制重探 /
/// 失效 / 探测异常 / 并发去重。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/remote/tmdb_image_route.dart';

void main() {
  late TmdbImageRouteResolver resolver;
  late DateTime now;
  late int probeCalls;

  setUp(() {
    now = DateTime(2026, 1, 1, 12);
    probeCalls = 0;
    resolver = TmdbImageRouteResolver(now: () => now);
    TmdbImageRouteResolver.enabled = true;
  });

  tearDown(() => resolver.debugReset());

  Future<bool> probeTrue() async {
    probeCalls++;
    return true;
  }

  Future<bool> probeFalse() async {
    probeCalls++;
    return false;
  }

  test('未配置代理 → 恒为 proxy，且不探测', () async {
    final TmdbImageRoute route = await resolver.resolve(
      proxyReady: false,
      probe: probeTrue,
    );
    expect(route, TmdbImageRoute.proxy);
    expect(probeCalls, 0);
  });

  test('回滚开关 enabled=false → 恒为 proxy，且不探测', () async {
    TmdbImageRouteResolver.enabled = false;
    final TmdbImageRoute route = await resolver.resolve(
      proxyReady: true,
      probe: probeTrue,
    );
    expect(route, TmdbImageRoute.proxy);
    expect(probeCalls, 0);
  });

  test('直连可用 → direct，并在 TTL 内复用（不重复探测）', () async {
    final TmdbImageRoute first =
        await resolver.resolve(proxyReady: true, probe: probeTrue);
    expect(first, TmdbImageRoute.direct);
    expect(probeCalls, 1);

    now = now.add(const Duration(minutes: 10));
    final TmdbImageRoute second =
        await resolver.resolve(proxyReady: true, probe: probeFalse);
    expect(second, TmdbImageRoute.direct);
    expect(probeCalls, 1);
  });

  test('TTL 过期 → 重新探测', () async {
    await resolver.resolve(proxyReady: true, probe: probeTrue);
    now = now.add(const Duration(minutes: 31));
    final TmdbImageRoute route =
        await resolver.resolve(proxyReady: true, probe: probeFalse);
    expect(route, TmdbImageRoute.proxy);
    expect(probeCalls, 2);
  });

  test('force → 跳过缓存重探', () async {
    await resolver.resolve(proxyReady: true, probe: probeTrue);
    final TmdbImageRoute route = await resolver.resolve(
      proxyReady: true,
      probe: probeFalse,
      force: true,
    );
    expect(route, TmdbImageRoute.proxy);
    expect(probeCalls, 2);
  });

  test('invalidate → 下次重探', () async {
    await resolver.resolve(proxyReady: true, probe: probeTrue);
    resolver.invalidate();
    final TmdbImageRoute route =
        await resolver.resolve(proxyReady: true, probe: probeFalse);
    expect(route, TmdbImageRoute.proxy);
    expect(probeCalls, 2);
  });

  test('探测抛异常 → 按不可用处理（proxy）', () async {
    final TmdbImageRoute route = await resolver.resolve(
      proxyReady: true,
      probe: () async => throw StateError('boom'),
    );
    expect(route, TmdbImageRoute.proxy);
  });

  test('并发 resolve 只探测一次', () async {
    final Future<TmdbImageRoute> a =
        resolver.resolve(proxyReady: true, probe: probeTrue);
    final Future<TmdbImageRoute> b =
        resolver.resolve(proxyReady: true, probe: probeTrue);
    expect(await a, TmdbImageRoute.direct);
    expect(await b, TmdbImageRoute.direct);
    expect(probeCalls, 1);
  });
}
