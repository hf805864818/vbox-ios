/// 订阅配置页（批次 G · G-07）。
///
/// 唯一真相源：iOS `vbox/Views/SettingsViews.swift` 的 `SubscribeConfigView`
/// （L2914-L2999）+ `SubscriptionRow`（L3001-L3049）：
///   · 添加卡片（L2927-L2946）—— 标题「添加新订阅源」（18 semibold）+ 「订阅地址」
///     （13 medium）+ URL 输入框（13）+ 「添加订阅」主色按钮（15 medium · 圆角 12 ·
///     垂直内边距 12 · 全宽），加载中显示进度圈，空地址 / 加载中禁用；
///     卡片底色 gray@6% · 圆角 16 · 内边距 20 · 外边距 16。
///   · 已订阅列表（L2948-L2969）—— 标题「已订阅源 (点击切换激活，左滑删除)」
///     （16 semibold）；行 = 短域名（14 medium）+ 完整 URL（11 secondary）+
///     激活勾选（主色 18）；激活行主色 @10% 底 + 主色 @50% 描边，非激活 gray@4% 底，
///     圆角 8，内边距 h12 v10；点击切换激活，左滑 / 长按删除。
///   · 反馈（L2974-L2977）—— 成功「订阅源已添加并加载」/ 失败展示 `errorMessage`。
///
/// 差异登记：
///   · iOS 隐藏 nav bar、以内容区 22pt 大标题呈现；Flutter 用标准 `AppBar`
///     标题（保留返回键），与 G-04 TG 页口径一致；
///   · iOS 删除入口为 `contextMenu`（长按）但文案写「左滑删除」；Flutter 同时
///     提供左滑删除与长按删除，两者语义等价。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/datasources/local/subscribe_config_store.dart';
import '../../../data/datasources/remote/subscribe_config_loader.dart';
import '../../theme/theme.dart';

/// 订阅配置页。
class SubscribeConfigPage extends StatefulWidget {
  /// 构造（[store] / [loader] 可注入；为 null 时消费全局单例，便于单测）。
  const SubscribeConfigPage({super.key, this.store, this.loader});

  /// 订阅配置存储（可注入）。
  final SubscribeConfigStore? store;

  /// 订阅配置加载器（可注入）。
  final SubscribeConfigLoader? loader;

  @override
  State<SubscribeConfigPage> createState() => _SubscribeConfigPageState();
}

class _SubscribeConfigPageState extends State<SubscribeConfigPage> {
  final TextEditingController _urlController = TextEditingController();
  SubscribeConfigLoader? _loaderInstance;

  SubscribeConfigStore get _store => widget.store ?? SubscribeConfigStore.shared;

  SubscribeConfigLoader get _loader =>
      widget.loader ?? (_loaderInstance ??= SubscribeConfigLoader(store: _store));

