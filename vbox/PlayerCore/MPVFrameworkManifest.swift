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
        return "\(displayName) 已完成文件占位，但当前构建暂不启用。需要确认 \(frameworkName) 可正常 Link + Embed，并补齐运行时依赖：\(dependencies)。"
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
        requiredRuntimeDependencies: ["Libmpv", "FFmpeg", "MPVKit wrapper 内部动态依赖"],
        currentLinkPolicy: "保留文件，不 Link，不 Embed",
        enableCondition: "确认底层 Libmpv/FFmpeg 依赖完整后，再打开 MPVKitBackend 的启用开关"
    )

    static let libmpv = MPVFrameworkManifest(
        backendType: .libmpv,
        displayName: "自由度",
        expectedPath: "vbox/Libraries/MPV/libmpv.xcframework",
        moduleName: "libmpv",
        frameworkName: "libmpv.xcframework",
        requiredSlices: ["ios-arm64"],
        recommendedSlices: ["ios-arm64_x86_64-simulator"],
        requiredRuntimeDependencies: ["libmpv C API", "FFmpeg", "Metal/OpenGL 渲染上下文依赖"],
        currentLinkPolicy: "等待 framework 产物，不 Link，不 Embed",
        enableCondition: "确认 libmpv.xcframework 可 import 且渲染上下文可创建后，再启用 LibMPVBackend"
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
