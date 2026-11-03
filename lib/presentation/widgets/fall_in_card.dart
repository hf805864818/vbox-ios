/// 掉落回弹入场容器（对齐 iOS `SubjectCard.hasAppeared` 动效）。
///
/// 首次构建后延迟 [delay] 秒触发：自上方 0.2 高度「掉落」+ easeOutBack 回弹 +
/// 淡入。用于豆瓣首页横向行（逐卡错峰）与分类网格（同行错峰）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

/// 掉落回弹入场容器。
class FallInCard extends StatefulWidget {
  /// 构造。
  const FallInCard({super.key, required this.delay, required this.child});

  /// 入场延迟（秒）。
  final double delay;

  final Widget child;

  @override
  State<FallInCard> createState() => _FallInCardState();
}

class _FallInCardState extends State<FallInCard> {
  bool _appeared = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(
      Duration(milliseconds: (widget.delay * 1000).round()),
      () {
        if (mounted) setState(() => _appeared = true);
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: _appeared ? Offset.zero : const Offset(0, -0.2),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutBack,
      child: AnimatedOpacity(
        opacity: _appeared ? 1 : 0,
        duration: const Duration(milliseconds: 300),
        child: widget.child,
      ),
    );
  }
}
