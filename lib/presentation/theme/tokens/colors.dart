/// 设计令牌 · 颜色（批次 A · A-01）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.1（皮肤系统）/ §2.2（颜色令牌）。
/// 全部十六进制字面量**只允许**出现在本文件（UI 守卫 R-4）。
///
/// 对齐口径：iOS 侧没有集中式设计令牌文件，颜色以「视图私有计算属性 +
/// `Color(hex:)` 字面量」散落存在；本文件把采样结果**归纳固化**为 Flutter 令牌层。
library;

import 'package:flutter/material.dart';

/// 皮肤枚举（契约键 `app_skin_mode`，默认 `light`）。
///
/// 对齐 iOS `AppSkinMode`（[AppSettings.swift](../../../vbox/App/AppSettings.swift)）：
/// `dark` / `light` 共用同一主色 `#E11D48`，差异只在 `ColorScheme` 明暗；
/// `frosted` / `liquid` 各有独立主色。
enum VboxSkin {
  /// 浅色模式（强制 Light）。
  light('light', '浅色模式', Brightness.light),

  /// 黑暗模式（强制 Dark）。
  dark('dark', '黑暗模式', Brightness.dark),

  /// 磨砂模式（跟随系统，主色紫）。
  frosted('frosted', '磨砂模式', null),

  /// 液态模式（强制 Dark，主色天蓝）。
  liquid('liquid', '液态模式', Brightness.dark);

  const VboxSkin(this.id, this.title, this.fixedBrightness);

  /// 契约字符串值（写入 `app_skin_mode`）。
  final String id;

  /// 中文显示名（对齐 iOS `AppSkinMode.title`）。
  final String title;

  /// 该皮肤固定的配色模式；`null` = 跟随系统。
  ///
  /// 对齐 iOS `AppSkinMode.preferredColorScheme`：
  /// `dark`/`liquid` → dark，`light` → light，`frosted` → nil。
  final Brightness? fixedBrightness;

  /// 契约默认皮肤（`app_skin_mode` 默认 `light`）。
  static const VboxSkin fallback = VboxSkin.light;

  /// 解析契约字符串（未知值回退 [fallback]）。
  static VboxSkin fromId(String? id) {
    for (final VboxSkin skin in VboxSkin.values) {
      if (skin.id == id) return skin;
    }
    return fallback;
  }

  /// 皮肤主色（对齐 UI 基准 §2.1）。
  Color get primary => switch (this) {
        VboxSkin.light || VboxSkin.dark => VboxColors.skinPrimaryRose,
        VboxSkin.frosted => VboxColors.skinPrimaryPurple,
        VboxSkin.liquid => VboxColors.skinPrimarySky,
      };
}

/// 日志 / 站点分类（语义固定映射，非装饰色）。
///
/// 对齐 iOS `LogEntry.Category`（[LogViewerView.swift](../../../vbox/Views/LogViewerView.swift#L372-L386)）。
enum VboxCategory {
  /// 应用。
  app('app'),

  /// 蜘蛛。
  spider('spider'),

  /// 播放器。
  player('player'),

  /// 云盘。
  cloud('cloud'),

  /// 代理。
  proxy('proxy'),

  /// 网络。
  network('network'),

  /// 数据库。
  db('db'),

  /// 下载。
  download('download'),

  /// 福利。
  welfare('welfare'),

  /// Node。
  node('node');

  const VboxCategory(this.id);

  /// 契约字符串值。
  final String id;
}

/// 颜色令牌。
class VboxColors {
  const VboxColors._();

  // ── 皮肤主色（UI 基准 §2.1）──────────────────────────────
  /// 浅色 / 黑暗皮肤主色（玫瑰红）。
  static const Color skinPrimaryRose = Color(0xFFE11D48);

  /// 磨砂皮肤主色（紫）。
  static const Color skinPrimaryPurple = Color(0xFF7C3AED);

  /// 液态皮肤主色（天蓝）。
  static const Color skinPrimarySky = Color(0xFF38BDF8);

  // ── 资产强调色 ─────────────────────────────────────────
  /// 资产目录强调色（`AccentColor.colorset`）。
  static const Color accentAsset = Color(0xFF191919);

