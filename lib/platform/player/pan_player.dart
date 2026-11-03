/// 平台层：网盘播放（pan 模式）编排（批次 F · F-08）。
///
/// 职责（对齐 iOS `CloudDriveManager.resolvePlayURL` 的 Node 分支 +
/// `NodePanResolver` + 统一播放缓存 `cloud_play_item_cache_v1`）：
///  - 分享链接 → 可播放条目（[NodePanClient.resolveShare]）；
///  - 条目 → 播放地址（[NodePanClient.resolvePlay]）；
///  - 解析结果落统一缓存（[CloudPlayItemCacheStore]，键 `provider|sourceKey`）；
///  - 交给 [PlayerController] 以**显式 `pan` 路由**打开播放。
///
/// 路由守卫（对齐 iOS `resolvePlayURL` 的分档）：
///  - Node 托管盘（115 / 123 / 139 / 189 / 迅雷 / 光鸭 / 蜗牛 / 夸克Node /
///    UC网盘Node / 百度网盘Node）→ Node 常驻系统链路；
///  - 阿里云盘 → PG 4kz 路链（F-P09，`AliyunAdriveClient`：ADrive 分享/转存 →
///    转码 m3u8 / 原画直链；未授权时明确报错）；
///  - 原生盘（夸克 / 百度 / UC）→ 原生路链：**夸克已接入**（F-P01，
///    `QuarkNativeClient`：分享解析 → 文件列表 → 转存 → 取链）；**百度已接入**
///    （F-P02，`BaiduIBoxClient` iBox 本机链：分享验证 → 多文件选集 → 转存 →
///    DLNA/locatedownload 取链；失败抛出，WebView 回退见 C3/Web-R1）；**UC 已接入**
///    （F-P03，`UcNativeClient`：分享解析 → 文件列表 → 转存 → v2/play/download）。
library;

import 'dart:async' show unawaited;

import '../../core/utils/logger.dart';
import '../../data/datasources/local/cloud_drive_credential_store.dart';
import '../../data/datasources/local/cloud_play_item_cache_store.dart';
import '../../data/datasources/local/pg_auto_store.dart';
import '../../data/datasources/local/prefs_manager.dart';
import '../../data/datasources/remote/aliyun_adrive_client.dart';
import '../../data/datasources/remote/baidu_ibox_client.dart';
import '../../data/datasources/remote/node_pan_client.dart';
import '../../data/datasources/remote/node_play_id.dart';
import '../../data/datasources/remote/quark_native_client.dart';
import '../../data/datasources/remote/uc_native_client.dart';
import '../../domain/entities/cloud/cloud_drive.dart';
import '../../domain/entities/cloud/cloud_play_item.dart';
import '../../domain/entities/cloud/node_pan.dart';
import '../../domain/entities/cloud/pg_auto.dart';
import '../../domain/entities/player/player.dart';
import '../webview/in_app_webview_bridge.dart';
import 'drive_error.dart';
import 'pan_fallback_chain.dart';
import 'playback_route.dart';
import 'player_controller.dart';

/// 网盘播放路由通道（对齐 iOS `resolvePlayURL` 分支）。
enum PanPlayChannel {
  /// Node 常驻系统链路（`/spider/push/4/*`）。
  nodePan,

  /// 阿里云盘 PG 4kz 路链（批次 F · F-09）。
  pgAli,

  /// 原生盘路链（夸克 / 百度 / UC）。
  native,

  /// 不支持。
  unsupported,
}

/// 网盘播放入口不可用 / 业务错误。
class PanPlayException implements Exception {
  /// 构造。
  const PanPlayException(this.message, {this.driveError});

  /// 由分档错误构造：展示文案取 [DriveError.description]，并保留分档信息，
  /// 供 [DriveErrorMapper] 施加 iOS 播放站点文案（如 `notImplemented` → 「暂不支持」）。
  PanPlayException.fromDrive(DriveError error)
      : message = error.description,
        driveError = error;

  /// 展示文案。
  final String message;

