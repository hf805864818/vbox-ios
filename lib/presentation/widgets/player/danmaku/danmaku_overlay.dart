/// 表现层：弹幕渲染层（批次 C · C-03）。
///
/// 纯渲染：接收 [DanmakuRenderState] 列表（由
/// `platform/player/danmaku/danmaku_lane_engine.dart` 引擎产出），
/// 以 Stack + Positioned 摆放。弹幕开关 / 透明度 / 区域由外部传入。
library;

import 'package:flutter/material.dart';

import '../../../../platform/player/danmaku/danmaku_item.dart';
import '../../../../platform/player/danmaku/danmaku_lane_engine.dart';
import '../../../../platform/player/danmaku/danmaku_settings.dart';
import '../../../theme/tokens/colors.dart';

/// 弹幕覆盖层。
class DanmakuOverlay extends StatelessWidget {
  /// 构造。
  const DanmakuOverlay({
    super.key,
    required this.states,
    this.opacity = 0.8,
    this.area = 1.0,
    this.fontSize,
    this.colorMode = 7,
    this.ignorePointer = true,
  });

  /// 引擎产出的当前渲染状态。
  final List<DanmakuRenderState> states;

  /// 不透明度（0.0 ~ 1.0）。
  final double opacity;

  /// 显示区域比例（0.25 ~ 1.0，1.0 全屏）。
  final double area;

  /// 覆盖字号（px；null 用弹幕自带 [DanmakuItem.sizePx]，对齐弹幕设置面板）。
  final double? fontSize;

  /// 颜色模式（0=原始 1=白 2=黄 3=绿 4=蓝 5=红 6=粉 7=随机；对齐 iOS
  /// `danmakuColorMode`，默认随机）。
  final int colorMode;

  /// 是否忽略指针事件（默认 true：不拦截播放器手势）。
  final bool ignorePointer;

  /// 解析单条弹幕的显示颜色（ARGB，对齐 iOS L2036 语义）：
  ///   · mode 0 → 弹幕原始颜色；
  ///   · mode 7 → 从随机池选色（iOS 逐条随机；此处按弹幕标识做**确定性选色**——
  ///     同一条弹幕每次重建稳定同色，避免逐帧重掷导致的闪烁，分布等效随机）；
  ///   · 其余 → 预设色表（缺项回落原始颜色）。
  int _resolveColor(DanmakuItem item) {
    switch (colorMode) {
      case 0:
        return item.argb;
      case 7:
        const List<int> pool = DanmakuSettings.randomColorPool;
        final String key = item.id ?? item.content;
        return 0xFF000000 | pool[key.hashCode.abs() % pool.length];
      default:
        final int? preset = DanmakuSettings.presetColors[colorMode];
        return preset == null
            ? item.argb
            : 0xFF000000 | preset;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (states.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      ignoring: ignorePointer,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 显示区域：仅保留顶部 area 比例的高度，其余裁剪（对齐设置面板「显示区域」）。
          final double limit =
              constraints.maxHeight * area.clamp(0.25, 1.0);
          return Align(
            alignment: Alignment.topCenter,
            child: ClipRect(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth,
                  maxHeight: limit,
                ),
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: <Widget>[
                    for (final DanmakuRenderState s in states)
                      Positioned(
                        left: s.x,
                        top: s.y,
                        child: Opacity(
                          opacity: opacity,
                          child: Text(
                            s.item.content,
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                            style: TextStyle(
                              color: Color(_resolveColor(s.item)),
                              fontSize: fontSize ?? s.item.sizePx,
                              fontWeight: FontWeight.w500,
                              shadows: const <Shadow>[
                                Shadow(
                                  color: VboxColors.danmakuShadow,
                                  blurRadius: 2,
                                  offset: Offset(1, 1),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