  // ── 语义色（UI 基准 §2.2）──────────────────────────────
  /// 选中 / 激活（播放器剧集当前项、面板选中）。
  static const Color selected = Color(0xFF2196F3);

  /// 选中胶囊（榜单胶囊填充 / 描边）。
  static const Color chipSelected = Color(0xFF34C759);

  /// 播放器深底（播放器空 / 错态背景）。
  static const Color playerBackground = Color(0xFF0F0F23);

  /// 播放器面板底色（深底 @90%，半透明覆盖层）。
  static const Color playerPanelBackground = Color(0xE60F0F23);

  /// 弹幕文字描边 / 阴影（80% 黑，提升浅底可读性）。
  static const Color danmakuShadow = Color(0xCC000000);

  /// 播放器强调绿（弹幕开关 / 倍速 / 更多菜单激活态；对齐 iOS `00BE06`）。
  static const Color playerAccentGreen = Color(0xFF00BE06);

  /// 播放器强调青（进度条 / 缓存片段 / 兼容内核文字；对齐 iOS `00BEFF`）。
  static const Color playerAccentCyan = Color(0xFF00BEFF);

  // ── 字幕颜色档位（UI-F5 字幕设置面板；对齐 iOS `SubtitleSettingsPanel.colorOptions`）──
  /// 字幕白色（默认档）。
  static const Color subtitleWhite = Color(0xFFFFFFFF);

  /// 字幕黄色。
  static const Color subtitleYellow = Color(0xFFFFFF00);

  /// 字幕青色。
  static const Color subtitleCyan = Color(0xFF00FFFF);

  /// 字幕颜色档位集合（索引与 `SubtitleStyle.colorIndex` 一一对应）。
  static const List<Color> subtitlePalette = <Color>[
    subtitleWhite,
    subtitleYellow,
    subtitleCyan,
  ];

  /// 按档位索引取字幕颜色（越界回退白色）。
  static Color subtitleColorAt(int index) =>
      (index >= 0 && index < subtitlePalette.length)
          ? subtitlePalette[index]
          : subtitleWhite;

  /// 危险操作（文字 + 背景 @10%）。
  static const Color danger = Color(0xFFEF4444);

  /// 成功 / 就绪（授权中心「已获取 / 正常 / 就绪」；对齐 iOS `.green`）。
  ///
  /// 批次 F · F-01 新增：网盘授权状态语义色（与 [chipSelected] 同为系统绿，
  /// 但语义独立，故单列以免误用）。
  static const Color success = Color(0xFF34C759);

  /// 警告 / 过渡态（「即将过期 / 启动中 / 内存告警」；对齐 iOS `.orange`）。
  ///
  /// 批次 F · F-01 新增。
  static const Color warning = Color(0xFFFF9500);

  /// 待确认态（登录「已扫码，待手机确认」；对齐 iOS `qrLoginState.scanned`
  /// 的 `.yellow`）。
  ///
  /// 批次 F · F-02 新增。
  static const Color pending = Color(0xFFFFCC00);

  // ── 首页顶栏 / 搜索评分（对齐 iOS 豆瓣首页顶栏与搜索结果卡）──────────
  /// 首页顶栏「切换源」选中态（对齐 iOS `.green` 的 `square.grid.2x2`）。
  ///
  /// 与 [chipSelected] / [success] 同值（`#34C759`），语义独立故单列。
  static const Color topBarSourceSelected = Color(0xFF34C759);

  /// 首页顶栏「AI 推荐」图标色（对齐 iOS `sparkles` 淡蓝 `#8AB4F8`）。
  static const Color topBarAiAccent = Color(0xFF8AB4F8);

  /// 搜索结果评分星标 / 分值（对齐 iOS 豆瓣评分 `#F5C518`）。
  static const Color ratingStar = Color(0xFFF5C518);

  /// 远程源设置图标色（对齐 iOS `cloud` 蓝 `#3B82F6`）。
  static const Color remoteSourceAccent = Color(0xFF3B82F6);

  /// 品牌红（搜索页榜钮 / 提交钮 / 选中胶囊；对齐 iOS `MainViews.swift:70`）。
  ///
  /// 批次 E · E2-4 新增：与 [skinPrimaryRose] 同值，语义独立单列
  /// （皮肤主色随皮肤切换，品牌红为固定强调色）。
  static const Color brandRed = Color(0xFFE11D48);

