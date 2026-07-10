import SwiftUI
import AVKit

// MARK: - 香肠派对主页（分类选择）

struct XCPHomeView: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = XCPService.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: 12
            ) {
                ForEach(svc.categories) { cat in
                    NavigationLink(destination: XCPCategoryView(
                        category: cat, platform: platform
                    )) {
                        VStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(UIColor.secondarySystemBackground))
                                    .frame(height: 60)
                                Image(systemName: "party.popper.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.accentColor.opacity(0.6))
                            }
                            Text(cat.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 100)
        }
        .navigationTitle("香肠派对")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 香肠派对分类页

struct XCPCategoryView: View {
    let category: XCPCategory
    let platform: YBoxPlatform2
    @StateObject private var svc = XCPService.shared
    @State private var videos: [XCPVideo] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var isLoading = false

    var body: some View {
        ZStack {
            List {
                ForEach(videos) { video in
                    NavigationLink(destination: XCPDetailView(vodId: video.vodId)) {
                        SihuVideoRow(video: SihuVideo(vodId: video.vodId, title: video.title, cover: video.cover, remarks: video.remarks))
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if video == videos.last, page < pageCount, !isLoading {
                            loadMore()
                        }
                    }
                }

                if isLoading && page > 1 {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)

            if videos.isEmpty && isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground).opacity(0.8))
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if videos.isEmpty { load() } }
    }

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let result = await svc.fetchCategory(typeId: category.typeId, page: page)
            await MainActor.run {
                videos = result.videos; pageCount = result.pageCount; isLoading = false
            }
        }
    }

    private func loadMore() {
        guard !isLoading, page < pageCount else { return }
        isLoading = true; page += 1
        Task {
            let result = await svc.fetchCategory(typeId: category.typeId, page: page)
            await MainActor.run {
                videos.append(contentsOf: result.videos)
                pageCount = result.pageCount; isLoading = false
            }
        }
    }
}

// MARK: - 香肠派对详情页（播放器 + 剧集）

struct XCPDetailView: View {
    let vodId: String
    @StateObject private var svc = XCPService.shared
    @State private var title: String = ""
    @State private var cover: String = ""
    @State private var playSources: [XCPPlaySource] = []
    @State private var selectedSourceIdx = 0
    @State private var selectedEpIdx = 0
    @State private var isLoading = true
    @State private var vodItem: VodItem?
    @State private var showPlayer = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle()
                    .fill(Color.black)
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else if vodItem == nil {
                            VStack(spacing: 12) {
                                Image(systemName: "play.slash")
                                    .font(.system(size: 36))
                                    .foregroundColor(.white.opacity(0.5))
                                Text("点击剧集播放")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        } else {
                            Button(action: { showPlayer = true }) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 60))
                                    .foregroundColor(.white.opacity(0.9))
                            }
                        }
                    }
            }
            .background(Color.black)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

            if playSources.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(playSources.enumerated()), id: \.offset) { idx, source in
                            Button(action: {
                                selectedSourceIdx = idx
                                selectedEpIdx = 0
                                buildVodItem()
                            }) {
                                Text(source.name)
                                    .font(.system(size: 13))
                                    .foregroundColor(selectedSourceIdx == idx ? .white : .primary)
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .background(selectedSourceIdx == idx ? Color.accentColor : Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(16)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 4)
            }

            if !playSources.isEmpty {
                let episodes = playSources[selectedSourceIdx].episodes
                Text("选集")
                    .font(.system(size: 13)).foregroundColor(.secondary)
                    .padding(.horizontal, 16).padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(Array(episodes.enumerated()), id: \.offset) { idx, ep in
                            Button(action: {
                                selectedEpIdx = idx
                                buildVodItem()
                            }) {
                                Text(ep.name)
                                    .font(.system(size: 13))
                                    .foregroundColor(selectedEpIdx == idx ? .white : .primary)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(selectedEpIdx == idx ? Color.accentColor : Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(maxHeight: 300)
            }

            Spacer().frame(height: 80)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if playSources.isEmpty { loadDetail() }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let vod = vodItem { VideoDetailView(video: vod) }
        }
    }

    private func loadDetail() {
        isLoading = true
        Task {
            let (t, c, sources) = await svc.fetchDetail(vodId: vodId)
            await MainActor.run {
                title = t; cover = c
                playSources = sources
                isLoading = false
            }
        }
    }

    private func buildVodItem() {
        guard !playSources.isEmpty else { return }
        let episode = playSources[selectedSourceIdx].episodes[selectedEpIdx]
        isLoading = true
        vodItem = nil
        Task {
            let url = await svc.fetchPlayURL(playPageURL: episode.playURL)
            await MainActor.run {
                isLoading = false
                guard let urlStr = url else { return }
                let headers: [String: String] = ["Referer": svc.currentHost]
                vodItem = VodItem(
                    vodId: vodId,
                    vodName: title,
                    vodPic: cover,
                    vodRemarks: "[福利]香肠派对",
                    vodPlayUrl: urlStr,
                    customHeaders: headers
                )
            }
        }
    }
}