  /// 分档错误（可空；非空时展示文案由集中映射层按播放站点档位给出）。
  final DriveError? driveError;

  @override
  String toString() => 'PanPlayException($message)';
}

/// 网盘播放编排。
class PanPlayer {
  /// 构造（[client] / [cacheStore] / [controller] 均可注入；测试用替身）。
  PanPlayer({
    NodePanClient? client,
    CloudPlayItemCacheStore? cacheStore,
    PlayerController? controller,
    QuarkNativeClient? quarkClient,
    BaiduIBoxClient? baiduIBoxClient,
    UcNativeClient? ucClient,
    AliyunAdriveClient? aliyunClient,
    Future<String> Function(CloudDriveType type)? cookieFor,
  })  : _client = client ?? NodePanClient(),
        _cache = cacheStore ??
            CloudPlayItemCacheStore(PrefsManager.instance),
        _controller = controller,
        _quark = quarkClient ?? QuarkNativeClient(),
        // 问题 3（P0）：注入真实 WebView 桥，使 bdstoken 四层兜底的第 3 层
        //（WKWebView/HeadlessWebView 载入 disk/main 复用 CookieJar 取用户态
        // bdstoken）生效（对齐 iOS `baiduFetchUserBdstokenViaWebView`）。
        // Windows 无头模式受崩溃保护闸门控制（InAppWebViewBridge
        // .windowsHeadlessEnabled，beta 插件原生 abort），闸死时自动退回
        // 第 4 层保存值兜底；后续由原生 WebView2 桥恢复浏览器栈层。仅 Linux
        // 无 WebView 实现时 `isAvailable=false`，行为与接线前一致。
        _baiduIBox = baiduIBoxClient ?? BaiduIBoxClient(webView: InAppWebViewBridge()),
        _uc = ucClient ?? UcNativeClient(),
        _aliyun = aliyunClient ??
            AliyunAdriveClient(
              // 刷新结果落库（对齐 iOS `refreshAliAccessTokenIfNeeded`
              // 全链落库语义）：refresh_token 轮换新值写回凭据存储。
              onTokenRefreshed: (String accessToken, String refreshToken) =>
                  unawaited(_saveAliTokenRefreshed(accessToken, refreshToken)),
            ),
        _cookieFor = cookieFor;

  final NodePanClient _client;
  final CloudPlayItemCacheStore _cache;
  PlayerController? _controller;

  /// 夸克原生分享链客户端（F-P01）。
  final QuarkNativeClient _quark;

  /// 百度 iBox 本机链客户端（F-P02，对齐 iOS `CloudDriveManager` 百度主路链）。
  final BaiduIBoxClient _baiduIBox;

  /// UC 原生分享链客户端（F-P03，对齐 iOS `CloudDriveManager` UC 分支）。
  final UcNativeClient _uc;

  /// 阿里云盘 PG 4kz 播放链客户端（F-P09，对齐 iOS `AliyunPgPlayManager`）。
  final AliyunAdriveClient _aliyun;

  /// 网盘 Cookie 提供者（缺省读凭据安全存储 `cloud_drive_credentials_v1`）。
  final Future<String> Function(CloudDriveType type)? _cookieFor;

  /// 取指定网盘的 Cookie。
  Future<String> _cookie(CloudDriveType type) async {
    final Future<String> Function(CloudDriveType)? provider = _cookieFor;
    if (provider != null) return provider(type);
    return (await _credential(type))?.cookie ?? '';
  }

  /// 取指定网盘凭据（缺省读凭据安全存储 `cloud_drive_credentials_v1`）。
  Future<CloudDriveCredential?> _credential(CloudDriveType type) async {
    try {
      final CloudDriveCredentialStore store =
          CloudDriveCredentialStore(PrefsManager.instance);
      return await store.credential(type);
    } catch (_) {
      return null;
    }
  }

  /// 阿里云盘 PG 播放所需 Refresh Token（对齐 iOS `credential.refreshToken`）。
  Future<String> _aliyunRefreshToken() async =>
      (await _credential(CloudDriveType.ali))?.refreshToken ?? '';