  // ── 品牌渐变（「我的」页头部）───────────────────────────
  /// 品牌渐变起点。
  static const Color brandGradientStart = Color(0xFF3B82F6);

  /// 品牌渐变中点。
  static const Color brandGradientMid = Color(0xFF2563EB);

  /// 品牌渐变终点。
  static const Color brandGradientEnd = Color(0xFF1D4ED8);

  /// 品牌渐变（左 → 右）。
  static const List<Color> brandGradient = <Color>[
    brandGradientStart,
    brandGradientMid,
    brandGradientEnd,
  ];

  // ── 下载（G-02，对齐 iOS `DownloadOverlayViews.swift`）─────────────────
  /// 下载中强调色（悬浮按键进度环 / 图标；iOS `Color(hex: "00A8FF")`）。
  static const Color downloadActive = Color(0xFF00A8FF);

  /// 下载完成托盘色（悬浮按键图标；iOS `Color(hex: "22C55E")`）。
  static const Color downloadCompleted = Color(0xFF22C55E);

  // ── 详情页（对齐 iOS `VideoDetailView` PlayerViews.swift）──────────────
  /// 详情页「立即播放」按钮底（iOS `Color(hex: "93C5FD")`）。
  static const Color detailPlayButton = Color(0xFF93C5FD);

  /// 详情页选中强调（线路 chip / 剧集排序激活态；iOS `Color(hex: "E11D48")`）。
  static const Color detailSelected = Color(0xFFE11D48);

  /// 详情页封面底部渐隐（透明 → 黑 10% → 黑 35%）。
  static const List<Color> detailCoverFadeGradient = <Color>[
    Color(0x00000000),
    Color(0x1A000000),
    Color(0x59000000),
  ];

  /// 详情页「剧情」标签文字色（白 @ 90%）。
  static const Color detailLabelText = Color(0xE6FFFFFF);

  // ── TG 搜索（G-04，对齐 iOS `SettingsViews.swift` / `TGChannelListView.swift`）──
  /// TG 频道管理图标色（设置入口天线图标；iOS `Color(hex: "8B5CF6")`）。
  static const Color tgChannelPurple = Color(0xFF8B5CF6);

  // ── TMDB（G-06，对齐 iOS `SettingsViews.swift` tmdbSettingsSection）──────
  /// TMDB 封面图标色（iOS `Color(hex: "3B82F6")`）。
  static const Color tmdbAccent = Color(0xFF3B82F6);

  /// TMDB 代理 Token 图标色（iOS `Color(hex: "F59E0B")`）。
  static const Color tmdbKeyAmber = Color(0xFFF59E0B);

  // ── 系统色（Apple HIG 语义色）───────────────────────────
  /// 系统底 · 浅（`.systemBackground`）。
  static const Color systemBackgroundLight = Color(0xFFFFFFFF);

  /// 系统底 · 深（`.systemBackground` Dark）。
  static const Color systemBackgroundDark = Color(0xFF000000);

  /// 系统分组底 · 浅（`.secondarySystemBackground`）。
  static const Color secondarySystemBackgroundLight = Color(0xFFF2F2F7);

  /// 系统分组底 · 深（`.secondarySystemBackground` Dark）。
  static const Color secondarySystemBackgroundDark = Color(0xFF1C1C1E);

  /// 次级文字 · 浅（`.secondaryLabel`，`#3C3C43` @ 60%）。
  static const Color secondaryLabelLight = Color(0x993C3C43);

  /// 次级文字 · 深（`.secondaryLabel` Dark，`#EBEBF5` @ 60%）。
  static const Color secondaryLabelDark = Color(0x99EBEBF5);

  /// 系统灰 2 · 浅（`.systemGray2`）—— 底栏未选中色（浅色 / 黑暗皮肤）。
  static const Color systemGray2Light = Color(0xFFAEAEB2);

  /// 系统灰 2 · 深（`.systemGray2` Dark）。
  static const Color systemGray2Dark = Color(0xFF636366);

  /// 系统灰 4 · 浅（`.systemGray4`）—— 底栏描边色（浅色 / 黑暗皮肤）。
  static const Color systemGray4Light = Color(0xFFD1D1D6);

