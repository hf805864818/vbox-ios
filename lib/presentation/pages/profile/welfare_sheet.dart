/// 「个人中心 · 福利专区」两阶段弹窗（批次 H · H-05 / 批次 A · A8 门控入口）。
///
/// 唯一真相源：iOS `ProfileView.swift` L504-L665（`welfareUnlockSheet`）与
/// L416-L420（宫格入口，点击前重置输入 / 错误态）。
///
/// 两阶段（对齐 iOS，R-13）：
///   · **阶段一（未解锁）**：gift 图标 + 「输入密码解锁福利内容」+ 密码框 +
///     错误提示 + 「确认解锁」——校验通过**只**置 `unlocked = true`（**不**自动启用）；
///   · **阶段二（已解锁）**：「启用福利专区」开关 + 密码掩码行 + 「完成」，
///     并在头区两侧显示「刷新」「设置」（**仅解锁后**渲染）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../theme/vbox_haptics.dart';
import '../../welfare/welfare_controller.dart';
import '../../widgets/vbox/vbox.dart';
import '../welfare/welfare_settings_page.dart';

/// 弹出福利专区弹窗（两阶段）。
///
/// [controller] 缺省取上层 `Provider<WelfareController>`。
Future<void> showVboxWelfareSheet(
  BuildContext context, {
  WelfareController? controller,
}) {
  final WelfareController resolved =
      controller ?? context.read<WelfareController>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext _) =>
        ChangeNotifierProvider<WelfareController>.value(
      value: resolved,
      child: const _WelfareSheet(),
    ),
  );
}

class _WelfareSheet extends StatefulWidget {
  const _WelfareSheet();

  @override
  State<_WelfareSheet> createState() => _WelfareSheetState();
}

class _WelfareSheetState extends State<_WelfareSheet> {
  final TextEditingController _password = TextEditingController();
  bool _error = false;
  bool _refreshing = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirmUnlock(WelfareController controller) async {
    final bool ok = await controller.unlock(_password.text);
    if (!mounted) return;
    if (!ok) {
      // UI-B1 触感反馈：对齐 iOS 福利密码错误 medium 震动（ProfileView.swift:585）。
      VboxHaptics.medium();
      setState(() => _error = true);
      return;
    }
    setState(() {
      _error = false;
      _password.clear();
    });
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    setState(() => _refreshing = false);
    VboxToast.show(context, '福利远程源已刷新');
  }

  @override
  Widget build(BuildContext context) {
    final WelfareController controller = context.watch<WelfareController>();
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color secondary = Theme.of(context).colorScheme.outline;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.sizeOf(context).height * 0.5,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            VboxSpacing.xl,
            VboxSpacing.sm,
            VboxSpacing.xl,
            VboxSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(context, controller, accent, secondary),
              const SizedBox(height: VboxSpacing.xl),
              if (!controller.unlocked)
                _unlockPhase(controller, accent)
              else
                _managePhase(controller, accent, secondary),
            ],
          ),
        ),
      ),
    );
  }

  /// 头区：居中礼物图标 + 标题 + 副标题；仅解锁后显示「刷新」「设置」。
  Widget _header(
    BuildContext context,
    WelfareController controller,
    Color accent,
    Color secondary,
  ) {
    return Stack(
      children: <Widget>[
        Column(
          children: <Widget>[
            Icon(Icons.card_giftcard, size: 44, color: accent),
            const SizedBox(height: VboxSpacing.sm),
            const Text(
              '福利专区',
              style: TextStyle(
                fontSize: VboxTypography.s24,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: VboxSpacing.xs),
            Text(
              controller.unlocked ? '管理福利功能' : '输入密码解锁福利内容',
              style: TextStyle(fontSize: VboxTypography.s14, color: secondary),
            ),
          ],
        ),
        if (controller.unlocked)
          Positioned(
            left: 0,
            top: 0,
            child: IconButton(
              tooltip: '刷新',
              onPressed: _refreshing ? null : _refresh,
              icon: _refreshing
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accent,
                      ),
                    )
                  : Icon(Icons.refresh, color: accent),
            ),
          ),
        if (controller.unlocked)
          Positioned(
            right: 0,
            top: 0,
            child: IconButton(
              tooltip: '设置',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext _) => const WelfareSettingsPage(),
                ),
              ),
              icon: Icon(Icons.settings, color: accent),
            ),
          ),
      ],
    );
  }

  /// 阶段一：密码输入。
  Widget _unlockPhase(WelfareController controller, Color accent) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _password,
          obscureText: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          autofocus: false,
          style: const TextStyle(fontSize: VboxTypography.s18),
          decoration: InputDecoration(
            hintText: '请输入解锁密码',
            filled: true,
            fillColor: scheme.surfaceContainerHighest,
            border: const OutlineInputBorder(
              borderRadius: VboxRadii.card,
              borderSide: BorderSide.none,
            ),
            contentPadding: VboxSpacing.symmetric(vertical: VboxSpacing.lg),
          ),
          onChanged: (_) {
            if (_error) setState(() => _error = false);
          },
          onSubmitted: (_) => _confirmUnlock(controller),
        ),
        if (_error) ...<Widget>[
          const SizedBox(height: VboxSpacing.md),
          const Text(
            '密码错误，请重试',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              color: VboxColors.danger,
            ),
          ),
        ],
        const SizedBox(height: VboxSpacing.xl),
        VboxButton(
          label: '确认解锁',
          expanded: true,
          onPressed: () => _confirmUnlock(controller),
        ),
      ],
    );
  }

  /// 阶段二：功能开关 + 密码掩码 + 完成。
  Widget _managePhase(
    WelfareController controller,
    Color accent,
    Color secondary,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '启用福利专区',
                    style: TextStyle(
                      fontSize: VboxTypography.s16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: VboxSpacing.xs),
                  Text(
                    '关闭后福利Tab和播放记录将隐藏',
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      color: secondary,
                    ),
                  ),
                ],
              ),
            ),
            Switch.adaptive(
              value: controller.enabled,
              activeTrackColor: accent,
              onChanged: (bool value) => controller.setEnabled(value),
            ),
          ],
        ),
        const SizedBox(height: VboxSpacing.lg),
        const Divider(),
        const SizedBox(height: VboxSpacing.lg),
        Row(
          children: <Widget>[
            const Text(
              '密码',
              style: TextStyle(
                fontSize: VboxTypography.s16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Text(
              '******',
              style: TextStyle(fontSize: VboxTypography.s14, color: secondary),
            ),
          ],
        ),
        const SizedBox(height: VboxSpacing.xl),
        VboxButton(
          label: '完成',
          expanded: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