  /// 阿里刷新结果落库（对齐 iOS `refreshAliAccessTokenIfNeeded` 全链落库，
  /// `CloudDriveAuthManager.swift:270-339`）。
  ///
  /// refresh_token 有轮换语义（每次刷新返回新值），不落库会导致下次播放
  /// 用旧值自毁凭据（`cloud_drive_credential_validator.dart` 登记缺陷）。
  static Future<void> _saveAliTokenRefreshed(
    String accessToken,
    String refreshToken,
  ) async {
    if (refreshToken.isEmpty) return;
    try {
      final CloudDriveCredentialStore store =
          CloudDriveCredentialStore(PrefsManager.instance);
      final CloudDriveCredential? cred =
          await store.credential(CloudDriveType.ali);
      if (cred == null) return;
      if (cred.refreshToken == refreshToken &&
          cred.accessToken == accessToken) {
        return;
      }
      await store.save(cred.copyWith(
        accessToken: accessToken.isEmpty ? null : accessToken,
        refreshToken: refreshToken,
        updatedAt: DateTime.now(),
      ));
    } catch (_) {
      // 落库失败不阻断播放（下次播放仍可用旧值重试刷新）。
    }
  }

  /// 百度授权中心保存的 bdstoken（凭据 `extra["bdstoken"]`）。
  ///
  /// 播放链 `fetchUserBdstoken` 四层兜底的最后一层
  /// （对齐 iOS `CloudDriveManager.swift:4726-4728`）。
  Future<String> _baiduSavedBdstoken() async =>
      (await _credential(CloudDriveType.baidu))?.extra['bdstoken'] ?? '';

  /// 百度用户态 bdstoken 回写（对齐 iOS `baiduPersistUserBdstoken`，
  /// `CloudDriveManager.swift:4758-4772`）：播放链活取成功后更新凭据 extra，
  /// **并合并本次请求所用 cookie**，下次活取被风控时可走保存值兜底。
  Future<void> _saveBaiduBdstoken(
    String bdstoken,
    String source,
    String mergedCookie,
  ) async {
    if (bdstoken.isEmpty) return;
    try {
      final CloudDriveCredentialStore store =
          CloudDriveCredentialStore(PrefsManager.instance);
      final CloudDriveCredential? cred =
          await store.credential(CloudDriveType.baidu);
      if (cred == null) return;
      // 对齐 iOS `baiduMergeCookieStrings([credential.cookie ?? "", mergedCookie])`：
      // 按 key 合并，保留旧 cookie 中未被覆盖的字段。
      final String merged = BaiduIBoxClient.mergeCookieStrings(
        <String>[cred.cookie ?? '', mergedCookie],
      );
      // bdstoken 与 cookie 均无变化则不写盘：secure storage（Windows 走 DPAPI）
      // 写入代价高，避免每次播放都重复落盘。
      if (cred.extra['bdstoken'] == bdstoken &&
          cred.extra['bdstoken_source'] == source &&
          (cred.cookie ?? '') == merged) {
        return;
      }
      await store.save(cred.copyWith(
        cookie: merged.isNotEmpty ? merged : cred.cookie,
        updatedAt: DateTime.now(),
        lastCheckedAt: DateTime.now(),
        state: CloudDriveAuthState.valid,
        statusMessage: '百度登录态已补齐 bdstoken',
        extra: <String, String>{
          ...cred.extra,
          'bdstoken': bdstoken,
          'bdstoken_source': source,
        },
      ));
      AppLog.info(
        'baidu-local',
        '已回写 bdstoken（source=$source）并合并 cookie',
        category: LogCategory.cloud,
      );
    } catch (e) {
      // 回写失败不阻断播放（对齐 iOS 宽松语义）。
      AppLog.warn(
        'baidu-local',
        '回写 bdstoken 失败：$e',
        category: LogCategory.cloud,
      );
    }
  }

