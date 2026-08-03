//
//  WelfareSpiderHomeView.swift
//  vbox
//
//  福利专区专用远程 Spider 平台入口。
//
//  此页面只展示福利 Spider 平台状态和脚本缓存结果。
//  不注册普通资源源池，不参与首页、全局搜索、普通播放和网盘切片链路。
//

import SwiftUI

struct WelfareSpiderHomeView: View {
    let platform: WelfarePlatform

    @StateObject private var service: WelfareSpiderService

    init(platform: WelfarePlatform) {
        self.platform = platform
        _service = StateObject(wrappedValue: WelfareSpiderService(platform: platform))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                scriptStatusCard
                runtimeNoticeCard

                if let preview = service.scriptPreview {
                    previewCard(preview)
                }
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(platform.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if case .idle = service.state {
                service.reload()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    service.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = service.state { return true }
        return false
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: platform.icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.name)
                        .font(.system(size: 18, weight: .semibold))
                    Text(platform.desc)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            infoRow("platformKey", platform.platformKey)
            infoRow("serviceType", platform.serviceType)
            infoRow("当前域名", service.currentDomain)

            if let api = platform.api, !api.isEmpty {
                infoRow("脚本路径", api)
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var scriptStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                statusIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(service.state.title)
                        .font(.system(size: 15, weight: .semibold))
                    statusDetail
                }
                Spacer()
            }

            Button {
                service.reload()
            } label: {
                Label("重新加载脚本", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusIcon: some View {
        Group {
            switch service.state {
            case .idle:
                Image(systemName: "doc")
                    .foregroundColor(.secondary)
            case .loading:
                ProgressView()
            case .loaded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
        }
        .font(.system(size: 22))
        .frame(width: 30)
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch service.state {
        case .idle:
            Text("准备从福利远程源加载脚本")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        case .loading:
            Text("正在下载并缓存福利专用脚本")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        case .loaded(let script):
            VStack(alignment: .leading, spacing: 2) {
                Text(script.remoteURL.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("本地缓存：\(service.localScriptPath ?? script.localURL.lastPathComponent)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.orange)
        }
    }

    private var runtimeNoticeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("运行时说明", systemImage: "info.circle")
                .font(.system(size: 15, weight: .semibold))
            Text("当前接入层已完成福利 Spider 平台识别、路由、脚本下载和缓存。项目尚未包含通用 Python 解释器，因此不会在这里强行执行 Python 脚本，避免影响现有资源蜘蛛、网盘和播放链路。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func previewCard(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("脚本预览")
                .font(.system(size: 15, weight: .semibold))

            ScrollView(.horizontal, showsIndicators: true) {
                Text(preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(UIColor.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value.isEmpty ? "未配置" : value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
