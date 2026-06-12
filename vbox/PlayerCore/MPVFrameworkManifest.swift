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

    var unavailableReason: String {
        let dependencies = requiredRuntimeDependencies.joined(separator: "、")
        return "\(displayName) 当前只完成依赖识别，尚未启用。需要安装并验证 \(frameworkName)，再确认以下依赖可正常链接：\(dependencies)。"
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
        enableCondition: "安装核心依赖并补齐 Package.swift 外部 binaryTarget 后，再打开 MPVKitBackend 的启用开关"
    )

    static let libmpv = MPVFrameworkManifest(
        backendType: .libmpv,
        displayName: "自由度",
        expectedPath: "vbox/Libraries/MPV/Dependencies/Libmpv.xcframework",
        moduleName: "Libmpv",
        frameworkName: "Libmpv.xcframework",
        requiredSlices: ["ios-arm64"],
        recommendedSlices: ["ios-arm64_x86_64-simulator"],
        requiredRuntimeDependencies: [
            "Libmpv C API",
            "FFmpeg 组件",
            "libass/libplacebo/MoltenVK 等 mpv 间接依赖"
        ],
        currentLinkPolicy: "可从 MPVKit binary bundle 安装核心文件，暂不 Link，不 Embed",
        enableCondition: "确认 canImport(Libmpv)、链接依赖和渲染上下文后，再启用 LibMPVBackend"
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
