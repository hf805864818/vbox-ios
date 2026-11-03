/// 统一组件库 · 登录弹窗（批次 B · B5）。
///
/// 唯一真相源：iOS `vbox/Views/ProfileView.swift` L890-L1070 `LoginSheetView`。
///
/// 规格（照 iOS 实测 / 图11）：
///   · 顶部 App 图标 72×72 圆角 20（兜底为蓝色渐变 + 白色闪电）；
///   · 标题「欢迎回来」24 bold + 副标题「登录你的账号继续使用」14 secondary；
///   · 卡片：白色 r20 + 黑色 8% 阴影 20/4，内边距 24，元素间距 16；
///   · 输入框：浅灰底 r12 + 左侧蓝图标（宽 22）+ h14/v12 内边距；
///   · 主按钮：蓝色横向渐变 50 高 r14 + 蓝色 35% 阴影，未填账号 / 加载中 → 透明 60%；
///   · 上级用户胶囊：浅灰 60% 底 r20 + 人像圈图标 + 12 secondary；
///   · 底部「取消」纯文字 15 secondary。
///
/// 近似说明：iOS 26pt 标题取最近档位 24；按钮 17pt 取 18（「大号按钮」档）；
/// Flutter 无 SF Symbols，图标以 Material 近似。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 登录弹窗内容（可作为底部抽屉 / 居中弹窗的主体，不含模态壳）。
///
/// 组件只负责表现层与交互回调，账号 / 密码的校验与持久化由调用方（I-02）承担。
class VboxLoginSheet extends StatefulWidget {
  /// 构造。
  const VboxLoginSheet({
    super.key,
    required this.usernameController,
    required this.passwordController,
    this.referralController,
    this.onSubmit,
    this.onCancel,
    this.error,
    this.loading = false,
    this.registered = false,
    this.parentUserLabel = '没有上级用户',
    this.icon,
  });

  /// 账号输入控制器。
  final TextEditingController usernameController;

  /// 密码输入控制器。
  final TextEditingController passwordController;

  /// 上级推荐码输入控制器（M-账1；`null` → 不渲染该输入行）。
  final TextEditingController? referralController;

  /// 点击主按钮回调（`null` 时按钮恒为禁用态）。
  final VoidCallback? onSubmit;

  /// 点击「取消」回调。
  final VoidCallback? onCancel;

  /// 错误提示（非空时显示在主按钮上方）。
  final String? error;

  /// 加载中（主按钮显示进度圈且禁用）。
  final bool loading;

  /// 账号是否已注册（已注册 → 「登录」，否则 → 「登录 / 注册」）。
  final bool registered;

  /// 上级用户文案（「上级用户：<label>」）。
  final String parentUserLabel;

  /// 顶部图标（`null` → 蓝色渐变 + 闪电兜底）。
  final Widget? icon;

  @override
  State<VboxLoginSheet> createState() => _VboxLoginSheetState();
}

class _VboxLoginSheetState extends State<VboxLoginSheet> {
  bool _showPassword = false;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final Color secondary = isDark
        ? VboxColors.secondaryLabelDark
        : VboxColors.secondaryLabelLight;
    final Color inputBg =
        isDark ? VboxColors.systemGray6Dark : VboxColors.systemGray6Light;
    final Color cardBg =
        isDark ? VboxColors.systemBackgroundDark : VboxColors.systemBackgroundLight;
    final Color sheetBg = (isDark
            ? VboxColors.systemGroupedBackgroundDark
            : VboxColors.systemGroupedBackgroundLight)
        .withValues(alpha: 0.5);

