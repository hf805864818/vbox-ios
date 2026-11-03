/// 领域层：播放器抽象接口。
///
/// 唯一真相源：迁移计划 D6（播放器策略）+ `contract/schema/site_v1.json`
///   · Android：Media3（主）→ libVLC（全格式回退）
///   · Windows/macOS：libmpv
///   · iOS：不迁移（维持原生 AVPlayer/MDK/VLC 等 6 后端）
library;

/// 播放器后端类型（对齐 D6）。
enum PlayerBackend {
  /// Android 主播放器（Media3 / ExoPlayer）。
  media3,

  /// 全格式回退（libVLC）—— Android 必需。
  libVLC,

  /// 桌面播放器（libmpv）—— 自研 mpv 渲染桥（OpenGL FBO + libswscale），已退役。
  libmpv,

  /// media_kit 内核（libmpv + ANGLE/D3D11 渲染，Windows/macOS 唯一主内核）。
  ///
  /// 纯 Dart 直连（不经 MethodChannel）；无真 GPU 时自动落 D3D11 WARP 软件光栅化，
  /// 根治自研桥在云电脑上「有声无画」的问题。
  mediaKit,

  /// 全格式硬解内核（MDK SDK）—— 统一内核接缝。
  ///
  /// M1 仅交付 Dart 侧接缝（枚举 / 链路 / 面板 / 降级）；原生接入见 M2（Android）
  /// 与 M3（Windows / macOS）。原生未接入时 [open] 回 `E_BACKEND_UNAVAILABLE`，
  /// 由降级链自动改投下一后端，行为与未接入前一致。
  mdk,

  /// iOS 原生（不迁移，仅作契约对齐占位）。
  nativeiOS,
}

/// 后端能力元数据（P-芯6：显示名 / 系统 PiP 支持单点内聚，避免 UI 重复文案表）。
extension PlayerBackendMeta on PlayerBackend {
  /// 长显示名（内核选择面板）。
  String get displayName => switch (this) {
        PlayerBackend.media3 => 'Media3（系统播放器）',
        PlayerBackend.libVLC => 'libVLC（全格式）',
        PlayerBackend.libmpv => 'libmpv',
        PlayerBackend.mediaKit => 'media_kit',
        PlayerBackend.mdk => 'MDK（全格式）',
        PlayerBackend.nativeiOS => '原生播放器',
      };

  /// 短显示名（播放控制条内核按钮）。
  String get shortName => switch (this) {
        PlayerBackend.media3 => 'Media3',
        PlayerBackend.libVLC => 'VLC',
        PlayerBackend.libmpv => 'MPV',
        PlayerBackend.mediaKit => 'MPV',
        PlayerBackend.mdk => 'MDK',
        PlayerBackend.nativeiOS => '原生',
      };

  /// 是否支持系统级画中画（对齐 PiP 策略的系统承载后端集合）。
  bool get supportsSystemPip => switch (this) {
        PlayerBackend.media3 => true,
        PlayerBackend.nativeiOS => true,
        PlayerBackend.libVLC => false,
        PlayerBackend.libmpv => false,
        PlayerBackend.mediaKit => false,
        PlayerBackend.mdk => false,
      };
}

/// 播放模式（对齐 `site_v1.json` 的 `playMode`）。
enum PlayMode {
  /// 普通直链播放。
  normal,

  /// 网盘播放（需分发到 panHosts）。
  pan,

  /// 混合（直链 + 网盘）。
  hybrid;

  static PlayMode fromJson(String? v) => switch (v) {
        'pan' => PlayMode.pan,
        'hybrid' => PlayMode.hybrid,
        'normal' => PlayMode.normal,
        _ => PlayMode.normal,
      };
}

/// 画面拉伸模式（UI-E2，对齐 iOS `PlayerState.VideoGravityMode`，
/// [PlayerViewsV2.swift:864-884](../../../../vbox/Views/PlayerViewsV2.swift#L864-L884)）。
///
/// 三档顺序与 iOS `CaseIterable` 声明序一致，[cycle] 循环切换（对齐 iOS
/// `cycleVideoGravity()` L1379-1385）；缺省 `aspectFill`（对齐 iOS `@Published
/// var videoGravity = .aspectFill` L948）。
enum VideoGravityMode {
  /// 填充（保持宽高比铺满裁切；iOS `.resizeAspectFill`）。
  aspectFill,

