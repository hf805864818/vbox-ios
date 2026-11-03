/// 表现层：Emby 媒体服务器配置卡片（批次 C）。
///
/// 唯一真相源：iOS `vbox/Views/SettingsViews.swift` 的 `embyAccountCard`
/// （L2111-L2228）+ 状态与业务方法（L1590-L1598 / L2230-L2384）：
///   · 卡片位于「网盘账号授权」页 Node 托管网盘组之后、手动 Token 兜底卡之前；
///   · 服务器下拉（「— 新增服务器 —」+ `N. 名称（默认）`）+「新增」按钮；
///   · 表单四字段：服务器名称 / 服务器地址（如 http://192.168.1.10:8096）/
///     用户名 / 密码（密文）；
///   · 按钮：保存服务器 / 测试登录（实心主色）· 设为默认 / 删除服务器（浅色）；
///   · 消息行含「失败」标红，否则标绿；
///   · 保存：编辑保留原 `choose`；新增且列表无默认时自动成为默认；
///   · 删除前先同步 Node 最新列表防序号错位；删除后无默认回退第一个；
///   · 测试登录走当前选中（编辑项优先，否则默认项）。
///
/// 数据经 [EmbyConfigClient]（Node 五接口）读写，与本卡片 1:1 对齐。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/datasources/remote/emby_config_client.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/typography.dart';

/// Emby 媒体服务器配置卡片（对齐 iOS `embyAccountCard`）。
class EmbyAccountCard extends StatefulWidget {
  /// 构造（[client] 供测试注入；缺省自建 Node 客户端）。
  const EmbyAccountCard({super.key, EmbyConfigClient? client})
      : _client = client;

  final EmbyConfigClient? _client;

  @override
  State<EmbyAccountCard> createState() => _EmbyAccountCardState();
}

class _EmbyAccountCardState extends State<EmbyAccountCard> {
  late final EmbyConfigClient _client =
      widget._client ?? EmbyConfigClient();

  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pass = TextEditingController();

  List<EmbyServerItem> _servers = const <EmbyServerItem>[];
  int _editingIndex = -1;
  bool _busy = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  // ── 派生态（对齐 iOS computed property）─────────────────────────────

  /// 默认项索引（第一个 choose==1；空列表 -1，否则回退 0）。
  int get _defaultIndex {
    final int found =
        _servers.indexWhere((EmbyServerItem s) => s.choose == 1);
    return found >= 0 ? found : (_servers.isEmpty ? -1 : 0);
  }

  /// 当前生效索引（编辑项优先，否则默认项；对齐 iOS `embySelectedIndex`）。
  int get _selectedIndex => _editingIndex >= 0 ? _editingIndex : _defaultIndex;

  // ── 业务方法（对齐 iOS L2245-L2384）─────────────────────────────────

  Future<void> _loadServers() async {
    try {
      final List<EmbyServerItem> servers = await _client.fetchServers();
      if (!mounted) return;
      setState(() {
        _servers = servers;
        if (_editingIndex >= servers.length) _editingIndex = -1;
      });
    } on EmbyConfigException catch (e) {
      if (!mounted) return;
      setState(() {
        _message = '读取服务器失败：${e.message}';
      });
    }
  }

  /// 下拉选择 → 填充表单（对齐 iOS `selectEmbyServer` / onChange）。
  void _onSelect(int? index) {
    final int newIndex = index ?? -1;
    setState(() {
      _editingIndex = newIndex;
      if (newIndex >= 0 && newIndex < _servers.length) {
        final EmbyServerItem item = _servers[newIndex];
        _name.text = item.servername;
        _url.text = item.serverurl;
        _user.text = item.username;
        _pass.text = item.password;
        _message = '';
      } else {
        _name.clear();
        _url.clear();
        _user.clear();
        _pass.clear();
      }
    });
  }

  /// 「新增」→ 清空表单进入新增态（对齐 iOS `startNewEmbyServer`）。
  void _startNew() {
    setState(() {
      _editingIndex = -1;
      _name.clear();
      _url.clear();
      _user.clear();
      _pass.clear();
      _message = '';
    });
  }

