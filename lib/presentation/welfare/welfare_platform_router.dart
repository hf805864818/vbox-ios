/// 表现层：福利平台路由（批次 H · H-02）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/WelfarePlatformRouter.swift`
///   · `makeDestinationView(for:settings:)`（L96-L154）：按 `serviceType` 分发；
///   · `makeFuliBaseDestination`（L160-L184）：`fuli_base` 按 `platformKey` 映射子类；
///   · `makeWelfareSpiderDestination`（L196-L226）：JS 脚本 → JS 引擎页，
///     其余 → Spider 脚本状态页；
///   · `unknown` → `UnsupportedPlatformView`（**不兜底**到其他平台）。
///
/// 移植口径：本批产出**路由描述**（[WelfareRoute]），不直接产出 Widget ——
/// 目标页面（`FuliPlatformMainView` 等）随「福利原生平台 / H-03 Spider」批次落地；
/// 页面层据描述构建实际页面（当前 `unknown` / 未注册 → [WelfareUnsupportedRoute]）。
library;

import 'package:flutter/widgets.dart';

import '../../domain/entities/welfare/welfare.dart';
import '../../domain/services/banana_xjsp_service.dart';
import '../../domain/services/daily_battle_service.dart';
import '../../domain/services/fuli_base_service.dart';
import '../../domain/services/kanliao_service.dart';
import '../../domain/services/remote_cms_v10_service.dart';
import '../../domain/services/welfare_js_spider_service.dart';
import '../../domain/services/welfare_python_spider_service.dart';
import '../pages/welfare/welfare_video_bridge_page.dart';

/// 原生专用平台种类（对齐 iOS 三个专用 View）。
enum WelfareNativeKind {
  /// 香蕉秀专用（`ybox_special` → `YBoxXjspMainView`）。
  bananaXjsp('香蕉秀专用页'),

  /// 每日大乱斗 / 每日大赛（`daily_battle` → `DailyBattleMainView`）。
  dailyBattle('每日大乱斗页'),

  /// 今日看料（`kanliao` → `KanliaoHomeView`）。
  kanliao('今日看料页');

  const WelfareNativeKind(this.label);

  /// 目标页面中文名。
  final String label;
}

/// 福利平台路由结果（按 [WelfarePlatform.service] 解析）。
sealed class WelfareRoute {
  /// 构造。
  const WelfareRoute(this.platform);

  /// 触发路由的平台元数据。
  final WelfarePlatform platform;

  /// 目标页面族中文名（提示 / 测试断言用）。
  String get destinationLabel;
}

/// 原生专用平台页（`ybox_special` / `daily_battle` / `kanliao`）。
final class WelfareNativeRoute extends WelfareRoute {
  /// 构造。
  const WelfareNativeRoute(super.platform, this.kind);

  /// 原生专用种类。
  final WelfareNativeKind kind;

  @override
  String get destinationLabel => kind.label;
}

/// 艾旦福利视频页（`aidan_video`，CMS V10 专用）。
final class WelfareAidanVideoRoute extends WelfareRoute {
  /// 构造。
  const WelfareAidanVideoRoute(super.platform);

  @override
  String get destinationLabel => '艾旦福利视频页';
}

/// 通用福利平台页（`fuli_base`，服务已注册）。
final class WelfareFuliBaseRoute extends WelfareRoute {
  /// 构造。
  const WelfareFuliBaseRoute(super.platform, this.service);

  /// 命中的服务实例。
  final FuliBaseService service;

  @override
  String get destinationLabel => '通用福利平台页';
}

/// 远程 CMS V10 福利页（`remote_cms_v10`）。
final class WelfareRemoteCmsV10Route extends WelfareRoute {
  /// 构造。
  const WelfareRemoteCmsV10Route(super.platform, this.service);

  /// 由平台配置驱动的 CMS V10 服务（UI-C1c，对齐 iOS `RemoteCMSV10Service`）。
  final FuliBaseService service;

  @override
  String get destinationLabel => '远程 CMS V10 福利页';
}

/// 福利 JS Spider 页（`welfare_spider` + `scriptType == javascript`）。
final class WelfareWelfareSpiderRoute extends WelfareRoute {
  /// 构造。
  const WelfareWelfareSpiderRoute(super.platform);

  @override
  String get destinationLabel => '福利 JS Spider 页';
}

/// 福利 Spider 脚本状态页（`welfare_spider` 非 JS）。
final class WelfareSpiderHomeRoute extends WelfareRoute {
  /// 构造。
  const WelfareSpiderHomeRoute(super.platform);

  @override
  String get destinationLabel => '福利 Spider 脚本页';
}

/// 福利 Python Spider 页（`python_spider`）。
final class WelfarePythonSpiderRoute extends WelfareRoute {
  /// 构造。
  const WelfarePythonSpiderRoute(super.platform);

