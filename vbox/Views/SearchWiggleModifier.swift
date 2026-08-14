//
//  SearchWiggleModifier.swift
//  vbox
//
//  搜索中放大镜"原地画圈"动画
//  放大镜方向保持正立不旋转，在原地做小圆周运动
//  模拟"四处寻找"的效果
//
//  使用方式：
//    Image(systemName: "magnifyingglass")
//        .searchWiggle(isActive: isLoading)
//

import SwiftUI

// MARK: - 搜索画圈动画 Modifier

struct SearchWiggleModifier: ViewModifier {
    /// 是否激活动画
    let isActive: Bool

    /// 圆周半径（pt）- 放大镜在原地画圈的半径
    private let orbitRadius: CGFloat = 8
    /// 转一圈时长（秒）
    private let cycleDuration: Double = 1.0

    @State private var angle: Double = 0
    @State private var timer: Timer?

    func body(content: Content) -> some View {
        content
            .offset(
                x: cos(angle) * orbitRadius,
                y: sin(angle) * orbitRadius
            )
            .onAppear {
                if isActive { startAnimation() }
            }
            .onChange(of: isActive) { newValue in
                if newValue {
                    startAnimation()
                } else {
                    stopAnimation()
                }
            }
            .onDisappear {
                stopAnimation()
            }
    }

    // MARK: - 动画控制

    private func startAnimation() {
        guard timer == nil else { return }
        angle = 0
        // 每 1/60 秒更新一次，约 60fps
        let step = (2 * .pi) / (cycleDuration * 60)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { _ in
            angle += step
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
        withAnimation(.easeOut(duration: 0.25)) {
            angle = 0
        }
    }
}

// MARK: - View 便捷扩展

extension View {
    /// 搜索画圈动画：放大镜保持正立，在原地做小圆周运动
    /// - Parameter isActive: 是否激活动画（通常绑定 isSearchLoading）
    func searchWiggle(isActive: Bool) -> some View {
        modifier(SearchWiggleModifier(isActive: isActive))
    }
}
