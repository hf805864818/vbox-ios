import SwiftUI

// MARK: - 漫画/套图中转页
// 点击漫画平台卡片后进入此页，加载详情并展示套图封面与基本信息，
// 用户点击封面后进入 ComicGalleryView 横向浏览全部图片。
struct ComicDetailBridgeView<Service: FuliPlatformService>: View {
    @ObservedObject var svc: Service
    let video: FuliVideo

    @State private var detail: FuliDetail?
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var showGallery = false

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                // 封面图
                AsyncImage(url: URL(string: video.vodPic)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit).cornerRadius(12)
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.2))
                            .aspectRatio(16 / 9, contentMode: .fit).cornerRadius(12)
                    }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .center) {
                    if isLoading {
                        ProgressView().scaleEffect(2).tint(.white)
                    } else if errorMsg != nil {
                        EmptyView()
                    } else if let first = detail?.episodes.first, let images = first.images, !images.isEmpty {
                        Button(action: { showGallery = true }) {
                            Image(systemName: "photo.stack.fill")
                                .font(.system(size: 60)).foregroundColor(.white.opacity(0.9))
                        }
                    }
                }

                if let err = errorMsg {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40)).foregroundColor(.secondary)
                        Text(err).font(.system(size: 14)).multilineTextAlignment(.center)
                        Button(action: { loadDetail() }) {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.system(size: 13)).foregroundColor(.white)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Color.accentColor).cornerRadius(8)
                        }
                    }
                    .padding(.horizontal, 20)
                    Spacer()
                } else if let detail = detail {
                    Text(detail.vodName)
                        .font(.system(size: 18, weight: .bold))
                        .padding(.horizontal, 16)

                    if let images = detail.episodes.first?.images, !images.isEmpty {
                        Button(action: { showGallery = true }) {
                            HStack {
                                Image(systemName: "photo.stack")
                                Text("浏览套图 (\(images.count)张)")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 28).padding(.vertical, 10)
                            .background(Color.accentColor).cornerRadius(22)
                        }
                        .buttonStyle(.plain)

                        if let content = detail.vodContent, !content.isEmpty {
                            Text(content)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .lineLimit(4)
                                .padding(.horizontal, 16)
                        }
                    } else {
                        Text("未解析到套图图片")
                            .font(.system(size: 14)).foregroundColor(.secondary)
                        Spacer()
                    }
                    Spacer()
                }
            }
            .padding(.top, 20)
            .navigationTitle("套图详情")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { loadDetail() }
            .fullScreenCover(isPresented: $showGallery) {
                if let images = detail?.episodes.first?.images {
                    ComicGalleryView(images: images, title: detail?.vodName ?? "")
                }
            }
        }
    }

    private func loadDetail() {
        isLoading = true; errorMsg = nil; detail = nil
        Task {
            await svc.ensureHostReady()
            let result = await svc.fetchDetail(vodId: video.vodId)
            await MainActor.run {
                detail = result; isLoading = false
                if result.episodes.isEmpty || result.episodes.first?.images?.isEmpty != false {
                    errorMsg = "未解析到套图图片"
                }
            }
        }
    }
}

// MARK: - 漫画/套图浏览页
struct ComicGalleryView: View {
    let images: [String]
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex = 0

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                TabView(selection: $currentIndex) {
                    ForEach(Array(images.enumerated()), id: \.offset) { idx, url in
                        AsyncImage(url: URL(string: url), transaction: .init(animation: .default)) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                            case .failure:
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: 36)).foregroundColor(.orange)
                                    Text("图片加载失败")
                                        .font(.system(size: 13)).foregroundColor(.secondary)
                                }
                            default:
                                ProgressView()
                                    .scaleEffect(1.5)
                                    .tint(.white)
                            }
                        }
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // 页码指示器
                VStack {
                    Spacer()
                    Text("\(currentIndex + 1) / \(images.count)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(14)
                        .padding(.bottom, 20)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("完成") { dismiss() }
                .foregroundColor(.white))
        }
    }
}
