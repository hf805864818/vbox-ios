//
//  SearchWiggleModifier.swift
//  vbox
//
//  搜索中放大镜"原地摇摆"动画
//  放大镜在原地左右轻微旋转，模拟"四处张望寻找"的效果
//  放大镜始终保持正立，不会倒过来
//
//  使用方式：
//    Image(systemName: "magnifyingglass")
//        .searchWiggle(isActive: isLoading)
//

import SwiftUI

// MARK: - 搜索摇摆动画 Modifier

struct SearchWiggleModifier: ViewModifier {
    /// 是否激活动画
    let isActive: Bool

    /// 单次摆动角度（度）- ±15°，放大镜不会倒过来
    private let swingAngle: Double = 15
    /// 单程动画时长（秒）
    private let swingDuration: Double = 0.5

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
        runSwingCycle()
    }

    private func stopAnimation() {
        animating = false
        withAnimation(.easeOut(duration: 0.25)) {
            rotation = 0
        }
    }

    /// 摆动循环：0 → +15° → 0 → -15° → 0 → 重复
    private func runSwingCycle() {
        guard animating else { return }

        let anim = Animation.easeInOut(duration: swingDuration)

        // 0 → 右摆 (+15°)
        withAnimation(anim) { rotation = swingAngle }

        DispatchQueue.main.asyncAfter(deadline: .now() + swingDuration) {
            guard self.animating else { return }
            // 右摆 → 回正 (0°)
            withAnimation(anim) { self.rotation = 0 }

            DispatchQueue.main.asyncAfter(deadline: .now() + self.swingDuration) {
                guard self.animating else { return }
                // 回正 → 左摆 (-15°)
                withAnimation(anim) { self.rotation = -self.swingAngle }

                DispatchQueue.main.asyncAfter(deadline: .now() + self.swingDuration) {
                    guard self.animating else { return }
                    // 左摆 → 回正 (0°)
                    withAnimation(anim) { self.rotation = 0 }

                    // 短暂停顿后继续下一轮
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.swingDuration + 0.15) {
                        guard self.animating else { return }
                        self.runSwingCycle()
                    }
                }
            }
        }
    }
}

// MARK: - View 便捷扩展

extension View {
    /// 搜索摇摆动画：搜索中放大镜左右轻微旋转（±15°），保持正立
    /// - Parameter isActive: 是否激活动画（通常绑定 isSearchLoading）
    func searchWiggle(isActive: Bool) -> some View {
        modifier(SearchWiggleModifier(isActive: isActive))
    }
}
