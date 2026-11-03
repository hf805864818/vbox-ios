/// 领域层：原生福利平台服务（批次 H · Fuli-S1）。
///
/// 对齐 iOS `WelfarePlatformRouter.makeFuliBaseDestination`（L164-L180）注册的
/// 4 个 `fuli_base` key：`panda_video` / `four_h_video` / `full_hd` / `banana_video`；
/// 另附 `aidan_video`（iOS `AidanVideoService`，走 `aidan_video` 路由）与
/// `lusushequ`（iOS 走 `welfare_spider` + 原生 `LusushequService`）。
///
/// 域名就绪：`reprobe()` 逐个探测 `allHosts`（自定义域名在前 + 默认域名），
/// 首个可达即就绪（对齐 iOS `FuliBaseService.reprobe()` L121-L152）。
///
/// **差异登记（如实）**：各平台**内容解析**（HTML / POST API）未在本批移植——
/// `fetch*` 走基类默认空实现（iOS 各子类覆写）。本批先打通「服务注册 + 路由可达 +
/// 域名探测」；内容解析随各平台批次补（对齐 iOS 对应子类的 parser）。
library;

import 'dart:async';

import '../../data/datasources/local/welfare_domain_store.dart';
import '../../platform/spider/spider_http_bridge.dart';
import 'fuli_base_service.dart';

/// 带域名探测的原生福利平台服务基类。
abstract class ProbedFuliService extends FuliBaseService {
  /// 构造（[bridge] 供测试注入假传输）。
  ProbedFuliService({
    required super.platformKey,
    required super.platformName,
    required super.defaultHosts,
    SpiderHttpBridge? bridge,
  }) : _bridge = bridge ?? SpiderHttpBridge();

  final SpiderHttpBridge _bridge;

  /// 底层 HTTP 桥（供子类复用，避免二次自建传输 / 丢失代理与 SSL 配置）。
  SpiderHttpBridge get bridge => _bridge;

  String _probedHost = '';
  bool _ready = false;

  @override
  String get currentHost => _probedHost.isEmpty ? primaryHost : _probedHost;

  @override
  bool get isHostReady => _ready;

  /// 逐个探测可用域名（自定义 → 默认），首个可达即就绪；全部失败保持未就绪。
  Future<void> probeHosts() async {
    for (final String host in allHosts) {
      if (host.trim().isEmpty) continue;
      if (await _reachable(host)) {
        _probedHost = host;
        _ready = true;
        return;
      }
    }
    _probedHost = '';
    _ready = false;
  }

  /// 探测单个域名可达性（HTTP 2xx/3xx；超时 5s，对齐 iOS `reprobe` 口径）。
  Future<bool> _reachable(String host) async {
    final String url = applyProxyIfNeeded(host);
    try {
      final SpiderHttpResult res = await _bridge.request(
        url,
        options: const SpiderHttpOptions(timeout: Duration(seconds: 5)),
      );
      return res.ok;
    } catch (_) {
      return false;
    }
  }

  @override
  void reprobe() {
    unawaited(probeHosts());
  }

  @override
  void resetDomain() {
    WelfareDomainStore.shared.clearDomains(platformName);
    unawaited(probeHosts());
  }
}

/// 熊猫视频（`panda_video`，POST API 类）。
class PandaFuliService extends ProbedFuliService {
  /// 构造。
  PandaFuliService({super.bridge})
      : super(
          platformKey: 'panda_video',
          platformName: '熊猫视频',
          defaultHosts: const <String>[
            'https://spiderscloudcn2.51111666.com',
            'https://spiderscloudcn1.51111666.com',
          ],
        );
}

/// 4H 视频（`four_h_video`，HTML 类）。
class FourHFuliService extends ProbedFuliService {
  /// 构造。
  FourHFuliService({super.bridge})
      : super(
          platformKey: 'four_h_video',
          platformName: '4H视频',
          defaultHosts: const <String>[
            'https://4h05.cc',
            'https://4h04.cc',
            'https://4h03.cc',
          ],
        );
}

/// FullHD（`full_hd`，HTML 类）。
class FullHDFuliService extends ProbedFuliService {
  /// 构造。
  FullHDFuliService({super.bridge})
      : super(
          platformKey: 'full_hd',
          platformName: 'FullHD',
          defaultHosts: const <String>[
            'https://www.fullhd.xxx',
            'https://fullhd.xxx',
          ],
        );
}

/// 香蕉视频（`banana_video`，HTML 类；标题 XOR 解密，解析待补）。
class BananaFuliService extends ProbedFuliService {
  /// 构造。
  BananaFuliService({super.bridge})
      : super(
          platformKey: 'banana_video',
          platformName: '香蕉视频',
          defaultHosts: const <String>[
            'https://618013.xyz',
            'https://618012.xyz',
            'https://618011.xyz',
            'https://618010.xyz',
            'https://618009.xyz',
          ],
        );
}

/// 艾旦福利视频（`aidan_video`，CMS V10 类）。
class AidanFuliService extends ProbedFuliService {
  /// 构造。
  AidanFuliService({super.bridge})
      : super(
          platformKey: 'aidan_video',
          platformName: '艾旦福利视频',
          defaultHosts: const <String>['https://www.lovedan.net'],
        );
}

/// 六速社区（`lusushequ`，iOS 走 `welfare_spider` + 原生 Service）。
class LusushequFuliService extends ProbedFuliService {
  /// 构造。
  LusushequFuliService({super.bridge})
      : super(
          platformKey: 'lusushequ',
          platformName: '六速社区',
          defaultHosts: const <String>['https://215.x89cneo.com:51111'],
        );
}

/// 注册原生福利平台服务（应用装配时调用；对齐 iOS 各 `*Service.shared` 的接线）。
///
/// [registry] / [bridge] 供测试注入。
void registerNativeFuliServices({
  FuliBaseServiceRegistry? registry,
  SpiderHttpBridge? bridge,
}) {
  final FuliBaseServiceRegistry target =
      registry ?? FuliBaseServiceRegistry.shared;
  // fuli_base（iOS makeFuliBaseDestination 的 4 个 key）。
  target.register(PandaFuliService(bridge: bridge));
  target.register(FourHFuliService(bridge: bridge));
  target.register(FullHDFuliService(bridge: bridge));
  target.register(BananaFuliService(bridge: bridge));
  // aidan_video / lusushequ（iOS 走各自路由，服务同源注册）。
  target.register(AidanFuliService(bridge: bridge));
  target.register(LusushequFuliService(bridge: bridge));
}