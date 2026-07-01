import SwiftUI

// MARK: - 二级分类页面 ViewModel
@MainActor
final class SangeCategoryViewModel: ObservableObject {
    @Published var bigCategories: [SangeBigCategory] = []
    @Published var selectedBig: SangeBigCategory?
    @Published var isLoading = true
    @Published var errorMsg: String?

    private let api = KXSPAPIService.shared

    func load() {
        isLoading = true
        errorMsg = nil
        Task {
            if !api.isConfigured {
                await api.setup(httpUrl: nil)
            }
            guard api.isConfigured else {
                await MainActor.run {
                    isLoading = false
                    errorMsg = api.lastError ?? "初始化失败"
                }
                return
            }

            do {
                let categories = try await api.fetchVideoNavList()
                await MainActor.run {
                    self.bigCategories = categories.isEmpty ? SangeBigCategory.samples : categories
                    self.selectedBig = self.bigCategories.first
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.bigCategories = SangeBigCategory.samples
                    self.selectedBig = self.bigCategories.first
                    self.isLoading = false
                    self.errorMsg = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 二级分类页面
struct SangeCategoryView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = SangeCategoryViewModel()

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            bigCategoryTabBar

            if viewModel.isLoading {
                Spacer()
                ProgressView("加载分类中...")
                Spacer()
            } else if let error = viewModel.errorMsg, viewModel.bigCategories.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundColor(.orange)
                    Text(error).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("重试") { viewModel.load() }
                }
                .padding(.horizontal, 32)
                Spacer()
            } else {
                subCategoryGrid
            }
        }
        .background(backgroundColor)
        .navigationTitle("三更")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { viewModel.load() }
    }

    // MARK: 顶部大分类 Tab
    private var bigCategoryTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.bigCategories) { category in
                    Button {
                        viewModel.selectedBig = category
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: category.navType.icon).font(.system(size: 12))
                            Text(category.name).font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(viewModel.selectedBig?.id == category.id ? accentColor : Color.clear)
                        .foregroundColor(viewModel.selectedBig?.id == category.id ? .white : textColor)
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(accentColor.opacity(0.4), lineWidth: viewModel.selectedBig?.id == category.id ? 0 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(backgroundColor)
    }

    // MARK: 小分类网格
    private var subCategoryGrid: some View {
        let subs = viewModel.selectedBig?.subCategories ?? []
        return ScrollView {
            if subs.isEmpty {
                VStack(spacing: 16) {
                    Spacer().frame(height: 80)
                    Image(systemName: "folder.badge.questionmark").font(.system(size: 50)).foregroundColor(.secondary)
                    Text("暂无子分类").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(subs) { sub in
                        NavigationLink(destination: SangeListView(
                            bigCategory: viewModel.selectedBig ?? SangeBigCategory(dict: [:]),
                            subCategory: sub
                        )) {
                            VStack(spacing: 8) {
                                Image(systemName: iconFor(sub: sub))
                                    .font(.system(size: 24))
                                    .foregroundColor(accentColor)
                                Text(sub.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(textColor)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 90)
                            .background(accentColor.opacity(0.08))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }

    private func iconFor(sub: SangeSubCategory) -> String {
        switch sub.parentType {
        case .video: return "play.rectangle.fill"
        case .shortVideo: return "play.square.stack.fill"
        case .comic: return "book.fill"
        case .novel: return "text.book.closed.fill"
        }
    }

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    private var textColor: Color {
        settings.usesVisualSkin ? .white : Color(uiColor: .label)
    }

    private var backgroundColor: Color {
        settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemGroupedBackground)
    }
}
