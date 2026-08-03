//
//  WelfareTabGateView.swift
//  vbox
//
//  Phase 3：iOS 现有文件最小改动
//  作用：底部 Tab 栏「福利」入口的路由门。
//        - 开关打开：展示 RemoteWelfareHomeView（远程源）
//        - 开关关闭：展示 WelfareHomeView（内置资源，与改造前一致）
//  为什么新建一个 View：
//        RemoteWelfareGateView 需要 Binding<Bool>（用于 sheet 弹窗），
//        而 Tab 入口不需要 Binding，因此用一个无参 wrapper 更简洁。
//

import SwiftUI

struct WelfareTabGateView: View {
    var body: some View {
        if WelfarePlatformConfigStore.shared.switchEnabled {
            RemoteWelfareHomeView()
        } else {
            WelfareHomeView()
        }
    }
}
