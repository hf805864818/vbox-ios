/// 日志查看页（A3 接线；全端共享）。
///
/// 数据源：核心层 [AppLog] 的内存环形缓冲（实时流订阅）。落盘文件由数据层
/// `LogFileSink` 负责写入 `StoragePaths.logDir`，本页只读内存缓冲并支持导出。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/logger.dart';
import '../../data/datasources/local/prefs_manager.dart';

/// 日志查看页。
class LogViewerPage extends StatefulWidget {
  /// 构造。
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  /// 最低级别过滤（null = 全部）。
  LogLevel? _minLevel;

  /// 模块分类过滤（null = 全部；对齐 iOS `selectedCategory`）。
  LogCategory? _category;

  /// 关键字过滤（标签 / 正文）。
  String _keyword = '';

  StreamSubscription<LogEntry>? _sub;

  /// 上次异常退出标记（批次 E · E3-3；对齐 iOS `AppLogStore.swift:259`）。
  bool _crashedLastLaunch = false;

  @override
  void initState() {
    super.initState();
    _sub = AppLog.stream.listen((_) {
      if (mounted) setState(() {});
    });
    _loadCrashMarker();
  }

  /// 读取并清除崩溃标记（一次性提示）。
  Future<void> _loadCrashMarker() async {
    try {
      final bool crashed =
          await PrefsManager.instance.getBool('app_log_crash_marker');
      if (crashed) {
        await PrefsManager.instance.set('app_log_crash_marker', false);
      }
      if (mounted) {
        setState(() => _crashedLastLaunch = crashed);
      }
    } catch (_) {
      // 偏好读取失败不影响日志页主功能。
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  List<LogEntry> get _filtered {
    final String kw = _keyword.trim().toLowerCase();
    return AppLog.entries.where((LogEntry e) {
      final LogLevel? min = _minLevel;
      if (min != null && e.level.index < min.index) return false;
      final LogCategory? cat = _category;
      if (cat != null && e.category != cat) return false;
      if (kw.isEmpty) return true;
      return e.tag.toLowerCase().contains(kw) ||
          e.message.toLowerCase().contains(kw);
    }).toList();
  }

  Future<void> _export() async {
    final String text = _filtered.map((LogEntry e) => e.format()).join('\n');
    if (text.isEmpty) {
      _toast('当前无可导出的日志');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _toast('已复制 ${_filtered.length} 条日志到剪贴板');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final List<LogEntry> entries = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: '导出（复制到剪贴板）',
            onPressed: _export,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空内存缓冲',
            onPressed: () {
              AppLog.clear();
              setState(() {});
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_crashedLastLaunch)
            // 批次 E · E3-3：崩溃恢复横幅（对齐 iOS 日志页顶部提示）。
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                dense: true,
                leading: Icon(
                  Icons.warning_amber_rounded,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                title: Text(
                  '检测到上次异常退出',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _crashedLastLaunch = false),
                ),
              ),
            ),
          _FilterBar(
            minLevel: _minLevel,
            onMinLevelChanged: (LogLevel? v) => setState(() => _minLevel = v),
            category: _category,
            onCategoryChanged: (LogCategory? v) =>
                setState(() => _category = v),
            onKeywordChanged: (String v) => setState(() => _keyword = v),
          ),
          Expanded(
            child: entries.isEmpty
                ? const _Empty(text: '暂无日志\n（可在设置中开启「应用日志」）')
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (BuildContext context, int index) {
                      // 展示最新在前
                      final LogEntry e = entries[entries.length - 1 - index];
                      return _LogTile(entry: e);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 过滤栏：级别分段 + 模块分类 + 关键字。
class _FilterBar extends StatefulWidget {
  const _FilterBar({
    required this.minLevel,
    required this.onMinLevelChanged,
    required this.category,
    required this.onCategoryChanged,
    required this.onKeywordChanged,
  });

  final LogLevel? minLevel;
  final ValueChanged<LogLevel?> onMinLevelChanged;

  /// 模块分类过滤（null = 全部）。
  final LogCategory? category;
  final ValueChanged<LogCategory?> onCategoryChanged;

  final ValueChanged<String> onKeywordChanged;

  @override
  State<_FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<_FilterBar> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: '按标签或内容搜索',
              border: OutlineInputBorder(),
            ),
            onChanged: widget.onKeywordChanged,
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                _LevelChip(
                  label: '全部',
                  selected: widget.minLevel == null,
                  onSelected: () => widget.onMinLevelChanged(null),
                ),
                for (final LogLevel level in LogLevel.values)
                  _LevelChip(
                    label: level.name.toUpperCase(),
                    selected: widget.minLevel == level,
                    onSelected: () => widget.onMinLevelChanged(level),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // 模块筛选（对齐 iOS `LogViewerView` 的 `LogCategory.allCases` 菜单）。
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                _LevelChip(
                  label: '全部模块',
                  selected: widget.category == null,
                  onSelected: () => widget.onCategoryChanged(null),
                ),
                for (final LogCategory cat in LogCategory.values)
                  _LevelChip(
                    label: cat.displayName,
                    selected: widget.category == cat,
                    onSelected: () => widget.onCategoryChanged(cat),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LevelChip extends StatelessWidget {
  const _LevelChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onSelected(),
      ),
    );
  }
}

/// 单条日志。
class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: _LevelBadge(level: entry.level),
      title: Text(
        entry.message,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
      subtitle: Text(
        '${entry.category.codeName}  ·  ${entry.tag}  ·  ${_time(entry.time)}'
        '${entry.error != null ? '\n${entry.error}' : ''}',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
      isThreeLine: entry.error != null,
    );
  }

  static String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

class _LevelBadge extends StatelessWidget {
  const _LevelBadge({required this.level});

  final LogLevel level;

  @override
  Widget build(BuildContext context) {
    final Color color = switch (level) {
      LogLevel.debug => Colors.grey,
      LogLevel.info => Colors.blue,
      LogLevel.warn => Colors.orange,
      LogLevel.error => Theme.of(context).colorScheme.error,
    };
    return CircleAvatar(
      radius: 12,
      backgroundColor: color.withValues(alpha: 0.15),
      child: Text(
        level.name.substring(0, 1).toUpperCase(),
        style:
            TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});

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
