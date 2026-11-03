/// 表现层：视频输出面（Wave A · R-渲1；UI-E2 补画面拉伸模式）。
///
/// 以原生 `open` 返回的 Flutter textureId 承载画面（[Texture]）；无纹理
/// （控制面后端 / 未开播）时渲染深色占位，避免「有声无画」被误判为黑屏故障。
///
/// 缩放模式（UI-E2，对齐 iOS `AVPlayerLayer.videoGravity`，缺省 `.contain`）：
///  - `contain`（适应）：已知视频尺寸时居中留边（对齐 iOS `.resizeAspect`）；
///  - `cover`（填充）：保持宽高比铺满裁切（对齐 iOS `.resizeAspectFill`）；
///  - `fill`（拉伸）：强制适配视图宽高比（对齐 iOS `.resize`）。
/// 未知尺寸时一律铺满（交由原生缩放）。
///
/// ⚠ **纹理尺寸预算（3.1890 卡顿根治 · 关键）**
///
/// Flutter 引擎按 [Texture] 的**布局物理尺寸**回调原生 `CopyPixelBuffer`，
/// 原生必须按这个尺寸出帧（尺寸不一致会 fastfail 0xC0000409）。旧实现让
/// Texture 铺满播放区，于是 4K 窗口下每帧都是 3840×2160×4 ≈ 33 MB：
///  - GL 路径：每帧 `glFinish` + `glReadPixels` 整帧下 PCIe，引擎再上传回 GPU；
///  - SW 路径：libswscale 转换 + 缩放 + 写内存在 CPU 上做，4K 直接压死。
/// 这是「不管播什么资源都一卡一卡」的统一根因（云电脑更明显：整条链路退化成
/// 纯 CPU）。
///
/// 现在把 Texture 的布局尺寸**钉在长边 ≤ [kMaxTextureLongSide] 物理像素**的
/// 预算内，再由 [FittedBox] 视觉放大/裁切到播放区——缩放交给合成器（GPU 上次
/// 要的一次四边形，成本可忽略），原生每帧字节数降到原来的 1/4 甚至更低。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/colors.dart';

/// 纹理长边物理像素上限（约 1080p 级）。
///
/// 取 1920：4K 窗口下每帧 8.3 MB（原 33 MB）。若未来改走 PBO 异步回读或
/// 子窗口直出，可以再调高。
const double kMaxTextureLongSide = 1920;

/// 视频输出面。
class VideoSurface extends StatelessWidget {
  /// 构造。
  const VideoSurface({
    super.key,
    this.textureId,
    this.aspectRatio,
    this.fit = BoxFit.contain,
    this.filterQuality = FilterQuality.low,
  });

  /// 原生纹理句柄（null = 无纹理输出 → 深色占位）。
  final int? textureId;

  /// 视频纵横比（宽 / 高；null / 非法值 = 铺满）。
  final double? aspectRatio;

  /// 缩放模式（UI-E2；仅已知纵横比时区分，未知尺寸一律铺满）。
  final BoxFit fit;

  /// 纹理采样质量。
  ///
  /// 保持 low（bilinear）：纹理先按预算尺寸渲染、再由 FittedBox 放大上屏，
  /// low 足够且不会触发桌面引擎无 mipmap 链的 medium 崩溃路径（3.1856 教训）。
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    final int? id = textureId;
    if (id == null) {
      return const ColoredBox(color: VboxColors.playerBackground);
    }

    // 物理像素预算 → 逻辑尺寸：Windows 的 devicePixelRatio 常见 1.0 / 1.25 / 1.5。
    final double rawDpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final double dpr = rawDpr <= 0 ? 1.0 : rawDpr;
    final double capLong = kMaxTextureLongSide / dpr;

    // 纵横比未知时按 16:9 给纹理定尺寸：mpv 在 FBO / 软缓冲内自己信箱化适配，
    // 不会因为这块盒子的比例而变形。
    // 注意：条件必须内联写，Dart 不会因为 `hasAspect` 这个 bool 就把 `ar`
    // 从 double? 提升成 double（编译期会报类型不匹配）。
    final double? ar = aspectRatio;
    final bool hasAspect =
        ar != null && ar > 0 && !ar.isNaN && !ar.isInfinite;
    final double ratio = (ar != null && ar > 0 && !ar.isNaN && !ar.isInfinite)
        ? ar
        : (16.0 / 9.0);
    final double capWidth = ratio >= 1.0 ? capLong : capLong * ratio;
    final double capHeight = ratio >= 1.0 ? capLong / ratio : capLong;

    // key 供测试按名定位纹理布局盒（断言纵横比与预算尺寸）。
    final Widget surface = SizedBox(
      key: const ValueKey<String>('vbox-texture-budget'),
      width: capWidth,
      height: capHeight,
      child: Texture(
        textureId: id,
        filterQuality: filterQuality,
      ),
    );

    // 预算尺寸 → 播放区：contain 留边 / cover 裁切 / fill 拉伸，全是合成器上
    // 的一次缩放，GPU 成本可忽略（对比原来每帧几十 MB 的回读）。
    if (!hasAspect) {
      return FittedBox(
        fit: BoxFit.contain,
        clipBehavior: Clip.hardEdge,
        child: surface,
      );
    }
    if (fit == BoxFit.contain) {
      return Center(
        child: FittedBox(
          fit: BoxFit.contain,
          clipBehavior: Clip.hardEdge,
          child: surface,
        ),
      );
    }
    return FittedBox(
      fit: fit,
      clipBehavior: Clip.hardEdge,
      child: surface,
    );
  }
}
