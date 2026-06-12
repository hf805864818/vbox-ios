import SwiftUI
import UIKit

struct MPVKitDebugPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = PlayerEngineController(initialEngineType: .mpvKit)
    @State private var urlText = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                MPVKitDebugRenderHost(controller: controller)
                    .frame(height: 220)
                    .background(Color.black)
                    .cornerRadius(12)
                    .padding(.horizontal, 16)

                statusPanel
                controlPanel
                logPanel
            }
            .padding(.top, 12)
            .navigationTitle("MPVKit 调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .onDisappear {
                controller.teardown()
            }
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MPVKit")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(MPVKitBackend.isAvailable ? "可用" : "未链接")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(MPVKitBackend.isAvailable ? .green : .red)
            }

            Text("内核：\(controller.currentEngineType.displayName)")
                .font(.system(size: 12))
                .foregroundColor(.gray)
            Text("进度：\(Int(controller.state.currentTime)) / \(Int(controller.state.duration)) 秒")
                .font(.system(size: 12))
                .foregroundColor(.gray)
            if let error = controller.state.errorMessage {
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
            TextField("输入 mp4 / m3u8 地址", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13))
                .padding(10)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(8)

            HStack(spacing: 10) {
                Button("播放") {
                    loadCurrentURL()
                }
                .buttonStyle(.borderedProminent)

                Button(controller.state.isPlaying ? "暂停" : "继续") {
                    controller.state.isPlaying ? controller.pause() : controller.play()
                }
                .buttonStyle(.bordered)

                Button("+30s") {
                    controller.seek(to: controller.state.currentTime + 30)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
    }

    private var logPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(controller.logs.enumerated()), id: \.offset) { _, log in
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
            return
        }

        let route = PlaybackRoute(
            type: url.pathExtension.lowercased() == "m3u8" ? .smoothM3U8 : .direct,
            url: url,
            title: "MPVKit 调试播放"
        )
        controller.load(route: route, preferredEngine: .mpvKit)
        controller.play()
    }
}

private struct MPVKitDebugRenderHost: UIViewRepresentable {
    let controller: PlayerEngineController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        Task { @MainActor in
            controller.attach(to: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        Task { @MainActor in
            controller.attach(to: uiView)
        }
    }
}
