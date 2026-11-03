/// 解析器管理页（Wave D · O-源2）。
///
/// 唯一真相源：iOS `vbox/Views/SettingsViews.swift` `ParserConfigView`
/// （L3329-L3470）：
///   · 自定义解析器列表（L3342-L3376）—— 标题「自定义解析器」（16 semibold），
///     行 = 名称（14 medium）+ 地址（11 secondary · 单行）+ 删除按钮（红 · trash 14）；
///   · 空态（L3377-L3392）—— `wand.and.stars` 图标（40 · gray）+
///     「暂无自定义解析器」（14 gray）+「添加解析器后可提高切片资源播放成功率」
///     （12 gray @80% · 居中）；
///   · 添加卡片（L3394-L3437）—— 标题「添加自定义解析器」（16 semibold）+
///     「解析器名称」「解析器地址」输入 +「添加解析器」主色按钮
///     （`plus.circle.fill` 16 + 文字 · 全宽 · v12 · 圆角 12 · 无效 @50% 禁用）；
///   · 删除二次确认 alert（L3451-L3460）。
///
/// 落地口径：
/// - 自定义解析器 = 契约键 `user_parsers`（对齐 iOS `SpiderManager.customParsers`）；
/// - 播放链路在 [SourceGovernanceUseCases.resolveWithParsers] 中按「解析器地址 +
///   编码后的原始地址」逐个尝试（远程默认 + 自定义），命中 m3u8/mp4 即返回
///   （对齐 iOS `PlayerViewsV2`）。
///
/// 差异登记：iOS 以 sheet 呈现（隐藏 nav bar +「关闭」按钮）；Flutter 用标准
/// `AppBar`（保留返回键），与订阅配置页口径一致。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/datasources/local/source_governance_store.dart';
import '../../../domain/entities/source/source_governance.dart';
import '../../theme/theme.dart';
import '../../widgets/vbox/vbox_toast.dart';

/// 解析器管理页。
class ParserManagePage extends StatefulWidget {
  /// 构造（[store] 可注入；为 null 时消费全局单例，便于单测）。
  const ParserManagePage({super.key, this.store});

  /// 源治理存储（可注入）。
  final SourceGovernanceStore? store;

  @override
  State<ParserManagePage> createState() => _ParserManagePageState();
}

class _ParserManagePageState extends State<ParserManagePage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();

  SourceGovernanceStore get _store =>
      widget.store ?? SourceGovernanceStore.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_store.load());
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (BuildContext context, Widget? _) => Scaffold(
        appBar: AppBar(title: const Text('解析器管理')),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: VboxSpacing.xl),
          children: <Widget>[
            if (_store.userParsers.isEmpty)
              _buildEmpty(context)
            else
              _buildList(context),
            _buildAddCard(context),
          ],
        ),
      ),
    );
  }

  /// 空态（对齐 iOS L3377-L3392）。
  Widget _buildEmpty(BuildContext context) {
    final Color gray = Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
      child: Column(
        children: <Widget>[
          Icon(Icons.auto_awesome, size: 40, color: gray),
          const SizedBox(height: VboxSpacing.md),
          Text(
            '暂无自定义解析器',
            style: TextStyle(fontSize: VboxTypography.s14, color: gray),
          ),
          const SizedBox(height: VboxSpacing.sm),
          Text(
            '添加解析器后可提高切片资源播放成功率',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: VboxTypography.s12,
              color: gray.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }

  /// 自定义解析器列表（对齐 iOS L3342-L3376）。
  Widget _buildList(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<ParserEntry> parsers = _store.userParsers;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: VboxSpacing.xs),
            child: Text(
              '自定义解析器',
              style: TextStyle(
                fontSize: VboxTypography.s16,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: VboxSpacing.md),
          for (int i = 0; i < parsers.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: VboxSpacing.md),
            Container(
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
                          parsers[i].name,
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
                          parsers[i].url,
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
                  const SizedBox(width: VboxSpacing.md),
                  IconButton(
                    onPressed: () => unawaited(_confirmDelete(parsers[i])),
                    icon: const Icon(
                      Icons.delete_outline,
                      size: VboxTypography.s18,
                    ),
                    color: Colors.red,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 添加卡片（对齐 iOS L3394-L3437）。
  Widget _buildAddCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        VboxSpacing.lg,
        VboxSpacing.xl,
        VboxSpacing.lg,
        0,
      ),
      padding: const EdgeInsets.all(VboxSpacing.xl),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.06),
        borderRadius: VboxRadii.chip,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '添加自定义解析器',
            style: TextStyle(
              fontSize: VboxTypography.s16,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: VboxSpacing.lg),
          _field(theme, label: '解析器名称', controller: _name, hint: '如：777 解析'),
          const SizedBox(height: VboxSpacing.lg),
          _field(
            theme,
            label: '解析器地址',
            controller: _url,
            hint: 'https://jx.xxx.com/player/?url=',
            url: true,
          ),
          const SizedBox(height: VboxSpacing.lg),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _url,
            builder: (BuildContext context, TextEditingValue urlVal, Widget? _) {
              return ValueListenableBuilder<TextEditingValue>(
                valueListenable: _name,
                builder:
                    (BuildContext context, TextEditingValue nameVal, Widget? _) {
                  final bool disabled =
                      nameVal.text.trim().isEmpty || urlVal.text.trim().isEmpty;
                  return _addButton(disabled);
                },
              );
            },
          ),
        ],
      ),
    );
  }

  /// 「添加解析器」主色按钮（对齐 iOS L3417-L3433）。
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
                  Icon(
                    Icons.add_circle,
                    size: VboxTypography.s16,
                    color: Colors.white,
                  ),
                  SizedBox(width: VboxSpacing.sm),
                  Text(
                    '添加解析器',
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
    final ParserEntry parser = ParserEntry(
      name: _name.text.trim(),
      url: _url.text.trim(),
    );
    if (!parser.isValid) return;
    final bool ok = await _store.addUserParser(parser);
    if (!mounted) return;
    if (!ok) {
      VboxToast.show(context, '该解析器已存在');
      return;
    }
    _name.clear();
    _url.clear();
    VboxToast.show(context, '已添加「${parser.name}」');
  }

  Future<void> _confirmDelete(ParserEntry parser) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除确认'),
        content: const Text('确定要删除这个解析器吗？'),
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
      await _store.removeUserParser(parser.url);
    }
  }
}