  /// 适应（保持宽高比留黑边；iOS `.resizeAspect`）。
  aspectFit,

  /// 拉伸（不保持宽高比强制适配；iOS `.resize`）。
  resize;

  /// 循环切到下一档（对齐 iOS `cycleVideoGravity()` 的声明序取模）。
  VideoGravityMode cycle() => values[(index + 1) % values.length];

  /// 展示名（对齐 iOS `rawValue`：填充 / 适应 / 拉伸）。
  String get displayName => switch (this) {
        VideoGravityMode.aspectFill => '填充',
        VideoGravityMode.aspectFit => '适应',
        VideoGravityMode.resize => '拉伸',
      };
}

/// 播放源（一次可播放的媒体）。
class PlayerSource {
  const PlayerSource({
    required this.url,
    this.headers = const <String, String>{},
    this.title,
    this.isLive = false,
    this.mimeType,
    this.source = '',
    this.fallbackUrl,
    this.fallbackHeaders = const <String, String>{},
    this.fallbackSource = '',
    this.fallbackUseQuarkProxy = false,
    this.provider,
  });

  /// 播放地址。
  final String url;

  /// 自定义请求头（对齐 `PlayerContentResult.header`）。
  final Map<String, String> headers;

  /// 显示标题。
  final String? title;

  /// 是否直播流。
  final bool isLive;

  /// MIME 类型（如 `application/vnd.apple.mpegurl`）。
  final String? mimeType;

  /// 主线路来源标记（对齐 iOS `PlayResult.source`：`download_url` /
  /// `v2-play-m3u8` / `uc_tv_token` / `v2-play` / `transcode` / `node-pan` 等）。
  ///
  /// 兜底链用于识别「原画直链」主线路（`download_url`）以决定是否启用首帧超时。
  final String source;

  /// 兜底播放地址（对齐 iOS `PlayResult.fallbackURL`；null 表示无兜底链）。
  final String? fallbackUrl;

  /// 兜底请求头（对齐 iOS `PlayResult.fallbackHeaders`）。
  final Map<String, String> fallbackHeaders;

  /// 兜底来源标记（对齐 iOS `PlayResult.fallbackSource`）。
  final String fallbackSource;

  /// 兜底线路是否需要走夸克 Go 代理（`registerQuarkStream`）。
  ///
  /// 对齐 iOS：夸克兜底线路触发时经本地代理注入鉴权头；其余网盘走直链。
  final bool fallbackUseQuarkProxy;

  /// 网盘 provider id（F-P28 按盘内核策略的分派键；对齐 `CloudPlayItem.provider`
  /// 即 `CloudDriveType.id`：`quark` / `baidu` / `baiduNode` / `uc` / `ucNode` /
  /// `139pan` / `115` …）。null = 非网盘源（蜘蛛直链等，无按盘维度）。
  final String? provider;

  /// 是否 HLS（m3u8）。
  bool get isHls =>
      url.contains('.m3u8') || (mimeType?.contains('mpegurl') ?? false);

  /// 是否具备可切换的兜底线路。
  bool get hasFallback => fallbackUrl != null && fallbackUrl!.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'url': url,
        if (headers.isNotEmpty) 'headers': headers,
        if (title != null) 'title': title,
        'isLive': isLive,
        if (mimeType != null) 'mimeType': mimeType,
        if (source.isNotEmpty) 'source': source,
        if (fallbackUrl != null) 'fallbackUrl': fallbackUrl,
        if (fallbackHeaders.isNotEmpty) 'fallbackHeaders': fallbackHeaders,
        if (fallbackSource.isNotEmpty) 'fallbackSource': fallbackSource,
        if (fallbackUseQuarkProxy) 'fallbackUseQuarkProxy': fallbackUseQuarkProxy,
        if (provider != null) 'provider': provider,
      };

  factory PlayerSource.fromJson(Map<String, Object?> j) => PlayerSource(
        url: (j['url'] ?? '').toString(),
        headers: (j['headers'] as Map?)?.map(
                (k, v) => MapEntry(k.toString(), v.toString())) ??
            const <String, String>{},
        title: j['title']?.toString(),
        isLive: j['isLive'] as bool? ?? false,
        mimeType: j['mimeType']?.toString(),
        source: (j['source'] as String?) ?? '',
        fallbackUrl: j['fallbackUrl']?.toString(),
        fallbackHeaders: (j['fallbackHeaders'] as Map?)?.map(
                (k, v) => MapEntry(k.toString(), v.toString())) ??
            const <String, String>{},
        fallbackSource: (j['fallbackSource'] as String?) ?? '',
        fallbackUseQuarkProxy: j['fallbackUseQuarkProxy'] as bool? ?? false,
        provider: j['provider']?.toString(),
      );
}

