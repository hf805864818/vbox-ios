/// PG 自动化设置页（批次 F · F-09，对齐 iOS `PgPlayConfigSection`）。
///
/// 对齐 iOS（唯一行为基准）：
/// - `AliyunPgQrLoginView.PgPlayConfigSection`（`vbox/Views/AliyunPgQrLoginView.swift:158`）
///   ——「播放参数」区（VIP 用户开关 + 并发线程 Stepper 1...64 + 画质 Picker +
///   保存按钮 +「PG 播放参数已更新」提示）；
/// - `AliyunPgConfig`（`vbox/Services/AliyunPgConfig.swift`）——总开关 / 画质 /
///   线程（含夜间自动切换）/ 转存目录 / 自动清理 + 延迟 / 代理端口。
///
/// 三块「自动化」规则在页面底部的「当前生效」卡可视化（对齐验收项「规则生效」）：
/// 清理（[PgAutoRules.shouldScheduleCleanup] / [PgAutoRules.cleanupDelay]）、
/// 线程（[PgAutoRules.currentThreadLimit]）、转存目录
/// （[PgAutoRules.resolvedTransferDir]）。
///
/// 持久化经 [PgAutoStore]（9 个 `pg_ali_*` 契约键）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/datasources/local/pg_auto_store.dart';
import '../../../data/datasources/local/prefs_manager.dart';
import '../../../domain/entities/cloud/pg_auto.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/vbox/vbox.dart';

/// PG 自动化设置页。
class PgAutoPage extends StatefulWidget {
  /// 构造（[store] / [now] 供测试注入；[now] 固定「当前生效」卡的线程时段判定）。
  const PgAutoPage({super.key, this.store, this.now});

  /// 配置存储（null → 自建，走 [PrefsManager]）。
  final PgAutoStore? store;

  /// 「当前生效」卡的求值时刻（null → [DateTime.now]）。
  final DateTime? now;

  @override
  State<PgAutoPage> createState() => _PgAutoPageState();
}

class _PgAutoPageState extends State<PgAutoPage> {
  late final PgAutoStore _store;
  late final TextEditingController _transferDirCtrl;
  late final TextEditingController _proxyPortCtrl;

  PgAutoConfig _config = PgAutoConfig.defaults;
  bool _loading = true;

  /// 线程 Stepper 范围（对齐 iOS `Stepper(in: 1...64)`）。
  static const int _threadMin = 1;
  static const int _threadMax = 64;

