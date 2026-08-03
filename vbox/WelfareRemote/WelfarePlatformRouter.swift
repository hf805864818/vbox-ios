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
        // MARK: 香蕉秀系列
        case .yboxSpecial:
            // 香蕉秀专用：使用 YBoxXjspMainView（兼容现有 .special 模式）
            return AnyView(
                YBoxXjspMainView(platform: makeYBoxPlatform2(from: platform))
            )

        case .yboxXjsp:
            // 香蕉秀通用分类：走 XJSPWelfareMainView（本期新增）
            return AnyView(
                XJSPWelfareMainView(platform: makeYBoxPlatform2(from: platform))
            )

        // MARK: 旧式 Service 系列（不继承 FuliBaseService 的）
        case .dailyBattle:
            return AnyView(
                DailyBattleMainView(platform: makeYBoxPlatform2(from: platform))
            )

        case .mysteryMovie:
            return AnyView(
                MysteryMovieMainView(platform: makeYBoxPlatform2(from: platform))
            )

        case .sihuVideo:
            return AnyView(
                SihuVideoHomeView(platform: makeYBoxPlatform2(from: platform))
            )

        case .xcp:
            return AnyView(
                XCPHomeView(platform: makeYBoxPlatform2(from: platform))
            )

        case .luoliAv:
            return AnyView(
                LuoliAVHomeView()
            )

        case .madouFree:
            return AnyView(
                MadouFreeHomeView()
            )

        case .jiujiu:
            return AnyView(
                JiujiuHomeView()
            )

        case .koreanPorn:
            return AnyView(
                KoreanPornHomeView()
            )

        case .kanliao:
            return AnyView(
                KanliaoHomeView()
            )

        case .heiliao:
            return AnyView(
                HeiliaoHomeView()
            )

        case .xigua:
            return AnyView(
                XiguaMainView(platform: makeYBoxPlatform2(from: platform))
            )

        case .sbAggregation:
            return AnyView(
                SBAggregationView(platform: makeYBoxPlatform2(from: platform))
            )

        // MARK: 新式 FuliBaseService 系列
        case .fuliBase:
            return makeFuliBaseDestination(for: platform)

        // MARK: 未实现路由
        case .unknown:
            // serviceType 不在枚举中：显示明确错误，不兜底到其他平台
            return AnyView(UnsupportedPlatformView(platform: platform))
        }
    }

    // MARK: - 私有辅助

    /// 根据 platformKey 解析到对应的 FuliBaseService 单例
    private func makeFuliBaseDestination(for platform: WelfarePlatform) -> AnyView {
        let key = platform.platformKey
        let p = makeYBoxPlatform2(from: platform)

        // 直接根据 platformKey 匹配（不依赖 platform.name，名字改了排序数据也不会丢）
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
            // 未知 fuli_base 平台：显示明确错误，不兜底到 XJSP
            return AnyView(UnsupportedPlatformView(platform: platform))
        }
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
