/// 平台层：Node 常驻系统运行时管理器（批次 I · ND-01）。
///
/// 唯一真相源：`vbox/Services/NodeRuntimeManager.swift`（iOS，L30-L738）。
/// 逐档对齐关系如下：
///
/// | iOS | Flutter | 说明 |
/// |---|---|---|
/// | `start()` 六步 | [start] | 部署 → 完整性 → 拉起 → 后台刷 bundle → 就绪 → 健康监控 |
/// | `prepareRuntimeFiles` | [prepareRuntimeFiles] | 代码文件覆盖 / 数据文件仅首次（保护网盘凭据） |
/// | `verifyBundleIntegrity` + manifest | [verifyBundleIntegrity] | MD5 校验，损坏回退内置资源 |
/// | `refreshBundleIfNeeded` | [refreshBundleIfNeeded] | 版本探针 → 跳过；否则下载 → ≥1MB 合理性 → MD5 比对 → 原子写 |
/// | `launchNodeEngine`（setenv 矩阵） | [_buildHostConfig] | 11 个环境变量 1:1 |
/// | `waitForStartupAck` + `probeHealth` | [waitReady] | **`.startup.ack` 文件握手不移植**（NS-16）：就绪语义由 HTTP 探活等价 |
/// | `startHealthMonitor` / `runHealthCheck` | [startHealthMonitor] / [runHealthCheck] | 30s 周期 / 连续 3 次失败判崩溃 / 崩溃后保持探测自愈 |
/// | `handleNodeCrash` | [_handleCrash] | **Flutter 独立宿主可重启**（iOS NodeMobile 单实例不可），最多 [maxRestarts] 次 |
/// | `startLXHealthMonitor` | [startLXHealthMonitor] | 15s 周期，lx 桥接独立探活，不影响主链路 |
/// | `handleMemoryWarning` | [handleMemoryWarning] | 仅标记降级 + 提示，不主动杀 Node（保网盘会话） |
/// | `.relisten` 挂起恢复 | —— | **不移植**（NS-16）：Flutter 宿主进程不随 App 挂起 |
///
/// 就绪/崩溃事件经 [statusStream] 广播（对齐 iOS `nodeRuntimeStatus` /
/// `nodeRuntimeCrash` 通知），供启动编排、状态胶囊与凭据自动推送订阅。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/storage/storage_paths.dart';
import '../../core/utils/logger.dart';
import 'node_host.dart';
import 'node_ports.dart';

/// Node 常驻系统状态（`id` 对齐 iOS `statusInfo` 字符串）。
enum NodeRuntimeStatus {
  /// 未启动 / 已停止（`node-stopped`）。
  stopped('node-stopped', '未启动'),

  /// 启动中（`node-starting`）。
  starting('node-starting', '启动中'),

  /// 就绪（iOS 为 `node-ready(<port>)`，见 [NodeRuntimeStatus.id]）。
  ready('node-ready', '就绪'),

  /// 内存告警降级（`node-memory-warning`）。
  memoryWarning('node-memory-warning', '内存告警'),

  /// 已崩溃（`node-crashed`）。
  crashed('node-crashed', '已停止'),

  /// 启动失败（`node-failed`）。
  failed('node-failed', '启动失败');

  const NodeRuntimeStatus(this.id, this.label);

  /// iOS 同名状态串（`node-ready(<port>)` 由 [NodeRuntimeManager.statusInfo] 补端口）。
  final String id;

  /// 中文短标签（状态胶囊用）。
  final String label;
}

/// Node 内置资源来源（Flutter asset 或测试内存）。
abstract class NodeAssetSource {
  /// 读取 [key]（如 `assets/noderuntime/main.js`）；不存在返回 null。
  Future<List<int>?> load(String key);
}

/// 默认资源来源（`rootBundle`）。
class BundleNodeAssetSource implements NodeAssetSource {
  /// 构造。
  const BundleNodeAssetSource();

  @override
  Future<List<int>?> load(String key) async {
    try {
      final ByteData data = await rootBundle.load(key);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      // 资源缺失 → null，由调用方处理（代码/数据文件缺失即失败；
      // bundle 缺失由 verifyBundleIntegrity 抛错，对齐 iOS bundleResourceMissing）。
      return null;
    }
  }
}

/// Node 相关 HTTP 接缝（探活 + bundle 下载；可注入以便单测）。
abstract class NodeHttpTransport {
  /// GET [url] 的状态码；网络错误 / 超时返回 null。
  Future<int?> statusCode(String url, {Duration? timeout});

  /// GET [url] 字节体；非 2xx / 网络错误返回 null。
  Future<List<int>?> getBytes(String url, {Duration? timeout});

  /// GET [url] 文本体（版本探针用）；失败返回 null。
  Future<String?> getText(String url, {Duration? timeout});
}

/// 本机 HTTP 实现（`dart:io`）。
class IoNodeHttpTransport implements NodeHttpTransport {
  /// 构造。
  IoNodeHttpTransport();

