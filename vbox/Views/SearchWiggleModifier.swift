//
//  SearchWiggleModifier.swift
//  vbox
//
//  搜索中放大镜"原地转圈"动画
//  放大镜在原地旋转，模拟"搜索中"的加载效果
//
//  使用方式：
//    Image(systemName: "magnifyingglass")
//        .searchWiggle(isActive: isLoading)
//

import SwiftUI

// MARK: - 搜索旋转动画 Modifier

struct SearchWiggleModifier: ViewModifier {
    /// 是否激活动画
    let isActive: Bool

    /// 旋转角度（度）- 一圈 360°
    private let rotationPerCycle: Double = 360
    /// 一圈动画时长（秒）
    private let cycleDuration: Double = 1.2

    @State private var rotation: Double = 0
    @State private var animating = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(rotation), anchor: .center)
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
        rotation = 0
        runNextCycle()
    }

    private func stopAnimation() {
        animating = false
        // 平滑归位
        withAnimation(.easeOut(duration: 0.3)) {
            rotation = 0
        }
    }

    private func runNextCycle() {
        guard animating else { return }

        // 线性旋转一圈，循环不停
        withAnimation(.linear(duration: cycleDuration)) {
            rotation += rotationPerCycle
        }

        // 一圈结束后继续下一圈
        DispatchQueue.main.asyncAfter(deadline: .now() + cycleDuration) {
            guard self.animating else { return }
            self.runNextCycle()
        }
    }
}

// MARK: - View 便捷扩展

extension View {
    /// 搜索旋转动画：搜索中时放大镜原地转圈
    /// - Parameter isActive: 是否激活动画（通常绑定 isSearchLoading）
    func searchWiggle(isActive: Bool) -> some View {
        modifier(SearchWiggleModifier(isActive: isActive))
    }
}
