/// 表现层：品牌启动页（批次 L · L-壳1）。
///
/// 唯一真相源：iOS `vbox/Views/VboxSplashView.swift` + `ContentView.swift`
/// （最短展示 3.5s · 首页数据门控 · 10s 兜底）。
///
/// 对齐口径（与 iOS **同源 PNG 素材**，1:1 复刻布局常量）：
///  - 素材：`assets/splash/splash_letter_{V,b,o,x}.png` + `splash_swoosh.png`
///    （四张字母同画布高 1010 / 同基线 860；swoosh 2446×469）；
///  - 字标：V 显示高 100pt、box 三字母 ×0.85 = 85pt，按 iOS 的
///    width/xOffset/yOffset 重叠聚拢（V 大一号），整体 -8° 上翘；
///  - swoosh 托底：宽 182.2pt、相对字标左上 (0, 72.3)、顺时针 4° 压平；
///  - 动画：四角飞入聚合（位移 500×(1,0.7)、旋转 ±30/±25、错峰 0/0.08/0.14/0.20s）
///    + swoosh 从左扫入（0.30s 延时）→ 聚合后发光（0.7s）
///    → 呼吸缩放（2.4s，1.05×）+ 上下浮动（3.0s，±6pt）无限循环；
///  - 底部两行小字 + 版本号（发光后淡入）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';

/// 启动页渐变底色（深浅自适应；启动图与品牌闪屏共用同一取值）。
List<Color> vboxSplashGradient(Brightness brightness) => brightness == Brightness.dark
    ? const <Color>[Color.fromRGBO(31, 31, 41, 1), Color.fromRGBO(13, 13, 18, 1)]
    : const <Color>[Color.fromRGBO(247, 247, 250, 1), Color.fromRGBO(230, 230, 237, 1)];

/// 静态品牌底色（对齐 iOS 原生启动图角色：依赖加载期铺满品牌渐变，杜绝白屏）。
///
/// 与 [VboxSplashView] 同色，故「静态底色 → 品牌闪屏」过渡无跳色。
class VboxSplashBackdrop extends StatelessWidget {
  /// 构造。
  const VboxSplashBackdrop({super.key, this.brightness});

  /// 指定明暗；缺省取运行环境平台亮度（此时尚未完成皮肤加载）。
  final Brightness? brightness;

