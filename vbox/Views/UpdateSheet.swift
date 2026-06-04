// MARK: - 更新弹窗
struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var updateManager = UpdateManager.shared
    @State private var isDownloading = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if updateManager.isChecking {
                    ProgressView("正在检查更新...")
                        .padding(.top, 60)
                } else if updateManager.hasUpdate {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(Color(hex: "E11D48"))
                    
                    Text("发现新版本")
                        .font(.system(size: 22, weight: .bold))
                    
                    HStack {
                        Text("当前: v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                        Text("最新: v" + updateManager.latestVersion)
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "E11D48"))
                    }
                    
                    if !updateManager.releaseNotes.isEmpty {
                        ScrollView {
                            Text(updateManager.releaseNotes)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .padding()
                        }
                        .frame(height: 150)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(12)
                    }
                    
                    Button(action: {
                        isDownloading = true
                        updateManager.openDownload()
                    }) {
                        HStack {
                            if isDownloading { ProgressView().tint(.white) }
                            Text(isDownloading ? "正在打开..." : "下载更新")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(hex: "E11D48"))
                        .cornerRadius(12)
                    }
                    
                    Text("下载后用巨魔商店安装")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                } else if let error = updateManager.updateError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.orange)
                    Text("检查失败")
                    Text(error).font(.system(size: 13)).foregroundColor(.secondary)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    Text("已是最新版本").font(.system(size: 18, weight: .semibold))
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("版本更新")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