  Future<void> _save() async {
    final String name = _name.text.trim();
    final String url = _url.text.trim();
    final String user = _user.text.trim();
    if (name.isEmpty) {
      setState(() => _message = '请填写服务器名称');
      return;
    }
    if (url.isEmpty) {
      setState(() => _message = '请填写服务器地址');
      return;
    }
    if (user.isEmpty) {
      setState(() => _message = '请填写用户名');
      return;
    }
    final List<EmbyServerItem> list = List<EmbyServerItem>.of(_servers);
    final bool editing =
        _editingIndex >= 0 && _editingIndex < list.length;
    // 编辑保留原 choose；新增且列表无默认时自动成为默认（对齐 iOS keepChoose）。
    final int keepChoose = editing
        ? list[_editingIndex].choose
        : (list.any((EmbyServerItem s) => s.choose == 1) ? 0 : 1);
    final EmbyServerItem item = EmbyServerItem(
      servername: name,
      serverurl: url,
      username: user,
      password: _pass.text,
      choose: keepChoose,
    );
    setState(() => _busy = true);
    try {
      if (editing) {
        list[_editingIndex] = item;
      } else {
        list.add(item);
        _editingIndex = list.length - 1;
      }
      await _client.saveServers(list);
      if (!mounted) return;
      setState(() {
        _servers = list;
        _message = '服务器已保存';
      });
    } on EmbyConfigException catch (e) {
      if (!mounted) return;
      setState(() => _message = '保存失败：${e.message}');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _test() async {
    if (_servers.isEmpty) {
      setState(() => _message = '还没有配置 Emby 服务器');
      return;
    }
    final int index = _selectedIndex;
    if (index < 0 || index >= _servers.length) {
      setState(() => _message = '服务器序号无效');
      return;
    }
    setState(() => _busy = true);
    try {
      await _client.test(index);
      if (!mounted) return;
      setState(() => _message = '登录测试成功：${_servers[index].servername}');
    } on EmbyConfigException catch (e) {
      if (!mounted) return;
      setState(() => _message = '测试失败：${e.message}');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _chooseDefault() async {
    if (_editingIndex < 0 || _editingIndex >= _servers.length) {
      setState(() => _message = '请先选择要设为默认的服务器');
      return;
    }
    setState(() => _busy = true);
    try {
      await _client.setDefault(_editingIndex);
      if (!mounted) return;
      setState(() {
        _servers = <EmbyServerItem>[
          for (int i = 0; i < _servers.length; i++)
            _servers[i].copyWith(choose: i == _editingIndex ? 1 : 0),
        ];
        _message = '已设为默认服务器';
      });
    } on EmbyConfigException catch (e) {
      if (!mounted) return;
      setState(() => _message = '设置失败：${e.message}');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    try {
      // 删除前先同步 Node 端最新列表，避免本地序号与 Node 数据错位导致删除失败
      // （对齐 iOS deleteEmbyServer）。
      final List<EmbyServerItem> latest = await _client.fetchServers();
      if (!mounted) return;
      setState(() {
        _servers = latest;
        if (_editingIndex >= latest.length) _editingIndex = -1;
      });
      if (latest.isEmpty) {
        setState(() {
          _message = '还没有配置 Emby 服务器';
          _busy = false;
        });
        return;
      }
      final int index = _selectedIndex;
      if (index < 0 || index >= latest.length) {
        setState(() {
          _message = '服务器序号无效（本地与 Node 数据不同步，请重试）';
          _busy = false;
        });
        return;
      }
      await _client.delete(index);
      final List<EmbyServerItem> list = List<EmbyServerItem>.of(latest)
        ..removeAt(index);
      if (_editingIndex == index) {
        _editingIndex = -1;
      } else if (_editingIndex > index) {
        _editingIndex -= 1;
      }
      // 与 Node 端保持一致：若无默认服务器则回退为第一个。
      if (list.isNotEmpty && !list.any((EmbyServerItem s) => s.choose == 1)) {
        list[0] = list[0].copyWith(choose: 1);
      }
      if (!mounted) return;
      setState(() {
        _servers = list;
        _message = '服务器已删除';
      });
    } on EmbyConfigException catch (e) {
      if (!mounted) return;
      setState(() => _message = '删除失败：${e.message}');
    }
    if (mounted) setState(() => _busy = false);
  }

  // ── UI（对齐 iOS embyAccountCard L2111-L2228）───────────────────────

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const Color primary = VboxColors.detailSelected;
    final bool ready = _servers.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VboxRadii.r14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: <Widget>[
          _header(scheme, primary, ready),
          _serverPicker(scheme, primary),
          _field(_name, '服务器名称', scheme),
          _field(
            _url,
            '服务器地址（如 http://192.168.1.10:8096）',
            scheme,
            keyboardType: TextInputType.url,
          ),
          _field(_user, '用户名', scheme, keyboardType: TextInputType.text),
          _field(_pass, '密码', scheme, obscure: true),
          Row(
            spacing: 10,
            children: <Widget>[
              Expanded(
                child: _solidButton('保存服务器', primary, onTap: _save),
              ),
              Expanded(
                child: _solidButton('测试登录', primary, onTap: _test),
              ),
            ],
          ),
          Row(
            spacing: 10,
            children: <Widget>[
              Expanded(
                child: _tintButton(
                  '设为默认',
                  primary,
                  onTap: (_busy || _servers.isEmpty || _editingIndex < 0)
                      ? null
                      : _chooseDefault,
                ),
              ),
              Expanded(
                child: _tintButton(
                  '删除服务器',
                  VboxColors.danger,
                  onTap: (_busy || _servers.isEmpty) ? null : _delete,
                ),
              ),
            ],
          ),
          if (_message.isNotEmpty)
            Text(
              _message,
              style: TextStyle(
                fontSize: VboxTypography.s12,
                color: _message.contains('失败')
                    ? VboxColors.danger
                    : VboxColors.success,
              ),
            ),
        ],
      ),
    );
  }

  /// 卡片头（对齐 iOS `accountHeader`：图标 + 标题 + 副标题 + 状态徽标）。
  Widget _header(ColorScheme scheme, Color primary, bool ready) {
    return Row(
      spacing: 12,
      children: <Widget>[
        Icon(
          Icons.dns,
          size: 22,
          color: ready ? primary : scheme.onSurfaceVariant,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Emby媒体服务器',
                style: TextStyle(
                  fontSize: VboxTypography.s16,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                _servers.isEmpty
                    ? '未配置服务器'
                    : '已配置 ${_servers.length} 个 · 当前：$_currentName',
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        _badge(scheme, ready),
      ],
    );
  }

  String get _currentName =>
      _servers.isEmpty ? '未配置' : _servers[_defaultIndex.clamp(0, _servers.length - 1)].servername;

  Widget _badge(ColorScheme scheme, bool ready) {
    final Color color = ready ? VboxColors.success : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        ready ? '已获取' : '未获取',
        style: TextStyle(
          fontSize: VboxTypography.s12,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }

  /// 服务器下拉 + 「新增」按钮（对齐 iOS Picker(.menu) + 新增按钮）。
  Widget _serverPicker(ColorScheme scheme, Color primary) {
    return Row(
      spacing: 8,
      children: <Widget>[
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _editingIndex,
                isExpanded: true,
                icon: Icon(Icons.expand_more,
                    size: 18, color: scheme.onSurfaceVariant),
                dropdownColor: scheme.surface,
                items: <DropdownMenuItem<int>>[
                  const DropdownMenuItem<int>(
                    value: -1,
                    child: Text(
                      '— 新增服务器 —',
                      style: TextStyle(fontSize: VboxTypography.s13),
                    ),
                  ),
                  for (int i = 0; i < _servers.length; i++)
                    DropdownMenuItem<int>(
                      value: i,
                      child: Text(
                        '${i + 1}. ${_servers[i].servername}'
                        '${_servers[i].choose == 1 ? '（默认）' : ''}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: VboxTypography.s13),
                      ),
                    ),
                ],
                onChanged: _onSelect,
              ),
            ),
          ),
        ),
        GestureDetector(
          onTap: _busy ? null : _startNew,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '新增',
              style: TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w500,
                color: primary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String hint,
    ColorScheme scheme, {
    bool obscure = false,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      inputFormatters: keyboardType == null
          ? null
          : <TextInputFormatter>[FilteringTextInputFormatter.singleLineFormatter],
      style: TextStyle(fontSize: VboxTypography.s13, color: scheme.onSurface),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: VboxTypography.s13,
          color: scheme.onSurfaceVariant,
        ),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        filled: true,
        fillColor: scheme.surface,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: VboxColors.detailSelected),
        ),
      ),
    );
  }

  Widget _solidButton(String label, Color primary, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: _busy ? Colors.grey : primary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: VboxTypography.s13,
            fontWeight: FontWeight.w500,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _tintButton(String label, Color color, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: color.withValues(alpha: onTap == null ? 0.04 : 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: VboxTypography.s13,
            fontWeight: FontWeight.w500,
            color: onTap == null ? Colors.grey : color,
          ),
        ),
      ),
    );
  }
}
