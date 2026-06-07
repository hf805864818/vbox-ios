import SwiftUI

struct SettingsView: View {
    @StateObject private var spiderManager = SpiderManager.shared
    @StateObject private var cloudDriveManager = CloudDriveManager.shared
    @State private var autoPlayNext = true
    @State private var playInBackground = true
    @State private var usePictureInPicture = true
    @AppStorage("show_debug_overlay") private var showDebugOverlay = false
    @State private var selectedQuality = "1080P"
    @State private var selectedSpeed = 1.0
    @State private var showCacheAlert = false
    @State private var cacheSize: String = "256 MB"
    @State private var showUpdateSheet = false
    @StateObject private var updateManager = UpdateManager.shared
    @State private var isChecking = false
    @State private var newURL = ""
    @State private var errorMessage = ""
    @State private var newParserName = ""
    @State private var newParserURL = ""
    @State private var selectedDriveType: CloudDriveManager.DriveType = .ali
    @State private var driveTokenName = ""
    @State private var driveTokenValue = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // 标题
                Text("设置")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)

                VStack(spacing: 20) {
                    // 播放设置
                    SettingsSection(title: "播放设置") {
                        SettingsToggleRow(title: "自动播放下一个", icon: "play.circle.fill", isOn: $autoPlayNext)
                        SettingsToggleRow(title: "后台播放", icon: "headphones", isOn: $playInBackground)
                        SettingsToggleRow(title: "画中画", icon: "rectangle.on.rectangle", isOn: $usePictureInPicture)
                        SettingsToggleRow(title: "调试信息浮层", icon: "ladybug.fill", isOn: $showDebugOverlay)
                    }

                    // 网盘管理
                    SettingsSection(title: "网盘播放") {
                        VStack(alignment: .leading, spacing: 12) {
                            if !cloudDriveManager.savedTokens.isEmpty {
                                ForEach(Array(cloudDriveManager.savedTokens.enumerated()), id: \.offset) { index, token in
                                    HStack {
                                        Image(systemName: iconForDriveType(token.type))
                                            .foregroundColor(Color(hex: "E11D48"))
                                            .frame(width: 24)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(CloudDriveManager.DriveType(rawValue: token.type)?.displayName ?? token.type)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(.black)
                                            Text(token.name)
                                                .font(.system(size: 11))
                                                .foregroundColor(.gray)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Button(action: { cloudDriveManager.removeToken(at: index) }) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 14))
                                                .foregroundColor(.red)
                                        }
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(Color.gray.opacity(0.06))
                                    .cornerRadius(8)
                                }
                            }

                            // 获取Token按钮
                            Button(action: {
                                if let url = URL(string: "https://cookie-butler.douer.me") {
                                    UIApplication.shared.open(url)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "key.fill")
                                        .font(.system(size: 16))
                                    Text("获取Token")
                                        .font(.system(size: 14, weight: .medium))
                                    Text("→")
                                        .font(.system(size: 12))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(hex: "E11D48"))
                                .cornerRadius(10)
                            }

                            HStack {
                                Picker("网盘类型", selection: $selectedDriveType) {
                                    ForEach(CloudDriveManager.DriveType.allCases, id: \.self) { type in
                                        Text(type.displayName).tag(type)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 100)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                TextField("备注名称", text: $driveTokenName)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .font(.system(size: 13))

                                TextField(selectedDriveType.tokenLabel, text: $driveTokenValue)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .font(.system(size: 12))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            }

                            Button(action: addDriveToken) {
                                Text("保存Token")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color(hex: "E11D48"))
                                    .cornerRadius(10)
                            }
                            .disabled(driveTokenName.isEmpty || driveTokenValue.isEmpty)
                        }
                        .padding(16)
                    }

                    // 存储管理
                    SettingsSection(title: "存储管理") {
                        SettingsNavigationRow(
                            title: "缓存管理",
                            subtitle: cacheSize,
                            icon: "externaldrive.fill"
                        ) { showCacheAlert = true }
                    }

                    // 关于
                    SettingsSection(title: "关于") {
                        HStack {
                            Text("版本").foregroundColor(.black)
                            Spacer()
                            Text("3.60").foregroundColor(.gray)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)

                        Button(action: { showUpdateSheet = true }) {
                            HStack {
                                Text("检查更新").foregroundColor(.black)
                                Spacer()
                                if isChecking { ProgressView().scaleEffect(0.8) }
                                else { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.gray) }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }

                        NavigationLink(destination: SubscribeConfigView()) {
                            HStack {
                                Text("订阅配置").foregroundColor(.black)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.gray)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .background(Color.white)
        .alert("清除缓存", isPresented: $showCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("确定", role: .destructive) {}
        } message: { Text("确定要清除所有缓存数据吗？") }
        .sheet(isPresented: $showUpdateSheet) { UpdateSheet() }
    }

    private func addDriveToken() {
        guard !driveTokenName.isEmpty, !driveTokenValue.isEmpty else { return }
        cloudDriveManager.saveToken(type: selectedDriveType.rawValue, name: driveTokenName, value: driveTokenValue)
        driveTokenName = ""; driveTokenValue = ""
    }

    private func iconForDriveType(_ type: String) -> String {
        switch type {
        case "115": return "1.circle.fill"
        case "ali": return "a.circle.fill"
        case "quark": return "q.circle.fill"
        case "baidu": return "b.circle.fill"
        case "uc": return "u.circle.fill"
        default: return "cloud.fill"
        }
    }
}
