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
    @State private var animating = false

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
    }

    // MARK: - 动画控制

    private func startAnimation() {
        guard !animating else { return }
        animating = true
        angle = 0
        runNextCycle()
    }

    private func stopAnimation() {
        animating = false
        withAnimation(.easeOut(duration: 0.25)) {
            angle = 0
        }
    }

    /// 圆周运动：每圈 360°，线性匀速
    private func runNextCycle() {
        guard animating else { return }

        withAnimation(.linear(duration: cycleDuration)) {
            angle += 2 * .pi  // 转一圈（弧度）
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + cycleDuration) {
            guard self.animating else { return }
            self.runNextCycle()
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