  /// 系统灰 4 · 深（`.systemGray4` Dark）。
  static const Color systemGray4Dark = Color(0xFF38383A);

  // ── 直播分类调色板（12 色，按 `cat_N` 取模循环）──────────────
  /// 直播分类胶囊调色板（对齐 iOS `LiveCategory.palette`）。
  static const List<Color> liveCategoryPalette = <Color>[
    Color(0xFF2196F3), // blue
    Color(0xFF4CAF50), // green
    Color(0xFFF44336), // red
    Color(0xFFFF9800), // orange
    Color(0xFF9C27B0), // purple
    Color(0xFFE91E63), // pink
    Color(0xFF00BCD4), // cyan
    Color(0xFF009688), // teal
    Color(0xFF3F51B5), // indigo
    Color(0xFFFFC107), // yellow
    Color(0xFF4DB6AC), // mint
    Color(0xFF795548), // brown
  ];

  // ── 分类色板（10 色，语义固定映射）──────────────────────
  /// 分类色板（用于日志分类 / 站点标签）。
  static const Map<VboxCategory, Color> categoryColors = <VboxCategory, Color>{
    VboxCategory.app: Color(0xFF6B7280),
    VboxCategory.spider: Color(0xFF8B5CF6),
    VboxCategory.player: Color(0xFFEF4444),
    VboxCategory.cloud: Color(0xFF3B82F6),
    VboxCategory.proxy: Color(0xFF10B981),
    VboxCategory.network: Color(0xFFF59E0B),
    VboxCategory.db: Color(0xFF6366F1),
    VboxCategory.download: Color(0xFFEC4899),
    VboxCategory.welfare: Color(0xFFF97316),
    VboxCategory.node: Color(0xFF14B8A6),
  };

  // ── 源类型徽标配色（对齐 iOS `SourceDiscoveryView.categoryBadgeColor`）──
  /// 源类型徽标配色（键为 `SiteConfig.categoryLabel`）。
  ///
  /// 键用字符串而非领域枚举，避免主题层反向依赖领域层（分层约束）；
  /// 未登记的键回退 [skinPrimaryRose]。
  static const Map<String, Color> siteCategoryBadgeColors = <String, Color>{
    '网盘': Color(0xFF007AFF), // iOS cloudCMS / cloudSPA（系统蓝）
    '论坛': Color(0xFFFF9500), // iOS cloudForum（系统橙）
    'API': Color(0xFF34C759), // iOS api（系统绿）
    'JS': Color(0xFFAF52DE), // iOS jsSpider（系统紫）
    '站源': Color(0xFFFF3B30), // iOS zhanyuan（系统红）
  };

  // ── 网盘品牌角标底色（批次 F · F-01 授权中心 / F-06 排序列表）──────
  /// 网盘品牌角标底色（键为 `CloudDriveType.id`；采样 iOS 图标配色）。
  ///
  /// 键用字符串而非领域枚举，避免主题层反向依赖领域层（分层约束）；
  /// 未登记的键回退 [VboxColors.categoryColors] 的 `cloud` 蓝。
  static const Map<String, Color> cloudDriveBrandColors = <String, Color>{
    'ali': Color(0xFF2563EB),
    'quark': Color(0xFF3B82F6),
    'quarkNode': Color(0xFF6B7280),
    'baidu': Color(0xFFE11D48),
    'baiduNode': Color(0xFF6B7280),
    '115': Color(0xFF3B82F6),
    'uc': Color(0xFF38BDF8),
    'ucNode': Color(0xFF6B7280),
    '123pan': Color(0xFF2563EB),
    '139pan': Color(0xFF2563EB),
    '189pan': Color(0xFF3B82F6),
    'xunlei': Color(0xFF38BDF8),
    'guangya': Color(0xFF14B8A6),
    'woniu4k': Color(0xFF8B5CF6),
    'bilibili': Color(0xFFEC4899),
  };

  // ── 系统分组底 / 分隔线（批次 B · B3 设置页行底）──────────────
  /// 系统分组底 · 浅（`.secondarySystemGroupedBackground`）——设置行底（浅色下为纯白）。
  static const Color secondarySystemGroupedBackgroundLight = Color(0xFFFFFFFF);

  /// 系统分组底 · 深（`.secondarySystemGroupedBackground` Dark）。
  static const Color secondarySystemGroupedBackgroundDark = Color(0xFF1C1C1E);

