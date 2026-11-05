/// 数据层：TMDB 图片路由（批次 B · 图片直连探测）。
///
/// 背景：TMDB 官方图床 `image.tmdb.org` 走 AWS CloudFront，部分大陆网络被阻断；
/// TMDB 另有一个同源的 BunnyCDN 拉流域 `images.tmdb.org`
/// （CNAME `tmdb-image-prod.b-cdn.net`），多数网络可直连。
///
/// 策略（用户已确认：无新增设置项、全自动）：
///   · 每次会话（30 分钟 TTL）用一张 `w92` 小图探一次直连是否可用；
///   · 可用 → 图片走 `images.tmdb.org` 直连（不消耗用户代理）；
///   · 不可用 → 图片走用户配置的代理（与旧行为一致）。
///
/// 唯一真相源：iOS `vbox/Services/TMDBService.swift` `resolveImageRoute`。
library;

import 'package:flutter/foundation.dart';

import '../../../core/utils/logger.dart';

/// 图片取图线路。
enum TmdbImageRoute {
  /// 直连 TMDB 的 BunnyCDN（`images.tmdb.org`）。
  direct,

  /// 走用户配置的 TMDB 代理（旧行为）。
  proxy,
}

/// 会话级线路判定：缓存 + TTL + 并发去重 + 手动失效。
class TmdbImageRouteResolver {
  /// 构造（[ttl] / [now] 便于单测注入；缺省 30 分钟、系统时钟）。
  TmdbImageRouteResolver({
    this.ttl = const Duration(minutes: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 全局共享实例（App 生命周期内复用判定结果）。
  static final TmdbImageRouteResolver shared = TmdbImageRouteResolver();

  /// 回滚开关：置 false 立即回到「图片全走代理」的旧行为（不需要改调用点）。
  static bool enabled = true;

  /// 判定有效期。
  final Duration ttl;

  final DateTime Function() _now;

  TmdbImageRoute? _route;
  DateTime? _resolvedAt;
  Future<TmdbImageRoute>? _inflight;

  @visibleForTesting
  int probeCount = 0;

  /// 解析线路。
  ///
  /// [proxyReady] 为假（未启用 / 未配置代理）时恒为 [TmdbImageRoute.proxy]：
  /// 此时上层根本不会发起 TMDB 请求，返回值只用于 URL 拼接的确定行为。
  /// [probe] 返回 true 表示直连可用；异常按不可用处理。
  /// [force] 跳过缓存重探（网络切换 / 用户改代理时由调用方触发）。
  Future<TmdbImageRoute> resolve({
    required bool proxyReady,
    required Future<bool> Function() probe,
    bool force = false,
  }) {
    if (!enabled || !proxyReady) {
      return Future<TmdbImageRoute>.value(TmdbImageRoute.proxy);
    }
    final TmdbImageRoute? cached = _route;
    final DateTime? at = _resolvedAt;
    if (!force &&
        cached != null &&
        at != null &&
        _now().difference(at) < ttl) {
      return Future<TmdbImageRoute>.value(cached);
    }
    // 并发去重：同一时刻只探一次（详情页首屏只会有一个 enrich 在跑，
    // 但改代理后可能重入）。
    final Future<TmdbImageRoute>? running = _inflight;
    if (running != null && !force) return running;

    final Future<TmdbImageRoute> task = _run(probe);
    _inflight = task;
    return task;
  }

  Future<TmdbImageRoute> _run(Future<bool> Function() probe) async {
    probeCount++;
    bool ok = false;
    try {
      ok = await probe();
    } catch (e) {
      AppLog.warn('tmdb', '直连图床探测异常：$e', category: LogCategory.network);
    }
    final TmdbImageRoute route =
        ok ? TmdbImageRoute.direct : TmdbImageRoute.proxy;
    _route = route;
    _resolvedAt = _now();
    _inflight = null;
    AppLog.info(
      'tmdb',
      '图片线路=${route == TmdbImageRoute.direct ? '直连 Bunny' : '代理'}',
      category: LogCategory.network,
    );
    return route;
  }

  /// 失效（网络切换 / 代理配置变更后调用，下次 resolve 重探）。
  void invalidate() {
    _route = null;
    _resolvedAt = null;
    _inflight = null;
  }

  /// 单测复位。
  @visibleForTesting
  void debugReset() {
    _route = null;
    _resolvedAt = null;
    _inflight = null;
    probeCount = 0;
    enabled = true;
  }
}
