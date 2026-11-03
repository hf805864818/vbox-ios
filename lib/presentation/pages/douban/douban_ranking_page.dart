/// 豆瓣榜单（批次 D · D-03）。
///
/// 顶部榜单分类胶囊（剧情 / 喜剧 / 动作…）+ 排行列表（名次 + 封面 + 标题 + 信息 +
/// 评分）。数据通路：[DoubanUseCases.ranking]（chart top_list）。
/// 条目点击 → 进搜索页自动搜索（对齐 iOS `settings.triggerSearch`，同豆瓣分类页）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/failures.dart';
import '../../../core/utils/result.dart';
import '../../../domain/entities/douban/douban_models.dart';
import '../../../domain/usecases/douban_usecases.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import '../../widgets/vbox/vbox.dart';
import '../search/search_page.dart';
import 'douban_widgets.dart';

/// 豆瓣榜单页。
class DoubanRankingPage extends StatefulWidget {
  /// 构造。
  const DoubanRankingPage({super.key});

  @override
  State<DoubanRankingPage> createState() => _DoubanRankingPageState();
}

class _DoubanRankingPageState extends State<DoubanRankingPage> {
  late final DoubanUseCases _uc;

  DoubanChartCategory _category = DoubanChartCategory.all.first;
  List<DoubanChartSubject> _items = const <DoubanChartSubject>[];
  Failure? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _uc = context.read<DoubanUseCases>();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final Result<List<DoubanChartSubject>> result = await _uc.ranking(_category);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = result.failureOrNull;
      _items = result.valueOrNull ?? const <DoubanChartSubject>[];
    });
  }

  Future<void> _selectCategory(DoubanChartCategory category) async {
    if (category.typeId == _category.typeId) return;
    _category = category;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('豆瓣榜单')),
      body: Column(
        children: <Widget>[
          _buildCategoryPills(),
          const SizedBox(height: VboxSpacing.xs),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildCategoryPills() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < DoubanChartCategory.all.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: VboxSpacing.sm),
            VboxChip(
              label: DoubanChartCategory.all[i].name,
              dense: true,
              selected: DoubanChartCategory.all[i].typeId == _category.typeId,
              onTap: () => _selectCategory(DoubanChartCategory.all[i]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final Failure? error = _error;
    if (error != null) {
      return DoubanErrorRetry(message: '$error', onRetry: _load);
    }
    if (_items.isEmpty) {
      return const DoubanEmptyHint(text: '该榜单暂无内容\n切换分类试试');
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: VboxSpacing.sm),
      itemCount: _items.length,
      itemBuilder: (BuildContext context, int index) => _RankRow(
        item: _items[index],
        onTap: () => _openSubject(_items[index]),
      ),
    );
  }

  /// 条目点击 → 进搜索页自动搜索（对齐 iOS `settings.triggerSearch(subject.title)`；
  /// 同豆瓣分类页，`SearchPage` 的 `initialKeyword` 自动搜索链路）。
  void _openSubject(DoubanChartSubject subject) {
    final String kw = subject.title.trim();
    if (kw.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SearchPage(initialKeyword: kw),
      ),
    );
  }
}

/// 排行行（名次 + 封面 + 标题 / 信息 + 评分）。
class _RankRow extends StatelessWidget {
  const _RankRow({required this.item, required this.onTap});

  final DoubanChartSubject item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String subtitle = <String?>[
      item.year,
      item.info,
    ].whereType<String>().join(' · ');

    return Padding(
      padding: VboxSpacing.symmetric(
        horizontal: VboxSpacing.lg,
        vertical: VboxSpacing.sm,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: VboxRadii.button,
        child: Row(
        children: <Widget>[
          SizedBox(
            width: 28,
            child: Text(
              '${item.rank}',
              style: TextStyle(
                fontSize: VboxTypography.s16,
                fontWeight: FontWeight.w700,
                color: item.rank <= 3 ? scheme.primary : scheme.outline,
              ),
            ),
          ),
          ClipRRect(
            borderRadius: VboxRadii.button,
            child: SizedBox(
              width: 52,
              height: 72,
              child: PlatformAsyncImage(url: item.coverUrl, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: VboxSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s14,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                if (subtitle.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (item.hasRating) ...<Widget>[
            const SizedBox(width: VboxSpacing.sm),
            Text(
              item.rating.toStringAsFixed(1),
              style: TextStyle(
                fontSize: VboxTypography.s14,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ],
        ],
        ),
      ),
    );
  }
}