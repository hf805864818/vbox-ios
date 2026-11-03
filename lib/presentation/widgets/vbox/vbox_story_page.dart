/// 统一组件库 · Story 页（批次 A · A-04 验收项）。
///
/// 唯一真相源：`docs/第2轮细分实施WBS_v1.6.md` A-04「组件 Story 页 + 单测；
/// 规格对齐 UI 基准」。
///
/// 用途：**组件总览画廊**（living style guide）——一页陈列全部 A-04 组件的
/// 代表形态，供：
///   1. 视觉核对（对照 `docs/ui_baseline/01_tokens.png` 规格图）；
///   2. Golden 基线（本页已入 `test/golden`，令牌/规格漂移当场像素失败）；
///   3. 后续页面开发的组件选型参考。
///
/// 注：仅开发/验收用，不接入路由（真机验收走 Golden + 单测）。
library;

import 'package:flutter/material.dart';

import '../../theme/brand.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import 'vbox.dart';

/// 组件 Story 页（全组件画廊）。
class VboxStoryPage extends StatelessWidget {
  /// 构造。
  const VboxStoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const VboxStoryView();
  }
}

class VboxStoryView extends StatelessWidget {
  const VboxStoryView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('组件 Story · A-04')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _section('品牌（A-13）', _brand()),
          _section('按钮 Button', _buttons()),
          _section('卡片 Card', _cards()),
          _section('胶囊 Chip / 剧集 EpisodeChip', _chips()),
          _section('区块标题 SectionHeader', const _SectionHeaders()),
          _section('源角标 SourceBadge', _badges()),
          _section('海报卡 PosterCard', _posters()),
          _section('导航 BottomNav（Rail 已弃用 · A8）', const _NavDemo()),
          _section('开关 Switch（A4）', const _SwitchDemo()),
          _section('设置分组 SettingsSection（B3）', const _SettingsDemo()),
          _section('皮肤选择 SkinPicker（B4）', const _SkinPickerDemo()),
          _section('登录弹窗 LoginSheet（B5）', const _LoginDemo()),
          _section('福利分段 + 平台网格（B6）', const _WelfareDemo()),
          _section('浮层 Dialog / Toast', const _OverlayDemo()),
        ],
      ),
    );
  }

  Widget _section(String title, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          VboxSectionHeader(title: title),
          const SizedBox(height: 8),
          child,
          const SizedBox(height: 24),
        ],
      );

  Widget _brand() => const Row(
        children: <Widget>[
          _BrandMark(),
          SizedBox(width: 12),
          Text(
            VboxBrand.wordmark,
            style: TextStyle(
              fontFamily: VboxBrand.fontFamily,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
        ],
      );

  Widget _buttons() => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          const VboxButton(label: '主要'),
          VboxButton(
            label: '次要',
            kind: VboxButtonKind.secondary,
            onPressed: () {},
          ),
          VboxButton(
            label: '危险',
            kind: VboxButtonKind.danger,
            onPressed: () {},
          ),
        ],
      );

  Widget _cards() => const Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          SizedBox(
            width: 200,
            child: VboxCard(child: Text('大卡片 · 圆角 20（面板/主角）')),
          ),
          SizedBox(
            width: 200,
            child: VboxCard(
              radius: VboxRadii.r10,
              child: Text('中卡片 · 圆角 10（分组列表）'),
            ),
          ),
        ],
      );

  Widget _chips() => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          VboxChip(label: '电影', onTap: () {}),
          const VboxChip(label: '剧集'),
          const VboxEpisodeChip(label: '01'),
          const VboxEpisodeChip(label: '02', selected: true),
        ],
      );

  Widget _badges() => const Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          VboxSourceBadge.category(label: 'app', category: VboxCategory.app),
          VboxSourceBadge.category(label: 'spider', category: VboxCategory.spider),
          VboxSourceBadge.category(label: 'player', category: VboxCategory.player),
          VboxSourceBadge.category(label: 'cloud', category: VboxCategory.cloud),
          VboxSourceBadge.category(label: 'proxy', category: VboxCategory.proxy),
          VboxSourceBadge.category(label: 'network', category: VboxCategory.network),
          VboxSourceBadge.category(label: 'db', category: VboxCategory.db),
          VboxSourceBadge.category(label: 'download', category: VboxCategory.download),
        ],
      );

  Widget _posters() => SizedBox(
        height: 240,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: const <Widget>[
            VboxPosterCard(title: '示例剧集', subtitle: '2026 · 全 12 集'),
            VboxPosterCard(
              title: '带评分',
              subtitle: '2025',
              rating: '8.9',
            ),
            VboxPosterCard(title: '占位封面', subtitle: '2024'),
          ],
        ),
      );
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      VboxBrand.splashLogoAsset,
      width: 56,
      height: 56,
      errorBuilder: (BuildContext context, Object e, StackTrace? s) =>
          const SizedBox(width: 56, height: 56),
    );
  }
}

