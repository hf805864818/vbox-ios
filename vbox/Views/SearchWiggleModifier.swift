//
//  SearchWiggleModifier.swift
//  vbox
//
//  搜索中放大镜"探索式跳动"动画
//  模拟用放大镜左右张望寻找东西的动作，贴合"搜索"语义
//
//  动画效果：
//    - 左右轻微摆动（±2pt）
//    - 上下轻抬（-2pt）
//    - 微微倾斜（±6°）
//    - 循环节奏舒缓（单程 0.8s，easeInOut）
//
//  使用方式：
//    Image(systemName: "magnifyingglass")
//        .searchWiggle(isActive: isLoading)
//

import SwiftUI

// MARK: - 搜索摆动动画 Modifier

struct SearchWiggleModifier: ViewModifier {
    /// 是否激活动画
    let isActive: Bool

    /// 水平摆动幅度（pt）
    private let horizontalAmp: CGFloat = 2
    /// 垂直抬起幅度（pt）
    private let verticalAmp: CGFloat = 2
    /// 旋转角度（度）
    private let rotationAmp: Double = 6
    /// 单程动画时长（秒）
    private let oneWayDuration: Double = 0.8

    @State private var phase: Int = 0 // 0=原位, 1=右上, 2=原位, 3=左上
    @State private var animating = false

    func body(content: Content) -> some View {
        content
            .offset(x: offsetX, y: offsetY)
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

    // MARK: - 动画计算

    private var offsetX: CGFloat {
        guard animating else { return 0 }
        switch phase {
        case 1: return horizontalAmp   // 右
        case 3: return -horizontalAmp  // 左
        default: return 0              // 原位
        }
    }

    private var offsetY: CGFloat {
        guard animating else { return 0 }
        switch phase {
        case 1, 3: return -verticalAmp  // 抬起
        default: return 0               // 原位
        }
    }

    private var rotation: Double {
        guard animating else { return 0 }
        switch phase {
        case 1: return -rotationAmp  // 向右看时镜片左倾（顺时针的反方向，更自然）
        case 3: return rotationAmp   // 向左看时镜片右倾
        default: return 0
        }
    }

    // MARK: - 动画控制

    private func startAnimation() {
        guard !animating else { return }
        animating = true
        phase = 0
        runAnimationCycle()
    }

    private func stopAnimation() {
        animating = false
        // 归位到初始状态（带平滑过渡）
        withAnimation(.easeOut(duration: oneWayDuration * 0.5)) {
            phase = 0
        }
    }

    private func runAnimationCycle() {
        guard animating else { return }

        // 相位 0→1：原位 → 右上
        withAnimation(.easeInOut(duration: oneWayDuration)) {
            phase = 1
        }

        // 相位 1→2：右上 → 原位
        DispatchQueue.main.asyncAfter(deadline: .now() + oneWayDuration) {
            guard self.animating else { return }
            withAnimation(.easeInOut(duration: self.oneWayDuration)) {
                self.phase = 2
            }

            // 相位 2→3：原位 → 左上
            DispatchQueue.main.asyncAfter(deadline: .now() + self.oneWayDuration) {
                guard self.animating else { return }
                withAnimation(.easeInOut(duration: self.oneWayDuration)) {
                    self.phase = 3
                }

                // 相位 3→0：左上 → 原位
                DispatchQueue.main.asyncAfter(deadline: .now() + self.oneWayDuration) {
                    guard self.animating else { return }
                    withAnimation(.easeInOut(duration: self.oneWayDuration)) {
                        self.phase = 0
                    }

                    // 下一循环
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.oneWayDuration * 0.5) {
                        guard self.animating else { return }
                        self.runAnimationCycle()
                    }
                }
            }
        }
    }
}

// MARK: - View 便捷扩展

extension View {
    /// 搜索摆动动画：搜索中时放大镜做"左右张望寻找"的动效
    /// - Parameter isActive: 是否激活动画（通常绑定 isSearchLoading）
    func searchWiggle(isActive: Bool) -> some View {
        modifier(SearchWiggleModifier(isActive: isActive))
    }
}