    return Container(
      color: sheetBg,
      child: SingleChildScrollView(
        child: Column(
          children: <Widget>[
            const SizedBox(height: VboxSpacing.md),
            _headerIcon(),
            const SizedBox(height: VboxSpacing.xl),
            Text(
              '欢迎回来',
              style: TextStyle(
                fontSize: VboxTypography.s24,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: VboxSpacing.compact),
            Text(
              '登录你的账号继续使用',
              style: TextStyle(fontSize: VboxTypography.s14, color: secondary),
            ),
            const SizedBox(height: 28),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: VboxSpacing.xxl),
              padding: const EdgeInsets.all(VboxSpacing.xxl),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(VboxRadii.r20),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: <Widget>[
                  _inputRow(
                    icon: Icons.person,
                    background: inputBg,
                    field: _field(
                      controller: widget.usernameController,
                      hint: '账号',
                      textColor: scheme.onSurface,
                      hintColor: secondary,
                    ),
                  ),
                  const SizedBox(height: VboxSpacing.lg),
                  _inputRow(
                    icon: Icons.lock,
                    background: inputBg,
                    field: _field(
                      controller: widget.passwordController,
                      hint: '密码',
                      textColor: scheme.onSurface,
                      hintColor: secondary,
                      obscure: !_showPassword,
                    ),
                    trailing: InkWell(
                      onTap: () => setState(() => _showPassword = !_showPassword),
                      child: Icon(
                        _showPassword ? Icons.visibility : Icons.visibility_off,
                        size: VboxTypography.s16,
                        color: secondary,
                      ),
                    ),
                  ),
                  if (widget.referralController != null) ...<Widget>[
                    const SizedBox(height: VboxSpacing.lg),
                    _inputRow(
                      icon: Icons.card_giftcard,
                      background: inputBg,
                      field: _field(
                        controller: widget.referralController!,
                        hint: '上级推荐码（选填）',
                        textColor: scheme.onSurface,
                        hintColor: secondary,
                      ),
                    ),
                  ],
                  if (widget.error != null) ...<Widget>[
                    const SizedBox(height: VboxSpacing.lg),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: VboxSpacing.xs,
                        ),
                        child: Text(
                          widget.error!,
                          style: const TextStyle(
                            fontSize: VboxTypography.s12,
                            color: VboxColors.danger,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: VboxSpacing.lg),
                  _submitButton(),
                  const SizedBox(height: VboxSpacing.lg),
                  _parentPill(inputBg, secondary),
                  const SizedBox(height: VboxSpacing.compact),
                  TextButton(
                    onPressed: widget.onCancel,
                    style: TextButton.styleFrom(
                      foregroundColor: secondary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: VboxSpacing.md,
                        vertical: VboxSpacing.xs,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      '取消',
                      style: TextStyle(fontSize: VboxTypography.s15),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: VboxSpacing.xl),
          ],
        ),
      ),
    );
  }

  /// 顶部图标（有则用，无则蓝色渐变 + 闪电兜底）。
  Widget _headerIcon() {
    if (widget.icon != null) {
      return SizedBox(
        width: 72,
        height: 72,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(VboxRadii.r20),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(VboxRadii.r20),
            child: widget.icon,
          ),
        ),
      );
    }
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: VboxColors.loginGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(VboxRadii.r20),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: VboxColors.loginAccent.withValues(alpha: 0.4),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: const Icon(Icons.bolt, size: 30, color: Colors.white),
    );
  }

  /// 输入行（图标 + 输入框 + 可选尾部控件）。
  Widget _inputRow({
    required IconData icon,
    required Widget field,
    required Color background,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.inputHorizontal,
        vertical: VboxSpacing.md,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(VboxRadii.r12),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 22,
            child: Icon(icon, size: VboxTypography.s16, color: VboxColors.loginAccent),
          ),
          const SizedBox(width: 10),
          Expanded(child: field),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  /// 内嵌输入框（无边框）。
  Widget _field({
    required TextEditingController controller,
    required String hint,
    required Color textColor,
    required Color hintColor,
    bool obscure = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      style: TextStyle(fontSize: VboxTypography.s16, color: textColor),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: hint,
        hintStyle: TextStyle(fontSize: VboxTypography.s16, color: hintColor),
      ),
    );
  }

  /// 主按钮（账号为空或加载中 → 禁用 + 透明 60%）。
  Widget _submitButton() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.usernameController,
      builder: (BuildContext context, TextEditingValue value, Widget? child) {
        final bool disabled =
            value.text.trim().isEmpty || widget.loading || widget.onSubmit == null;
        return Opacity(
          opacity: disabled ? 0.6 : 1.0,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: disabled ? null : widget.onSubmit,
              borderRadius: BorderRadius.circular(VboxRadii.r14),
              child: Container(
                height: 50,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: VboxColors.loginGradient,
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                  borderRadius: BorderRadius.circular(VboxRadii.r14),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: VboxColors.loginAccent.withValues(alpha: 0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: widget.loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        widget.registered ? '登录' : '登录 / 注册',
                        style: const TextStyle(
                          fontSize: VboxTypography.s18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 上级用户胶囊。
  Widget _parentPill(Color inputBg, Color secondary) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.inputHorizontal,
        vertical: VboxSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: inputBg.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(VboxRadii.r20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.account_circle, size: 11, color: secondary),
          const SizedBox(width: VboxSpacing.compact),
          Text(
            '上级用户：${widget.parentUserLabel}',
            style: TextStyle(fontSize: VboxTypography.s12, color: secondary),
          ),
        ],
      ),
    );
  }
}