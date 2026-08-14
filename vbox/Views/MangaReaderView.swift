//
//  MangaReaderView.swift
//  vbox
//
//  条漫长卷模式漫画阅读器
//
//  设计特点：
//  - 沉浸式全屏阅读，黑色背景
//  - 图片宽度自适应屏幕，无缝衔接成一条长卷
//  - 点击切换工具栏显示/隐藏
//  - 实时进度指示（第X张/共Y张 + 进度条）
//  - 懒加载 + 占位图 + 加载失败重试（复用 PlatformAsyncImage）
//  - 支持双击缩放
//  - 支持长按保存图片
//  - 顶部/底部快速跳转按钮
//

import SwiftUI

// MARK: - 长卷漫画阅读器主视图
struct MangaReaderView: View {
    let images: [String]
    let title: String
    let referer: String?
    let sslBypass: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var showBars = true
    @State private var currentIndex: Int = 0
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(images.enumerated()), id: \.offset) { idx, url in
                            MangaImageView(
                                url: url,
                                referer: referer,
                                sslBypass: sslBypass,
                                onAppear: { currentIndex = idx }
                            )
                            .id(idx)
                        }
                    }
                }
                .onAppear { scrollProxy = proxy }
                .onTapGesture(count: 1) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showBars.toggle()
                    }
                }
            }

            // 顶部导航栏
            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .opacity(showBars ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: showBars)
        }
        .statusBar(hidden: !showBars)
        .navigationBarHidden(true)
    }

    // MARK: - 顶部栏

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            // 占位保持平衡
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 8)
        .padding(.top, safeAreaTop)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - 底部栏

    private var bottomBar: some View {
        VStack(spacing: 6) {
            // 进度条
            ProgressView(value: progress)
                .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                .padding(.horizontal, 16)

            HStack {
                Text("第 \(currentIndex + 1) 张 / 共 \(images.count) 张")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.85))

                Spacer()

                Button(action: { scrollToTop() }) {
                    Image(systemName: "arrow.up.to.line")
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button(action: { scrollToBottom() }) {
                    Image(systemName: "arrow.down.to.line")
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, safeAreaBottom)
        }
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - 计算属性

    private var progress: Double {
        guard !images.isEmpty else { return 0 }
        return Double(currentIndex + 1) / Double(images.count)
    }

    private var safeAreaTop: CGFloat {
        UIApplication.shared.windows.first?.safeAreaInsets.top ?? 0
    }

    private var safeAreaBottom: CGFloat {
        UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? 0
    }

    // MARK: - 滚动跳转

    private func scrollToTop() {
        withAnimation {
            scrollProxy?.scrollTo(0, anchor: .top)
        }
    }

    private func scrollToBottom() {
        withAnimation {
            scrollProxy?.scrollTo(images.count - 1, anchor: .bottom)
        }
    }
}

// MARK: - 单张漫画图片视图
/// 复用 PlatformAsyncImage，支持 Referer、SSL 绕过、缓存、重试
struct MangaImageView: View {
    let url: String
    let referer: String?
    let sslBypass: Bool
    var onAppear: () -> Void = {}

    @State private var scale: CGFloat = 1.0
    @State private var showRetry = false

    var body: some View {
        ZStack {
            if showRetry {
                // 加载失败：显示重试按钮
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.5))
                    Text("图片加载失败")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                    Button(action: { showRetry = false }) {
                        Text("点击重试")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(Color.gray.opacity(0.2))
            } else {
                PlatformAsyncImage.sourceCover(
                    url,
                    referer: referer,
                    sslBypass: sslBypass,
                    contentMode: .fit
                )
                .frame(maxWidth: .infinity)
                .scaleEffect(scale)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        scale = scale > 1 ? 1.0 : 2.0
                    }
                }
                .contextMenu {
                    Button(action: { saveImage() }) {
                        Label("保存图片", systemImage: "square.and.arrow.down")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { onAppear() }
        .onChange(of: url) { _ in
            showRetry = false
        }
    }

    private func saveImage() {
        // 从缓存中读取图片并保存
        let cacheKey = PlatformImageLoader.makeCacheKey(url, mode: .mysteryMovie)
        if let cached = PlatformImageCache.shared.get(cacheKey) {
            UIImageWriteToSavedPhotosAlbum(cached, nil, nil, nil)
        }
    }
}