  @override
  Widget build(BuildContext context) {
    final Brightness b = brightness ??
        MediaQuery.maybePlatformBrightnessOf(context) ??
        Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: vboxSplashGradient(b),
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// 飞入方向（对齐 iOS `LetterFlyDirection`）。
enum _FlyDirection {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight;

  /// 位移（距离 500，纵向 ×0.7）。
  Offset get offset => switch (this) {
        _FlyDirection.topLeft => const Offset(-500, -350),
        _FlyDirection.topRight => const Offset(500, -350),
        _FlyDirection.bottomLeft => const Offset(-500, 350),
        _FlyDirection.bottomRight => const Offset(500, 350),
      };

  /// 初始旋转角（度）。
  double get rotation => switch (this) {
        _FlyDirection.topLeft => -30,
        _FlyDirection.topRight => 30,
        _FlyDirection.bottomLeft => 25,
        _FlyDirection.bottomRight => -25,
      };
}

/// 单个字母配置（对齐 iOS `LetterImageConfig`）。
class _LetterSpec {
  const _LetterSpec({
    required this.asset,
    required this.width,
    required this.height,
    required this.xOffset,
    required this.yOffset,
    required this.direction,
    required this.delay,
  });

  /// 素材路径。
  final String asset;

  /// 显示宽度（按归一化画布 1010 等比换算，对齐 iOS `frame(width:)`）。
  final double width;

  /// 显示高度（= 宽度 × 画布高/图宽，与 iOS `.scaledToFit()` 同值）。
  final double height;

  /// 聚合后的水平位置。
  final double xOffset;

  /// 聚合后的垂直位置（box 缩小后下移，墨迹底对齐基线）。
  final double yOffset;

  /// 飞入方向。
  final _FlyDirection direction;

  /// 错峰延时（秒）。
  final double delay;
}

/// 品牌启动页。
class VboxSplashView extends StatefulWidget {
  /// 构造。
  const VboxSplashView({super.key});

  /// 飞入聚合总时长。
  static const Duration enterDuration = Duration(milliseconds: 900);

  @override
  State<VboxSplashView> createState() => _VboxSplashViewState();
}

class _VboxSplashViewState extends State<VboxSplashView>
    with TickerProviderStateMixin {
  /// 字标聚合宽度（对齐 iOS `compWidth`）。
  static const double _compWidth = 182.2;

  /// 字标高度基准（V 显示高 100pt，对齐 iOS `logoHeight`）。
  static const double _logoHeight = 100;

  /// 字标整体倾角（-8° 右端上翘，对齐 iOS `logoTilt`）。
  static const double _logoTilt = -8;

  /// swoosh 宽 / 高（2446×469 按 182.2pt 等比）。
  static const double _swooshWidth = 182.2;
  static const double _swooshHeight = 34.9;

  /// swoosh 相对字标左上的偏移（对齐 iOS `swooshOffset`）。
  static const Offset _swooshOffset = Offset(0, 72.3);

  /// swoosh 顺时针压平角度（对齐 iOS `swooshTilt`）。
  static const double _swooshTilt = 4;

  /// 字母素材（v9：V 大一号，box 缩小 0.85；与 iOS 同源 PNG）。
  static const List<_LetterSpec> _letters = <_LetterSpec>[
    _LetterSpec(
      asset: 'assets/splash/splash_letter_V.png',
      width: 81.0,
      height: 100.0,
      xOffset: 0.0,
      yOffset: 0.0,
      direction: _FlyDirection.topLeft,
      delay: 0.00,
    ),
    _LetterSpec(
      asset: 'assets/splash/splash_letter_b.png',
      width: 43.6,
      height: 85.0,
      xOffset: 50.5,
      yOffset: 12.7,
      direction: _FlyDirection.bottomLeft,
      delay: 0.08,
    ),
    _LetterSpec(
      asset: 'assets/splash/splash_letter_o.png',
      width: 37.8,
      height: 85.0,
      xOffset: 89.1,
      yOffset: 12.7,
      direction: _FlyDirection.topRight,
      delay: 0.14,
    ),
    _LetterSpec(
      asset: 'assets/splash/splash_letter_x.png',
      width: 66.3,
      height: 85.0,
      xOffset: 115.9,
      yOffset: 12.7,
      direction: _FlyDirection.bottomRight,
      delay: 0.20,
    ),
  ];

  /// 进入（飞入聚合 + swoosh 扫入）。
  late final AnimationController _enter;

  /// 发光（聚合后常亮）。
  late final AnimationController _glow;

  /// 呼吸缩放（无限循环）。
  late final AnimationController _breath;

  /// 上下浮动（无限循环）。
  late final AnimationController _float;

  final List<Timer> _timers = <Timer>[];

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(vsync: this, duration: VboxSplashView.enterDuration)
      ..forward();
    _glow = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _float = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    // 第 2 阶段：聚合完成后发光（0.7s）。
    _timers.add(Timer(const Duration(milliseconds: 700), () {
      if (mounted) _glow.forward();
    }));
    // 第 3 阶段：进入呼吸 + 浮动无限循环（1.0s）。
    _timers.add(Timer(const Duration(milliseconds: 1000), () {
      if (!mounted) return;
      _breath.repeat(reverse: true);
      _float.repeat(reverse: true);
    }));
  }

  @override
  void dispose() {
    for (final Timer t in _timers) {
      t.cancel();
    }
    _enter.dispose();
    _glow.dispose();
    _breath.dispose();
    _float.dispose();
    super.dispose();
  }

  /// 单个字母的入场进度曲线（按错峰延时切 Interval）。
  Animation<double> _letterProgress(double delay) {
    final double begin = (delay / 0.9).clamp(0.0, 0.99);
    return CurvedAnimation(
      parent: _enter,
      curve: Interval(begin, 1, curve: Curves.easeOutBack),
    );
  }

  /// 单个字母的透明度曲线（更早到达 1）。
  Animation<double> _letterOpacity(double delay) {
    final double begin = (delay / 0.9).clamp(0.0, 0.9);
    final double end = (begin + 0.4).clamp(0.1, 1.0);
    return CurvedAnimation(parent: _enter, curve: Interval(begin, end));
  }

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    final Color subtitleColor = brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.25)
        : Colors.black.withValues(alpha: 0.18);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: vboxSplashGradient(brightness),
        ),
      ),
      child: Stack(
        children: <Widget>[
          Center(child: _logo()),
          Positioned(
            left: 0,
            right: 0,
            bottom: 80,
            child: _subtitle(subtitleColor),
          ),
        ],
      ),
    );
  }

  /// 字标：swoosh 托底 + 四字母飞入聚合 + 发光 + 呼吸浮动。
  Widget _logo() {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[_breath, _float]),
      builder: (BuildContext context, Widget? child) {
        final double scale = 1 + 0.05 * _breath.value;
        final double dy = -6 + 12 * _float.value;
        return Transform.translate(
          offset: Offset(0, dy),
          child: Transform.scale(scale: scale, child: child),
        );
      },
      child: Transform.rotate(
        angle: _logoTilt * math.pi / 180,
        child: SizedBox(
          width: _compWidth,
          height: _logoHeight,
          child: Stack(
            alignment: Alignment.topLeft,
            clipBehavior: Clip.none,
            children: <Widget>[
              _swoosh(),
              for (final _LetterSpec spec in _letters) _letter(spec),
            ],
          ),
        ),
      ),
    );
  }

  /// swoosh 托底（从左向右扫入，顺时针 4°）。
  Widget _swoosh() {
    final Animation<double> progress = CurvedAnimation(
      parent: _enter,
      curve: const Interval(0.33, 1, curve: Curves.easeOut),
    );
    final Animation<double> opacity = CurvedAnimation(
      parent: _enter,
      curve: const Interval(0.33, 0.7),
    );
    return Transform.translate(
      offset: _swooshOffset,
      child: AnimatedBuilder(
        animation: progress,
        builder: (BuildContext context, Widget? child) {
          return Opacity(
            opacity: opacity.value,
            child: Transform.translate(
              offset: Offset(-160 * (1 - progress.value), 0),
              child: Transform.rotate(
                angle: _swooshTilt * math.pi / 180,
                child: child,
              ),
            ),
          );
        },
        child: Image.asset(
          'assets/splash/splash_swoosh.png',
          width: _swooshWidth,
          height: _swooshHeight,
          fit: BoxFit.fill,
        ),
      ),
    );
  }

  /// 单字母：位移 + 旋转 + 透明度入场，聚合后常亮发光。
  Widget _letter(_LetterSpec spec) {
    final Animation<double> progress = _letterProgress(spec.delay);
    final Animation<double> opacity = _letterOpacity(spec.delay);
    return AnimatedBuilder(
      animation: progress,
      builder: (BuildContext context, Widget? child) {
        final double p = progress.value;
        final Offset offset =
            spec.direction.offset * (1 - p) + Offset(spec.xOffset, spec.yOffset);
        final double rotation = spec.direction.rotation * (1 - p) * math.pi / 180;
        return Opacity(
          opacity: opacity.value.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: offset,
            child: Transform.rotate(angle: rotation, child: child),
          ),
        );
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          // 发光层（聚合后常亮；对齐 iOS blur(14) + opacity 0.5）。
          FadeTransition(
            opacity: _glow.drive(Tween<double>(begin: 0.0, end: 0.5)),
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: _letterImage(spec),
            ),
          ),
          _letterImage(spec),
        ],
      ),
    );
  }

  /// 字母位图（显式宽高 = iOS `frame(width:)` + `scaledToFit()` 的结果）。
  Widget _letterImage(_LetterSpec spec) => Image.asset(
        spec.asset,
        width: spec.width,
        height: spec.height,
        fit: BoxFit.fill,
      );

  /// 底部小字 + 版本号。
  Widget _subtitle(Color color) {
    return FadeTransition(
      opacity: _glow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '愿你每一次观影都能释放现有压力',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 2,
              color: color,
            ),
          ),
          Text(
            'vbox聚合观影软件由Ai开发而来',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 2,
              color: color,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            AppInfo.version,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1,
              color: color.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }
}