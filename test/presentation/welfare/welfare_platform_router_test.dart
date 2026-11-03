/// 呈现层单测：福利平台路由（批次 H · H-02）。
///
/// 覆盖：8 个 serviceType 的分发结果 / JS 与非 JS Spider 分流 /
/// `fuli_base` 注册命中与未注册 / `unknown`（空 + 未知）兜底原因。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';
import 'package:vbox/domain/services/fuli_base_service.dart';
import 'package:vbox/domain/services/remote_cms_v10_service.dart';
import 'package:vbox/domain/services/welfare_python_spider_service.dart';
import 'package:vbox/presentation/pages/welfare/welfare_video_bridge_page.dart';
import 'package:vbox/presentation/welfare/welfare_platform_router.dart';

/// 测试替身：最小可用的 `fuli_base` 服务。
class _FakeFuliService extends FuliBaseService {
  _FakeFuliService({
    required super.platformKey,
    super.platformName = '熊猫视频',
    super.defaultHosts = const <String>['https://a.example'],
  });

  String _host = '';
  bool _ready = false;

  /// `reprobe()` 调用计数（W-福6 断言）。
  int reprobeCount = 0;

  @override
  String get currentHost => _host;

  @override
  bool get isHostReady => _ready;

  @override
  void reprobe() {
    reprobeCount++;
    _host = primaryHost;
    _ready = primaryHost.isNotEmpty;
  }

  @override
  void resetDomain() {
    _host = '';
    _ready = false;
  }
}

WelfarePlatform platform({
  String serviceType = '',
  String? scriptType,
  String key = 'k1',
  String name = '平台',
}) =>
    WelfarePlatform(
      platformKey: key,
      name: name,
      category: WelfarePlatformCategory.video,
      serviceType: serviceType,
      scriptType: scriptType,
    );

