import SwiftUI
import UIKit

#if canImport(Libmpv)
private final class LibmpvMoltenVKCoreBox: ObservableObject {
    var core = LibmpvMoltenVKPlayerCore()

    func replaceCore() {
        core.teardown()
        core = LibmpvMoltenVKPlayerCore()
    }

    func teardown() {
        core.teardown()
    }
}
#endif

struct LibmpvMoltenVKDebugView: View {
    private static let defaultHLSURL = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"

    @Environment(\.dismiss) private var dismiss
    @State private var urlText: String
    @State private var logs: [String] = []
    @State private var state = PlayerEngineState()
    @State private var isSwitching = false
    @State private var renderSessionID = UUID()
    private let initialHeaders: [String: String]

    private let hlsTSURL = LibmpvMoltenVKDebugView.defaultHLSURL
    private let hlsFMP4URL = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"
    private let mp4URL = "https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4"
    private let mkv100URL = "https://thetestdata.com/assets/video/mkv/720/100MB_720P_THETESTDATA.COM_mkv.mkv"
    private let mkv200URL = "https://thetestdata.com/assets/video/mkv/1080/200MB_1080P_THETESTDATA.COM_mkv.mkv"

    #if canImport(Libmpv)
    @StateObject private var coreBox = LibmpvMoltenVKCoreBox()
    #endif

    init(initialURL: String? = nil, headers: [String: String] = [:]) {
        _urlText = State(initialValue: initialURL?.isEmpty == false ? initialURL! : Self.defaultHLSURL)
        self.initialHeaders = headers
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                renderArea
                statusPanel
                controlPanel
                logPanel
            }
            .padding(.top, 12)
            .navigationTitle("Libmpv-MoltenVK调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .onDisappear {
                #if canImport(Libmpv)
                coreBox.teardown()
                #endif
            }
        }
    }

    private var renderArea: some View {
        #if canImport(Libmpv)
        LibmpvMoltenVKRenderHost(core: coreBox.core, onLog: appendLog, onStateChange: { state = $0 })
            .frame(height: 220)
            .background(Color.black)
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .id(renderSessionID)
        #else
        Text("Libmpv模块未导入，无法运行MoltenVK调试")
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .background(Color.black)
            .foregroundColor(.white)
            .cornerRadius(12)
            .padding(.horizontal, 16)
        #endif
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Libmpv-MoltenVK")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(MPVIntegrationStatus.isMPVKitInitializationReady ? "可初始化" : "未就绪")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(MPVIntegrationStatus.isMPVKitInitializationReady ? .green : .red)
            }
            Text("路线：Libmpv + gpu-next + Vulkan + MoltenVK + CAMetalLayer")
                .font(.system(size: 12))
                .foregroundColor(.gray)
            Text("目标：绕开 GLKView/OpenGLES RenderContext 偏色与 INVALID_ENUM")
                .font(.system(size: 12))
                .foregroundColor(.gray)
            Text("进度：\(Int(state.currentTime)) / \(Int(state.duration)) 秒")
                .font(.system(size: 12))
                .foregroundColor(.gray)
            Text("尺寸：\(state.width)x\(state.height)")
                .font(.system(size: 12))
                .foregroundColor(.gray)
            if let error = state.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
        }
        .padding(14)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }

    private var controlPanel: some View {
        VStack(spacing: 10) {
            TextField("输入 mp4 / m3u8 / mkv 地址", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13))
                .padding(10)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(8)

            HStack(spacing: 8) {
                Button("HLS-极速") {
                    urlText = hlsTSURL
                    loadCurrentURL(profile: .hlsFast)
                }
                .buttonStyle(.bordered)
                .disabled(isSwitching)

                Button("HLS-高清") {
                    urlText = hlsTSURL
                    loadCurrentURL(profile: .hlsQuality)
                }
                .buttonStyle(.bordered)
                .disabled(isSwitching)

                Button("HLS-fMP4兼容") {
                    urlText = hlsFMP4URL
                    loadCurrentURL(profile: .hlsFMP4)
                }
                .buttonStyle(.bordered)
                .disabled(isSwitching)
            }

            HStack(spacing: 8) {
                Button("MP4") {
                    urlText = mp4URL
                    loadCurrentURL(profile: .mp4)
                }
                .buttonStyle(.bordered)
                .disabled(isSwitching)

                Button("MKV-100M") {
                    urlText = mkv100URL
                    loadCurrentURL(profile: .mkvLarge)
                }
                .buttonStyle(.bordered)
                .disabled(isSwitching)

                Button("MKV-200M压力") {
                    urlText = mkv200URL
                    loadCurrentURL(profile: .mkvLarge)
                }
                .buttonStyle(.bordered)
                .disabled(isSwitching)
            }

            HStack(spacing: 8) {
                Button("播放") {
                    loadCurrentURL()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSwitching)

                Button(state.isPlaying ? "暂停" : "继续") {
                    #if canImport(Libmpv)
                    state.isPlaying ? coreBox.core.pause() : coreBox.core.play()
                    #endif
                }
                .buttonStyle(.bordered)
                .disabled(isSwitching)

                Button("重置内核") {
                    resetCore()
                }
                .buttonStyle(.bordered)
                .disabled(isSwitching)
            }
        }
        .padding(.horizontal, 16)
    }

    private var logPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                    Text(log)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .background(Color.black.opacity(0.04))
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }

    private func loadCurrentURL(profile: LibmpvMoltenVKPlayerCore.PlaybackProfile? = nil) {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            appendLog("URL无效")
            return
        }
        #if canImport(Libmpv)
        let effectiveProfile = profile ?? inferredProfile(for: url)
        isSwitching = true
        logs.removeAll()
        state = PlayerEngineState()
        appendLog("准备切换：\(url.absoluteString)")
        appendLog("播放会话：新建 MoltenVK session")
        coreBox.replaceCore()
        renderSessionID = UUID()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            coreBox.core.load(url: url, headers: initialHeaders, profile: effectiveProfile)
            coreBox.core.play()
            isSwitching = false
        }
        #else
        appendLog("Libmpv模块未导入")
        #endif
    }

    private func resetCore() {
        #if canImport(Libmpv)
        isSwitching = true
        logs.removeAll()
        state = PlayerEngineState()
        appendLog("手动重置Libmpv-MoltenVK播放会话")
        coreBox.replaceCore()
        renderSessionID = UUID()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            isSwitching = false
        }
        #endif
    }

    private func inferredProfile(for url: URL) -> LibmpvMoltenVKPlayerCore.PlaybackProfile {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" { return .hlsFast }
        if ext == "mkv" { return .mkvLarge }
        if ext == "mp4" || ext == "m4v" || ext == "mov" { return .mp4 }
        return .generic
    }

    private func appendLog(_ message: String) {
        logs.append(message)
        if logs.count > 120 {
            logs.removeFirst(logs.count - 120)
        }
    }
}

#if canImport(Libmpv)
private struct LibmpvMoltenVKRenderHost: UIViewRepresentable {
    let core: LibmpvMoltenVKPlayerCore
    let onLog: (String) -> Void
    let onStateChange: (PlayerEngineState) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        core.onLog = onLog
        core.onStateChange = onStateChange
        core.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        core.onLog = onLog
        core.onStateChange = onStateChange
        core.attach(to: uiView)
    }
}
#endif
