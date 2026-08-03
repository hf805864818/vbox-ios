//
//  XJSPWelfareMainView.swift
//  vbox
//
//  Phase 2：iOS 客户端新增文件（不改任何现有代码）
//  作用：香蕉秀通用分类页面（远程源平台的兜底/默认页）。
//        复用于以下 platform：
//        - ybox_xjsp: 幻想次元 / 午夜寻欢 / 绿帽淫妻 / 1080视频 等
//        - 远端 fuli_base 平台中未识别的也走这里
//
//  实现要点：
//        - 调用 YBoxService2.fetchBananaVideos(cateId, page) 拉数据
//        - 与 YBoxXjspMainView 一致的 UI 体验
//        - 远程源模式下不再依赖 YBoxService2 内置的 yboxVideo 列表
//        - 完全独立：出错时仅显示错误信息，不影响其他平台
//

import SwiftUI

struct XJSPWelfareMainView: View {
    let platform: YBoxPlatform2

    @State private var videos: [YBoxBananaVideo] = []
    @State private var categories: [YBoxBananaCategory] = []
    @State private var selectedCategoryId: String = "0"
    @State private var currentPage: Int = 1
    @State private var hasMore: Bool = true
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 1. 平台信息头
            platformHeader

            // 2. 分类横向滚动
            if !categories.isEmpty {
                categoryBar
            }

            // 3. 错误信息
            if let err = errorMessage {
                errorView(err)
            }

            // 4. 视频列表
            if videos.isEmpty && isLoading {
                loadingView
            } else if videos.isEmpty {
                emptyView
            } else {
                videoList
            }
        }
        .navigationTitle(platform.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if categories.isEmpty {
                Task { await loadCategories() }
            }
            if videos.isEmpty {
                Task { await loadVideos(reset: true) }
            }
        }
    }

    // MARK: - 平台信息头

    private var platformHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: platform.icon)
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                Text(platform.name)
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Text("远程源 · XJSP")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.accentColor)
                    )
            }
            Text(platform.desc)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.5))
    }

    // MARK: - 分类栏

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories) { cat in
                    Button {
                        selectedCategoryId = cat.cateId
                        Task { await loadVideos(reset: true) }
                    } label: {
                        Text(cat.name)
                            .font(.system(size: 13, weight: selectedCategoryId == cat.cateId ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(selectedCategoryId == cat.cateId
                                          ? Color.accentColor
                                          : Color(uiColor: .tertiarySystemBackground))
                            )
                            .foregroundColor(selectedCategoryId == cat.cateId ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 错误 / 空 / 加载

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text("加载失败")
                .font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试") {
                Task { await loadVideos(reset: true) }
            }
            .font(.system(size: 13))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("加载中…").font(.system(size: 13)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.fill")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("该分类暂无视频").font(.system(size: 14)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - 视频列表

    private var videoList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(videos) { video in
                    VideoRow(video: video)
                        .onAppear {
                            if video == videos.last, hasMore, !isLoading {
                                Task { await loadVideos(reset: false) }
                            }
                        }
                }
                if isLoading && !videos.isEmpty {
                    ProgressView().padding(.vertical, 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 数据加载

    private func loadCategories() async {
        let result = await YBoxService2.shared.fetchBananaCategories()
        await MainActor.run {
            self.categories = result
        }
    }

    private func loadVideos(reset: Bool) async {
        if isLoading { return }
        await MainActor.run {
            self.isLoading = true
            if reset {
                self.errorMessage = nil
            }
        }
        let pageToLoad = reset ? 1 : currentPage + 1
        let result = await YBoxService2.shared.fetchBananaVideos(
            cateId: selectedCategoryId,
            page: pageToLoad
        )
        await MainActor.run {
            if reset {
                self.videos = result
                self.currentPage = 1
            } else {
                self.videos.append(contentsOf: result)
                self.currentPage = pageToLoad
            }
            self.hasMore = !result.isEmpty
            self.isLoading = false
            if result.isEmpty && reset {
                self.errorMessage = nil  // 空数据不算错误
            }
        }
    }
}

// MARK: - 视频行

private struct VideoRow: View {
    let video: YBoxBananaVideo

    var body: some View {
        HStack(spacing: 12) {
            // 封面（异步加载）
            AsyncImage(url: URL(string: video.cover)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Color.gray.opacity(0.3)
                case .empty:
                    Color.gray.opacity(0.1)
                @unknown default:
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // 信息
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                if let score = video.score, !score.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundColor(.yellow)
                        Text(score).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(video.duration).font(.system(size: 10)).foregroundColor(.secondary)
                    if !video.tags.isEmpty {
                        Text(video.tags.prefix(2).joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
