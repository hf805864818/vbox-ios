import SwiftUI
import UIKit

struct MPVKitDebugPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
    @State private var logs: [String] = []
    @State private var state = PlayerEngineState()

    private let hlsURL = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
    private let mp4URL = "https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4"
    private let mkv720LargeURL = "https://test-videos.co.uk/vids/bigbuckbunny/mkv/720/Big_Buck_Bunny_720_10s_30MB.mkv"
    private let mkv1080LargeURL = "https://test-videos.co.uk/vids/bigbuckbunny/mkv/1080/Big_Buck_Bunny_1080_10s_30MB.mkv"

    #if canImport(Libmpv)
    private let core = MPVKitRenderedPlayerCore()
    #endif

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                renderArea
                statusPanel
                controlPanel
                logPanel
            }
            .padding(.top, 12)
            .navigationTitle("MPV播放调试")
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
        MPVKitDebugRenderHost(core: core, onLog: appendLog, onStateChange: { state = $0 })
            .frame(height: 220)
            .background(Color.black)
            .cornerRadius(12)
            .padding(.horizontal, 16)
        #else
        Text("Libmpv模块未导入，无法运行MPV渲染调试")
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
                Text("MPV")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(MPVIntegrationStatus.isMPVKitInitializationReady ? "可初始化" : "未就绪")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(MPVIntegrationStatus.isMPVKitInitializationReady ? .green : .red)
            }
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

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Button("HLS") {
                        urlText = hlsURL
                        loadCurrentURL()
                    }
                    .buttonStyle(.bordered)

                    Button("MP4") {
                        urlText = mp4URL
                        loadCurrentURL()
                    }
                    .buttonStyle(.bordered)

                    Button("播放") {
                        loadCurrentURL()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(state.isPlaying ? "暂停" : "继续") {
                        #if canImport(Libmpv)
                        state.isPlaying ? core.pause() : core.play()
                        #endif
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    Button("MKV-720P大") {
                        urlText = mkv720LargeURL
                        loadCurrentURL()
                    }
                    .buttonStyle(.bordered)

                    Button("MKV-1080P大") {
                        urlText = mkv1080LargeURL
                        loadCurrentURL()
                    }
                    .buttonStyle(.bordered)
                }
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

    private func loadCurrentURL() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            appendLog("URL无效")
            return
        }
        #if canImport(Libmpv)
        logs.removeAll()
        core.load(url: url)
        core.play()
        #else
        appendLog("Libmpv模块未导入")
        #endif
    }

    private func appendLog(_ message: String) {
        logs.append(message)
        if logs.count > 80 {
            logs.removeFirst(logs.count - 80)
        }
    }
}

#if canImport(Libmpv)
private struct MPVKitDebugRenderHost: UIViewRepresentable {
    let core: MPVKitRenderedPlayerCore
    let onLog: (String) -> Void
    let onStateChange: (PlayerEngineState) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
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
