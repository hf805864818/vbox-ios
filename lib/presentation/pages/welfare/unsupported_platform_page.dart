/// 未支持平台页（批次 H · H-02）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/UnsupportedPlatformView.swift`
///   · 头部：橙 15% 圆底 64 + `exclamationmark.triangle.fill` 28 + 标题
///     「该平台暂不可用」18 semibold + 副标题「客户端尚未实现该平台类型的路由」14 secondary；
///   · 信息卡（`.secondarySystemBackground` + 圆角 12）：平台名称 / platformKey /
///     serviceType / 分类 / 备注（行 v12 h16，label 13 secondary + value 13 monospaced）；
///   · 排查建议卡：标题 14 semibold + 3 条 13 secondary。
///
/// 与 iOS 的差异（如实登记）：额外展示路由给出的 `reason`（用于区分
/// 「未知 serviceType」与「fuli_base 未注册服务」），iOS 仅显示固定副标题。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/welfare/welfare.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// 未支持平台页（`unknown` / `fuli_base` 未注册服务）。
class UnsupportedPlatformPage extends StatelessWidget {
  /// 构造。
  const UnsupportedPlatformPage({
    super.key,
    required this.platform,
    this.reason,
  });

  /// 触发路由的平台元数据。
  final WelfarePlatform platform;

  /// 未支持原因（可选，来自路由结果 `WelfareUnsupportedRoute.reason`）。
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;
    final Color cardColor = isDark
        ? VboxColors.secondarySystemBackgroundDark
        : VboxColors.secondarySystemBackgroundLight;
    final Color secondary = isDark
        ? VboxColors.secondaryLabelDark
        : VboxColors.secondaryLabelLight;

    return Scaffold(
      appBar: AppBar(
        title: Text(platform.name),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SizedBox(height: VboxSpacing.xxxl),
            // 头部：橙色警告图标 + 标题 + 副标题。
            Column(
              children: <Widget>[
                Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: VboxColors.warning.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.warning_amber_rounded,
                    size: 28,
                    color: VboxColors.warning,
                  ),
                ),
                const SizedBox(height: VboxSpacing.md),
                const Text(
                  '该平台暂不可用',
                  style: TextStyle(
                    fontSize: VboxTypography.s18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: VboxSpacing.md),
                Text(
                  '客户端尚未实现该平台类型的路由',
                  style: TextStyle(
                    fontSize: VboxTypography.s14,
                    color: secondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: VboxSpacing.xl),
            // 平台信息卡。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.xl),
              child: Container(
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: VboxRadii.card,
                ),
                child: Column(
                  children: <Widget>[
                    _infoRow('平台名称', platform.name, secondary),
                    _divider(),
                    _infoRow('platformKey', platform.platformKey, secondary),
                    _divider(),
                    _infoRow('serviceType', platform.serviceType, secondary),
                    _divider(),
                    _infoRow('分类', platform.category.displayName, secondary),
                    if ((platform.notes ?? '').isNotEmpty) ...<Widget>[
                      _divider(),
                      _infoRow('备注', platform.notes!, secondary),
                    ],
                    if ((reason ?? '').isNotEmpty) ...<Widget>[
                      _divider(),
                      _infoRow('原因', reason!, secondary),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: VboxSpacing.xl),
            // 排查建议卡。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.xl),
              child: Container(
                padding: const EdgeInsets.all(VboxSpacing.lg),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: VboxRadii.card,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      '排查建议',
                      style: TextStyle(
                        fontSize: VboxTypography.s14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: VboxSpacing.sm),
                    _tip('检查 JSON 中 serviceType 是否拼写正确', secondary),
                    _tip('检查客户端 WelfareServiceType 枚举是否有对应 case', secondary),
                    _tip('如果是新平台类型，需在 WelfarePlatformRouter 中新增路由', secondary),
                  ],
                ),
              ),
            ),
            const SizedBox(height: VboxSpacing.xxxl),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, Color secondary) => Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.lg,
          vertical: VboxSpacing.md,
        ),
        child: Row(
          children: <Widget>[
            Text(
              label,
              style: TextStyle(fontSize: VboxTypography.s13, color: secondary),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: VboxTypography.s13,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      );

  Widget _divider() => const Padding(
        padding: EdgeInsets.only(left: VboxSpacing.lg),
        child: Divider(height: 1),
      );

  Widget _tip(String text, Color secondary) => Padding(
        padding: const EdgeInsets.only(top: VboxSpacing.sm),
        child: Text(
          '• $text',
          style: TextStyle(fontSize: VboxTypography.s13, color: secondary),
        ),
      );
}