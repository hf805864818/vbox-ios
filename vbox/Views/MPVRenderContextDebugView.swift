import GLKit
import SwiftUI
import UIKit

struct MPVRenderContextDebugView: View {
    private static let defaultHLSURL = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"

    @Environment(\.dismiss) private var dismiss
    @State private var urlText: String
    @State private var logs: [String] = []
    @State private var state = PlayerEngineState()
    @State private var isSwitching = false
    @State private var lastProfile: MPVRenderContextPlayerCore.PlaybackProfile?
    private let initialHeaders: [String: String]

    private let hlsTSURL = MPVRenderContextDebugView.defaultHLSURL
    private let hlsFMP4URL = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"
    private let mp4URL = "https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4"
    private let mkv100URL = "https://thetestdata.com/assets/video/mkv/720/100MB_720P_THETESTDATA.COM_mkv.mkv"
    private let mkv200URL = "https://thetestdata.com/assets/video/mkv/1080/200MB_1080P_THETESTDATA.COM_mkv.mkv"

    #if canImport(Libmpv)
    private let core = MPVRenderContextPlayerCore()
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
            .navigationTitle("MPV RenderContext调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .onDisappear {
                #if canImport(Libmpv)
                core.teardown()
                #endif
            }
        }
    }

    private var renderArea: some View {
        #if canImport(Libmpv)
        MPVRenderContextHost(core: core, onLog: appendLog, onStateChange: { state = $0 })
            .frame(height: 220)
            .background(Color.black)
            .cornerRadius(12)
            .padding(.horizontal, 16)
        #else
        Text("Libmpv模块未导入，无法运行RenderContext调试")
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
                Text("RenderContext")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(MPVIntegrationStatus.isMPVKitInitializationReady ? "可初始化" : "未就绪")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(MPVIntegrationStatus.isMPVKitInitializationReady ? .green : .red)
            }
            Text("路线：mpv_render_context + GLKView/EAGLContext")
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

                Button("HLS-fMP4") {
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

                Button("MKV-200M") {
                    urlText = mkv200URL
                    loadCurrentURL(profile: .mkvLarge)
                }
                .buttonStyle(.bordered)
                .disabled(isSwitching)

                Button("播放") {
                    loadCurrentURL()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSwitching)

                Button(state.isPlaying ? "暂停" : "继续") {
                    #if canImport(Libmpv)
                    state.isPlaying ? core.pause() : core.play()
                    #endif
                }
                .buttonStyle(.bordered)
                .disabled(isSwitching)
            }

            Button("重置内核") {
                resetCore()
            }
            .buttonStyle(.bordered)
            .disabled(isSwitching)
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

    private func loadCurrentURL(profile: MPVRenderContextPlayerCore.PlaybackProfile? = nil) {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            appendLog("URL无效")
            return
        }
        #if canImport(Libmpv)
        let effectiveProfile = profile ?? inferredProfile(for: url)
        let needsRebuild = lastProfile.map { $0.family != effectiveProfile.family } ?? false
        isSwitching = true
        logs.removeAll()
        state = PlayerEngineState()
        appendLog("准备切换：\(url.absoluteString)")
        appendLog(needsRebuild ? "切换方式：重建内核" : "切换方式：轻切换")
        if needsRebuild {
            core.rebuildForNewLoad()
        } else {
            core.resetForNewLoad()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: needsRebuild ? 450_000_000 : 250_000_000)
            core.load(url: url, headers: initialHeaders, profile: effectiveProfile)
            core.play()
            lastProfile = effectiveProfile
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
        lastProfile = nil
        appendLog("手动重置RenderContext内核")
        core.rebuildForNewLoad()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            isSwitching = false
        }
        #endif
    }

    private func inferredProfile(for url: URL) -> MPVRenderContextPlayerCore.PlaybackProfile {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" {
            return .hlsFast
        }
        if ext == "mkv" {
            return .mkvLarge
        }
        if ext == "mp4" || ext == "m4v" || ext == "mov" {
            return .mp4
        }
        return .generic
    }

    private func appendLog(_ message: String) {
        logs.append(message)
        if logs.count > 80 {
            logs.removeFirst(logs.count - 80)
        }
    }
}

#if canImport(Libmpv)
private struct MPVRenderContextHost: UIViewRepresentable {
    let core: MPVRenderContextPlayerCore
    let onLog: (String) -> Void
    let onStateChange: (PlayerEngineState) -> Void

    func makeUIView(context: Context) -> GLKView {
        let view = GLKView()
        view.backgroundColor = .black
        core.onLog = onLog
        core.onStateChange = onStateChange
        core.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: GLKView, context: Context) {
        core.onLog = onLog
        core.onStateChange = onStateChange
        core.attach(to: uiView)
    }
}
#endif