/// 播放器状态。
enum PlayerState {
  idle,
  opening,
  playing,
  paused,
  buffering,
  ended,
  error,
}

/// 播放进度。
class PlaybackProgress {
  const PlaybackProgress({
    required this.positionMs,
    required this.durationMs,
    required this.bufferedMs,
    this.isLive = false,
  });

  final int positionMs;
  final int durationMs;
  final int bufferedMs;
  final bool isLive;

  /// 进度百分比（直播或时长未知时为 0）。
  double get percent {
    if (isLive || durationMs <= 0) return 0;
    return (positionMs / durationMs).clamp(0.0, 1.0);
  }

  @override
  String toString() => 'PlaybackProgress(pos=${positionMs}ms, '
      'dur=${durationMs}ms, buf=${bufferedMs}ms, live=$isLive)';
}

/// 播放器接口（平台适配层实现）。
abstract class Player {
  /// 当前后端。
  PlayerBackend get backend;

  /// 可用后端列表（按优先级）。
  List<PlayerBackend> get availableBackends;

  /// 视频纹理输出面的 Flutter textureId。
  ///
  /// `null` 表示当前后端**无纹理输出**（Dart 侧渲染深色占位，避免「有声无画」
  /// 时误判为黑屏故障）；非 null 时由 [VideoSurface] 以 `Texture(textureId:)`
  /// 承载，对齐 iOS `PlayerContainerView` 的画面层语义（R-渲1）。
  int? get textureId;

  /// 状态流式回调。
  set onStateChanged(void Function(PlayerState)? handler);

  /// 进度流式回调。
  set onProgress(void Function(PlaybackProgress)? handler);

  /// 视频尺寸回调（R-渲1：输出面按纵横比自适应，对齐 iOS `videoGravity`）。
  ///
  /// 原生解出视频轨后上报（宽/高像素）；不上报时播放页按拉伸铺满处理。
  set onVideoSize(void Function(int width, int height)? handler);

  /// 错误回调。
  set onError(void Function(String message, {bool fatal})? handler);

  /// 纹理注册就绪（R-渲1 补发）：内核懒注册纹理，`open` 返回时通常尚未就绪，
  /// 句柄随后经此回调补发（对齐 ChannelPlayer 的 `textureReady` 事件），宿主
  /// 据此挂载输出面。
  set onTextureReady(void Function(int textureId)? handler);

  /// 打开媒体源。
  Future<void> open(PlayerSource source);

  /// 播放。
  Future<void> play();

  /// 暂停。
  Future<void> pause();

  /// 跳转到指定位置（毫秒）。
  Future<void> seekTo(int positionMs);

  /// 设置音量（0.0 ~ 1.0）。
  Future<void> setVolume(double volume);

  /// 设置倍速。
  Future<void> setSpeed(double speed);

  /// 释放资源。
  Future<void> dispose();
}

/// 后端选择器（D6 策略：主后端失败时回退）。
class PlayerBackendSelector {
  PlayerBackendSelector._();