void main() {
  group('WelfareServiceType.fromRaw', () {
    test('已知契约串逐项命中', () {
      expect(WelfareServiceType.fromRaw('ybox_special'),
          WelfareServiceType.yboxSpecial);
      expect(WelfareServiceType.fromRaw('daily_battle'),
          WelfareServiceType.dailyBattle);
      expect(WelfareServiceType.fromRaw('kanliao'),
          WelfareServiceType.kanliao);
      expect(
          WelfareServiceType.fromRaw('aidan_video'), WelfareServiceType.aidanVideo);
      expect(WelfareServiceType.fromRaw('fuli_base'),
          WelfareServiceType.fuliBase);
      expect(WelfareServiceType.fromRaw('remote_cms_v10'),
          WelfareServiceType.remoteCmsV10);
      expect(WelfareServiceType.fromRaw('welfare_spider'),
          WelfareServiceType.welfareSpider);
      expect(WelfareServiceType.fromRaw('python_spider'),
          WelfareServiceType.pythonSpider);
    });

    test('空 / 未知 / 大小写差异回退 unknown', () {
      expect(WelfareServiceType.fromRaw(null), WelfareServiceType.unknown);
      expect(WelfareServiceType.fromRaw('  '), WelfareServiceType.unknown);
      expect(WelfareServiceType.fromRaw('YBOX_SPECIAL'),
          WelfareServiceType.unknown);
      expect(WelfareServiceType.fromRaw('whatever'),
          WelfareServiceType.unknown);
    });

    test('isWelfareSpider / isRoutable 口径', () {
      expect(WelfareServiceType.welfareSpider.isWelfareSpider, isTrue);
      expect(WelfareServiceType.pythonSpider.isWelfareSpider, isTrue);
      expect(WelfareServiceType.fuliBase.isWelfareSpider, isFalse);
      expect(WelfareServiceType.unknown.isRoutable, isFalse);
      expect(WelfareServiceType.fuliBase.isRoutable, isTrue);
    });
  });

  group('WelfarePlatformRouter.resolve', () {
    test('原生专用三类分别命中对应 kind', () {
      final WelfarePlatformRouter router = WelfarePlatformRouter();

      final WelfareRoute ybox =
          router.resolve(platform(serviceType: 'ybox_special'));
      expect(ybox, isA<WelfareNativeRoute>());
      expect((ybox as WelfareNativeRoute).kind, WelfareNativeKind.bananaXjsp);

      final WelfareRoute daily =
          router.resolve(platform(serviceType: 'daily_battle'));
      expect((daily as WelfareNativeRoute).kind, WelfareNativeKind.dailyBattle);

      final WelfareRoute kanliao =
          router.resolve(platform(serviceType: 'kanliao'));
      expect((kanliao as WelfareNativeRoute).kind, WelfareNativeKind.kanliao);
    });

    test('aidan_video / remote_cms_v10 / python_spider 各归其页', () {
      final WelfarePlatformRouter router = WelfarePlatformRouter();
      expect(router.resolve(platform(serviceType: 'aidan_video')),
          isA<WelfareAidanVideoRoute>());
      expect(router.resolve(platform(serviceType: 'remote_cms_v10')),
          isA<WelfareRemoteCmsV10Route>());
      expect(router.resolve(platform(serviceType: 'python_spider')),
          isA<WelfarePythonSpiderRoute>());
    });

    test('welfare_spider：javascript 走 JS 页，其余走脚本状态页', () {
      final WelfarePlatformRouter router = WelfarePlatformRouter();
      expect(
        router.resolve(
          platform(serviceType: 'welfare_spider', scriptType: 'javascript'),
        ),
        isA<WelfareWelfareSpiderRoute>(),
      );
      expect(
        router.resolve(
          platform(serviceType: 'welfare_spider', scriptType: 'JavaScript'),
        ),
        isA<WelfareWelfareSpiderRoute>(),
        reason: 'scriptType 判定大小写不敏感',
      );
      expect(
        router.resolve(
          platform(serviceType: 'welfare_spider', scriptType: 'python'),
        ),
        isA<WelfareSpiderHomeRoute>(),
      );
      expect(
        router.resolve(platform(serviceType: 'welfare_spider')),
        isA<WelfareSpiderHomeRoute>(),
        reason: '缺 scriptType 归脚本状态页',
      );
    });

    test('welfare_spider 三重隔离违规 → 未支持页（H-04 拦截）', () {
      final WelfarePlatformRouter router = WelfarePlatformRouter();
      final WelfareRoute route = router.resolve(
        platform(serviceType: 'welfare_spider', scriptType: 'javascript')
            .copyWith(visibleInHome: true),
      );
      expect(route, isA<WelfareUnsupportedRoute>());
      expect((route as WelfareUnsupportedRoute).reason, contains('visibleInHome'));
    });

    test('welfare_spider 脚本路径越界 → 未支持页（H-04 拦截）', () {
      final WelfarePlatformRouter router = WelfarePlatformRouter();
      final WelfareRoute route = router.resolve(
        platform(
          serviceType: 'welfare_spider',
          scriptType: 'javascript',
        ).copyWith(api: './sources/other/x.py'),
      );
      expect(route, isA<WelfareUnsupportedRoute>());
      expect((route as WelfareUnsupportedRoute).reason,
          contains('sources/welfare-js/'));
    });

    test('fuli_base：注册命中 → 服务路由；未注册 → 未支持', () {
      final FuliBaseServiceRegistry registry = FuliBaseServiceRegistry();
      registry.register(_FakeFuliService(platformKey: 'panda'));
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: registry);

      final WelfareRoute hit =
          router.resolve(platform(serviceType: 'fuli_base', key: 'panda'));
      expect(hit, isA<WelfareFuliBaseRoute>());
      expect((hit as WelfareFuliBaseRoute).service.platformKey, 'panda');

      final WelfareRoute miss =
          router.resolve(platform(serviceType: 'fuli_base', key: 'nope'));
      expect(miss, isA<WelfareUnsupportedRoute>());
      expect((miss as WelfareUnsupportedRoute).reason, contains('nope'));
    });

    test('welfareSpider：已注册原生服务优先于 JS/状态页（对齐 iOS）', () {
      final FuliBaseServiceRegistry registry = FuliBaseServiceRegistry();
      registry.register(_FakeFuliService(platformKey: 'lusushequ'));
      final WelfarePlatformRouter nativeRouter =
          WelfarePlatformRouter(registry: registry);

      final WelfareRoute native = nativeRouter.resolve(
          platform(serviceType: 'welfare_spider', key: 'lusushequ'));
      expect(native, isA<WelfareFuliBaseRoute>());
      expect((native as WelfareFuliBaseRoute).service.platformKey, 'lusushequ');

      final WelfareRoute fallback = nativeRouter
          .resolve(platform(serviceType: 'welfare_spider', key: 'other'));
      expect(fallback, isA<WelfareSpiderHomeRoute>());
    });

    test('unknown：缺 serviceType 与未知串给出不同原因，均不兜底', () {
      final WelfarePlatformRouter router = WelfarePlatformRouter();

      final WelfareRoute empty = router.resolve(platform(serviceType: ''));
      expect(empty, isA<WelfareUnsupportedRoute>());
      expect((empty as WelfareUnsupportedRoute).reason, contains('缺少'));

      final WelfareRoute weird = router.resolve(platform(serviceType: 'x_y_z'));
      expect(weird, isA<WelfareUnsupportedRoute>());
      expect((weird as WelfareUnsupportedRoute).reason, contains('x_y_z'));
    });
  });

  group('WelfarePlatformRouter.makeVideoBridgeView（W-福2 重播桥）', () {
    test('fuli_base：注册命中 → 中转页；未注册 → null（不兜底）', () {
      final FuliBaseServiceRegistry registry = FuliBaseServiceRegistry();
      registry.register(_FakeFuliService(platformKey: 'panda'));
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: registry);

      final Widget? hit = router.makeVideoBridgeView(
        platform: platform(serviceType: 'fuli_base', key: 'panda'),
        vodId: 'v1',
        vodName: '片名',
        vodPic: 'http://pic',
      );
      expect(hit, isA<WelfareVideoBridgePage>());
      expect((hit! as WelfareVideoBridgePage).service.platformKey, 'panda');
      expect((hit as WelfareVideoBridgePage).video.vodId, 'v1');

      expect(
        router.makeVideoBridgeView(
          platform: platform(serviceType: 'fuli_base', key: 'nope'),
          vodId: 'v1',
          vodName: '片名',
          vodPic: 'http://pic',
        ),
        isNull,
      );
    });

    test('welfare_spider：JS 脚本 → 中转页；非 JS 无原生服务 → null', () {
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: FuliBaseServiceRegistry());

      expect(
        router.makeVideoBridgeView(
          platform: platform(
            serviceType: 'welfare_spider',
            scriptType: 'javascript',
            key: 'js1',
          ),
          vodId: 'v1',
          vodName: '片名',
          vodPic: '',
        ),
        isA<WelfareVideoBridgePage>(),
      );
      expect(
        router.makeVideoBridgeView(
          platform: platform(
            serviceType: 'welfare_spider',
            scriptType: 'python',
            key: 'stat1',
          ),
          vodId: 'v1',
          vodName: '片名',
          vodPic: '',
        ),
        isNull,
        reason: '非 JS 且无原生服务的 welfare_spider 无播放中转页',
      );
    });

    test('welfare_spider：已注册原生服务优先于 JS 引擎', () {
      final FuliBaseServiceRegistry registry = FuliBaseServiceRegistry();
      registry.register(_FakeFuliService(platformKey: 'lusushequ'));
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: registry);

      final Widget? view = router.makeVideoBridgeView(
        platform: platform(serviceType: 'welfare_spider', key: 'lusushequ'),
        vodId: 'v1',
        vodName: '片名',
        vodPic: '',
      );
      expect(view, isA<WelfareVideoBridgePage>());
      expect((view! as WelfareVideoBridgePage).service.platformKey, 'lusushequ');
    });

    test('python_spider → 中转页', () {
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: FuliBaseServiceRegistry());
      expect(
        router.makeVideoBridgeView(
          platform: platform(serviceType: 'python_spider', key: 'py1'),
          vodId: 'v1',
          vodName: '片名',
          vodPic: '',
        ),
        isA<WelfareVideoBridgePage>(),
      );
    });

    test('aidan_video：platformKey 未命中时回落固定键 aidan_video', () {
      final FuliBaseServiceRegistry registry = FuliBaseServiceRegistry();
      registry.register(_FakeFuliService(
        platformKey: 'aidan_video',
        platformName: '艾旦福利视频',
      ));
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: registry);

      final Widget? view = router.makeVideoBridgeView(
        platform: platform(serviceType: 'aidan_video', key: 'aidan_remote'),
        vodId: 'v1',
        vodName: '片名',
        vodPic: '',
      );
      expect(view, isA<WelfareVideoBridgePage>());
      expect((view! as WelfareVideoBridgePage).service.platformKey, 'aidan_video');
    });

    test('remote_cms_v10 → 中转页（UI-C1c 页面已落地）', () {
      RemoteCmsV10FuliService.clearCache();
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: FuliBaseServiceRegistry());
      final Widget? view = router.makeVideoBridgeView(
        platform: platform(serviceType: 'remote_cms_v10', key: 'cms1'),
        vodId: 'v1',
        vodName: '片名',
        vodPic: '',
      );
      expect(view, isA<WelfareVideoBridgePage>());
      expect(
        (view! as WelfareVideoBridgePage).service.platformKey,
        'cms1',
      );
      RemoteCmsV10FuliService.clearCache();
    });

    test('原生专用 / unknown → null（页面未落地，不兜底）', () {
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: FuliBaseServiceRegistry());
      for (final String type in <String>[
        'ybox_special',
        'daily_battle',
        'kanliao',
        '',
        'x_y_z',
      ]) {
        expect(
          router.makeVideoBridgeView(
            platform: platform(serviceType: type, key: 'k'),
            vodId: 'v1',
            vodName: '片名',
            vodPic: '',
          ),
          isNull,
          reason: type,
        );
      }
    });
  });

  group('WelfarePlatformRouter.triggerServiceReset（W-福6）', () {
    tearDown(WelfarePythonSpiderService.clearCache);

    test('fuli_base：命中注册服务 → reprobe；未注册 → 无操作', () {
      final FuliBaseServiceRegistry registry = FuliBaseServiceRegistry();
      final _FakeFuliService fake = _FakeFuliService(platformKey: 'panda');
      registry.register(fake);
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: registry);

      router.triggerServiceReset(
          platform(serviceType: 'fuli_base', key: 'panda'));
      expect(fake.reprobeCount, 1);

      // 未注册 key：不抛异常、不误触其他服务。
      router.triggerServiceReset(
          platform(serviceType: 'fuli_base', key: 'nope'));
      expect(fake.reprobeCount, 1);
    });

    test('aidan_video：platformKey 不同时回落固定键 aidan_video', () {
      final FuliBaseServiceRegistry registry = FuliBaseServiceRegistry();
      final _FakeFuliService fake =
          _FakeFuliService(platformKey: 'aidan_video');
      registry.register(fake);
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: registry);

      router.triggerServiceReset(
          platform(serviceType: 'aidan_video', key: 'aidan_remote'));
      expect(fake.reprobeCount, 1);
    });

    test('daily_battle / kanliao：命中同名注册服务 → reprobe', () {
      final FuliBaseServiceRegistry registry = FuliBaseServiceRegistry();
      final _FakeFuliService battle = _FakeFuliService(platformKey: 'daily');
      final _FakeFuliService kanliao = _FakeFuliService(platformKey: 'kl');
      registry.register(battle);
      registry.register(kanliao);
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: registry);

      router.triggerServiceReset(
          platform(serviceType: 'daily_battle', key: 'daily'));
      router.triggerServiceReset(
          platform(serviceType: 'kanliao', key: 'kl'));
      expect(battle.reprobeCount, 1);
      expect(kanliao.reprobeCount, 1);
    });

    test('welfare_spider：已注册原生服务补重探测；纯 JS 脚本无操作', () {
      final FuliBaseServiceRegistry registry = FuliBaseServiceRegistry();
      final _FakeFuliService fake = _FakeFuliService(platformKey: 'lusushequ');
      registry.register(fake);
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: registry);

      router.triggerServiceReset(
          platform(serviceType: 'welfare_spider', key: 'lusushequ'));
      expect(fake.reprobeCount, 1);

      // 纯 JS 脚本（无原生服务）→ 无操作，不误触已注册服务。
      router.triggerServiceReset(
          platform(
            serviceType: 'welfare_spider',
            key: 'js1',
            scriptType: 'javascript',
          ));
      expect(fake.reprobeCount, 1);
    });

    test('unknown / ybox_special / remote_cms_v10：无操作不抛异常', () {
      final WelfarePlatformRouter router = WelfarePlatformRouter();
      for (final String type in <String>[
        'unknown_x',
        'ybox_special',
        'remote_cms_v10',
      ]) {
        expect(
          () => router.triggerServiceReset(platform(serviceType: type)),
          returnsNormally,
          reason: type,
        );
      }
    });

    test('python_spider：触发 Python 服务 reprobe（不抛异常）', () {
      final WelfarePlatformRouter router =
          WelfarePlatformRouter(registry: FuliBaseServiceRegistry());
      expect(
        () => router.triggerServiceReset(
            platform(serviceType: 'python_spider', key: 'py1')),
        returnsNormally,
      );
    });
  });

  group('FuliBaseServiceRegistry', () {
    test('空 platformKey 不注册；unregister / serviceFor 行为', () {
      final FuliBaseServiceRegistry registry = FuliBaseServiceRegistry();
      registry.register(_FakeFuliService(platformKey: ''));
      expect(registry.count, 0);

      registry.register(_FakeFuliService(platformKey: 'panda'));
      expect(registry.count, 1);
      expect(registry.serviceFor('panda'), isNotNull);
      expect(registry.unregister('panda'), isTrue);
      expect(registry.serviceFor('panda'), isNull);
      expect(registry.unregister('panda'), isFalse);
    });
  });
}