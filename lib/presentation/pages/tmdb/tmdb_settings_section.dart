/// 表现层：TMDB 设置分区（批次 G · G-06）。
///
/// 唯一真相源：iOS `vbox/Views/SettingsViews.swift` `tmdbSettingsSection`
/// （L222-L301）：
///   · 标题「TMDB 设置」；
///   · 首行：图标 `photo.on.rectangle.angled`（`#3B82F6`）+「加载 TMDB 封面与演职人员」
///     + 开关 `settings.enableTMDB`；
///   · 启用后展开：「代理地址」标签 + 输入框（占位「请输入代理域名」）→
///     图标 `key.fill`（`#F59E0B`）+「代理需要 Token」+ 开关（`tmdbUseToken`）→
///     勾选后再显「代理 Token」标签 + 输入框（占位「请输入密钥」）。
///
/// 落地口径：输入框沿用本仓 TG 分区（G-04）的令牌化样式（`VboxTypography.s15` /
/// `VboxRadii.button` / `VboxSpacing`），保证同一设置页内观感一致；图标以
/// `Icons.photo_library_outlined` 近似 iOS `photo.on.rectangle.angled`（Material
/// 无逐字对应），色值走令牌 `VboxColors.tmdbAccent` / `tmdbKeyAmber`。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/datasources/local/tmdb_config_store.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/vbox/vbox.dart';

/// TMDB 设置分区（消费 [TmdbConfigStore]，配置热改即时落盘）。
class TmdbSettingsSection extends StatefulWidget {
  /// 构造。
  const TmdbSettingsSection({super.key});

  @override
  State<TmdbSettingsSection> createState() => _TmdbSettingsSectionState();
}

class _TmdbSettingsSectionState extends State<TmdbSettingsSection> {
  final TextEditingController _proxy = TextEditingController();
  final TextEditingController _token = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 启动时 store 已 load（app 装配 await），此处取初值填充输入框。
    final TmdbConfigStore store = context.read<TmdbConfigStore>();
    _proxy.text = store.proxyUrl;
    _token.text = store.proxyToken;
  }

  @override
  void dispose() {
    _proxy.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TmdbConfigStore store = context.watch<TmdbConfigStore>();
    return VboxSettingsSection(
      title: 'TMDB 设置',
      children: <Widget>[
        VboxSettingsRow.toggle(
          title: '加载 TMDB 封面与演职人员',
          icon: Icons.photo_library_outlined,
          iconColor: VboxColors.tmdbAccent,
          value: store.enabled,
          onChanged: store.setEnabled,
        ),
        if (store.enabled) ...<Widget>[
          _inputField(
            label: '代理地址',
            controller: _proxy,
            hint: '请输入代理域名',
            keyboardType: TextInputType.url,
            onChanged: store.setProxyUrl,
          ),
          VboxSettingsRow.toggle(
            title: '代理需要 Token',
            icon: Icons.key,
            iconColor: VboxColors.tmdbKeyAmber,
            value: store.useToken,
            onChanged: store.setUseToken,
          ),
          if (store.useToken)
            _inputField(
              label: '代理 Token',
              controller: _token,
              hint: '请输入密钥',
              onChanged: store.setProxyToken,
            ),
        ],
      ],
    );
  }

  /// 标签 + 输入框行（令牌化样式，对齐 TG 分区的输入框口径）。
  Widget _inputField({
    required String label,
    required TextEditingController controller,
    required String hint,
    required ValueChanged<String> onChanged,
    TextInputType? keyboardType,
  }) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color rowBackground = (isDark
            ? VboxColors.secondarySystemGroupedBackgroundDark
            : VboxColors.secondarySystemGroupedBackgroundLight)
        .withValues(alpha: 0.7);
    final Color inputFill = isDark
        ? VboxColors.tertiarySystemGroupedBackgroundDark
        : VboxColors.tertiarySystemGroupedBackgroundLight;
    final Color secondary =
        isDark ? VboxColors.secondaryLabelDark : VboxColors.secondaryLabelLight;
    final Color onSurface = Theme.of(context).colorScheme.onSurface;

    return Material(
      color: rowBackground,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.lg,
          vertical: VboxSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              style: TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w500,
                color: onSurface,
              ),
            ),
            const SizedBox(height: VboxSpacing.sm),
            TextField(
              controller: controller,
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
              keyboardType: keyboardType,
              onChanged: onChanged,
              style: TextStyle(
                fontSize: VboxTypography.s15,
                color: onSurface,
              ),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: inputFill,
                hintText: hint,
                hintStyle: TextStyle(
                  fontSize: VboxTypography.s15,
                  color: secondary,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: VboxSpacing.md,
                  vertical: VboxSpacing.md,
                ),
                border: const OutlineInputBorder(
                  borderRadius: VboxRadii.button,
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}