  @override
  String get destinationLabel => '福利 Python Spider 页';
}

/// 未支持平台页（`unknown` / `fuli_base` 未注册服务）。
final class WelfareUnsupportedRoute extends WelfareRoute {
  /// 构造。
  const WelfareUnsupportedRoute(super.platform, this.reason);

  /// 未支持原因（排查日志 / 页面展示用）。
  final String reason;

  @override
  String get destinationLabel => '未支持平台页';
}

/// 福利平台路由分发器（对齐 iOS `WelfarePlatformRouter`）。
class WelfarePlatformRouter {
  /// 构造（注册表可注入，默认取全局共享实例）。
  WelfarePlatformRouter({FuliBaseServiceRegistry? registry})
      : _registry = registry ?? FuliBaseServiceRegistry.shared;

  final FuliBaseServiceRegistry _registry;

  /// 按 `serviceType` 解析路由（5 类路由 + 原生专用 + 未支持）。
  WelfareRoute resolve(WelfarePlatform platform) {
    switch (platform.service) {
      case WelfareServiceType.yboxSpecial:
        return WelfareNativeRoute(platform, WelfareNativeKind.bananaXjsp);
      case WelfareServiceType.dailyBattle:
        return WelfareNativeRoute(platform, WelfareNativeKind.dailyBattle);
      case WelfareServiceType.kanliao:
        return WelfareNativeRoute(platform, WelfareNativeKind.kanliao);
      case WelfareServiceType.aidanVideo:
        return WelfareAidanVideoRoute(platform);
      case WelfareServiceType.fuliBase:
        final FuliBaseService? service =
            _registry.serviceFor(platform.platformKey);
        if (service == null) {
          return WelfareUnsupportedRoute(
            platform,
            'fuli_base 平台未注册服务：${platform.platformKey}',
          );
        }
        return WelfareFuliBaseRoute(platform, service);
      case WelfareServiceType.remoteCmsV10:
        // UI-C1c：由平台配置驱动的 CMS V10 服务（对齐 iOS
        // `RemoteCMSV10Service.service(for:)`）。
        return WelfareRemoteCmsV10Route(
          platform,
          RemoteCmsV10FuliService.serviceFor(platform),
        );
      case WelfareServiceType.welfareSpider:
        // 对齐 iOS `makeWelfareSpiderDestination` 优先级：
        // ① 已注册原生服务（如 lusushequ）→ 原生平台页；
        // ② 三重隔离前置（H-04）：违规平台一律进未支持页；
        // ③ JS 脚本 → JS 引擎页；其余 → 脚本状态页。
        final FuliBaseService? native =
            _registry.serviceFor(platform.platformKey);
        if (native != null) {
          return WelfareFuliBaseRoute(platform, native);
        }
        final String? violation = WelfareIsolationPolicy.violationFor(platform);
        if (violation != null) {
          return WelfareUnsupportedRoute(platform, violation);
        }
        return platform.isJavaScriptSpider
            ? WelfareWelfareSpiderRoute(platform)
            : WelfareSpiderHomeRoute(platform);
      case WelfareServiceType.pythonSpider:
        return WelfarePythonSpiderRoute(platform);
      case WelfareServiceType.unknown:
        return WelfareUnsupportedRoute(
          platform,
          platform.serviceType.trim().isEmpty
              ? '远程配置缺少 serviceType'
              : '未知 serviceType：${platform.serviceType}',
        );
    }
  }

