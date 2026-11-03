/// 单一页树 + 全端统一底栏（批次 A · A-08 / A8）。
///
/// 唯一真相源：iOS `ContentView.swift` L50-L57（`visibleTabs`）·
/// L94-L133（悬浮胶囊底栏）· L256-L278（四皮肤底栏配色）；决策 2026-10-03（§1.5(1)）。
///
/// 收敛口径（A8）：
///   · 导航项**枚举单源** [AppTab]（基础 4 项 `[首页,短剧,直播,我的]`
///     + 福利按需插入 index 3，最多 5）；
///   · 内容区由 [AppTab] **枚举派生**（不是下标），福利 Tab 增删不漂移错位（解 D15）；
///   · 全端（Android / Android TV / Windows / macOS）统一底部悬浮胶囊 TabBar（解 D18）；
///   · 底栏显隐受 [WelfareController.tabVisible]（门控）与 `tabBarHidden` 控制。
///
/// 输入模态只加**反馈层**（遥控 → D-pad 焦点遍历，T.7），不改版式（§3.4）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../pages/pages.dart';
import '../theme/tokens/colors.dart';
import '../theme/vbox_skin_controller.dart';
import '../ui_mode/ui_mode.dart';
import '../welfare/welfare_controller.dart';
import '../widgets/adaptive/adaptive.dart';
import '../widgets/download/download_overlay_widgets.dart';
import '../widgets/input/input.dart';
import '../widgets/music/mini_player.dart';
import '../widgets/remote_source/remote_source_status_bar.dart';
import 'app_tab.dart';

/// 首页外壳：单一页树，全端统一底部悬浮胶囊 TabBar。
class HomeShellPage extends StatefulWidget {
  /// 构造。
  const HomeShellPage({super.key});

  @override
  State<HomeShellPage> createState() => _HomeShellPageState();
}

class _HomeShellPageState extends State<HomeShellPage> {
  /// 当前选中 Tab（**枚举**驱动，非下标）。
  AppTab _tab = AppTab.home;

  /// 内容区：由 [AppTab] 枚举派生（福利 Tab 增删不影响映射）。
  Widget _contentFor(AppTab tab) => switch (tab) {
        AppTab.home => const VboxHomePage(),
        AppTab.shortDrama => const ShortDramaPage(),
        AppTab.live => const LiveTVPage(),
        AppTab.welfare => const WelfareGatePage(),
        AppTab.profile => const ProfilePage(),
      };

  @override
  Widget build(BuildContext context) {
    final UiFormController uiForm = context.watch<UiFormController>();
    final WelfareController welfare = context.watch<WelfareController>();
    final VboxSkinController skin = context.watch<VboxSkinController>();
    final ThemeData theme = Theme.of(context);
    final MediaQueryData mq = MediaQuery.of(context);
    final UiForm form = uiForm.resolveAt(
      size: mq.size,
      orientation: mq.orientation,
    );

    // 动态可见 Tab：基础 4 项 + 福利按需插入 index 3（对齐 iOS `visibleTabs`）。
    final List<AppTab> tabs =
        AppTab.visibleTabs(welfareVisible: welfare.tabVisible);
    // 当前 Tab 因门控被裁剪时回退首页，避免选中下标漂移错位。
    final AppTab current = tabs.contains(_tab) ? _tab : AppTab.home;

    final Widget shell = AdaptiveScaffold(
      form: form,
      items: tabs.map((AppTab tab) => tab.toNavItem()).toList(),
      selectedIndex: tabs.indexOf(current),
      onSelected: (int index) => setState(() => _tab = tabs[index]),
      hideTabBar: welfare.tabBarHidden,
      tabBarPalette:
          VboxTabBarPalette.resolve(skin.skin, theme.brightness),
      body: _contentFor(current),
    );

    // 输入模态反馈层（§3.4）：不改版式。
    //   · 遥控 → D-pad 焦点遍历（T.7）+ 十英尺缩放（§3.3，1.35× 文案档位）
    //   · 触摸 / 鼠标键盘 → 无额外包裹（hover / 快捷键由页面按需用 input/ 层）
    final Widget base = uiForm.modality == InputModality.remote
        ? TenFootScaler(
            child: FocusTraversalGroup(
              policy: WidgetOrderTraversalPolicy(),
              child: Focus(autofocus: true, child: shell),
            ),
          )
        : shell;

    // 下载 overlay（G-02 UI，对齐 iOS ContentView L91/L217-L227）：
    //   ① 全局胶囊通知（底部居中，5s 自动消失）
    //   ② 悬浮下载按键（有记录时显示；点击打开管理弹窗）
    // 音乐 MiniPlayer 全局浮层（G-音2，对齐 iOS ContentView L140-L143）：
    //   有播放队列时底部居中常驻；点击主体展开全屏播放器。
    //
    // 布局加固（桌面端「启动后看不到底栏、最大化后才出现」的根因防御）：
    // RenderStack 的尺寸只由**非定位子项**决定；若存在一个会收缩为 0 的非定位
    // 子项（悬浮下载按键在无记录时返回 SizedBox.shrink），一旦父级下发松约束，
    // 整个 Stack 就会塌缩为 0×0 → 底栏随外壳一起消失。这里把所有子项统一为
    // Positioned，使 Stack 退化为「无非定位子项」分支（取 constraints.biggest），
    // 无论父级给紧约束还是松约束都能铺满，不再依赖上游的约束形态。
    return Stack(
      children: <Widget>[
        Positioned.fill(child: base),
        const Positioned.fill(
          child: DownloadCapsuleNotification(),
        ),
        // 远程源加载状态胶囊（UI-D1，对齐 iOS ContentView L88-L91 的
        // `RemoteSourceStatusBar`，位于底栏正上方）。订阅 `RemoteSourceConfigManager
        // .shared.loadState`，由启动同步 / 手动刷新驱动显隐。
        const Positioned.fill(
          child: RemoteSourceStatusBar(),
        ),
        Positioned.fill(
          child: MiniPlayerBar(
            onExpand: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const MusicPlayerPage(),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: FloatingVideoDownloadButton(
            onTap: () => showDownloadManagementPopup(context),
          ),
        ),
      ],
    );
  }
}