  /// 清理延迟 Stepper 范围与步长（对齐 iOS `cleanupDelay` 秒口径）。
  static const int _delayMin = 0;
  static const int _delayMax = 600;
  static const int _delayStep = 30;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? PgAutoStore(PrefsManager.instance);
    _transferDirCtrl = TextEditingController();
    _proxyPortCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _transferDirCtrl.dispose();
    _proxyPortCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final PgAutoConfig config = await _store.load();
    if (!mounted) return;
    setState(() {
      _config = config;
      _transferDirCtrl.text = config.transferDir;
      _proxyPortCtrl.text = '${config.proxyPort}';
      _loading = false;
    });
  }

  Future<void> _save() async {
    final PgAutoConfig config = _config.copyWith(
      transferDir: _transferDirCtrl.text.trim(),
      proxyPort: _parsePort(_proxyPortCtrl.text) ?? _config.proxyPort,
    );
    await _store.save(config);
    if (!mounted) return;
    setState(() => _config = config);
    VboxToast.show(context, 'PG 播放参数已更新');
  }

  Future<void> _reset() async {
    await _store.reset();
    await _load();
    if (!mounted) return;
    VboxToast.show(context, '已恢复默认参数');
  }

  static int? _parsePort(String raw) {
    final int? value = int.tryParse(raw.trim());
    if (value == null || value < 1 || value > 65535) return null;
    return value;
  }

  void _update(PgAutoConfig next) => setState(() => _config = next);

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('PG 自动化'),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('pg_auto_reset'),
            onPressed: _loading ? null : _reset,
            child: Text(
              '恢复默认',
              style: TextStyle(
                fontSize: VboxTypography.s13,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(VboxSpacing.lg),
              children: <Widget>[
                _switchCard(),
                const SizedBox(height: VboxSpacing.lg),
                _playParamsCard(scheme),
                const SizedBox(height: VboxSpacing.lg),
                _transferCard(scheme),
                const SizedBox(height: VboxSpacing.lg),
                _effectiveCard(scheme),
                const SizedBox(height: VboxSpacing.xl),
                _saveButton(scheme),
                const SizedBox(height: VboxSpacing.lg),
              ],
            ),
    );
  }

  /// 总开关卡。
  Widget _switchCard() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return _panel(
      scheme,
      children: <Widget>[
        _switchRow(
          key: 'pg_auto_enabled',
          title: 'PG 播放路链',
          subtitle: '关闭后阿里云盘走原生链路，不影响其它网盘',
          value: _config.enabled,
          onChanged: (bool v) => _update(_config.copyWith(enabled: v)),
        ),
      ],
    );
  }

  /// 播放参数卡（对齐 iOS `PgPlayConfigSection`）。
  Widget _playParamsCard(ColorScheme scheme) {
    return _panel(
      scheme,
      children: <Widget>[
        _sectionLabel(scheme, '播放参数', Icons.play_circle_fill),
        const SizedBox(height: VboxSpacing.md),
        _switchRow(
          key: 'pg_auto_vip',
          title: 'VIP 用户',
          subtitle: '开启后并发线程可调，最高 $_threadMax',
          value: _config.isVip,
          onChanged: (bool v) => _update(_config.copyWith(isVip: v)),
        ),
        if (_config.isVip) ...<Widget>[
          const SizedBox(height: VboxSpacing.sm),
          _stepperRow(
            scheme,
            key: 'pg_auto_thread_stepper',
            label: '并发线程',
            value: _config.threadLimit,
            min: _threadMin,
            max: _threadMax,
            step: 1,
            onChanged: (int v) => _update(_config.copyWith(threadLimit: v)),
          ),
          const SizedBox(height: VboxSpacing.sm),
          _stepperRow(
            scheme,
            key: 'pg_auto_thread_night_stepper',
            label: '夜间线程',
            value: _config.threadNight,
            min: _threadMin,
            max: _threadMax,
            step: 1,
            onChanged: (int v) => _update(_config.copyWith(threadNight: v)),
          ),
        ],
        const SizedBox(height: VboxSpacing.sm),
        _qualityRow(scheme),
      ],
    );
  }

  /// 转存与清理卡。
  Widget _transferCard(ColorScheme scheme) {
    return _panel(
      scheme,
      children: <Widget>[
        _sectionLabel(scheme, '转存与清理', Icons.cleaning_services_outlined),
        const SizedBox(height: VboxSpacing.md),
        _textRow(
          scheme,
          key: 'pg_auto_transfer_dir',
          label: '转存目录',
          controller: _transferDirCtrl,
          hint: PgAutoRules.defaultTransferDir,
        ),
        const SizedBox(height: VboxSpacing.sm),
        _switchRow(
          key: 'pg_auto_auto_cleanup',
          title: '转存后自动清理',
          subtitle: '播放结束后按延迟删除转存文件',
          value: _config.autoCleanup,
          onChanged: (bool v) => _update(_config.copyWith(autoCleanup: v)),
        ),
        const SizedBox(height: VboxSpacing.sm),
        _stepperRow(
          scheme,
          key: 'pg_auto_cleanup_delay_stepper',
          label: '清理延迟',
          value: _config.cleanupDelaySeconds,
          min: _delayMin,
          max: _delayMax,
          step: _delayStep,
          unit: 's',
          onChanged: (int v) =>
              _update(_config.copyWith(cleanupDelaySeconds: v)),
        ),
        const SizedBox(height: VboxSpacing.sm),
        _textRow(
          scheme,
          key: 'pg_auto_proxy_port',
          label: '代理端口',
          controller: _proxyPortCtrl,
          hint: '58090',
          numeric: true,
        ),
      ],
    );
  }

  /// 「当前生效」卡（验收项「规则生效」的可视化）。
  Widget _effectiveCard(ColorScheme scheme) {
    final DateTime now = widget.now ?? DateTime.now();
    final int threads = PgAutoRules.currentThreadLimit(_config, now: now);
    final String quality = PgAutoRules.vodQuality(_config).displayName;
    final String dir = PgAutoRules.resolvedTransferDir(_config);
    final bool cleanup = PgAutoRules.shouldScheduleCleanup(_config);
    final int delay = PgAutoRules.cleanupDelay(_config).inSeconds;
    return _panel(
      scheme,
      children: <Widget>[
        _sectionLabel(scheme, '当前生效', Icons.bolt),
        const SizedBox(height: VboxSpacing.md),
        _effectiveLine(scheme, '线程', '$threads 线程'),
        _effectiveLine(scheme, '画质', quality),
        _effectiveLine(scheme, '转存目录', dir),
        _effectiveLine(
          scheme,
          '清理',
          cleanup ? '$delay 秒后清理' : '不自动清理',
        ),
        _effectiveLine(scheme, '代理地址', PgAutoRules.proxyUrl(_config)),
      ],
    );
  }

  /// 保存按钮（对齐 iOS「保存参数」+「PG 播放参数已更新」）。
  Widget _saveButton(ColorScheme scheme) {
    return Material(
      color: scheme.primary,
      borderRadius: BorderRadius.circular(VboxRadii.r10),
      child: InkWell(
        key: const ValueKey<String>('pg_auto_save'),
        borderRadius: BorderRadius.circular(VboxRadii.r10),
        onTap: _save,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text(
              '保存参数',
              style: TextStyle(
                fontSize: VboxTypography.s14,
                fontWeight: FontWeight.w600,
                color: scheme.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 组件 ────────────────────────────────────────────────

  Widget _panel(ColorScheme scheme, {required List<Widget> children}) {
    return Container(
      padding: const EdgeInsets.all(VboxSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VboxRadii.r12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _sectionLabel(ColorScheme scheme, String text, IconData icon) {
    return Row(
      children: <Widget>[
        Icon(icon, size: VboxTypography.s16, color: VboxColors.selected),
        const SizedBox(width: VboxSpacing.sm),
        Text(
          text,
          style: TextStyle(
            fontSize: VboxTypography.s14,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }

  Widget _switchRow({
    required String key,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  fontSize: VboxTypography.s14,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: VboxTypography.s11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Switch(
          key: ValueKey<String>(key),
          value: value,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _stepperRow(
    ColorScheme scheme, {
    required String key,
    required String label,
    required int value,
    required int min,
    required int max,
    required int step,
    String unit = '',
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: VboxTypography.s14,
              color: scheme.onSurface,
            ),
          ),
        ),
        _stepButton(
          key: '${key}_minus',
          icon: Icons.remove,
          enabled: value > min,
          onTap: () => onChanged((value - step).clamp(min, max)),
        ),
        SizedBox(
          width: 56,
          child: Center(
            child: Text(
              '$value$unit',
              key: ValueKey<String>('${key}_value'),
              style: TextStyle(
                fontSize: VboxTypography.s14,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
        ),
        _stepButton(
          key: '${key}_plus',
          icon: Icons.add,
          enabled: value < max,
          onTap: () => onChanged((value + step).clamp(min, max)),
        ),
      ],
    );
  }

  Widget _stepButton({
    required String key,
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(VboxRadii.r8),
      child: InkWell(
        key: ValueKey<String>(key),
        borderRadius: BorderRadius.circular(VboxRadii.r8),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: VboxTypography.s16,
            color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _qualityRow(ColorScheme scheme) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '画质',
            style: TextStyle(
              fontSize: VboxTypography.s14,
              color: scheme.onSurface,
            ),
          ),
        ),
        DropdownButton<PgVodQuality>(
          key: const ValueKey<String>('pg_auto_quality'),
          value: PgAutoRules.vodQuality(_config),
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(VboxRadii.r10),
          onChanged: (PgVodQuality? q) {
            if (q == null) return;
            _update(_config.copyWith(vodFlags: q.id));
          },
          items: <DropdownMenuItem<PgVodQuality>>[
            for (final PgVodQuality q in PgVodQuality.values)
              DropdownMenuItem<PgVodQuality>(
                value: q,
                child: Text(
                  q.displayName,
                  style: TextStyle(
                    fontSize: VboxTypography.s14,
                    color: scheme.onSurface,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _textRow(
    ColorScheme scheme, {
    required String key,
    required String label,
    required TextEditingController controller,
    required String hint,
    bool numeric = false,
  }) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: VboxTypography.s14,
              color: scheme.onSurface,
            ),
          ),
        ),
        SizedBox(
          width: 180,
          child: TextField(
            key: ValueKey<String>(key),
            controller: controller,
            textAlign: TextAlign.right,
            keyboardType: numeric ? TextInputType.number : TextInputType.text,
            inputFormatters: numeric
                ? <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly]
                : null,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              color: scheme.onSurface,
            ),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(
                fontSize: VboxTypography.s13,
                color: scheme.onSurfaceVariant,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(VboxRadii.r8),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: VboxSpacing.sm,
                vertical: VboxSpacing.sm,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _effectiveLine(ColorScheme scheme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VboxSpacing.xs),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
