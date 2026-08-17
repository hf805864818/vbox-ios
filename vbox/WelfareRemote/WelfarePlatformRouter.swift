//
//  WelfarePlatformRouter.swift
//  vbox
//
//  Phase 2：iOS 客户端新增文件（不改任何现有代码）
//  作用：根据 WelfarePlatform.serviceType 把平台分发到对应的 Service / View。
//        - 不修改 WelfareHomeView.destinationView(for:) 任何代码
//        - 复用现有所有 Service 单例
//        - 复用现有所有 HomeView
//        - 仅做映射，不做新功能
//
//  使用示例：
//    let router = WelfarePlatformRouter.shared
//    let view = router.makeDestinationView(for: platform, settings: settings)
//

import SwiftUI

/// 福利平台路由分发器
@MainActor
struct WelfarePlatformRouter {

    // MARK: 单例

    static let shared = WelfarePlatformRouter()

    private init() {}

    // MARK: 公开 API

    /// 根据 platformKey 和视频信息，创建福利视频播放中转页
    /// 用于观看记录/收藏点击播放时，重建福利平台 Service 并直接进入视频详情
    func makeVideoBridgeView(
        platformKey: String,
        vodId: String,
        vodName: String,
        vodPic: String
    ) -> AnyView? {
        guard let platform = WelfarePlatformConfigStore.shared.platform(forKey: platformKey) else {
            return nil
        }
        let video = FuliVideo(vodId: vodId, vodName: vodName, vodPic: vodPic)
        let type = WelfareServiceType(raw: platform.serviceType)

        switch type {
        case .aidanVideo:
            return AnyView(FuliVideoBridgeView(svc: AidanVideoService.shared, video: video))
        case .fuliBase:
            return makeFuliBaseVideoBridge(platform: platform, video: video)
        case .remoteCmsV10:
            return AnyView(FuliVideoBridgeView(svc: RemoteCMSV10Service.service(for: platform), video: video))
        case .welfareSpider:
            return makeWelfareSpiderVideoBridge(platform: platform, video: video)
        case .pythonSpider:
            return AnyView(FuliVideoBridgeView(svc: WelfarePythonSpiderService.service(for: platform), video: video))
        default:
            return nil
        }
    }

    /// 通用 FuliBaseService 视频桥接路由
    private func makeFuliBaseVideoBridge(platform: WelfarePlatform, video: FuliVideo) -> AnyView? {
        switch platform.platformKey {
        case "panda_video":
            return AnyView(FuliVideoBridgeView(svc: PandaVideoService.shared, video: video))
        case "four_h_video":
            return AnyView(FuliVideoBridgeView(svc: FourHVideoService.shared, video: video))
        case "full_hd":
            return AnyView(FuliVideoBridgeView(svc: FullHDService.shared, video: video))
        case "banana_video":
            return AnyView(FuliVideoBridgeView(svc: BananaVideoService.shared, video: video))
        default:
            return nil
        }
    }

    /// 福利 Spider 视频桥接路由
    private func makeWelfareSpiderVideoBridge(platform: WelfarePlatform, video: FuliVideo) -> AnyView? {
        switch platform.platformKey {
        case "lusushequ":
            return AnyView(FuliVideoBridgeView(svc: LusushequService.shared, video: video))
        default:
            break
        }
        if platform.scriptType?.lowercased() == "javascript" {
            return AnyView(FuliVideoBridgeView(svc: WelfareJSSpiderService.service(for: platform), video: video))
        }
        return nil
    }

    /// 根据 platform 元数据生成对应的目标 View
    /// - Parameters:
    ///   - platform: 远程源中的平台元数据
    ///   - settings: AppSettings 实例（部分 View 需要，如 MissAV 走 .environmentObject）
    /// - Returns: 包装后的 AnyView，可直接用于 NavigationLink
    func makeDestinationView(
        for platform: WelfarePlatform,
        settings: AppSettings
    ) -> AnyView {
        let type = WelfareServiceType(raw: platform.serviceType)

        switch type {
        // MARK: 香蕉秀专用
        case .yboxSpecial:
            // 香蕉秀专用：使用 YBoxXjspMainView（兼容现有 .special 模式）
            return AnyView(
                YBoxXjspMainView(platform: makeYBoxPlatform2(from: platform))
            )

        // MARK: 每日大乱斗 / 每日大赛
        case .dailyBattle:
            return AnyView(
                DailyBattleMainView(platform: makeYBoxPlatform2(from: platform))
            )

        // MARK: 今日看料
        case .kanliao:
            return AnyView(
                KanliaoHomeView()
            )

        // MARK: 艾旦福利视频（CMS V10 专用）
        case .aidanVideo:
            return AnyView(
                FuliPlatformMainView(platform: makeYBoxPlatform2(from: platform), service: AidanVideoService.shared)
            )

        // MARK: 通用 FuliBaseService 子类（熊猫视频等）
        case .fuliBase:
            return makeFuliBaseDestination(for: platform)

        // MARK: 远程可配置 CMS V10 福利源
        case .remoteCmsV10:
            return AnyView(
                FuliPlatformMainView(
                    platform: makeYBoxPlatform2(from: platform),
                    service: RemoteCMSV10Service.service(for: platform)
                )
            )

        // MARK: 福利专区专用远程 Spider（JS）
        case .welfareSpider:
            return makeWelfareSpiderDestination(for: platform)

        // MARK: 福利专区 Python 蜘蛛
        case .pythonSpider:
            return makePythonSpiderDestination(for: platform)

        // MARK: 未实现路由
        case .unknown:
            // serviceType 不在枚举中：显示明确错误，不兜底到其他平台
            return AnyView(UnsupportedPlatformView(platform: platform))
        }
    }