  /// 阿里 PG 自动化配置（对齐 iOS `AliyunPgConfig.shared`，读取 `pg_ali_*`）。
  ///
  /// 读取失败回退契约缺省（与 iOS 未写入时的缺省行为一致：`enabled` 除外，
  /// 契约缺省关闭且 Flutter 不做首次写入）。
  Future<PgAutoConfig> _pgConfig() async {
    try {
      return await PgAutoStore(PrefsManager.instance).load();
    } catch (_) {
      return PgAutoConfig.defaults;
    }
  }

  /// UC TV Token（对齐 iOS `credential.extra["uc_tv_token"]`）。
  ///
  /// 注入 [cookieFor] 替身时无 extra，返回空串（等价 iOS 无 TV Token，
  /// 取链自动降级 v2/play → download_url）。
  Future<String> _ucTvToken() async {
    if (_cookieFor != null) return '';
    return (await _credential(CloudDriveType.uc))?.extra['uc_tv_token'] ?? '';
  }

  /// 取指定网盘的 Token 向量（对齐 iOS `CloudDriveManager.tokens(for:)`）。
  ///
  /// 注入 [cookieFor] 替身时以后者构造单元素向量（测试替身等价 iOS 手动 Token）。
  Future<List<DriveToken>> _tokensFor(CloudDriveType type) async {
    final Future<String> Function(CloudDriveType)? provider = _cookieFor;
    if (provider != null) {
      final String value = await provider(type);
      return value.isEmpty
          ? const <DriveToken>[]
          : <DriveToken>[DriveToken(type: type.id, name: '注入凭据', value: value)];
    }
    try {
      return await CloudDriveCredentialStore(PrefsManager.instance)
          .tokensFor(type);
    } catch (_) {
      return const <DriveToken>[];
    }
  }

  /// 百度双 Token 配对（对齐 iOS `CloudDriveManager.baiduTokenPair()`）。
  ///
  /// 注入 [cookieFor] 替身时以其构造 Web Token（无 PCS）。
  Future<BaiduTokenPair?> _baiduTokenPair() async {
    final Future<String> Function(CloudDriveType)? provider = _cookieFor;
    if (provider != null) {
      final String value = await provider(CloudDriveType.baidu);
      return value.isEmpty
          ? null
          : BaiduTokenPair(
              web: DriveToken(
                type: CloudDriveType.baidu.id,
                name: '注入凭据',
                value: value,
              ),
            );
    }
    try {
      return await CloudDriveCredentialStore(PrefsManager.instance)
          .baiduTokenPair();
    } catch (_) {
      return null;
    }
  }

  /// 播放前「凭据非空」统一前置校验（对齐 iOS `handleDriveUrl` 的
  /// `guard !tokens.isEmpty` → 「未配置<盘名> Token」）。
  ///
  /// 仅对需要本地 Token 的通道生效：Node 托管盘（走 Node 常驻系统，不依赖
  /// 本地凭据）与未支持盘跳过；缺失时统一文案（此前各盘分支自报、口径不一）。
  Future<void> _ensureTokens(CloudDriveType type) async {
    final PanPlayChannel channel = channelFor(type);
    if (channel != PanPlayChannel.native && channel != PanPlayChannel.pgAli) {
      return;
    }
    final List<DriveToken> tokens = await _tokensFor(type);
    if (tokens.isEmpty) {
      throw PanPlayException.fromDrive(
        DriveError.tokenNotConfigured(type.displayName),
      );
    }
  }

  /// 播放控制器（缺省取全局单例）。
  PlayerController get controller => _controller ??= PlayerController.instance;

  /// 路由通道判定（对齐 iOS `resolvePlayURL`）。
  static PanPlayChannel channelFor(CloudDriveType type) {
    if (NodePanRouting.isNodeManaged(type)) return PanPlayChannel.nodePan;
    if (type == CloudDriveType.ali) return PanPlayChannel.pgAli;
    if (type == CloudDriveType.quark ||
        type == CloudDriveType.baidu ||
        type == CloudDriveType.uc) {
      return PanPlayChannel.native;
    }
    return PanPlayChannel.unsupported;
  }

