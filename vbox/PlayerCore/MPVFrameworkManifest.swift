import Foundation

/// MPV framework 静态预检清单。
/// 这个文件只描述仓库内 framework 的接入条件，不 import/link 第三方 MPV 模块。
struct MPVFrameworkManifest {
    let backendType: MPVBackendType
    let displayName: String
    let expectedPath: String
    let moduleName: String
    let frameworkName: String
    let requiredSlices: [String]
    let recommendedSlices: [String]
    let requiredRuntimeDependencies: [String]
    let currentLinkPolicy: String
    let enableCondition: String
    let roleDescription: String

    var unavailableReason: String {
        let dependencies = requiredRuntimeDependencies.joined(separator: "、")
        return "\(displayName) 当前只完成依赖识别，尚未启用。\(roleDescription)。需要安装并验证 \(frameworkName)，再确认以下依赖可正常链接：\(dependencies)。"
    }

    var shortSummary: String {
        "\(displayName)：模块 \(moduleName)，路径 \(expectedPath)，策略：\(currentLinkPolicy)"
    }
}

enum MPVFrameworkManifests {
    static let mpvKit = MPVFrameworkManifest(
        backendType: .mpvKit,
        displayName: "MPV",
        expectedPath: "vbox/Libraries/MPV/MPVKit.xcframework",
        moduleName: "MPVKit",
        frameworkName: "MPVKit.xcframework",
        requiredSlices: ["ios-arm64"],
        recommendedSlices: ["ios-arm64_x86_64-simulator"],
        requiredRuntimeDependencies: [
            "Libmpv.xcframework",
            "Libavcodec/Libavformat/Libavutil 等 FFmpeg 组件",
            "Package.swift 中声明的外部 binaryTarget"
        ],
        currentLinkPolicy: "保留 wrapper 和依赖安装脚本，不 Link，不 Embed",
        enableCondition: "安装 MPVKitDependencies 核心依赖并补齐 Package.swift 外部 binaryTarget 后，再打开 MPVKitBackend 的启用开关",
        roleDescription: "这是标准 MPVKit wrapper 路线，不直接使用 Freedom/libmpv.xcframework"
    )

    static let libmpv = MPVFrameworkManifest(
        backendType: .libmpv,
        displayName: "自由度",
        expectedPath: "vbox/Libraries/MPV/Freedom/libmpv.xcframework",
        moduleName: "libmpv",
        frameworkName: "libmpv.xcframework",
        requiredSlices: ["ios-arm64"],
        recommendedSlices: ["ios-arm64_x86_64-simulator"],
        requiredRuntimeDependencies: [
            "自由度 libmpv C API",
            "自由度内核自带或配套的 FFmpeg 组件",
            "自由度内核配套的渲染上下文依赖"
        ],
        currentLinkPolicy: "预留 Freedom/libmpv.xcframework 路径，暂不 Link，不 Embed",
        enableCondition: "确认自由度 libmpv.xcframework 的模块名、链接依赖和渲染上下文后，再启用 LibMPVBackend",
        roleDescription: "这是后续自由度独立内核路线，不复用 MPVKitDependencies/Libmpv.xcframework"
    )

    static let all: [MPVFrameworkManifest] = [
        mpvKit,
        libmpv
    ]

    static func manifest(for backendType: MPVBackendType) -> MPVFrameworkManifest? {
        switch backendType {
        case .automatic:
            return mpvKit
        case .mpvKit:
            return mpvKit
        case .libmpv:
            return libmpv
        }
    }
}