  /// 域名 / 代理变更后触发对应 Service 重探测（W-福6，对齐 iOS
  /// `RemoteWelfareSettingsView.triggerServiceReset` L573-L603）。
  ///
  /// 消费场景：设置页保存 / 清除代理、切换平台代理开关、增删 / 清空自定义域名后
  /// 立即让对应服务的域名缓存失效并重新探测，**无需重启应用**。
  ///
  /// 差异登记：iOS 对 `welfare_spider` 一律 no-op（纯 JS 脚本内实例「下次进入」
  /// 重新解析）；Flutter 除 JS 脚本外还有 `lusushequ` 等已注册原生服务，故此处
  /// 额外对命中注册表的原生服务补一次 `reprobe()`（超集，不改变 JS 脚本语义）。
  void triggerServiceReset(WelfarePlatform platform) {
    switch (platform.service) {
      case WelfareServiceType.fuliBase:
        _registry.serviceFor(platform.platformKey)?.reprobe();
      case WelfareServiceType.dailyBattle:
        // UI-C1b：每日大乱斗 / 每日大赛原生专用服务重探测（对齐 iOS
        // `DailyBattleService.reprobe`）。注册表命中优先（测试 / 注入场景），
        // 否则回退按平台名解析的共享实例。
        (_registry.serviceFor(platform.platformKey) ??
                DailyBattleFuliService.serviceFor(
                  platformKey: platform.platformKey,
                  platformName: platform.name,
                ))
            .reprobe();
      case WelfareServiceType.kanliao:
        // UI-C1e：今日看料原生专用服务重探测（对齐 iOS `KanliaoService.reprobe`）。
        // 注册表命中优先（测试 / 注入场景），否则回退共享实例（对齐 aidan 固定键模式）。
        (_registry.serviceFor(platform.platformKey) ??
                KanliaoFuliService.serviceFor())
            .reprobe();
      case WelfareServiceType.aidanVideo:
        // aidan 用固定服务，键名回落 'aidan_video'（远程配置的 platformKey 可能不同）。
        (_registry.serviceFor(platform.platformKey) ??
                _registry.serviceFor('aidan_video'))
            ?.reprobe();
      case WelfareServiceType.pythonSpider:
        WelfarePythonSpiderService.serviceFor(platform).reprobe();
      case WelfareServiceType.welfareSpider:
        // 纯 JS 脚本无操作（对齐 iOS）；已注册原生服务补一次重探测。
        _registry.serviceFor(platform.platformKey)?.reprobe();
      case WelfareServiceType.remoteCmsV10:
        // UI-C1c：域名 / 代理变更 → CMS V10 服务重探测（对齐 iOS
        // `RemoteCMSV10Service.service(for:).reprobe()`）。
        RemoteCmsV10FuliService.serviceFor(platform).reprobe();
      case WelfareServiceType.yboxSpecial:
        // UI-C1a：香蕉秀 XJSP 原生专用服务重探测。iOS 该平台网关写死、无
        // 探测语义（`YBoxService2.apiGateway`）；Flutter 接入统一域名体系后
        // 自定义域名 / 代理变更需重新探测。注册表命中优先（测试 / 注入场景）。
        (_registry.serviceFor(platform.platformKey) ??
                BananaXjspFuliService.serviceFor())
            .reprobe();
      case WelfareServiceType.unknown:
        // 无域名探测语义 → 无操作（对齐 iOS break）。
        break;
    }
  }

  /// 按 `platformKey` + 视频信息重建福利播放中转页（W-福2，对齐 iOS
  /// `WelfarePlatformRouter.makeVideoBridgeView` L33-L59）。
  ///
  /// 用于收藏 / 观看记录点击福利条目时的「福利重播桥」：记录中携带的
  /// `platformKey`（存于 `detailua`）在此重建 Service 并直达详情。
  /// 平台已下线 / 未支持 / 对应页面未落地（`remote_cms_v10`、原生专用页）→
  /// 返回 `null`，由调用方给出明确提示，**不兜底**到通用详情页。
  Widget? makeVideoBridgeView({
    required WelfarePlatform platform,
    required String vodId,
    required String vodName,
    required String vodPic,
  }) {
    final FuliVideo video =
        FuliVideo(vodId: vodId, vodName: vodName, vodPic: vodPic);
    switch (platform.service) {
      case WelfareServiceType.aidanVideo:
        // 对齐 iOS `AidanVideoService.shared`：aidan 用固定服务，键名回落
        // 'aidan_video'（远程配置的 platformKey 可能不同）。
        final FuliBaseService? aidan =
            _registry.serviceFor(platform.platformKey) ??
                _registry.serviceFor('aidan_video');
        return aidan == null
            ? null
            : WelfareVideoBridgePage(service: aidan, video: video);
      case WelfareServiceType.fuliBase:
        final FuliBaseService? service =
            _registry.serviceFor(platform.platformKey);
        return service == null
            ? null
            : WelfareVideoBridgePage(service: service, video: video);
      case WelfareServiceType.welfareSpider:
        // 对齐 iOS `makeWelfareSpiderVideoBridge`：已注册原生服务（如
        // lusushequ）优先；否则仅 JS 脚本走通用 JS 引擎。
        final FuliBaseService? native =
            _registry.serviceFor(platform.platformKey);
        if (native != null) {
          return WelfareVideoBridgePage(service: native, video: video);
        }
        if (platform.isJavaScriptSpider) {
          return WelfareVideoBridgePage(
            service: WelfareJSSpiderService.serviceFor(platform),
            video: video,
          );
        }
        return null;
      case WelfareServiceType.pythonSpider:
        return WelfareVideoBridgePage(
          service: WelfarePythonSpiderService.serviceFor(platform),
          video: video,
        );
      case WelfareServiceType.remoteCmsV10:
        // UI-C1c：远程 CMS V10 重播桥（对齐 iOS `RemoteCMSV10Service`）。
        return WelfareVideoBridgePage(
          service: RemoteCmsV10FuliService.serviceFor(platform),
          video: video,
        );
      case WelfareServiceType.dailyBattle:
      case WelfareServiceType.kanliao:
      case WelfareServiceType.yboxSpecial:
      case WelfareServiceType.unknown:
        // 原生专用页无「视频重播」语义（对齐 iOS default → nil）。
        return null;
    }
  }
}