/// 全端共享视图：收藏列表 / 历史列表（直连 UseCase）。
///
/// 单一页树（`shell/HomeShellPage` 的 `ShelfView`）在竖/横双排布下共用同一套
/// 列表逻辑与展示。状态接入直连领域层 UseCase（D21 轻量路线）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/result.dart';
import '../../core/utils/time_utils.dart';
import '../../domain/entities/library/library.dart';
import '../../domain/usecases/usecases.dart';
import '../welfare/welfare_controller.dart';
import '../welfare/welfare_replay_bridge.dart';
import 'detail_page.dart';
import 'platform_async_image.dart';

/// 收藏 Tab（直连 [FavoriteUseCases]）。
class FavoritesView extends StatefulWidget {
  /// 构造。
  const FavoritesView({super.key});

  @override
  State<FavoritesView> createState() => _FavoritesViewState();
}

class _FavoritesViewState extends State<FavoritesView> {
  // 用例引用在 initState 缓存，避免跨 async gap 使用 context
  late final FavoriteUseCases _uc;
  List<FavoriteItem>? _items;
  Object? _error;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _uc = context.read<FavoriteUseCases>();
    _load();
  }

  Future<void> _load() async {
    final Result<List<FavoriteItem>> result = await _uc.list();
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _error = result.failureOrNull;
      _items = result.valueOrNull ?? const <FavoriteItem>[];
    });
  }

  Future<void> _remove(FavoriteItem item) async {
    final int? id = item.id;
    if (id == null) return;
    await _uc.remove(id);
    await _load();
  }

  Future<void> _clearAll() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空收藏'),
        content: const Text('确定清空全部收藏？此操作不可撤销。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _uc.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final Object? error = _error;
    if (error != null) {
      return _ErrorRetry(message: '$error', onRetry: _load);
    }
    final List<FavoriteItem> items = _items ?? const <FavoriteItem>[];
    if (items.isEmpty) {
      return const _EmptyHint(text: '暂无收藏\n去远程源订阅你喜欢的资源吧');
    }
    return ListView.separated(
      itemCount: items.length + 1,
      separatorBuilder: (BuildContext context, int index) =>
          const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) {
          return Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('清空'),
            ),
          );
        }
        final FavoriteItem item = items[index - 1];
        return ListTile(
          leading: const Icon(Icons.movie_outlined),
          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${item.laiyuan.isEmpty ? '未知来源' : item.laiyuan}'
            ' · ${TimeUtils.relative(TimeUtils.fromUnixSeconds(item.addedAt))}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '移除',
            onPressed: () => _remove(item),
          ),
          onTap: () {
            // W-福2：福利记录分流到「福利重播桥」（laiyuan 前缀 [福利]
            // + detailua=platformKey）；其余走详情页·播放入口接线
            // （laiyuan=站点 key，detailurl=影片 ID，jishu=剧集索引）。
            if (isWelfareReplayRecord(
              laiyuan: item.laiyuan,
              detailua: item.detailua,
            )) {
              unawaited(_openWelfare(item));
              return;
            }
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => DetailPage(
                  siteKey: item.laiyuan,
                  vodId: item.detailurl,
                  initialIndex: item.jishu,
                  title: item.name,
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 打开福利重播桥（对齐 iOS `WelfareBridgeContainer`）。
  Future<void> _openWelfare(FavoriteItem item) => openWelfareReplayBridge(
        context,
        platformKey: item.detailua,
        vodId: item.detailurl,
        vodName: item.name,
        vodPic: item.imgurl,
      );
}

/// 历史 Tab（直连 [HistoryUseCases]）。
class HistoryView extends StatefulWidget {
  /// 构造。
  const HistoryView({super.key});

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  // 用例引用在 initState 缓存，避免跨 async gap 使用 context
  late final HistoryUseCases _uc;
  List<HistoryItem>? _items;
  Object? _error;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _uc = context.read<HistoryUseCases>();
    _load();
  }

  Future<void> _load() async {
    final Result<List<HistoryItem>> result =
        await _uc.recent(limit: HistoryUseCases.defaultLimit);
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _error = result.failureOrNull;
      _items = result.valueOrNull ?? const <HistoryItem>[];
    });
  }

  Future<void> _remove(HistoryItem item) async {
    final int? id = item.id;
    if (id == null) return;
    await _uc.remove(id);
    await _load();
  }

  Future<void> _clearAll() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('确定清空全部播放历史？此操作不可撤销。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _uc.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final Object? error = _error;
    if (error != null) {
      return _ErrorRetry(message: '$error', onRetry: _load);
    }
    // 福利总开关关闭时过滤 [福利] 记录（对齐 iOS `WatchHistoryView.onAppear`）。
    final bool welfareEnabled = context.watch<WelfareController>().enabled;
    final List<HistoryItem> items = (_items ?? const <HistoryItem>[])
        .where((HistoryItem i) => welfareEnabled || !i.laiyuan.startsWith('[福利]'))
        .toList(growable: false);
    if (items.isEmpty) {
      // 对齐 iOS 空态：「暂无观看记录」14pt 灰。
      return Center(
        child: Text(
          '暂无观看记录',
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
    }
    // 对齐 iOS `WatchHistoryView`（ProfileView L1210）：
    //   · 行 = 封面 60×80 圆角 6 + 名称 15pt medium + 来源 12pt 灰 + 绝对日期
    //     11pt 灰（`yyyy-MM-dd HH:mm`）——无进度条 / 无集数；
    //   · 删除 = 左滑（iOS swipeActions trailing destructive），行尾无按钮；
    //   · 清空 = 顶部右侧主色文字按钮（iOS 在导航栏 trailing，Flutter 该视图
    //     为嵌入 body，以列表首行右侧按钮等价承接）。
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4),
      itemCount: items.length + 1,
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) {
          return Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _clearAll,
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: const Text('清空'),
            ),
          );
        }
        final HistoryItem item = items[index - 1];
        return Dismissible(
          key: ValueKey<int>(item.id ?? item.hashCode),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.red,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 24),
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          onDismissed: (_) => _remove(item),
          child: InkWell(
            onTap: () => _openRecord(item),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 60,
                      height: 80,
                      child: item.imgurl.isEmpty
                          ? ColoredBox(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              child: const Icon(Icons.movie_outlined),
                            )
                          : PlatformAsyncImage(
                              url: item.imgurl,
                              fit: BoxFit.cover,
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (item.laiyuan.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            item.laiyuan,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          TimeUtils.formatUnixSeconds(
                            item.lastPlayedAt,
                            pattern: 'yyyy-MM-dd HH:mm',
                          ),
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ],
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

  /// 打开记录（福利分流 + 续播入口，与 iOS `onTapGesture` 分流一致）。
  void _openRecord(HistoryItem item) {
    if (isWelfareReplayRecord(
      laiyuan: item.laiyuan,
      detailua: item.detailua,
    )) {
      unawaited(_openWelfare(item));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => DetailPage(
          siteKey: item.laiyuan,
          vodId: item.detailurl,
          initialIndex: item.jishu,
          title: item.name,
        ),
      ),
    );
  }

  /// 打开福利重播桥（对齐 iOS `WelfareBridgeContainer`）。
  Future<void> _openWelfare(HistoryItem item) => openWelfareReplayBridge(
        context,
        platformKey: item.detailua,
        vodId: item.detailurl,
        vodName: item.name,
        vodPic: item.imgurl,
      );
}

/// 空态提示。
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      ),
    );
  }
}

/// 加载失败提示 + 重试。
class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
