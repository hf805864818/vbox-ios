/// 切片资源管理页（Wave D · O-源3 / O-源1）。
///
/// 唯一真相源：iOS `vbox/Views/SettingsViews.swift` `FallbackConfigView`
/// （L3128-L3326）：
///   · 远程默认源列表（L3150-L3178）—— 标题「远程默认源」（16 semibold），
///     行 = 源名（14 medium）+「远程」蓝色角标（10 白字 · 蓝 @60% · 圆角 4）；
///   · 自定义兜底源列表（L3212-L3247）—— 标题「自定义兜底源」，行 = 源名 +
///     API（11 secondary · 单行）+ 删除按钮（红 · trash 14）；
///   · 添加卡片（L3250-L3293）—— 标题「添加自定义切片源」（16 semibold）+
///     「源名称」「API地址」输入 +「添加」主色按钮（15 medium · 全宽 · v12 ·
///     圆角 12 · 无效时 @50% 禁用）；
///   · 删除二次确认 alert（L3307-L3316）。
/// 行底 gray@4% · 圆角 8 · 内边距 h12 v10；卡片 gray@6% · 圆角 16 · 内边距 20。
///
/// 落地口径（对齐 iOS 数据语义）：
/// - 「远程默认源」= allSources 的 `apiEndpoint` 站点（只读，对齐 iOS
///   `remoteSourceManager.cachedAPISites()`）；
/// - 「自定义兜底源」= 契约键 `custom_fallback_sites`（对齐 iOS
///   `SpiderManager.customFallbackSites`）。
///
/// 差异登记：iOS 以 sheet 呈现（隐藏 nav bar +「关闭」按钮）；Flutter 用标准
/// `AppBar`（保留返回键），与订阅配置页口径一致。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/datasources/local/source_governance_store.dart';
import '../../../domain/entities/source/source_governance.dart';
import '../../../domain/usecases/source_governance_usecases.dart';
import '../../theme/theme.dart';
import '../../widgets/vbox/vbox_toast.dart';

/// 切片资源管理页。
class FallbackSliceSourcePage extends StatefulWidget {
  /// 构造（[store] / [governance] 可注入；为 null 时消费全局单例，便于单测）。
  const FallbackSliceSourcePage({super.key, this.store, this.governance});

  /// 源治理存储（可注入）。
  final SourceGovernanceStore? store;

  /// 源治理用例（可注入；为 null 时远程列表降级为空）。
  final SourceGovernanceUseCases? governance;

  @override
  State<FallbackSliceSourcePage> createState() => _FallbackSliceSourcePageState();
}

