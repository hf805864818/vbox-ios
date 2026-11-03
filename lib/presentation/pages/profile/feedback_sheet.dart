/// 「个人中心 · Bug 反馈」弹窗（批次 G · G-09）。
///
/// 唯一真相源：iOS `vbox/Views/ProfileView.swift` L669-L780（`feedbackSheet`）
/// 与 iOS 截图 `docs/ui_baseline/ios_ref/Bug 反馈界面.PNG`。
///
/// 版式：标题「Bug 反馈」+ 关闭按钮 → 问题标题（placeholder「简要描述问题」）→
/// 详细描述（多行，placeholder「请详细描述问题发生的场景、操作步骤等...」）→
/// 错误提示（红字）→ 提交按钮（标题为空 / 提交中禁用；loading 显示「提交中...」）；
/// 提交成功态：绿对勾 +「提交成功」+「感谢你的反馈！」+「关闭」。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/http_client.dart';
import '../../../data/datasources/remote/feedback_service.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/vbox/vbox.dart';

/// 弹出 Bug 反馈弹窗（对齐 iOS `feedbackSheet` 的 `.medium` 高度语义）。
///
/// [service] 缺省创建（真实 GitHub 提交）；测试可注入带假 transport 的服务。
/// 每次弹出前重置成功 / 错误态（对齐 iOS 入口前 `feedbackService.reset()`）。
Future<void> showVboxFeedbackSheet(
  BuildContext context, {
  FeedbackService? service,
}) {
  final FeedbackService resolved =
      service ?? FeedbackService(transport: GithubFeedbackTransport(client: HttpClient()));
  resolved.reset();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext _) => ChangeNotifierProvider<FeedbackService>.value(
      value: resolved,
      child: const FeedbackSheet(),
    ),
  );
}

/// Bug 反馈弹窗内容。
class FeedbackSheet extends StatefulWidget {
  /// 构造。
  const FeedbackSheet({super.key});

  @override
  State<FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<FeedbackSheet> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _body = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final FeedbackService service = context.read<FeedbackService>();
    await service.submit(title: _title.text, body: _body.text);
  }

  @override
  Widget build(BuildContext context) {
    final FeedbackService service = context.watch<FeedbackService>();
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          VboxSpacing.xxl,
          VboxSpacing.sm,
          VboxSpacing.xxl,
          VboxSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(scheme),
            const SizedBox(height: VboxSpacing.xl),
            if (service.submitSuccess)
              _success(scheme)
            else
              _form(service, scheme),
          ],
        ),
      ),
    );
  }

  /// 标题行：左「Bug 反馈」+ 右关闭按钮。
  Widget _header(ColorScheme scheme) {
    return Row(
      children: <Widget>[
        Text(
          'Bug 反馈',
          style: TextStyle(
            fontSize: VboxTypography.s18,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
          icon: Icon(Icons.cancel, size: VboxTypography.s24, color: scheme.outline),
        ),
      ],
    );
  }

  /// 提交成功态（绿对勾 + 文案 + 关闭）。
  Widget _success(ColorScheme scheme) {
    return Column(
      children: <Widget>[
        const Icon(
          Icons.check_circle,
          size: 48,
          color: VboxColors.success,
        ),
        const SizedBox(height: VboxSpacing.lg),
        Text(
          '提交成功',
          style: TextStyle(
            fontSize: VboxTypography.s18,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: VboxSpacing.sm),
        Text(
          '感谢你的反馈！',
          style: TextStyle(fontSize: VboxTypography.s14, color: scheme.outline),
        ),
        const SizedBox(height: VboxSpacing.xl),
        VboxButton(
          label: '关闭',
          expanded: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  /// 表单：问题标题 + 详细描述 + 错误提示 + 提交按钮。
  Widget _form(FeedbackService service, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text(
          '问题标题',
          style: TextStyle(
            fontSize: VboxTypography.s14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: VboxSpacing.compact),
        _field(
          controller: _title,
          hint: '简要描述问题',
          radius: VboxRadii.button,
          scheme: scheme,
        ),
        const SizedBox(height: VboxSpacing.xl),
        const Text(
          '详细描述',
          style: TextStyle(
            fontSize: VboxTypography.s14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: VboxSpacing.compact),
        TextField(
          controller: _body,
          minLines: 5,
          maxLines: 8,
          style: TextStyle(fontSize: VboxTypography.s15, color: scheme.onSurface),
          decoration: _decoration(
            hint: '请详细描述问题发生的场景、操作步骤等...',
            radius: VboxRadii.card,
            scheme: scheme,
          ),
        ),
        if (service.submitError != null) ...<Widget>[
          const SizedBox(height: VboxSpacing.md),
          Text(
            service.submitError!,
            style: const TextStyle(
              fontSize: VboxTypography.s13,
              color: VboxColors.danger,
            ),
          ),
        ],
        const SizedBox(height: VboxSpacing.xl),
        _submitButton(service, scheme),
      ],
    );
  }

  /// 单行输入框（对齐 iOS 标题输入：浅灰底 + 圆角 8 + 内边距 12）。
  Widget _field({
    required TextEditingController controller,
    required String hint,
    required BorderRadius radius,
    required ColorScheme scheme,
  }) {
    return TextField(
      controller: controller,
      style: TextStyle(fontSize: VboxTypography.s15, color: scheme.onSurface),
      decoration: _decoration(hint: hint, radius: radius, scheme: scheme),
      onSubmitted: (_) => _submit(),
    );
  }

  /// 输入框装饰（浅灰底 + 无描边 + 内边距 12）。
  InputDecoration _decoration({
    required String hint,
    required BorderRadius radius,
    required ColorScheme scheme,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: VboxTypography.s15, color: scheme.outline),
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.md,
        vertical: VboxSpacing.md,
      ),
    );
  }

  /// 提交按钮（标题为空 / 提交中禁用；loading 显示转圈 +「提交中...」）。
  Widget _submitButton(FeedbackService service, ColorScheme scheme) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _title,
      builder: (BuildContext context, TextEditingValue value, Widget? child) {
        final bool disabled =
            value.text.trim().isEmpty || service.isSubmitting;
        final Color background = disabled
            ? scheme.primary.withValues(alpha: 0.4)
            : scheme.primary;
        return Material(
          color: background,
          borderRadius: VboxRadii.card,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: disabled ? null : _submit,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: VboxSpacing.md),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (service.isSubmitting) ...<Widget>[
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: VboxSpacing.sm),
                  ],
                  Text(
                    service.isSubmitting ? '提交中...' : '提交反馈',
                    style: const TextStyle(
                      fontSize: VboxTypography.s16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
