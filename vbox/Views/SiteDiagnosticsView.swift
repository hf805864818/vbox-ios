import SwiftUI

struct SiteDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var spiderManager = SpiderManager.shared
    @StateObject private var diagnosticsManager = SiteDiagnosticsManager.shared
    @State private var selectedFilter: SiteStatusFilter = .all

    enum SiteStatusFilter: String, CaseIterable {
        case all = "全部"
        case searchable = "可搜索"
        case failed = "有异常"
        case type0 = "API(type0)"
        case type1 = "API(type1)"
        case type2 = "站源(type2)"
        case type3 = "JS蜘蛛(type3)"
    }

    var filteredResults: [SiteDiagnosticResult] {
        switch selectedFilter {
        case .all: return diagnosticsManager.results
        case .searchable: return diagnosticsManager.results.filter { $0.canSearch }
        case .failed: return diagnosticsManager.results.filter { !$0.canSearch }
        case .type0: return diagnosticsManager.results.filter { $0.type == 0 }
        case .type1: return diagnosticsManager.results.filter { $0.type == 1 }
        case .type2: return diagnosticsManager.results.filter { $0.type == 2 }
        case .type3: return diagnosticsManager.results.filter { $0.type == 3 }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 统计摘要
                if let summary = diagnosticsManager.summary {
                    summaryCard(summary)
                }

                // 筛选器
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SiteStatusFilter.allCases, id: \.self) { filter in
                            Button(action: { selectedFilter = filter }) {
                                Text(filter.rawValue)
                                    .font(.system(size: 13, weight: selectedFilter == filter ? .semibold : .medium))
                                    .foregroundColor(selectedFilter == filter ? .white : .primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(selectedFilter == filter ? Color(hex: "E11D48") : Color.gray.opacity(0.12))
                                    .cornerRadius(16)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                // 诊断列表
                if diagnosticsManager.isDiagnosing {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在检测接口状态...")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                } else if diagnosticsManager.results.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("点击开始检测接口状态")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                } else {
                    List {
                        Section(header: Text("共 \(filteredResults.count) 个接口")) {
                            ForEach(filteredResults) { result in
                                SiteDiagnosticRow(result: result)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("接口状态诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        Task {
                            await diagnosticsManager.diagnose(spiderManager: spiderManager)
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16))
                    }
                    .disabled(diagnosticsManager.isDiagnosing)
                }
            }
        }
        .onAppear {
            if diagnosticsManager.results.isEmpty {
                Task {
                    await diagnosticsManager.diagnose(spiderManager: spiderManager)
                }
            }
        }
    }

    private func summaryCard(_ summary: SiteDiagnosticsManager.DiagnosticSummary) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                SummaryItem(title: "总计", value: "\(summary.total)", color: .primary)
                SummaryItem(title: "引擎就绪", value: "\(summary.engineReady)", color: .green)
                SummaryItem(title: "仅API", value: "\(summary.apiOnly)", color: .blue)
                SummaryItem(title: "可搜索", value: "\(summary.searchableCount)", color: Color(hex: "E11D48"))
            }
            if summary.failed > 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("\(summary.failed) 个接口加载失败，请查看详情")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}

struct SummaryItem: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SiteDiagnosticRow: View {
    let result: SiteDiagnosticResult
    @State private var isExpanded = false

    var typeLabel: String {
        switch result.type {
        case 0: return "API"
        case 1: return "API"
        case 2: return "站源"
        case 3: return "JS蜘蛛"
        default: return "未知"
        }
    }

    var typeColor: Color {
        switch result.type {
        case 0, 1: return .blue
        case 2: return .purple
        case 3: return .green
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(result.status.icon)
                    .font(.system(size: 18))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(result.siteName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                        Text(typeLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(typeColor)
                            .cornerRadius(4)
                        if result.canSearch {
                            Text("可搜索")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(hex: "E11D48"))
                                .cornerRadius(4)
                        }
                    }
                    Text(result.status.rawValue)
                        .font(.system(size: 12))
                        .foregroundColor(statusColor)
                }

                Spacer()

                if result.errorMessage != nil {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                if result.errorMessage != nil {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }

            if isExpanded, let error = result.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("问题详情:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let api = result.api {
                        Text("API: \(api)")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                            .lineLimit(2)
                    }
                }
                .padding(.bottom, 10)
                .padding(.leading, 34)
            }
        }
    }

    var statusColor: Color {
        switch result.status {
        case .engineReady, .loaded: return .green
        case .apiOnly: return .blue
        case .noApi, .downloadFailed, .invalidContent, .registerFailed: return .orange
        case .unknown, .skipped: return .gray
        }
    }
}
