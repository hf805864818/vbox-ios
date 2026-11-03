/// 输入适配 · 键盘快捷键（批次 A · A-09）。
///
/// 唯一真相源：`docs/第2轮开发计划_功能补全_v2.6.md` §3.4（鼠标键盘：快捷键
/// —— 空格播放 / 方向键 seek / Esc 返回）。
///
/// 键位映射（播放器场景）：
///   空格 → 播放/暂停 · ← → 快退/快进 · ↑ ↓ 音量（由页面注入）
///   回车 → 确认 · Esc → 返回
///
/// 门控：仅 `InputModality.mouseKeyboard` 下绑定；触摸 / 遥控不拦截按键
/// （方向键等保留给滚动与 D-pad 导航）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../ui_mode/ui_mode.dart';

/// 键盘快捷键层（包裹内容区，按模态启用）。
class InputShortcuts extends StatelessWidget {
  /// 构造。
  const InputShortcuts({
    super.key,
    required this.child,
    this.onPlayPause,
    this.onSeekBack,
    this.onSeekForward,
    this.onBack,
    this.onConfirm,
  });

  /// 子项。
  final Widget child;

  /// 空格 → 播放/暂停。
  final VoidCallback? onPlayPause;

  /// 方向键左 → 快退。
  final VoidCallback? onSeekBack;

  /// 方向键右 → 快进。
  final VoidCallback? onSeekForward;

  /// Esc → 返回。
  final VoidCallback? onBack;

  /// 回车 → 确认。
  final VoidCallback? onConfirm;

  /// 组装键位绑定（只绑定已注入的回调）。
  Map<ShortcutActivator, VoidCallback> _bindings() => <ShortcutActivator, VoidCallback>{
        if (onPlayPause != null)
          const SingleActivator(LogicalKeyboardKey.space): onPlayPause!,
        if (onSeekBack != null)
          const SingleActivator(LogicalKeyboardKey.arrowLeft): onSeekBack!,
        if (onSeekForward != null)
          const SingleActivator(LogicalKeyboardKey.arrowRight): onSeekForward!,
        if (onBack != null)
          const SingleActivator(LogicalKeyboardKey.escape): onBack!,
        if (onConfirm != null)
          const SingleActivator(LogicalKeyboardKey.enter): onConfirm!,
      };

  @override
  Widget build(BuildContext context) {
    final bool mouse = context.select<UiFormController, bool>(
      (UiFormController c) => c.modality == InputModality.mouseKeyboard,
    );
    if (!mouse) return child;
    return CallbackShortcuts(bindings: _bindings(), child: child);
  }
}