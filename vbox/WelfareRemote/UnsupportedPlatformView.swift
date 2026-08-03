//
//  UnsupportedPlatformView.swift
//  vbox
//
//  作用：当远程平台 serviceType 在客户端路由中没有对应实现时，
//        显示明确的错误信息，而不是兜底跳到其他平台。
//        这样维护者能一眼发现哪个平台失效，方便检查修复或移除。
//

import SwiftUI

struct UnsupportedPlatformView: View {
    let platform: WelfarePlatform

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 图标 + 警告
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 64, height: 64)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.orange)
                    }

                    Text("该平台暂不可用")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)

                    Text("客户端尚未实现该平台类型的路由")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)

                // 平台信息
                VStack(spacing: 0) {
                    infoRow(label: "平台名称", value: platform.name)
                    Divider().padding(.leading, 16)
                    infoRow(label: "platformKey", value: platform.platformKey)
                    Divider().padding(.leading, 16)
                    infoRow(label: "serviceType", value: platform.serviceType)
                    Divider().padding(.leading, 16)
                    infoRow(label: "分类", value: platform.category)
                    if let notes = platform.notes, !notes.isEmpty {
                        Divider().padding(.leading, 16)
                        infoRow(label: "备注", value: notes)
                    }
                }
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal, 20)

                // 排查建议
                VStack(alignment: .leading, spacing: 8) {
                    Text("排查建议")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)

                    Text("• 检查 JSON 中 serviceType 是否拼写正确")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("• 检查客户端 WelfareServiceType 枚举是否有对应 case")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("• 如果是新平台类型，需在 WelfarePlatformRouter 中新增路由")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal, 20)

                Spacer()
            }
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .navigationTitle(platform.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