  /// 按平台返回后端降级链。
  ///
  /// - Android：Media3 → libVLC（原生仅实现 media3 / libVLC 两个内核；MDK 是
  ///   iOS 侧内核，Flutter 端**无原生实现**——若留在链中，`open(backend=mdk)`
  ///   必抛 `E_BACKEND_UNAVAILABLE：未知后端：mdk`，白白多一跳且打断降级序）
  /// - Windows/macOS：libmpv（原生插件仅实现 libmpv，桌面端 MDK/libVLC 未接线，
  ///   故链中不含 MDK —— 否则 `open` 失败回退到 MDK 会直接抛
  ///   `E_BACKEND_UNAVAILABLE：该插件仅实现 libmpv 后端`）
  /// - iOS：nativeiOS（不迁移）
  ///
  /// 链首为**默认主后端**（默认路径不经过复杂封装分支）；复杂封装 / 直播 FLV
  /// 等需全格式时由 [PlayerBackendSelector] / `PlayerController` 改投
  /// **libVLC 优先**，失败再依次回退（仅 Android 生效）。
  static List<PlayerBackend> chainFor(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return const <PlayerBackend>[
          PlayerBackend.media3,
          PlayerBackend.libVLC,
        ];
      case 'windows':
      case 'macos':
        return const <PlayerBackend>[PlayerBackend.mediaKit];
      case 'ios':
        return const <PlayerBackend>[PlayerBackend.nativeiOS];
      default:
        return const <PlayerBackend>[PlayerBackend.media3];
    }
  }

  /// 挑选初始后端（M1）。
  ///
  /// 默认返回**链首**（各端主后端，默认路径不经过 MDK）；当 [needsFullFormat]
  /// 为真（复杂封装 / 直播 FLV）时按统一内核口径优先：**MDK → libVLC → libmpv**，
  /// 三者皆不在链中则回链首。
  ///
  /// 纯函数（无平台分支），便于逐端单测。
  static PlayerBackend initialBackend({
    required List<PlayerBackend> chain,
    required bool needsFullFormat,
  }) {
    if (needsFullFormat) {
      if (chain.contains(PlayerBackend.mdk)) return PlayerBackend.mdk;
      if (chain.contains(PlayerBackend.libVLC)) return PlayerBackend.libVLC;
      if (chain.contains(PlayerBackend.libmpv)) return PlayerBackend.libmpv;
    }
    return chain.first;
  }

  /// 判断某 URL 是否需要回退到全格式播放器（libVLC）。
  ///
  /// 契约（计划书 1092 行）：MKV 等复杂封装 → libVLC 回退。
  ///
  /// [resourceName] 为**真实文件名 / 标题**（可选）：网盘 / Node 代理流的 URL
  /// 常为无扩展名的本地回环代理（`http://127.0.0.1:58080/spider/push/...`），
  /// 仅凭 URL 无法判定封装；此时以真实文件名补判，避免 4K HEVC MKV 等被误投
  /// Media3（open 成功但解码失败）。对齐 iOS「只认真实文件名」的判定口径。
  static bool needsFallback(String url, {String? resourceName}) {
    final String u = url.toLowerCase();
    final String r = (resourceName ?? '').toLowerCase();
    const List<String> complexContainers = <String>[
      '.mkv', '.flv', '.ts', '.rmvb', '.avi', '.wmv', '.m2ts',
    ];
    for (final String ext in complexContainers) {
      if (u.contains(ext) || r.contains(ext)) return true;
    }
    return false;
  }

  // ─────────────── F-P28 · 按盘内核策略表 ───────────────

  /// Node 常驻代理流判定（逐字对齐 iOS `isNodePanProxyURL`，
  /// `PlayerViewsV2.swift:1251-1254`：本地回环 + `/spider/push/` 路径）。
  static bool isNodePanProxyUrl(String url) {
    final Uri? u = Uri.tryParse(url);
    if (u == null) return false;
    return (u.host == '127.0.0.1' || u.host == 'localhost') &&
        u.path.contains('/spider/push/');
  }

  /// UC 播放直链判定（逐字对齐 iOS `isUCPlaybackURL`，L4576-4588：
  /// `*.uc.cn`（排除 `drive.uc.cn` / `pc-api.uc.cn` / `www.uc.cn`）、
  /// UC TV Token CDN（`*.cdn.yun.cn`）、`ucdl` / `ucloud` 主机片段）。
  static bool isUcPlaybackUrl(String url) {
    final Uri? u = Uri.tryParse(url);
    final String? host = u?.host.toLowerCase();
    if (u == null || host == null || host.isEmpty) return false;
    if (host == 'uc.cn' || host.endsWith('.uc.cn')) {
      const Set<String> excluded = <String>{
        'drive.uc.cn', 'pc-api.uc.cn', 'www.uc.cn',
      };
      return !excluded.contains(host);
    }
    if (host.endsWith('.cdn.yun.cn')) return true;
    return host.contains('ucdl') || host.contains('ucloud');
  }

  /// UC 流判定（对齐 iOS `isUCStreamURL`，L4570-4574：`uc-stream` 本地代理
  /// 或 UC 播放直链）。
  static bool isUcStreamUrl(String url) {
    final Uri? u = Uri.tryParse(url);
    if (u != null &&
        (u.host == '127.0.0.1' || u.host == 'localhost') &&
        u.path.contains('uc-stream')) {
      return true;
    }
    return isUcPlaybackUrl(url);
  }

  /// Node 代理流的「系统内核明确不支持」封装 / 编码判定（对齐 iOS
  /// `nodeCompatibilityReason`，L1314-1333；只认明确不支持项，避免仅含
  /// `4k` 的 MP4 误判——Node 代理 URL 无扩展名，只能靠真实文件名）。
  static String? nodeCompatibilityReason(String fileName) {
    final String lower = fileName.toLowerCase();
    const List<(String, String)> rules = <(String, String)>[
      ('.mkv', 'MKV 封装'),
      ('.flv', 'FLV 封装'),
      ('.avi', 'AVI 封装'),
      ('.rmvb', 'RMVB 封装'),
      ('hevc', 'HEVC/H.265'),
      ('h265', 'HEVC/H.265'),
      ('x265', 'HEVC/H.265'),
      ('10bit', '10bit 视频'),
      ('hdr', 'HDR 视频'),
      ('ddp', 'DDP/E-AC-3 音轨'),
      ('eac3', 'DDP/E-AC-3 音轨'),
      ('dts', 'DTS 音轨'),
      ('truehd', 'TrueHD 音轨'),
      ('atmos', 'Atmos 音轨'),
    ];
    for (final (String, String) r in rules) {
      if (lower.contains(r.$1)) return r.$2;
    }
    return null;
  }

  /// AVPlayer 必定打不开的硬容器（对齐 iOS `hardUnsupportedContainers`，
  /// L1337-1345；刻意不含 mp4/m3u8/mov/webm/hevc/hdr，避免把本就能播的
  /// 资源误推兼容内核）。
  static String? hardContainerReason(String fileName) {
    final String lower = fileName.toLowerCase();
    const List<(String, String)> rules = <(String, String)>[
      ('.iso', 'ISO 镜像'),
      ('.m2ts', 'M2TS 原盘'),
      ('.vob', 'DVD VOB'),
      ('.rmvb', 'RMVB 封装'),
      ('.flv', 'FLV 封装'),
      ('.avi', 'AVI 封装'),
      ('.mkv', 'MKV 封装'),
    ];
    for (final (String, String) r in rules) {
      if (lower.contains(r.$1)) return r.$2;
    }
    return null;
  }

  /// 按盘内核链（F-P28，对齐 iOS `preferredCompatibilityEngineName` 的
  /// `.auto` 分支 + 主分派链 `PlayerViewsV2.swift:3911-4117`）。
  ///
  /// 返回 null = 该盘 / 该 URL 形态**无按盘策略**（回落既有「源特征」逻辑：
  /// 复杂封装 / 直播 FLV → MDK，默认链首），对齐 iOS 落默认 AVPlayer。
  ///
  /// 逐盘依据（IJK / AliPlayer 在 Flutter 端无对应后端，从 iOS 序列中剔除）：
  /// - **夸克**（代理流 `quark-stream` / `quark-m3u8`）→ `mdk → libmpv → libVLC`
  ///   （iOS L3918-3930：MDK → MPV → IJK → VLC，MDK 针对 VT 硬解 / FFmpeg 软解
  ///   + 缓冲预热专项优化；夸克**直链**不命中 → 落默认，对齐 iOS）；
  /// - **UC**（原生 `uc` / Node `ucNode`，UC CDN 直链或 `uc-stream` 代理）→
  ///   `mdk → libVLC → libmpv`（iOS L1194-1209 门闸：MDK 优先，**禁 MPV**——
  ///   MPV-MoltenVK 在 UC 流上有声无画且 `mpv_initialize` 闪退，VLC 兜底
  ///   4K HDR 黑屏，故 libmpv 沉底仅作最后兜底）；
  /// - **百度**（原生 `baidu` / Node `baiduNode`，`baidu-stream` 代理或 Node
  ///   代理流）→ `mdk → libmpv → libVLC`（iOS `shouldPreferMDK` L1262-1266：
  ///   `baidu-stream` / Node 代理命中 MDK 优先；L1279 `shouldPreferMPV` 的
  ///   baidu-stream 分支仅在 MDK 不可用时可达，故 libmpv 次位）；
  /// - **139**（`139pan`，真实文件名命中硬容器 ISO/M2TS/VOB/RMVB/FLV/AVI/MKV）→
  ///   `mdk → libVLC → libmpv`（iOS L1185-1192 门闸钉死 pan139 + 硬容器；
  ///   非硬容器 → null 落默认，对齐 iOS）；
  /// - **其它 Node 托管盘**（115 / 123 / 189 / 迅雷 / 光鸭 / 蜗牛 / bilibili）：
  ///   Node 代理流 + 真实文件名命中 [nodeCompatibilityReason] →
  ///   `mdk → libVLC → libmpv`（iOS L4098-4114 + L1238-1243：Node 代理流
  ///   兜底禁 MPV）；否则 null。
  static List<PlayerBackend>? driveChainFor({
    required String provider,
    required String url,
    String? resourceName,
  }) {
    switch (provider) {
      case 'quark':
        final bool proxyStream =
            url.contains('quark-stream') || url.contains('quark-m3u8');
        if (!proxyStream) return null;
        return const <PlayerBackend>[
          PlayerBackend.mdk,
          PlayerBackend.libmpv,
          PlayerBackend.libVLC,
        ];
      case 'uc':
      case 'ucNode':
        if (!isUcStreamUrl(url)) return null;
        return const <PlayerBackend>[
          PlayerBackend.mdk,
          PlayerBackend.libVLC,
          PlayerBackend.libmpv,
        ];
      case 'baidu':
      case 'baiduNode':
        if (!url.contains('baidu-stream') && !isNodePanProxyUrl(url)) {
          return null;
        }
        return const <PlayerBackend>[
          PlayerBackend.mdk,
          PlayerBackend.libmpv,
          PlayerBackend.libVLC,
        ];
      case '139pan':
        if (resourceName == null ||
            resourceName.isEmpty ||
            hardContainerReason(resourceName) == null) {
          return null;
        }
        return const <PlayerBackend>[
          PlayerBackend.mdk,
          PlayerBackend.libVLC,
          PlayerBackend.libmpv,
        ];
      case '115':
      case '123pan':
      case '189pan':
      case 'xunlei':
      case 'guangya':
      case 'woniu4k':
      case 'bilibili':
        if (!isNodePanProxyUrl(url)) return null;
        if (resourceName == null ||
            resourceName.isEmpty ||
            nodeCompatibilityReason(resourceName) == null) {
          return null;
        }
        return const <PlayerBackend>[
          PlayerBackend.mdk,
          PlayerBackend.libVLC,
          PlayerBackend.libmpv,
        ];
      default:
        // 阿里及其它未列盘：iOS 无专门分支（`shouldPreferAliPlayer` 恒 false，
        // L1298-1308）→ 回落源特征逻辑。
        return null;
    }
  }

  /// 从按盘链中挑选平台**可用**的首个后端（等价 iOS `isXXXBuildAvailable`
  /// 逐级可用性检查）；全不可用 → null（调用方回落源特征逻辑）。
  static PlayerBackend? pickDriveBackend({
    required List<PlayerBackend> driveChain,
    required List<PlayerBackend> available,
  }) {
    for (final PlayerBackend b in driveChain) {
      if (available.contains(b)) return b;
    }
    return null;
  }
}