class _SectionHeaders extends StatelessWidget {
  const _SectionHeaders();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        VboxSectionHeader(title: '影院热映'),
        SizedBox(height: 8),
        VboxSectionHeader(title: '即将上映', subtitle: '本周上新'),
      ],
    );
  }
}

class _NavDemo extends StatelessWidget {
  const _NavDemo();

  @override
  Widget build(BuildContext context) {
    const List<VboxNavItem> items = <VboxNavItem>[
      VboxNavItem(icon: Icons.home_outlined, label: '首页'),
      VboxNavItem(icon: Icons.search, label: '搜索'),
      VboxNavItem(icon: Icons.video_library_outlined, label: '书架'),
    ];
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(height: 72, child: _BottomNavDemo(items: items)),
        SizedBox(height: 12),
        Text('NavRail：A8 决策后已弃用（全端统一底部胶囊底栏），仅存档参考'),
        SizedBox(height: 8),
        SizedBox(
          height: 200,
          child: _RailDemo(items: items),
        ),
      ],
    );
  }
}

class _BottomNavDemo extends StatefulWidget {
  const _BottomNavDemo({required this.items});

  final List<VboxNavItem> items;

  @override
  State<_BottomNavDemo> createState() => _BottomNavDemoState();
}

class _BottomNavDemoState extends State<_BottomNavDemo> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return VboxBottomNav(
      items: widget.items,
      selectedIndex: _index,
      onSelected: (int i) => setState(() => _index = i),
    );
  }
}

class _RailDemo extends StatefulWidget {
  const _RailDemo({required this.items});

  final List<VboxNavItem> items;

  @override
  State<_RailDemo> createState() => _RailDemoState();
}

class _RailDemoState extends State<_RailDemo> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return VboxNavRail(
      items: widget.items,
      selectedIndex: _index,
      onSelected: (int i) => setState(() => _index = i),
    );
  }
}

class _OverlayDemo extends StatelessWidget {
  const _OverlayDemo();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: <Widget>[
        VboxButton(
          label: '打开 Dialog',
          onPressed: () => VboxDialog.show(
            context,
            title: '示例弹窗',
            child: const Text('VboxDialog · 居中卡片（圆角 14）'),
          ),
        ),
        VboxButton(
          label: '弹 Toast',
          onPressed: () => VboxToast.show(context, '已加入收藏'),
        ),
      ],
    );
  }
}

/// 开关两态（批次 A · A4 验收：开关开 / 关两态）。
///
/// `onChanged` 传非空回调以保持「启用」配色（`onChanged: null` 会进入禁用灰态，
/// 无法展示 A4 定义的主色轨道）。「禁用」一项故意传 `null`，供对照。
class _SwitchDemo extends StatelessWidget {
  const _SwitchDemo();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Text('开'),
        Switch(value: true, onChanged: (bool _) {}),
        const SizedBox(width: 24),
        const Text('关'),
        Switch(value: false, onChanged: (bool _) {}),
        const SizedBox(width: 24),
        const Text('禁用'),
        const Switch(value: true, onChanged: null),
      ],
    );
  }
}

/// 设置分组三行型（批次 B · B3 验收：开关 / 箭头 / 输入）。
class _SettingsDemo extends StatefulWidget {
  const _SettingsDemo();

  @override
  State<_SettingsDemo> createState() => _SettingsDemoState();
}