  /// 三级分组底 · 浅（`.tertiarySystemGroupedBackground`）——未选中皮肤卡渐变终点。
  static const Color tertiarySystemGroupedBackgroundLight = Color(0xFFFFFFFF);

  /// 三级分组底 · 深（`.tertiarySystemGroupedBackground` Dark）。
  static const Color tertiarySystemGroupedBackgroundDark = Color(0xFF2C2C2E);

  /// 分隔线 · 浅（`.separator`，`#3C3C43` @ 29%）。
  static const Color separatorLight = Color(0x4A3C3C43);

  /// 分隔线 · 深（`.separator` Dark，`#545458` @ 65%）。
  static const Color separatorDark = Color(0xA6545458);

  // ── 皮肤选择卡（批次 B · B4，对齐 iOS `SkinModeButton.selectedGradient`）──
  /// 浅色模式卡选中渐变（`#F59E0B → #FDE68A`）。
  static const List<Color> skinCardLight = <Color>[
    Color(0xFFF59E0B),
    Color(0xFFFDE68A),
  ];

  /// 黑暗模式卡选中渐变（`#111827 → #374151`）。
  static const List<Color> skinCardDark = <Color>[
    Color(0xFF111827),
    Color(0xFF374151),
  ];

  /// 液态模式卡选中渐变（`#06B6D4 → #7C3AED → #EC4899`）。
  static const List<Color> skinCardLiquid = <Color>[
    Color(0xFF06B6D4),
    Color(0xFF7C3AED),
    Color(0xFFEC4899),
  ];

  /// 磨砂模式卡选中渐变（`#93C5FD → #C4B5FD → #FBCFE8`）。
  static const List<Color> skinCardFrosted = <Color>[
    Color(0xFF93C5FD),
    Color(0xFFC4B5FD),
    Color(0xFFFBCFE8),
  ];

  /// 皮肤卡选中文字色（浅 / 磨砂卡上为深色；对齐 iOS `selectedTextColor`）。
  static const Color skinCardOnLightText = Color(0xFF111827);

  /// 皮肤卡选中渐变（按皮肤解析；对齐 iOS `SkinModeButton.selectedGradient`）。
  static List<Color> skinCardGradient(VboxSkin skin) => switch (skin) {
        VboxSkin.light => skinCardLight,
        VboxSkin.dark => skinCardDark,
        VboxSkin.liquid => skinCardLiquid,
        VboxSkin.frosted => skinCardFrosted,
      };

  // ── 系统灰 6 / 分组底（批次 B · B5 输入框底 / B6 页面底）──────────
  /// 系统灰 6 · 浅（`.systemGray6`）——登录输入框底。
  static const Color systemGray6Light = Color(0xFFF2F2F7);

  /// 系统灰 6 · 深（`.systemGray6` Dark）——登录输入框底。
  static const Color systemGray6Dark = Color(0xFF1C1C1E);

  /// 分组页底 · 浅（`.systemGroupedBackground`）——登录弹窗背景。
  static const Color systemGroupedBackgroundLight = Color(0xFFF2F2F7);

  /// 分组页底 · 深（`.systemGroupedBackground` Dark）——登录弹窗背景。
  static const Color systemGroupedBackgroundDark = Color(0xFF000000);

  // ── 登录弹窗（批次 B · B5，对齐 iOS `LoginSheetView`）──────────────
  /// 登录强调色（图标 / 按钮阴影底；`#3B82F6`）。
  static const Color loginAccent = Color(0xFF3B82F6);

  /// 登录按钮 / 图标兜底渐变（`#3B82F6 → #2563EB → #1D4ED8`，横向）。
  static const List<Color> loginGradient = <Color>[
    Color(0xFF3B82F6),
    Color(0xFF2563EB),
    Color(0xFF1D4ED8),
  ];

  // ── 福利分段 + 平台网格（批次 B · B6，对齐 iOS `RemoteWelfareHomeView`）──
  /// 福利 · 视频分段选中渐变（`#FF598C → #F23373`）。
  static const List<Color> welfareTabVideoGradient = <Color>[
    Color(0xFFFF598C),
    Color(0xFFF23373),
  ];