  /// 解析分享链接 → 条目列表（Node 托管盘 / 夸克原生）。
  Future<NodePanShare> resolveShare(CloudDriveType type, String shareUrl) async {
    await _ensureTokens(type);
    switch (channelFor(type)) {
      case PanPlayChannel.nodePan:
        try {
          return await _client.resolveShare(shareUrl);
        } on NodePanException catch (e) {
          throw PanPlayException(e.displayMessage);
        } catch (e) {
          // P0-D（问题 4）：扩大捕获面，非 NodePanException 也收敛为播放异常，
          // 避免冒泡到 UI 触发 App 闪退。
          throw PanPlayException('Node 网盘分享解析异常：$e');
        }
      case PanPlayChannel.native:
        if (type == CloudDriveType.quark) {
          final String cookie = await _cookie(type);
          final List<QuarkShareFile> files;
          try {
            files = await _quark.getFileList(
              shareUrl: shareUrl,
              cookie: cookie,
            );
          } on QuarkNativeException catch (e) {
            throw PanPlayException(e.message);
          }
          return NodePanShare(
            title: '夸克分享',
            entries: files
                .map((QuarkShareFile f) =>
                    NodePanEntry(playID: f.fid, name: f.fileName))
                .toList(growable: false),
          );
        }
        if (type == CloudDriveType.baidu) {
          // F-P17：经 baiduTokenPair 取 Web Cookie（账号态 BDUSS+STOKEN）。
          final BaiduTokenPair? pair = await _baiduTokenPair();
          if (pair == null) {
            throw PanPlayException.fromDrive(
              const DriveError.tokenNotConfigured('百度网盘'),
            );
          }
          final List<BaiduFileItem> files;
          try {
            files = await _baiduIBox.getFileList(
              shareUrl: shareUrl,
              cookie: pair.web.value,
            );
          } on BaiduIBoxException catch (e) {
            throw PanPlayException(e.message);
          } catch (e) {
            // P0-D（问题 4）：同 prepare 分支，扩大捕获面，避免非预期异常冒泡闪退。
            throw PanPlayException('百度分享解析异常：$e');
          }
          return NodePanShare(
            title: '百度分享',
            entries: files
                .map((BaiduFileItem f) =>
                    NodePanEntry(playID: f.fsId, name: f.name))
                .toList(growable: false),
          );
        }
        if (type == CloudDriveType.uc) {
          final String cookie = await _cookie(type);
          final String tvToken = await _ucTvToken();
          final List<UcShareFile> files;
          try {
            files = await _uc.getFileList(
              shareUrl: shareUrl,
              cookie: cookie,
              tvToken: tvToken,
            );
          } on UcNativeException catch (e) {
            throw PanPlayException(e.message);
          }
          return NodePanShare(
            title: 'UC分享',
            entries: files
                .map((UcShareFile f) =>
                    NodePanEntry(playID: f.fid, name: f.fileName))
                .toList(growable: false),
          );
        }
        throw PanPlayException.fromDrive(const DriveError.notImplemented());
      case PanPlayChannel.pgAli:
        final String refreshToken = await _aliyunRefreshToken();
        if (refreshToken.isEmpty) {
          throw const PanPlayException('阿里云盘未授权（缺少 Refresh Token），请先扫码登录');
        }
        final List<AliyunShareFile> files;
        try {
          files = await _aliyun.listPlayableFiles(
            shareUrl: shareUrl,
            refreshToken: refreshToken,
          );
        } on AliyunAdriveException catch (e) {
          throw PanPlayException(e.message);
        }
        return NodePanShare(
          title: '阿里云盘分享',
          entries: files
              .map((AliyunShareFile f) =>
                  NodePanEntry(playID: f.fileId, name: f.name))
              .toList(growable: false),
        );
      case PanPlayChannel.unsupported:
        throw PanPlayException.fromDrive(const DriveError.notImplemented());
    }
  }