    /// 通用 FuliBaseService 路由
    ///
    /// 根据 platformKey 匹配到对应的 FuliBaseService 子类。
    /// 新增 fuli_base 平台时：在此处加一个 case + 创建对应 Service 文件。
    private func makeFuliBaseDestination(for platform: WelfarePlatform) -> AnyView {
        let key = platform.platformKey
        let p = makeYBoxPlatform2(from: platform)

        switch key {
        case "panda_video":
            return AnyView(
                FuliPlatformMainView(platform: p, service: PandaVideoService.shared)
            )
        case "four_h_video":
            return AnyView(
                FuliPlatformMainView(platform: p, service: FourHVideoService.shared)
            )
        case "full_hd":
            return AnyView(
                FuliPlatformMainView(platform: p, service: FullHDService.shared)
            )
        case "banana_video":
            return AnyView(
                FuliPlatformMainView(platform: p, service: BananaVideoService.shared)
            )
        default:
            return AnyView(UnsupportedPlatformView(platform: platform))
        }
    }

    /// 福利专区专用 Spider 路由
    ///
    /// 优先级：
    /// 1. 已实现原生 Swift Service 的平台（如 lusushequ）→ 原生 Service
    /// 2. scriptType == "javascript" → WelfareJSSpiderService（通用 JS 引擎执行）
    /// 3. 其他 → WelfareSpiderHomeView（脚本缓存状态页）
    ///
    /// 新增福利 Spider 平台时：
    /// - JS 脚本平台：只需在远程源 JSON 中配置 scriptType="javascript" + api + sslBypass
    /// - 原生平台：在此处加一个 case + 创建对应 Service 文件
    private func makeWelfareSpiderDestination(for platform: WelfarePlatform) -> AnyView {
        let key = platform.platformKey

        // 已实现原生 Swift Service 的平台
        switch key {
        case "lusushequ":
            // 六速社区：已实现原生 Swift Service，复用自适应框架
            let p = makeYBoxPlatform2(from: platform)
            return AnyView(
                FuliPlatformMainView(platform: p, service: LusushequService.shared)
            )
        default:
            break
        }

        // JS 脚本类型 → 通用 JS 引擎执行
        if platform.scriptType?.lowercased() == "javascript" {
            let p = makeYBoxPlatform2(from: platform)
            return AnyView(
                FuliPlatformMainView(
                    platform: p,
                    service: WelfareJSSpiderService.service(for: platform)
                )
            )
        }

        // 其他福利 Spider：使用通用加载页（显示脚本加载状态）
        return AnyView(
            WelfareSpiderHomeView(platform: platform)
        )
    }

    /// 福利专区 Python 蜘蛛路由
    ///
    /// 所有 serviceType == "python_spider" 的平台都走这里，
    /// 通用 Python 引擎执行脚本，复用 FuliPlatformMainView。
    ///
    /// 新增 Python 福利平台：只需在远程源 JSON 中配置：
    ///   - serviceType: "python_spider"
    ///   - scriptType: "python"
    ///   - api: "./sources/welfare-js/xxx.py"
    ///   - defaultHosts: [...]
    /// 无需修改客户端代码。
    private func makePythonSpiderDestination(for platform: WelfarePlatform) -> AnyView {
        let p = makeYBoxPlatform2(from: platform)
        return AnyView(
            FuliPlatformMainView(
                platform: p,
                service: WelfarePythonSpiderService.service(for: platform)
            )
        )
    }

    /// 把远程 WelfarePlatform 转换为现有 YBoxPlatform2（YBoxHomeView 系列都吃这个类型）
    private func makeYBoxPlatform2(from platform: WelfarePlatform) -> YBoxPlatform2 {
        return YBoxPlatform2(
            name: platform.name,
            icon: platform.icon,
            type: mapCategory(platform.category),
            baseURL: platform.primaryHost,
            desc: platform.desc,
            crawlerPlatformId: platform.platformKey
        )
    }

    /// 分类字符串 → PlatformType2
    private func mapCategory(_ category: String) -> YBoxPlatform2.PlatformType2 {
        switch category {
        case "live": return .live
        case "comic": return .comic
        case "audio": return .audio
        default: return .video
        }
    }
}