  /// 福利 · 直播分段选中渐变（`#664DF2 → #8C40D9`，图17 实测紫色实心）。
  static const List<Color> welfareTabLiveGradient = <Color>[
    Color(0xFF664DF2),
    Color(0xFF8C40D9),
  ];

  /// 福利 · 漫画分段选中渐变（`#33A6F2 → #1A73D9`）。
  static const List<Color> welfareTabComicGradient = <Color>[
    Color(0xFF33A6F2),
    Color(0xFF1A73D9),
  ];

  /// 福利平台图标 8 色渐变板（对齐 iOS `RemoteWelfareHomeView.platformGradient`）。
  static const List<List<Color>> welfarePlatformPalette = <List<Color>>[
    <Color>[Color(0xFFFF598C), Color(0xFFF23373)],
    <Color>[Color(0xFF664DF2), Color(0xFF8C40D9)],
    <Color>[Color(0xFF33A6F2), Color(0xFF1A73D9)],
    <Color>[Color(0xFFFF8C33), Color(0xFFF2661A)],
    <Color>[Color(0xFF4DBF73), Color(0xFF339959)],
    <Color>[Color(0xFFD94DA6), Color(0xFFB33380)],
    <Color>[Color(0xFF6680F2), Color(0xFF4059D9)],
    <Color>[Color(0xFFFFA64D), Color(0xFFF28026)],
  ];

  /// 平台图标渐变（按名称稳定取模）。
  ///
  /// iOS 用 `abs(name.hashValue) % 8`，而 Swift `String.hashValue` **每进程随机**
  /// （截图中的具体配色因此不可复现）；Flutter 侧改用**稳定求和哈希**，
  /// 保证同名平台跨运行 / 跨平台取同一色板槽位。
  static List<Color> welfarePlatformGradient(String name) {
    int hash = 0;
    for (final int unit in name.codeUnits) {
      hash = (hash + unit) & 0x7FFFFFFF;
    }
    return welfarePlatformPalette[hash % welfarePlatformPalette.length];
  }
}

/// 底栏（悬浮胶囊 TabBar）配色。
///
/// 唯一真相源：iOS `ContentView.swift` L256-L278（四皮肤底栏配色计算属性）。
/// Flutter 侧无 `ultraThinMaterial`，以 [base] 半透明底 + 1px [stroke] 近似。
@immutable
class VboxTabBarPalette {
  /// 构造。
  const VboxTabBarPalette({
    required this.active,
    required this.inactive,
    required this.base,
    required this.stroke,
  });

  /// 选中色（图标 + 文字）。
  final Color active;

  /// 未选中色。
  final Color inactive;

  /// 胶囊底（半透明）。
  final Color base;

  /// 胶囊 1px 描边。
  final Color stroke;

  /// 按皮肤 + 配色模式解析（对齐 iOS `activeTabColor` 等四个计算属性）。
  static VboxTabBarPalette resolve(VboxSkin skin, Brightness brightness) {
    final bool isDark = brightness == Brightness.dark;
    switch (skin) {
      case VboxSkin.frosted:
        return VboxTabBarPalette(
          active: skin.primary,
          inactive: isDark
              ? VboxColors.secondaryLabelDark
              : VboxColors.secondaryLabelLight,
          base: (isDark
                  ? VboxColors.secondarySystemBackgroundDark
                  : VboxColors.secondarySystemBackgroundLight)
              .withValues(alpha: 0.62),
          stroke: Colors.white.withValues(alpha: 0.34),
        );
      case VboxSkin.liquid:
        return VboxTabBarPalette(
          active: skin.primary,
          inactive: Colors.white.withValues(alpha: 0.72),
          base: Colors.black.withValues(alpha: 0.34),
          stroke: Colors.white.withValues(alpha: 0.22),
        );
      case VboxSkin.light:
      case VboxSkin.dark:
        return VboxTabBarPalette(
          active: skin.primary,
          inactive: isDark
              ? VboxColors.systemGray2Dark
              : VboxColors.systemGray2Light,
          base: (isDark
                  ? VboxColors.systemBackgroundDark
                  : VboxColors.systemBackgroundLight)
              .withValues(alpha: 0.9),
          stroke: isDark
              ? VboxColors.systemGray4Dark
              : VboxColors.systemGray4Light,
        );
    }
  }
}