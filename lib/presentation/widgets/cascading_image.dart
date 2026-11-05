/// 表现层：多候选图片（批次 B · 图片直连 + 代理兜底）。
///
/// 用法：把同一张图的候选地址按优先级排好交给本组件，
/// 例如 `[直连, 代理, 豆瓣兜底, 站点图]`；加载失败自动切下一张，
/// 全部失败才显示占位。候选中的 `null` / 空串会被跳过。
///
/// 与 [PlatformAsyncImage] 的关系：本组件只做「换 URL 重试」，
/// 具体加载、请求头、缓存、占位样式仍由 [PlatformAsyncImage] 负责。
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'platform_async_image.dart';

/// 级联图片：按顺序尝试多个 URL，全部失败后显示占位。
class CascadingImage extends StatefulWidget {
  /// 构造。
  const CascadingImage({
    super.key,
    required this.urls,
    this.fit = BoxFit.cover,
    this.placeholderColor,
    this.placeholder,
    this.timeout = const Duration(seconds: 5),
    this.errorBuilder,
  });

  /// 候选地址（按优先级，`null` / 空串自动跳过）。
  final List<String?> urls;

  /// 填充方式。
  final BoxFit fit;

  /// 占位底色（缺省取主题表面色）。
  final Color? placeholderColor;

  /// 自定义占位组件。
  final Widget? placeholder;

  /// 单次请求超时（直连被阻断时尽快判失败，缺省 5 秒）。
  final Duration timeout;

  /// 全部候选失败后的自定义失败态（缺省为占位盒）。
  final Widget Function(BuildContext context, Object error, StackTrace? stackTrace)?
      errorBuilder;

  @override
  State<CascadingImage> createState() => _CascadingImageState();
}

class _CascadingImageState extends State<CascadingImage> {
  int _index = 0;
  bool _advanceScheduled = false;
  Object? _lastError;
  StackTrace? _lastStack;

  /// 候选集版本号：切图时自增，用于作废上一组候选排队中的「切下一张」回调
  /// （否则新图会从第 2 张开始试，跳过首候选）。
  int _generation = 0;

  List<String> get _candidates => <String>[
        for (final String? u in widget.urls)
          if (u != null && u.trim().isNotEmpty) u.trim(),
      ];

  @override
  void didUpdateWidget(covariant CascadingImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 候选集变化（例如从「直连+代理」变成别的图）→ 从头重试。
    if (!listEquals(oldWidget.urls, widget.urls)) {
      _generation++;
      _index = 0;
      _advanceScheduled = false;
      _lastError = null;
      _lastStack = null;
    }
  }

  /// errorBuilder 处于 build 阶段：延到帧后切下一候选，避免 build 期 setState。
  void _advance(Object error, StackTrace? stackTrace) {
    _lastError = error;
    _lastStack = stackTrace;
    if (_advanceScheduled) return;
    if (_index >= _candidates.length - 1) return;
    _advanceScheduled = true;
    final int generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _index++;
        _advanceScheduled = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<String> candidates = _candidates;
    if (candidates.isEmpty) return _placeholder(context);
    final int i = _index.clamp(0, candidates.length - 1);
    return PlatformAsyncImage(
      key: ValueKey<String>(candidates[i]),
      url: candidates[i],
      fit: widget.fit,
      placeholderColor: widget.placeholderColor,
      placeholder: widget.placeholder,
      timeout: widget.timeout,
      errorBuilder: (BuildContext ctx, Object error, StackTrace? stackTrace) {
        _advance(error, stackTrace);
        return _placeholder(ctx);
      },
    );
  }

  Widget _placeholder(BuildContext context) {
    final Widget? custom = widget.placeholder;
    if (custom != null) return custom;
    // 只有「最后一个候选也失败」才算彻底失败；中间候选失败仍显示普通占位，
    // 否则 logo 这类带 errorBuilder 的位置会先闪一下兜底 UI 再切下一张。
    final bool exhausted =
        _candidates.isNotEmpty && _index >= _candidates.length - 1;
    final Object? error = _lastError;
    final Widget Function(BuildContext, Object, StackTrace?)? builder =
        widget.errorBuilder;
    if (exhausted && error != null && builder != null) {
      return builder(context, error, _lastStack);
    }
    final Color color = widget.placeholderColor ??
        Theme.of(context).colorScheme.surfaceContainerHighest;
    return PlatformAsyncImage.placeholderBox(color: color);
  }
}