class _SettingsDemoState extends State<_SettingsDemo> {
  bool _danmaku = true;
  final TextEditingController _url =
      TextEditingController(text: 'https://your-danmu-api.com');

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VboxSettingsSection(
      title: '播放设置',
      children: <Widget>[
        VboxSettingsRow.toggle(
          title: '自定义弹幕源',
          subtitle: _danmaku ? '已开启 — 使用自定义弹幕API地址' : '关闭 — 使用默认弹幕源',
          icon: Icons.forum_rounded,
          iconColor: VboxColors.selected,
          value: _danmaku,
          onChanged: (bool value) => setState(() => _danmaku = value),
        ),
        if (_danmaku)
          VboxSettingsInputRow(
            controller: _url,
            hint: 'https://your-danmu-api.com',
          ),
        VboxSettingsRow.navigation(
          title: '缓存管理',
          subtitle: '256 MB',
          icon: Icons.folder_rounded,
          onTap: () => VboxToast.show(context, '示例：进入缓存管理'),
        ),
      ],
    );
  }
}

/// 皮肤四选（批次 B · B4 验收：四皮肤各一张或四态合一）。
class _SkinPickerDemo extends StatefulWidget {
  const _SkinPickerDemo();

  @override
  State<_SkinPickerDemo> createState() => _SkinPickerDemoState();
}

class _SkinPickerDemoState extends State<_SkinPickerDemo> {
  VboxSkin _skin = VboxSkin.light;

  @override
  Widget build(BuildContext context) {
    return VboxSkinPicker(
      selected: _skin,
      onSelected: (VboxSkin skin) => setState(() => _skin = skin),
    );
  }
}

/// 登录弹窗（批次 B · B5 验收：空态禁用 + 填写态）。
class _LoginDemo extends StatefulWidget {
  const _LoginDemo();

  @override
  State<_LoginDemo> createState() => _LoginDemoState();
}

class _LoginDemoState extends State<_LoginDemo> {
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pwd = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pwd.dispose();
    super.dispose();
  }

  void _submit() {
    if (_pwd.text.isEmpty) {
      setState(() => _error = '请输入密码');
      return;
    }
    setState(() => _error = null);
    VboxToast.show(context, '示例：登录 ${_user.text.trim()}');
  }

  @override
  Widget build(BuildContext context) {
    return VboxLoginSheet(
      usernameController: _user,
      passwordController: _pwd,
      error: _error,
      onSubmit: _submit,
      onCancel: () => VboxToast.show(context, '示例：取消登录'),
    );
  }
}

/// 福利分段 + 平台网格（批次 B · B6 验收：三栏目切换 + 4 列网格）。
class _WelfareDemo extends StatefulWidget {
  const _WelfareDemo();

  @override
  State<_WelfareDemo> createState() => _WelfareDemoState();
}

class _WelfareDemoState extends State<_WelfareDemo> {
  VboxWelfareCategory _category = VboxWelfareCategory.live;

  static const List<VboxWelfarePlatform> _platforms = <VboxWelfarePlatform>[
    VboxWelfarePlatform(name: '熊猫直播', icon: Icons.live_tv_rounded),
    VboxWelfarePlatform(name: '哔哩直播', icon: Icons.play_circle_fill_rounded),
    VboxWelfarePlatform(name: '酷狗直播', icon: Icons.music_note_rounded),
    VboxWelfarePlatform(name: '斗鱼直播', icon: Icons.videogame_asset_rounded),
    VboxWelfarePlatform(name: '虎牙直播', icon: Icons.sports_esports_rounded),
    VboxWelfarePlatform(name: '抖音直播', icon: Icons.music_video_rounded),
    VboxWelfarePlatform(name: '快手直播', icon: Icons.video_camera_back_rounded),
    VboxWelfarePlatform(name: '体育直播', icon: Icons.sports_basketball_rounded),
    VboxWelfarePlatform(name: '影视直播', icon: Icons.movie_rounded),
    VboxWelfarePlatform(name: '音乐直播', icon: Icons.album_rounded),
    VboxWelfarePlatform(name: '央视直播', icon: Icons.tv_rounded),
    VboxWelfarePlatform(name: '电台直播', icon: Icons.radio_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        VboxWelfareTabs(
          selected: _category,
          onSelected: (VboxWelfareCategory c) => setState(() => _category = c),
        ),
        const SizedBox(height: VboxSpacing.lg),
        VboxWelfarePlatformGrid(
          platforms: _platforms,
          onTap: (VboxWelfarePlatform p) =>
              VboxToast.show(context, '示例：进入 ${p.name}'),
        ),
      ],
    );
  }
}