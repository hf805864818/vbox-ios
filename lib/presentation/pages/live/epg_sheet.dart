/// 节目单 Sheet（批次 E · E-03）。
///
/// 对齐 iOS `EPGSheetView`：日期切换（今天 / 昨天 / 前天）+ 加载态 + 空态
/// （「暂无节目单」）+ 节目列表（时间橙字 + 标题）。[fetchEpg] 供测试注入，
/// 缺省对齐 iOS `LiveTVService.fetchEPG`（EPG 接口已失效，返回空）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/live/live.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';

/// EPG 拉取回调（channel + day → 节目单）。
typedef EpgFetchHandler = Future<List<EpgProgram>> Function(
    LiveChannel channel, EpgDay day);

/// 节目单 Sheet。
class EpgSheet extends StatefulWidget {
  /// 构造。
  const EpgSheet({super.key, required this.channel, this.fetchEpg});

  /// 目标频道。
  final LiveChannel channel;

  /// 拉取回调（null → 缺省空实现，对齐 iOS 接口失效）。
  final EpgFetchHandler? fetchEpg;

  @override
  State<EpgSheet> createState() => _EpgSheetState();
}

class _EpgSheetState extends State<EpgSheet> {
  EpgDay _day = EpgDay.today;
  bool _loading = true;
  List<EpgProgram> _programs = const <EpgProgram>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  static Future<List<EpgProgram>> _emptyFetch(
          LiveChannel channel, EpgDay day) async =>
      const <EpgProgram>[];

  Future<void> _load() async {
    setState(() => _loading = true);
    final EpgFetchHandler handler = widget.fetchEpg ?? _emptyFetch;
    final List<EpgProgram> result = await handler(widget.channel, _day);
    if (mounted) {
      setState(() {
        _programs = result;
        _loading = false;
      });
    }
  }

  Future<void> _selectDay(EpgDay day) async {
    if (day == _day) return;
    setState(() => _day = day);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.7;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: maxHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _titleRow(scheme),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  VboxSpacing.lg, 0, VboxSpacing.lg, VboxSpacing.md),
              child: SegmentedButton<EpgDay>(
                segments: EpgDay.values
                    .map((EpgDay d) =>
                        ButtonSegment<EpgDay>(value: d, label: Text(d.label)))
                    .toList(growable: false),
                selected: <EpgDay>{_day},
                onSelectionChanged: (Set<EpgDay> selection) =>
                    _selectDay(selection.first),
              ),
            ),
            Expanded(child: _body(scheme)),
          ],
        ),
      ),
    );
  }

  Widget _titleRow(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          VboxSpacing.lg, VboxSpacing.sm, VboxSpacing.sm, VboxSpacing.sm),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '${widget.channel.name} 节目单',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: VboxTypography.s18,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_programs.isEmpty) {
      return _empty(scheme);
    }
    return ListView.separated(
      padding: VboxSpacing.symmetric(
          horizontal: VboxSpacing.lg, vertical: VboxSpacing.sm),
      itemCount: _programs.length,
      separatorBuilder: (BuildContext context, int index) =>
          const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final EpgProgram program = _programs[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: VboxSpacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 56,
                child: Text(
                  program.time,
                  style: const TextStyle(
                    fontSize: VboxTypography.s15,
                    fontWeight: FontWeight.w500,
                    color: Colors.orange,
                  ),
                ),
              ),
              const SizedBox(width: VboxSpacing.md),
              Expanded(
                child: Text(
                  program.title,
                  style: TextStyle(
                    fontSize: VboxTypography.s15,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _empty(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.list_alt_outlined, size: 48, color: scheme.outline),
          const SizedBox(height: VboxSpacing.md),
          Text(
            '暂无节目单',
            style: TextStyle(
              fontSize: VboxTypography.s15,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}