  final HttpClient _client = HttpClient();

  @override
  Future<int?> statusCode(String url, {Duration? timeout}) async {
    final Duration t = timeout ?? const Duration(seconds: 3);
    try {
      final HttpClientRequest req =
          await _client.getUrl(Uri.parse(url)).timeout(t);
      final HttpClientResponse res = await req.close().timeout(t);
      await res.drain<void>().timeout(t);
      return res.statusCode;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<int>?> getBytes(String url, {Duration? timeout}) async {
    final Duration t = timeout ?? const Duration(seconds: 30);
    try {
      final HttpClientRequest req =
          await _client.getUrl(Uri.parse(url)).timeout(t);
      final HttpClientResponse res = await req.close().timeout(t);
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in res) {
        bytes.addAll(chunk);
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> getText(String url, {Duration? timeout}) async {
    final List<int>? bytes =
        await getBytes(url, timeout: timeout ?? const Duration(seconds: 10));
    if (bytes == null || bytes.isEmpty) return null;
    return utf8.decode(bytes, allowMalformed: true).trim();
  }
}

/// Node 常驻系统运行时管理器。
class NodeRuntimeManager {
  /// 构造（[host] / [assets] / [http] / [runtimeDirPath] 供测试注入）。
  NodeRuntimeManager({
    NodeHost? host,
    NodeAssetSource? assets,
    NodeHttpTransport? http,
    String? runtimeDirPath,
    this.healthInterval = const Duration(seconds: 30),
    this.maxHealthFailures = 3,
    this.healthProbeRetries = 12,
    this.healthProbeRetryDelay = const Duration(milliseconds: 500),
    this.lxHealthInterval = const Duration(seconds: 15),
    this.readyProbeRetries = 90,
    this.readyProbeDelay = const Duration(milliseconds: 500),
    this.maxRestarts = 3,
  })  : _host = host ?? NodeHost.forCurrentPlatform(),
        _assets = assets ?? const BundleNodeAssetSource(),
        _http = http ?? IoNodeHttpTransport(),
        _runtimeDirOverride = runtimeDirPath {
    // 子进程退出 → 立即感知（见 [_onChildExited]）；主动 stop 由 _stopping 屏蔽。
    _host.onChildExited = _onChildExited;
  }

  /// 全局单例（对齐 iOS `NodeRuntimeManager.shared`）。
  static final NodeRuntimeManager instance = NodeRuntimeManager();

  /// 内置资源根（`assets/` 下与本管理器同构的目录）。
  static const String assetRoot = 'assets/noderuntime';

  /// 心跳周期（对齐 iOS `healthInterval` 30s）。
  final Duration healthInterval;

  /// 连续心跳失败判定崩溃的阈值（对齐 iOS `maxHealthFailures` 3）。
  final int maxHealthFailures;

  /// 单次心跳内的探活重试次数（对齐 iOS `probeHealth(retries: 12)`）。
  ///
  /// iOS 每次心跳会重试 12 次才计一次失败，能吸收网络抖动 / 引擎短暂卡顿；
  /// 若只用 1 次，瞬时抖动会被放大成「连续失败 → 判崩溃 → 自动重启」，
  /// 直接打断正在播放的网盘链路，故逐档对齐。
  final int healthProbeRetries;

  /// 单次心跳内的探活重试间隔（对齐 iOS 500ms）。
  final Duration healthProbeRetryDelay;

  /// lx 桥接健康周期（对齐 iOS 15s）。
  final Duration lxHealthInterval;

  /// 就绪探活重试次数（等价 iOS `waitForStartupAck(45s)` + `probeHealth(12 次)`）。
  ///
  /// iOS 先等 `.startup.ack`（上限 45s）再 HTTP 探活；Flutter 不移植 ack 文件握手
  /// （NS-16），故把整段预算都给 HTTP 探活：90 × 500ms = 45s，避免慢设备上
  /// 引擎尚未监听就被误判为 `node-failed`（进而影响网盘取流 / 播放）。
  final int readyProbeRetries;

  /// 就绪探活重试间隔。
  final Duration readyProbeDelay;

  /// 崩溃后自动重启上限（Flutter 独立宿主能力；iOS 不可重启）。
  final int maxRestarts;

  final NodeHost _host;
  final NodeAssetSource _assets;
  final NodeHttpTransport _http;
  final String? _runtimeDirOverride;

  final StreamController<NodeRuntimeStatus> _statusController =
      StreamController<NodeRuntimeStatus>.broadcast();

  NodeRuntimeStatus _status = NodeRuntimeStatus.stopped;
  bool _isSystemReady = false;
  bool _isLXReady = false;
  bool _isCrashed = false;
  bool _starting = false;
  bool _startedOnce = false;

  /// 主动停止中：stop 杀子进程触发的退出回调不应视为崩溃。
  bool _stopping = false;

  /// 本次启动探活失败的具体原因（子进程退出 / 端口被顶包）；无则用通用文案。
  String? _probeFailureReason;

  int _consecutiveHealthFailures = 0;
  int _restartCount = 0;
  String? _lastError;

  Timer? _healthTimer;
  Timer? _lxHealthTimer;

  /// 在途的「崩溃后自动重启」任务。[stop] 需等待其收敛，否则停止后仍会继续落盘，
  /// 与调用方随后的目录清理 / 关闭竞态（如单测 tearDown 删除运行时目录）。
  Future<void>? _restartFuture;

  /// 状态变化广播（对齐 iOS `nodeRuntimeStatus` 通知）。
  Stream<NodeRuntimeStatus> get statusStream => _statusController.stream;

  /// 崩溃事件广播（对齐 iOS `nodeRuntimeCrash`，携带文案）。
  final StreamController<String> _crashController =
      StreamController<String>.broadcast();

  /// 崩溃事件流。
  Stream<String> get crashStream => _crashController.stream;

  /// 当前状态。
  NodeRuntimeStatus get status => _status;

  /// 是否就绪（启动探活通过且未被判崩溃）。
  bool get isSystemReady => _isSystemReady;

  /// lx-music 桥接是否就绪。
  bool get isLXReady => _isLXReady;

  /// 是否已判崩溃。
  bool get isCrashed => _isCrashed;

  /// 最近一次失败 / 崩溃文案。
  String? get lastError => _lastError;

  /// 当前生效端口（iOS 固定 58080）。
  int get activePort => NodePorts.main;

  /// 当前 Node HTTP base（供 Node 桥 / 网盘解析 / 凭据同步消费）。
  String get baseUrl => 'http://127.0.0.1:$activePort';

  /// 状态描述串（对齐 iOS `statusInfo`；就绪态带端口）。
  String get statusInfo => _status == NodeRuntimeStatus.ready
      ? 'node-ready($activePort)'
      : _status.id;

  /// 状态摘要（状态胶囊消费）。
  String get statusSummary => statusInfo;

  /// Node 运行时根目录（`<appData>/noderuntime`，与
  /// [defaultNodeConfigFilePath] 的 `wexfnwconfig.json` 同级）。
  String get runtimeDirPath =>
      _runtimeDirOverride ?? p.join(StoragePaths.root, 'noderuntime');

  /// bundle 落盘目录（`<runtimeDir>/bundles`）。
  String get bundleDirPath => p.join(runtimeDirPath, 'bundles');

  /// 当前 bundle 文件（`kstore_index.js`）。
  String get activeBundlePath => p.join(bundleDirPath, 'kstore_index.js');

  /// bundle MD5 清单路径。
  String get manifestPath => p.join(runtimeDirPath, 'bundle.manifest.json');

  /// 入口脚本路径（`main.js`）。
  String get mainScriptPath => p.join(runtimeDirPath, 'main.js');

  /// lx 插件目录（ND-03 下发）。
  String get lxPluginsDirPath => p.join(runtimeDirPath, 'plugins', 'lx');

  /// lx 桥接握手文件路径（对齐 iOS `LX_ACK_PATH`）。
  String get lxAckPath => p.join(runtimeDirPath, '.lx.ack');

  // ─────────────── 生命周期 ───────────────

  /// 启动 Node 常驻系统（启动编排 L-05-3 调用）。
  ///
  /// [bundleRefreshUrl] / [bundleVersionUrl] 为可选远端 bundle 地址（ND-02 下发；
  /// 未交付时传 null，行为与 iOS「未配置远端」一致）。
  Future<void> start({
    String? bundleRefreshUrl,
    String? bundleVersionUrl,
  }) async {
    if (_starting || _startedOnce) return;
    _starting = true;
    _startedOnce = true;
    _probeFailureReason = null;
    _setStatus(NodeRuntimeStatus.starting);
    try {
      // 1) 部署运行时文件（首次从资源复制到可写目录）
      await prepareRuntimeFiles();

      // 2) bundle 完整性校验（MD5 manifest，损坏回退内置资源）
      await verifyBundleIntegrity();

      // 2.5) 收编常驻引擎：Node 常驻设计下，上次 App 运行留下的 node.exe 仍
      // 占住端口。若其健康端点正常响应（同部署可复用的常驻引擎），直接收编、
      // 不再拉起新子进程 —— 否则新子进程必然 EADDRINUSE，顶包校验还会把
      // 「上次常驻」误判为「外来顶包」，导致每次重启 App 都报「Node 未就绪」
      // （3.1842 实测回归）。健康端点无响应 / 冒名进程占位时才走拉起流程。
      final String? adopted = await _tryAdoptResidentNode();
      if (adopted != null) {
        _log('♻️ 收编常驻 Node 引擎（$adopted），跳过重新拉起');
        _isSystemReady = true;
        _isCrashed = false;
        _lastError = null;
        _consecutiveHealthFailures = 0;
        _setStatus(NodeRuntimeStatus.ready);
        startHealthMonitor();
        startLXHealthMonitor();
        return;
      }

      // 2.6) 启动新子进程前清理占住主端口的孤儿 node.exe（Windows）：
      // 收编失败说明端口被「非本次可复用」的旧进程占住（典型：旧版本常驻
      // node.exe 孤儿）。若不清理，新子进程必然 EADDRINUSE。仅终止「占住
      // 58080 且镜像名为 node.exe」的进程，绝不动其他服务。
      await _clearStaleResidentOnPort();

      // 3) 拉起 Node 引擎（端口矩阵经环境变量注入）
      await _host.start(_buildHostConfig());

      // 4) 后台异步刷新远端 bundle（不阻塞就绪；新版下次启动生效）
      if (bundleRefreshUrl != null && bundleRefreshUrl.isNotEmpty) {
        unawaited(
          refreshBundleIfNeeded(bundleRefreshUrl, bundleVersionUrl)
              .catchError((Object e) => _log('⚠️ bundle 刷新失败：$e')),
        );
      }

      // 5) 就绪判定（HTTP 探活，等价 iOS ack + probe）
      final bool ready = await waitReady();
      if (!ready) {
        // 带上具体原因（子进程退出 / 端口被顶包），无则保持原通用文案。
        await _failStart(_probeFailureReason ?? 'Node 启动后 HTTP 探活失败');
        return;
      }

      _isSystemReady = true;
      _isCrashed = false;
      _lastError = null;
      _consecutiveHealthFailures = 0;
      _setStatus(NodeRuntimeStatus.ready);
      startHealthMonitor();
      startLXHealthMonitor();
    } on NodeHostException catch (e) {
      await _failStart(e.message);
    } catch (e) {
      await _failStart('$e');
    } finally {
      _starting = false;
    }
  }

  /// 停止 Node 系统并停掉全部定时器。
  Future<void> stop() async {
    _stopping = true;
    _healthTimer?.cancel();
    _healthTimer = null;
    _lxHealthTimer?.cancel();
    _lxHealthTimer = null;
    // 等待在途自动重启收敛：其 prepareRuntimeFiles 仍在写盘，若不等，
    // 停止后仍会继续写文件，与调用方随后的目录清理 / 关闭竞态。
    final Future<void>? restart = _restartFuture;
    if (restart != null) await restart;
    await _host.stop();
    _isSystemReady = false;
    _isLXReady = false;
    _setStatus(NodeRuntimeStatus.stopped);
    _stopping = false;
  }

  /// 内存告警降级（对齐 iOS `handleMemoryWarning`）。
  ///
  /// 未就绪时忽略（避免把启动态误标为异常）；就绪时仅标记 + 提示，
  /// **不主动杀 Node**（会丢失网盘会话）。
  void handleMemoryWarning() {
    _log('🧹 内存告警：Node 常驻占用较大');
    if (!_isSystemReady) return;
    _setStatus(NodeRuntimeStatus.memoryWarning);
  }

  // ─────────────── 运行时文件部署（对齐 iOS `prepareRuntimeFiles`） ───────────────

  /// 部署运行时文件：**代码文件以资源为准覆盖**，**数据文件仅首次复制**。
  ///
  /// `db.json` 登录后由 Node 侧写入网盘凭据，升级覆盖会导致用户数据丢失，
  /// 故与 iOS 一致严禁覆盖。
  Future<void> prepareRuntimeFiles() async {
    await Directory(runtimeDirPath).create(recursive: true);
    await Directory(bundleDirPath).create(recursive: true);

    // 代码文件（App 升级即覆盖，携带修复）
    for (final String name in <String>['main.js', 'node-intl-polyfill.js']) {
      await _copyAsset('$assetRoot/$name', p.join(runtimeDirPath, name), overwrite: true);
    }
    // lx-music 桥接层（非第三方插件；插件由远程源下发）
    final List<int>? lxBridge = await _assets.load('$assetRoot/lx/lx-bridge.js');
    if (lxBridge != null) {
      final String dst = p.join(runtimeDirPath, 'lx', 'lx-bridge.js');
      await Directory(p.dirname(dst)).create(recursive: true);
      await File(dst).writeAsBytes(lxBridge, flush: true);
    }
    // 插件目录（内容以远程同步为准）
    await Directory(lxPluginsDirPath).create(recursive: true);

    // 数据文件（仅首次；保护网盘凭据）
    for (final String name in <String>['db.json', 'default.db.json', 'wexfnwconfig.json']) {
      await _copyAsset('$assetRoot/$name', p.join(runtimeDirPath, name), overwrite: false);
    }
    _log('✅ 运行时文件就绪: $runtimeDirPath');
  }

  /// 复制内置资源到可写目录（[overwrite] 为 false 时已存在则跳过）。
  Future<void> _copyAsset(String assetKey, String dstPath, {required bool overwrite}) async {
    final File dst = File(dstPath);
    if (!overwrite && await dst.exists()) return;
    final List<int>? bytes = await _assets.load(assetKey);
    if (bytes == null) {
      if (overwrite) throw NodeHostException('Node 内置资源缺失: $assetKey');
      return;
    }
    await dst.writeAsBytes(bytes, flush: true);
  }

  // ─────────────── bundle 完整性（对齐 iOS `verifyBundleIntegrity`） ───────────────

  /// 校验落盘 bundle 与 manifest 的 MD5（对齐 iOS `verifyBundleIntegrity`）。
  ///
  /// · manifest 一致 → 放行；
  /// · 不一致 / 未登记 → 从**随包内置资源**回退复制并重建 manifest（对齐 iOS
  ///   `restoreBundleFromResource`，见 [assets/noderuntime/bundles/kstore_index.js]）；
  /// · 内置资源也缺失 → 抛 [NodeHostException]，由 [start] 收敛为 `node-failed`
  ///   （对齐 iOS `NodeRuntimeError.bundleResourceMissing`）。
  Future<void> verifyBundleIntegrity() async {
    final File bundle = File(activeBundlePath);
    final Map<String, Object?>? manifest = await readBundleManifest();
    final String? manifestMd5 = manifest?['md5'] as String?;

    if (bundle.existsSync() && manifestMd5 != null && manifestMd5.isNotEmpty) {
      final String local = md5.convert(await bundle.readAsBytes()).toString();
      if (local == manifestMd5) {
        _log('✅ bundle 完整性校验通过 MD5=${manifestMd5.substring(0, 8)}');
        return;
      }
    }

    _log('⚠️ bundle 与 manifest 不符或未登记，回退内置资源副本');
    final List<int>? builtin = await _assets.load('$assetRoot/bundles/kstore_index.js');
    if (builtin == null) {
      throw const NodeHostException('Node 资源缺失: bundles/kstore_index.js');
    }
    await bundle.writeAsBytes(builtin, flush: true);
    final String restored = md5.convert(builtin).toString();
    await writeBundleManifest(md5Hex: restored, source: 'bundled');
    _log('✅ bundle 已从内置资源恢复 MD5=${restored.substring(0, 8)}');
  }

  /// 读取 bundle manifest（缺失 / 解析失败返回 null）。
  Future<Map<String, Object?>?> readBundleManifest() async {
    try {
      final File f = File(manifestPath);
      if (!await f.exists()) return null;
      final Object? json = jsonDecode(await f.readAsString());
      return json is Map<String, Object?> ? json : null;
    } catch (_) {
      return null;
    }
  }

  /// 写入 bundle manifest（对齐 iOS `writeBundleManifest`）。
  Future<void> writeBundleManifest({
    required String md5Hex,
    required String source,
    String? version,
  }) async {
    final Map<String, Object?> manifest = <String, Object?>{
      'fileName': p.basename(activeBundlePath),
      'md5': md5Hex,
      'version': version,
      'source': source,
      'updatedAt': DateTime.now().millisecondsSinceEpoch / 1000,
    };
    await File(manifestPath).writeAsString(jsonEncode(manifest), flush: true);
  }

  /// 读本地记录的 bundle 版本（无记录返回 null）。
  Future<String?> readLocalBundleVersion() async =>
      (await readBundleManifest())?['version'] as String?;

  // ─────────────── 远端 bundle 刷新（对齐 iOS `refreshBundleIfNeeded`） ───────────────

  /// 版本探针比对 + 下载 MD5 校验 + 原子落盘（P1-03 / ND-02 安装段）。
  Future<void> refreshBundleIfNeeded(String url, [String? versionUrl]) async {
    // 版本探针：远端版本一致则跳过完整下载（大幅减少启动耗时）
    String? remoteVersion;
    if (versionUrl != null && versionUrl.isNotEmpty) {
      remoteVersion = await _http.getText(versionUrl);
      if (remoteVersion != null && remoteVersion.isNotEmpty) {
        final String? local = await readLocalBundleVersion();
        if (remoteVersion == local) {
          _log('✅ bundle 版本一致（$remoteVersion），无需更新');
          return;
        }
      }
    }

    final List<int>? data = await _http.getBytes(url);
    if (data == null || data.isEmpty) {
      _log('⚠️ bundle 拉取失败，回退本地缓存');
      return;
    }
    // 合理性校验：bundle 至少 1MB，防下载到错误页 / 空包
    if (data.length <= 1000000) {
      _log('⚠️ bundle 拉取异常（${data.length}B），丢弃');
      return;
    }
    final String remoteMd5 = md5.convert(data).toString();
    final File bundle = File(activeBundlePath);
    if (await bundle.exists() &&
        md5.convert(await bundle.readAsBytes()).toString() == remoteMd5) {
      _log('✅ bundle MD5 一致，无需更新');
      return;
    }
    // 原子写盘（先写临时文件再替换，避免写一半损坏）
    // 目标目录可能尚未部署（如独立调用刷新 / 首启竞态），先确保存在。
    await Directory(p.dirname(activeBundlePath)).create(recursive: true);
    final File tmp = File('$activeBundlePath.tmp');
    await tmp.writeAsBytes(data, flush: true);
    if (await bundle.exists()) await bundle.delete();
    await tmp.rename(activeBundlePath);
    await writeBundleManifest(md5Hex: remoteMd5, source: 'remote', version: remoteVersion);
    _log('✅ bundle 已更新 MD5=${remoteMd5.substring(0, 8)}');
  }

  // ─────────────── 宿主启动参数（对齐 iOS `launchNodeEngine`） ───────────────

  /// 尝试收编常驻 Node 引擎（健康时复用，不重新拉起）。
  ///
  /// 判定标准（两条都过才收编）：健康端点返回含 pid 的 JSON + 主端口状态端点
  /// 2xx。任一不满足（无进程 / 非 Node 的冒名服务 / 半死引擎）→ 返回 null，
  /// 走常规拉起流程（顶包校验保留兜底）。
  ///
  /// 说明：收编后 [_host.pid] 为 null，[probeHealth] 的顶包校验自动跳过
  /// （仅 ownPid != null 时执行），心跳退化为状态码判定；收编引擎若后续
  /// 死亡，走既有心跳失败 → 崩溃 → 重启路径，重启会重新拉起子进程。
  Future<String?> _tryAdoptResidentNode() async {
    try {
      final String? body = await _http.getText(
        'http://127.0.0.1:${NodePorts.health}/health',
        timeout: const Duration(seconds: 2),
      );
      int? residentPid;
      if (body != null && body.isNotEmpty) {
        try {
          final Object? json = jsonDecode(body);
          if (json is Map && json['pid'] is int) {
            residentPid = json['pid'] as int;
          }
        } catch (_) {
          return null; // 非 JSON（冒名服务占位）→ 不收编
        }
      }
      if (residentPid == null) return null;
      final int? code = await _http.statusCode(
        'http://127.0.0.1:$activePort/website/api/status',
        timeout: const Duration(seconds: 2),
      );
      if (code == null || code < 200 || code >= 300) return null;
      return 'pid=$residentPid';
    } catch (_) {
      return null; // 探测异常 → 按无常驻处理
    }
  }

  // ─────────────── 旧孤儿 node 进程清理（Windows）───────────────

  /// 清理占住主端口的孤儿 node.exe（Windows），启动新子进程前调用。
  ///
  /// 仅终止「正监听 58080 且进程镜像名为 node.exe」的进程，绝不误杀其他服务。
  /// 非 Windows 直接返回（macOS 无此场景，且 Job Object 该平台不适用）。
  Future<void> _clearStaleResidentOnPort() async {
    if (!Platform.isWindows) return;
    final int pid = await _pidListeningOnPort(activePort);
    if (pid <= 0) return;
    if (!await _isNodeProcess(pid)) {
      _log('⚠️ 端口 $activePort 被非 node 进程（pid=$pid）占用，不主动清理');
      return;
    }
    _log('🧹 清理占住端口 $activePort 的孤儿 node.exe（pid=$pid）');
    try {
      final ProcessResult r = await Process.run(
        'taskkill',
        <String>['/PID', '$pid', '/F'],
      );
      _log('🧹 taskkill /PID $pid /F → exit=${r.exitCode}');
    } catch (e) {
      _log('⚠️ 清理孤儿 node.exe 失败：$e');
    }
  }

  /// 用 `netstat -ano -p tcp` 找监听 [port] 的 pid；无则返回 0。
  Future<int> _pidListeningOnPort(int port) async {
    try {
      final ProcessResult r = await Process.run(
        'netstat',
        <String>['-ano', '-p', 'tcp'],
      );
      final String out = r.stdout.toString();
      if (r.exitCode != 0 || out.isEmpty) return 0;
      for (final String line in const LineSplitter().convert(out)) {
        if (!line.contains('LISTENING') || !line.contains(':$port')) continue;
        final List<String> parts = line.trim().split(RegExp(r'\s+'));
        final int pid = int.tryParse(parts.isNotEmpty ? parts.last : '') ?? 0;
        if (pid > 0) return pid;
      }
    } catch (_) {
      // netstat 不可用 → 视为无占用。
    }
    return 0;
  }

  /// 用 `tasklist` 判断 [pid] 是否为 node.exe。
  Future<bool> _isNodeProcess(int pid) async {
    try {
      final ProcessResult r = await Process.run(
        'tasklist',
        <String>['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH'],
      );
      return r.stdout.toString().toLowerCase().contains('node.exe');
    } catch (_) {
      return false;
    }
  }

  /// 构造宿主启动参数（环境变量矩阵与 iOS `setenv` 1:1）。
  NodeHostConfig _buildHostConfig() => NodeHostConfig(
        runtimeDir: runtimeDirPath,
        mainScript: mainScriptPath,
        bundlePath: activeBundlePath,
        lxPluginsDir: lxPluginsDirPath,
        lxAckPath: lxAckPath,
        environment: <String, String>{
          'PORT': '$activePort',
          'DEV_HTTP_PORT': '$activePort',
          'DART_PORT': '${activePort + 1}',
          'HEALTH_PORT': '${NodePorts.health}',
          'NODE_PATH': runtimeDirPath,
          'BUNDLE_PATH': activeBundlePath,
          'LX_PORT': '${NodePorts.lx}',
          'LX_HEALTH_PORT': '${NodePorts.lxHealth}',
          'LX_PLUGINS_DIR': lxPluginsDirPath,
          'LX_ACK_PATH': lxAckPath,
        },
      );

  // ─────────────── 就绪判定（等价 iOS ack + probe） ───────────────

  /// 等待 Node 就绪：HTTP 探活（健康端口优先，回退主端口状态端点）。
  ///
  /// NS-16：iOS `.startup.ack` 文件握手不移植，就绪语义由心跳等价判定。
  Future<bool> waitReady() =>
      probeHealth(retries: readyProbeRetries, retryDelay: readyProbeDelay);

  /// HTTP 探活（对齐 iOS `probeHealth`）。
  ///
  /// 额外做**顶包校验**：健康端点（main.js healthServer）返回
  /// `{status, pid, uptime}`，若响应 pid 与本宿主子进程 pid 不一致，说明端口
  /// 被其他进程占用（典型：旧版本常驻 node.exe 未退出，新子进程 EADDRINUSE），
  /// 当前子进程必然没绑上端口 —— 立即失败并给出可操作文案，避免探活打到
  /// 冒名进程而误判「就绪」（业务请求会全部落到错误进程上）。
  Future<bool> probeHealth({
    int retries = 1,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) async {
    final int attempts = retries < 1 ? 1 : retries;
    final int? ownPid = await _host.pid();
    for (int i = 0; i < attempts; i++) {
      // 顶包校验（仅健康端点返回 pid；主端口状态端点由状态码兜底）。
      if (ownPid != null) {
        final String? body = await _http.getText(
          'http://127.0.0.1:${NodePorts.health}/health',
          timeout: const Duration(seconds: 3),
        );
        final int? foreign = _foreignPidInHealth(body, ownPid);
        if (foreign != null) {
          _probeFailureReason = 'Node 端口 ${NodePorts.main} 已被其他进程占用'
              '（健康响应 pid=$foreign，本宿主子进程 pid=$ownPid，'
              '常见于旧版本常驻 node.exe 未退出）——'
              '请重启电脑，或在任务管理器结束对应进程后重试';
          _log('❌ $_probeFailureReason');
          return false;
        }
      }
      for (final String endpoint in <String>[
        'http://127.0.0.1:${NodePorts.health}/health',
        'http://127.0.0.1:$activePort/website/api/status',
      ]) {
        final int? code = await _http.statusCode(endpoint, timeout: const Duration(seconds: 3));
        if (code != null && code >= 200 && code < 300) return true;
      }
      if (i < attempts - 1) await Future<void>.delayed(retryDelay);
    }
    return false;
  }

  /// 解析健康端点响应体：能解析出 pid 且与 [ownPid] 不同 → 返回外来 pid。
  ///
  /// 响应缺失 / 非 JSON（其他服务占住端口）返回 null，交由状态码兜底判定。
  int? _foreignPidInHealth(String? body, int ownPid) {
    if (body == null || body.isEmpty) return null;
    try {
      final Object? json = jsonDecode(body);
      if (json is Map) {
        final Object? pid = json['pid'];
        if (pid is int && pid != ownPid) return pid;
      }
    } catch (_) {
      // 非 JSON → 无法判定顶包，维持原状态码语义。
    }
    return null;
  }

  /// 子进程意外退出（宿主回调；主动 stop 由 [_stopping] 屏蔽）。
  void _onChildExited(int exitCode) {
    if (_stopping) return;
    _log('⚠️ Node 子进程已退出（exitCode=$exitCode）');
    if (_starting) {
      // 启动阶段子进程就死了（典型：端口被占 → EADDRINUSE → main.js 不退出
      // 但也监听失败）。记录原因，让随后的探活失败文案带可操作信息；
      // 若探活随后检出顶包，会以更精确的文案覆盖。
      _probeFailureReason ??= 'Node 进程启动后立即退出（exitCode=$exitCode，'
          '端口可能被其他程序占用），请重启电脑或结束占用进程后重试';
      return;
    }
    if (_isSystemReady) {
      // 运行中崩溃 → 走既有崩溃处理（广播 + 自动重启）。
      _handleCrash();
    }
  }

  // ─────────────── 心跳与崩溃（对齐 iOS `startHealthMonitor`） ───────────────

  /// 启动 30s 周期心跳监控。
  void startHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(healthInterval, (_) => unawaited(runHealthCheck()));
  }

  /// 单次心跳检查（崩溃后仍保持探测以便自愈）。
  Future<void> runHealthCheck() async {
    if (!_isSystemReady && !_isCrashed) return;
    // 对齐 iOS `runHealthCheck` 内 `probeHealth()`（默认 12 次 × 500ms）：
    // 单次抖动不直接计失败，避免误判崩溃导致播放中断。
    final bool ok = await probeHealth(
      retries: healthProbeRetries,
      retryDelay: healthProbeRetryDelay,
    );
    if (ok) {
      _consecutiveHealthFailures = 0;
      if (_isCrashed || !_isSystemReady) {
        _isCrashed = false;
        _isSystemReady = true;
        _lastError = null;
        _setStatus(NodeRuntimeStatus.ready);
        _log('✅ Node 自愈：心跳恢复，系统重新就绪');
      } else if (_status == NodeRuntimeStatus.memoryWarning) {
        // 内存告警仅提示，健康恢复后还原就绪状态
        _setStatus(NodeRuntimeStatus.ready);
      }
      return;
    }
    _consecutiveHealthFailures += 1;
    _log('⚠️ 心跳失败 $_consecutiveHealthFailures/$maxHealthFailures');
    if (_consecutiveHealthFailures >= maxHealthFailures) {
      _handleCrash();
    }
  }

  /// 崩溃处理：标记 + 广播 + **尝试自动重启**（Flutter 独立宿主可重启）。
  void _handleCrash() {
    if (_isCrashed) return;
    _isCrashed = true;
    _isSystemReady = false;
    _consecutiveHealthFailures = 0;
    _lastError = 'Node 常驻服务已停止（连续 $maxHealthFailures 次心跳失败）。';
    _log('❌ $_lastError');
    if (!_crashController.isClosed) _crashController.add(_lastError!);
    _setStatus(NodeRuntimeStatus.crashed);
    _restartFuture = _attemptRestart();
  }

  /// 崩溃后自动重启（对齐 v2.10「崩溃自动恢复」；上限 [maxRestarts]）。
  Future<void> _attemptRestart() async {
    if (_restartCount >= maxRestarts) {
      _log('⚠️ Node 重启次数已达上限（$maxRestarts），停止重试');
      return;
    }
    _restartCount += 1;
    _log('🔁 尝试重启 Node（第 $_restartCount/$maxRestarts 次）');
    _setStatus(NodeRuntimeStatus.starting);
    _probeFailureReason = null;
    try {
      await prepareRuntimeFiles();
      await _clearStaleResidentOnPort();
      await _host.start(_buildHostConfig());
      if (await waitReady()) {
        _isCrashed = false;
        _isSystemReady = true;
        _lastError = null;
        _restartCount = 0;
        _setStatus(NodeRuntimeStatus.ready);
        _log('✅ Node 重启成功');
        return;
      }
    } catch (e) {
      _log('⚠️ Node 重启失败：$e');
    }
    _failStart('Node 重启失败（已尝试 $_restartCount/$maxRestarts 次）'
        '${_probeFailureReason == null ? '' : '：$_probeFailureReason'}');
  }

  /// 启动失败收尾（对齐 iOS `failStart`）。
  Future<void> _failStart(String message) async {
    _isSystemReady = false;
    _isCrashed = true;
    _lastError = message;
    _log('❌ 启动失败: $message');
    if (!_crashController.isClosed) _crashController.add(message);
    _setStatus(NodeRuntimeStatus.failed);
  }

  // ─────────────── lx-music 桥接健康（对齐 iOS `startLXHealthMonitor`） ───────────────

  /// 启动 lx 桥接健康监控（15s 周期 + 立即探一次）。
  void startLXHealthMonitor() {
    _lxHealthTimer?.cancel();
    _lxHealthTimer =
        Timer.periodic(lxHealthInterval, (_) => unawaited(runLXHealthCheck()));
    unawaited(runLXHealthCheck());
  }

  /// 单次 lx 探活；lx 不可用**不影响 kstore 主链路**。
  Future<void> runLXHealthCheck() async {
    final bool ok = await probeLXHealth();
    if (ok == _isLXReady) return;
    _isLXReady = ok;
    _log(ok
        ? '✅ lx-music 桥接就绪（127.0.0.1:${NodePorts.lx}）'
        : '⚠️ lx-music 桥接探活失败，标记不可用（kstore 主链路不受影响）');
    _emit();
  }

  /// lx 健康探活（对齐 iOS `probeLXHealth`：8 次 × 400ms）。
  Future<bool> probeLXHealth({
    int retries = 8,
    Duration retryDelay = const Duration(milliseconds: 400),
  }) async {
    for (int i = 0; i < retries; i++) {
      final int? code = await _http.statusCode(
        'http://127.0.0.1:${NodePorts.lxHealth}/health',
        timeout: const Duration(seconds: 2),
      );
      if (code != null && code >= 200 && code < 300) return true;
      if (i < retries - 1) await Future<void>.delayed(retryDelay);
    }
    return false;
  }

  // ─────────────── 内部工具 ───────────────

  void _setStatus(NodeRuntimeStatus status) {
    _status = status;
    _emit();
  }

  void _emit() {
    if (!_statusController.isClosed) _statusController.add(_status);
  }

  void _log(String message) {
    AppLog.log(LogLevel.info, 'node', message, category: LogCategory.node);
  }
}