  @override
  void initState() {
    super.initState();
    // 幂等恢复（`_loaded` 守卫保证只读一次契约键）。
    unawaited(_store.load());
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (BuildContext context, Widget? _) => _scaffold(context),
    );
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('订阅配置')),
      body: ListView(
        padding: const EdgeInsets.only(
          top: VboxSpacing.lg,
          bottom: VboxSpacing.xxxl,
        ),
        children: <Widget>[
          _buildAddCard(context),
          if (_store.hasConfigUrls) _buildSubscribedSection(context),
        ],
      ),
    );
  }

  /// 添加新订阅源卡片（对齐 iOS L2927-L2946）。
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
            '添加新订阅源',
            style: TextStyle(
              fontSize: VboxTypography.s18,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: VboxSpacing.lg),
          Text(
            '订阅地址',
            style: TextStyle(
              fontSize: VboxTypography.s13,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: VboxSpacing.sm),
          TextField(
            controller: _urlController,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            style: const TextStyle(fontSize: VboxTypography.s13),
            decoration: const InputDecoration(
              hintText: 'URL',
              isDense: true,
              border: OutlineInputBorder(borderRadius: VboxRadii.button),
            ),
            onSubmitted: (_) => unawaited(_add()),
          ),
          const SizedBox(height: VboxSpacing.lg),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _urlController,
            builder: (BuildContext context, TextEditingValue value, Widget? _) {
              final bool disabled =
                  value.text.trim().isEmpty || _store.isLoading;
              return _buildAddButton(disabled);
            },
          ),
        ],
      ),
    );
  }

  /// 「添加订阅」主色按钮（对齐 iOS L2935-L2943）。
  Widget _buildAddButton(bool disabled) {
    const Color rose = VboxColors.skinPrimaryRose;
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: Material(
        color: rose,
        borderRadius: VboxRadii.card,
        child: InkWell(
          borderRadius: VboxRadii.card,
          onTap: disabled ? null : () => unawaited(_add()),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: VboxSpacing.md),
            child: Center(
              child: _store.isLoading
                  ? const SizedBox(
                      width: VboxTypography.s18,
                      height: VboxTypography.s18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text(
                      '添加订阅',
                      style: TextStyle(
                        fontSize: VboxTypography.s15,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// 已订阅源列表（对齐 iOS L2948-L2969）。
  Widget _buildSubscribedSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<String> urls = _store.configUrls;
    return Padding(
      padding: const EdgeInsets.only(
        top: VboxSpacing.xl,
        left: VboxSpacing.lg,
        right: VboxSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.xs),
            child: Text(
              '已订阅源 (点击切换激活，左滑删除)',
              style: TextStyle(
                fontSize: VboxTypography.s16,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: VboxSpacing.md),
          for (int i = 0; i < urls.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: VboxSpacing.md),
            _SubscriptionRow(
              url: urls[i],
              isActive: i == _store.activeURLIndex,
              onTap: () => unawaited(_store.switchTo(i)),
              onDelete: () => unawaited(_confirmDelete(urls[i])),
            ),
          ],
        ],
      ),
    );
  }

  /// 添加订阅（对齐 iOS L2980-L2998 的判定链）。
  Future<void> _add() async {
    final String url = _urlController.text.trim();
    if (url.isEmpty || _store.isLoading) return;
    final String? error = await _loader.load(url);
    if (!mounted) return;
    _urlController.clear();
    if (error != null) {
      await _showAlert('添加失败', error);
      return;
    }
    await _showAlert('添加成功', '订阅源已添加并加载');
  }

  /// 删除确认（长按入口；左滑删除直接执行，对齐 iOS 无二次确认语义）。
  Future<void> _confirmDelete(String url) async {
    final BuildContext context = this.context;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除订阅源'),
        content: Text('确定删除「${_shortenUrl(url)}」？'),
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
      await _store.removeUrl(url);
    }
  }

  Future<void> _showAlert(String title, String message) async {
    final BuildContext context = this.context;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

/// 订阅源行（对齐 iOS `SubscriptionRow`）。
class _SubscriptionRow extends StatelessWidget {
  const _SubscriptionRow({
    required this.url,
    required this.isActive,
    required this.onTap,
    required this.onDelete,
  });

  final String url;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    const Color rose = VboxColors.skinPrimaryRose;
    final ThemeData theme = Theme.of(context);
    final Color background = isActive
        ? rose.withValues(alpha: 0.1)
        : Colors.grey.withValues(alpha: 0.04);
    return Dismissible(
      key: ValueKey<String>(url),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
        decoration: BoxDecoration(
          color: theme.colorScheme.error,
          borderRadius: VboxRadii.button,
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      child: Material(
        color: background,
        borderRadius: VboxRadii.button,
        child: InkWell(
          borderRadius: VboxRadii.button,
          onTap: onTap,
          onLongPress: onDelete,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: VboxSpacing.md,
              vertical: VboxSpacing.md,
            ),
            decoration: BoxDecoration(
              borderRadius: VboxRadii.button,
              border: Border.all(
                color: isActive ? rose.withValues(alpha: 0.5) : Colors.transparent,
              ),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _shortenUrl(url),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: VboxTypography.s14,
                          fontWeight: FontWeight.w500,
                          color: isActive
                              ? rose
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: VboxSpacing.xs),
                      Text(
                        url,
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
                if (isActive)
                  const Icon(Icons.check_circle, color: rose, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 短域名（对齐 iOS `shortenURL`：优先 host，否则截断 30 字符）。
String _shortenUrl(String url) {
  final String host = Uri.tryParse(url)?.host ?? '';
  if (host.isNotEmpty) return host;
  return url.length > 30 ? '${url.substring(0, 30)}...' : url;
}