  /// 解析条目 → 播放地址，并写入统一缓存。
  ///
  /// [sourceKey] 缺省用 [NodePanEntry.playID]（配合 provider 构成缓存键）。
  Future<CloudPlayItem> prepare({
    required CloudDriveType type,
    required String shareUrl,
    required NodePanEntry entry,
    String? sourceKey,
    String? routePreference,
    DateTime? now,
  }) async {
    await _ensureTokens(type);
    final DateTime stamp = now ?? DateTime.now();
    final String playURL;
    final String fileName;
    final Map<String, String> headers;
    final String source;
    // 兜底线路（主=原画/兜底=m3u8 等拓扑，对齐 iOS `PlayResult`）。
    String? fallbackUrl;
    Map<String, String> fallbackHeaders = const <String, String>{};
    String fallbackSource = '';
    switch (channelFor(type)) {
      case PanPlayChannel.nodePan:
        // F-P26：fragment 携带的 playID 可能已过期（Node 每次 detail 重签
        // playToken）→ 先重取本次文件列表三级匹配，再用新 playID 取链。
        final NodePanEntry matched;
        final NodePanPlayData data;
        try {
          matched = await _matchNodeEntry(shareUrl, entry);
          data = await _client.resolvePlay(matched.playID);
        } on NodePanException catch (e) {
          throw PanPlayException(e.displayMessage);
        } catch (e) {
          // P0-D（问题 4）：扩大异常捕获面 —— NodePanException 之外的异常
          //（空指针 / 通道异常等）也统一收敛，绝不允许冒泡触发 App 闪退。
          throw PanPlayException('Node 网盘播放解析异常：$e');
        }
        playURL = data.url;
        fileName = matched.name.isEmpty ? entry.name : matched.name;
        headers = data.headers;
        source = 'node-pan';
      case PanPlayChannel.native:
        if (type == CloudDriveType.quark) {
          final String cookie = await _cookie(type);
          try {
            final QuarkPlayResult r = await _quark.resolvePlayUrlWithRetry(
              shareUrl: shareUrl,
              cookie: cookie,
              preferredFid: entry.playID,
              routePreference: routePreference,
            );
            playURL = r.url;
            fileName = r.fileName.isEmpty ? entry.name : r.fileName;
            headers = r.headers.isNotEmpty
                ? r.headers
                : <String, String>{
                    if (cookie.isNotEmpty) 'Cookie': cookie,
                    'Referer': QuarkNativeClient.defaultReferer,
                  };
            fallbackUrl = r.fallbackUrl;
            fallbackHeaders = r.fallbackHeaders;
            fallbackSource = r.fallbackSource;
          } on QuarkNativeException catch (e) {
            throw PanPlayException(e.message);
          }
          source = 'quark-native';
        } else if (type == CloudDriveType.baidu) {
          // F-P17：Web Cookie（bduss）与 PCS Cookie 分离取用（对齐 iOS baiduTokenPair）。
          final BaiduTokenPair? pair = await _baiduTokenPair();
          if (pair == null) {
            throw PanPlayException.fromDrive(
              const DriveError.tokenNotConfigured('百度网盘'),
            );
          }
          final BaiduPlayResult r;
          try {
            r = await _baiduIBox.resolvePlayURL(
              shareUrl: shareUrl,
              bduss: pair.web.value,
              fsId: entry.playID,
              pcsCookie: pair.pcs?.value ?? '',
              savedBdstoken: await _baiduSavedBdstoken(),
              onBdstokenFetched:
                  (String token, String source, String mergedCookie) =>
                      unawaited(
                        _saveBaiduBdstoken(token, source, mergedCookie),
                      ),
            );
          } on BaiduIBoxException catch (e) {
            throw PanPlayException(e.message);
          } catch (e) {
            // P0-D（问题 4）：扩大异常捕获面 —— 非 `BaiduIBoxException` 的异常
            //（空指针 / 平台通道异常等）也统一转成 PanPlayException 文案，
            // 绝不允许冒泡到 UI 触发 App 闪退。
            throw PanPlayException('百度播放解析异常：$e');
          }
          playURL = r.url;
          fileName = entry.name;
          headers = r.headers;
          source = r.source;
        } else if (type == CloudDriveType.uc) {
          final String cookie = await _cookie(type);
          final String tvToken = await _ucTvToken();
          final UcPlayResult r;
          try {
            r = await _uc.resolvePlayUrl(
              shareUrl: shareUrl,
              cookie: cookie,
              preferredFid: entry.playID,
              tvToken: tvToken,
            );
          } on UcNativeException catch (e) {
            throw PanPlayException(e.message);
          }
          playURL = r.url;
          fileName = entry.name;
          headers = r.headers;
          fallbackUrl = r.fallbackUrl;
          fallbackHeaders = r.fallbackHeaders;
          fallbackSource = r.fallbackSource;
          source = 'uc-native';
        } else {
          throw PanPlayException.fromDrive(const DriveError.notImplemented());
        }
      case PanPlayChannel.pgAli:
        final String refreshToken = await _aliyunRefreshToken();
        if (refreshToken.isEmpty) {
          throw const PanPlayException('阿里云盘未授权（缺少 Refresh Token），请先扫码登录');
        }
        final PgAutoConfig pgConfig = await _pgConfig();
        final AliyunPlayResult r;
        try {
          r = await _aliyun.resolvePlayUrl(
            shareUrl: shareUrl,
            refreshToken: refreshToken,
            preferredFileId: entry.playID,
            pgConfig: pgConfig,
          );
        } on AliyunAdriveException catch (e) {
          throw PanPlayException(e.message);
        }
        playURL = r.url;
        fileName = r.fileName.isEmpty ? entry.name : r.fileName;
        headers = r.headers;
        fallbackUrl = r.fallbackUrl;
        fallbackHeaders = r.fallbackHeaders;
        fallbackSource = r.fallbackSource;
        source = r.source;
      case PanPlayChannel.unsupported:
        throw PanPlayException.fromDrive(const DriveError.notImplemented());
    }
    final CloudPlayItem item = CloudPlayItem(
      provider: type.id,
      sourceKey: sourceKey ?? entry.playID,
      shareURL: shareUrl,
      resourceId: entry.playID,
      fileName: fileName,
      playURL: playURL,
      headers: headers,
      compatibilityHint: source == 'node-pan' ? 'node-proxy' : source,
      preparedAt: stamp,
      updatedAt: stamp,
      source: source,
      fallbackURL: fallbackUrl,
      fallbackHeaders: fallbackHeaders,
      fallbackSource: fallbackSource,
    );
    await _cache.store(item);
    return item;
  }