class _FallbackSliceSourcePageState extends State<FallbackSliceSourcePage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _api = TextEditingController();

  List<FallbackSearchSource> _remote = const <FallbackSearchSource>[];

  /// 源治理用例：优先取注入项，缺省从 Provider 读取（设置页以路由跳转时不带参）。
  SourceGovernanceUseCases? _governance;

  SourceGovernanceStore get _store =>
      widget.store ?? SourceGovernanceStore.instance;

  @override
  void initState() {
    super.initState();
    _governance = widget.governance ?? _readGovernance();
    unawaited(_store.load());
    unawaited(_loadRemote());
  }

  /// 读取可选源治理用例（未注入 Provider 时返回 null，便于 widget 测试）。
  SourceGovernanceUseCases? _readGovernance() {
    try {
      return context.read<SourceGovernanceUseCases>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _api.dispose();
    super.dispose();
  }

  Future<void> _loadRemote() async {
    final SourceGovernanceUseCases? uc = _governance;
    if (uc == null) return;
    final List<FallbackSearchSource> list = await uc.remoteApiSites();
    if (!mounted) return;
    setState(() => _remote = list);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (BuildContext context, Widget? _) => Scaffold(
        appBar: AppBar(title: const Text('切片资源管理')),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: VboxSpacing.xl),
          children: <Widget>[
            if (_remote.isNotEmpty) _buildRemoteSection(context),
            if (_store.customFallbackSites.isNotEmpty)
              _buildCustomSection(context),
            _buildAddCard(context),
          ],
        ),
      ),
    );
  }

  /// 远程默认源（只读；对齐 iOS L3150-L3178）。
  Widget _buildRemoteSection(BuildContext context) {
    return _section(
      context,
      title: '远程默认源',
      children: <Widget>[
        for (final FallbackSearchSource s in _remote)
          _sourceRow(
            context,
            name: s.name,
            subtitle: s.api,
            badge: const _SourceBadge(label: '远程', color: Colors.blue),
          ),
      ],
    );
  }

  /// 自定义兜底源（可删；对齐 iOS L3212-L3247）。
  Widget _buildCustomSection(BuildContext context) {
    return _section(
      context,
      title: '自定义兜底源',
      children: <Widget>[
        for (final FallbackSite s in _store.customFallbackSites)
          _sourceRow(
            context,
            name: s.name,
            subtitle: s.api,
            trailing: _deleteButton(() => unawaited(_confirmDelete(s))),
          ),
      ],
    );
  }

  /// 添加卡片（对齐 iOS L3250-L3293）。
  Widget _buildAddCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
      padding: const EdgeInsets.all(VboxSpacing.xl),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.06),
        borderRadius: VboxRadii.chip,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '添加自定义切片源',
            style: TextStyle(
              fontSize: VboxTypography.s16,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: VboxSpacing.lg),
          _field(theme, label: '源名称', controller: _name, hint: '如：我的资源站'),
          const SizedBox(height: VboxSpacing.lg),
          _field(
            theme,
            label: 'API地址',
            controller: _api,
            hint: 'https://example.com/api.php/provide/vod',
            url: true,
          ),
          const SizedBox(height: VboxSpacing.lg),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _api,
            builder: (BuildContext context, TextEditingValue apiVal, Widget? _) {
              return ValueListenableBuilder<TextEditingValue>(
                valueListenable: _name,
                builder:
                    (BuildContext context, TextEditingValue nameVal, Widget? _) {
                  final bool disabled = nameVal.text.trim().isEmpty ||
                      apiVal.text.trim().isEmpty;
                  return _addButton(disabled);
                },
              );
            },
          ),
        ],
      ),
    );
  }

  /// 「添加」主色按钮（对齐 iOS L3274-L3289）。
  Widget _addButton(bool disabled) {
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: Material(
        color: VboxColors.skinPrimaryRose,
        borderRadius: VboxRadii.card,
        child: InkWell(
          borderRadius: VboxRadii.card,
          onTap: disabled ? null : () => unawaited(_add()),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: VboxSpacing.md),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.add, size: VboxTypography.s18, color: Colors.white),
                  SizedBox(width: VboxSpacing.xs),
                  Text(
                    '添加',
                    style: TextStyle(
                      fontSize: VboxTypography.s15,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    ThemeData theme, {
    required String label,
    required TextEditingController controller,
    required String hint,
    bool url = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: VboxTypography.s13,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: VboxSpacing.sm),
        TextField(
          controller: controller,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          keyboardType: url ? TextInputType.url : TextInputType.text,
          style: TextStyle(
            fontSize: url ? VboxTypography.s12 : VboxTypography.s13,
          ),
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            border: const OutlineInputBorder(borderRadius: VboxRadii.button),
          ),
        ),
      ],
    );
  }

  Future<void> _add() async {
    final FallbackSite site = FallbackSite(
      name: _name.text.trim(),
      api: _api.text.trim(),
    );
    if (!site.isValid) return;
    final bool ok = await _store.addCustomFallbackSite(site);
    if (!mounted) return;
    if (!ok) {
      VboxToast.show(context, '该切片源已存在');
      return;
    }
    _name.clear();
    _api.clear();
    VboxToast.show(context, '已添加「${site.name}」');
  }

  Future<void> _confirmDelete(FallbackSite site) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除确认'),
        content: const Text('确定要删除这个自定义切片源吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await _store.removeCustomFallbackSite(site.api);
    }
  }

  /// 分区（标题 16 semibold + 行列表；对齐 iOS 的 VStack 口径）。
  Widget _section(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        left: VboxSpacing.lg,
        right: VboxSpacing.lg,
        bottom: VboxSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: VboxSpacing.xs),
            child: Text(
              title,
              style: TextStyle(
                fontSize: VboxTypography.s16,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: VboxSpacing.md),
          for (int i = 0; i < children.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: VboxSpacing.md),
            children[i],
          ],
        ],
      ),
    );
  }

  Widget _sourceRow(
    BuildContext context, {
    required String name,
    required String subtitle,
    _SourceBadge? badge,
    Widget? trailing,
  }) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.md,
        vertical: VboxSpacing.md,
      ),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.04),
        borderRadius: VboxRadii.button,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s14,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: VboxSpacing.xs),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s11,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          if (badge != null) ...<Widget>[
            const SizedBox(width: VboxSpacing.md),
            badge,
          ],
          if (trailing != null) ...<Widget>[
            const SizedBox(width: VboxSpacing.md),
            trailing,
          ],
        ],
      ),
    );
  }

  Widget _deleteButton(VoidCallback onTap) => IconButton(
        onPressed: onTap,
        icon: const Icon(Icons.delete_outline, size: VboxTypography.s18),
        color: Colors.red,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      );
}

/// 源角标（对齐 iOS「远程」/「内置」角标）。
///
/// 差异登记：iOS 垂直内边距 2pt，无对应间距令牌，取最近档 [VboxSpacing.xs]。
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.sm,
        vertical: VboxSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.6),
        borderRadius: VboxRadii.badge,
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: VboxTypography.s10,
          color: Colors.white,
        ),
      ),
    );
  }
}