  /// Node playID 稳定匹配（对齐 iOS `handleNodeManagedDrive` 三级匹配）。
  ///
  /// [shareUrl] 非空时先重取**本次**文件列表，再依次按
  /// ① playID 整串精确 → ② 稳定文件键（`fileId`，其次 `playToken.fid`）→
  /// ③ 文件名兜底 匹配详情页指定的剧集；命中后一律返回本次新解析出的条目，
  /// 用其新 playID 取链（避免 fragment 携带的旧 token 过期）。
  ///
  /// 三级皆未命中 → 明确报错（对齐 iOS `NodePanError.nodeRejected`
  /// 「详情页指定剧集未命中文件列表」）；[target] 无 playID（未指定剧集）→
  /// 回落首条（对齐 iOS `vbox_node` 缺省 `selectedIndex = 0`）。
  Future<NodePanEntry> _matchNodeEntry(
    String shareUrl,
    NodePanEntry target,
  ) async {
    if (shareUrl.isEmpty) return target;
    final NodePanShare share = await _client.resolveShare(shareUrl);
    final List<NodePanEntry> entries = share.entries;
    if (target.playID.isEmpty) return entries.first;

    for (final NodePanEntry e in entries) {
      if (e.playID == target.playID) return e;
    }
    final String? key = NodePlayId.stableFileKey(target.playID);
    if (key != null) {
      for (final NodePanEntry e in entries) {
        if (NodePlayId.stableFileKey(e.playID) == key) return e;
      }
    }
    final String? name = NodePlayId.fileName(target.playID);
    if (name != null) {
      for (final NodePanEntry e in entries) {
        if (e.name == name) return e;
      }
    }
    throw const PanPlayException('详情页指定剧集未命中文件列表');
  }

  /// 网盘条目 → 播放源（主线路经 Go 代理落地 + 携带兜底线路）。
  ///
  /// 对齐 iOS `CloudDriveManager.resolveQuarkStream` / 各盘注册语义：HLS（m3u8）
  /// 与夸克原画直链经本地 Go 代理注入鉴权头后播放；代理不可用则降级直链。
  Future<PlayerSource> sourceFor(CloudPlayItem item, {String? title}) async {
    final String? url = item.playURL;
    if (url == null || url.isEmpty) {
      throw const PanPlayException('播放地址为空');
    }
    final bool quark = item.provider == CloudDriveType.quark.id;
    // F-P09：百度 PCS 直链经本地代理注入合并后的 Cookie/UA/Referer（对齐 iOS
    // `playDriveVideo` 的 `provider:"baidu"` 分支，`PlayerViewsV2.swift:3814-3825`）。
    final bool baiduPcs = _isBaiduPcsUrl(url);
    return resolvePanSource(
      primary: PanPlaybackLine(
        url: url,
        headers: item.headers,
        source: item.source.startsWith('quark-') ||
                item.source.startsWith('uc-') ||
                item.source == 'node-pan'
            ? ''
            : item.source,
        useQuarkProxy: quark,
        useStreamProxy: baiduPcs,
      ),
      fallback: item.hasFallback
          ? PanPlaybackLine(
              url: item.fallbackURL!,
              headers: item.fallbackHeaders,
              source: item.fallbackSource,
              useQuarkProxy: quark,
            )
          : null,
      title: title,
      // F-P28：provider 随源透传（按盘内核策略分派键，对齐 iOS 按盘门闸）。
      provider: item.provider,
    );
  }

  /// 是否百度 PCS 直链（对齐 iOS `playDriveVideo` 的 `url.contains("baidupcs.com")
  /// || url.contains("d.pcs.baidu.com")` 判定，`PlayerViewsV2.swift:3815`）。
  static bool _isBaiduPcsUrl(String url) =>
      url.contains('baidupcs.com') || url.contains('d.pcs.baidu.com');

  /// 解析并打开播放（显式 `pan` 路由）。
  Future<CloudPlayItem> open({
    required CloudDriveType type,
    required String shareUrl,
    required NodePanEntry entry,
    String? sourceKey,
    DateTime? now,
  }) async {
    final CloudPlayItem item = await prepare(
      type: type,
      shareUrl: shareUrl,
      entry: entry,
      sourceKey: sourceKey,
      now: now,
    );
    if (!item.hasPlayURL) {
      throw const PanPlayException('播放地址为空');
    }
    await controller.open(
      // 统一播放源落地：HLS 经 Go 代理注册 + 携带兜底线路（F21）。
      await sourceFor(item, title: item.fileName.isEmpty ? null : item.fileName),
      route: PlaybackRoute.pan,
    );
    return item;
  }

  /// 缓存汇总（对齐 iOS `cloudPlayItemSummary`）。
  Future<CloudPlayItemSummary> summary(CloudDriveType type, {DateTime? now}) =>
      _cache.summary(type.id, now: now);

  /// 失效标记（`playURL` / `expiresAt` 清空，来源追加原因）。
  Future<void> invalidate({
    required CloudDriveType type,
    required String sourceKey,
    String reason = 'invalidated',
    DateTime? now,
  }) =>
      _cache.invalidate(
        provider: type.id,
        sourceKey: sourceKey,
        reason: reason,
        now: now,
      );

  /// 过期清理（仅目标 provider）。
  Future<void> clearExpired(CloudDriveType type, {DateTime? now}) =>
      _cache.clearExpired(type.id, now: now);

  /// 按盘清空缓存。
  Future<void> clear(CloudDriveType type) => _cache.clear(type.id);
}
