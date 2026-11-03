/// ND-03：lx-music 桥接插件远程缓存单测。
///
/// 对齐 iOS `RemoteSourceConfigManager.downloadAndCacheLXPlugins`（L553-589）
/// 与 `syncLXPlugin`（L591-646）全语义：版本标记跳过 / 相对与绝对 URL /
/// 内容下限 / md5 强校验 / 原子写入 + version 标记 / 失败保留旧版不抛错。
library;

import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/remote/lx_plugin_syncer.dart';

void main() {
  late Directory tempDir;
  late List<Uri> requested;
  late Map<String, List<int>> responses;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lx_sync_test');
    requested = <Uri>[];
    responses = <String, List<int>>{};
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  LxPluginSyncer syncer() => LxPluginSyncer(
        fetch: (Uri url) async {
          requested.add(url);
          final List<int>? body = responses[url.toString()];
          if (body == null) throw StateError('404: $url');
          return body;
        },
        pluginsDirPath: () => tempDir.path,
        logger: (_) {},
      );

  Map<String, Object?> lxSite({
    String key = 'nodejs_musicaidaxe',
    String pluginPath = 'sources/lx/daxe.js',
    String? version,
    String? md5,
  }) =>
      <String, Object?>{
        'key': key,
        'name': '音乐',
        'type': 3,
        'engineType': 'lxMusic',
        'pluginPath': pluginPath,
        if (version != null) 'version': version,
        if (md5 != null) 'md5': md5,
      };

  test('无 lx 站点 → 不发起请求', () async {
    final LxPluginSyncReport r = await syncer().syncSites(
      sites: <Map<String, Object?>>[
        <String, Object?>{'key': 'a', 'name': 'A', 'type': 0},
      ],
      baseURL: 'https://example.com/cfg',
    );
    expect(r.lxSiteCount, 0);
    expect(requested, isEmpty);
    expect(r.ok, isTrue);
  });

  test('未注入目录 / 下载通道 → 空转不抛', () async {
    final LxPluginSyncReport r = await LxPluginSyncer(logger: (_) {})
        .syncSites(sites: <Map<String, Object?>>[lxSite()], baseURL: 'x');
    expect(r.lxSiteCount, 0);
    expect(requested, isEmpty);
  });

  test('正常下载：md5 匹配 → 原子写入 + version 标记', () async {
    final List<int> body = List<int>.generate(200, (int i) => i % 256);
    responses['https://example.com/cfg/sources/lx/daxe.js'] = body;
    final LxPluginSyncReport r = await syncer().syncSites(
      sites: <Map<String, Object?>>[
        lxSite(version: '1.2.0', md5: crypto.md5.convert(body).toString()),
      ],
      baseURL: 'https://example.com/cfg',
    );
    expect(r.synced, <String>['nodejs_musicaidaxe']);
    expect(r.ok, isTrue);
    final File dest = File('${tempDir.path}/daxe.js');
    expect(dest.existsSync(), isTrue);
    expect(dest.readAsBytesSync(), body);
    expect(
      File('${tempDir.path}/daxe.js.version').readAsStringSync(),
      '1.2.0',
    );
    // 原子写入：不留 .tmp 残留。
    expect(
      Directory(tempDir.path).listSync().any(
            (FileSystemEntity e) => e.path.endsWith('.tmp'),
          ),
      isFalse,
    );
  });

  test('版本标记一致 → skipped 且不请求', () async {
    File('${tempDir.path}/daxe.js').writeAsStringSync('// old', flush: true);
    File('${tempDir.path}/daxe.js.version')
        .writeAsStringSync('  9.9.9\n', flush: true);
    final LxPluginSyncReport r = await syncer().syncSites(
      sites: <Map<String, Object?>>[lxSite(version: '9.9.9')],
      baseURL: 'https://example.com/cfg',
    );
    expect(r.skipped, <String>['nodejs_musicaidaxe']);
    expect(requested, isEmpty);
    // 旧文件保留。
    expect(File('${tempDir.path}/daxe.js').readAsStringSync(), '// old');
  });

  test('md5 不匹配 → 丢弃不落盘', () async {
    final List<int> body = List<int>.generate(200, (int i) => 7);
    responses['https://example.com/cfg/sources/lx/daxe.js'] = body;
    final LxPluginSyncReport r = await syncer().syncSites(
      sites: <Map<String, Object?>>[
        lxSite(md5: 'deadbeefdeadbeefdeadbeefdeadbeef'),
      ],
      baseURL: 'https://example.com/cfg',
    );
    expect(r.failed, <String>['nodejs_musicaidaxe']);
    expect(File('${tempDir.path}/daxe.js').existsSync(), isFalse);
  });

  test('内容过短（≤100 字节）→ 丢弃', () async {
    responses['https://example.com/cfg/sources/lx/daxe.js'] =
        List<int>.filled(100, 65);
    final LxPluginSyncReport r = await syncer().syncSites(
      sites: <Map<String, Object?>>[lxSite()],
      baseURL: 'https://example.com/cfg',
    );
    expect(r.failed, <String>['nodejs_musicaidaxe']);
    expect(File('${tempDir.path}/daxe.js').existsSync(), isFalse);
  });

  test('非 .js 后缀 → 不请求直接失败', () async {
    final LxPluginSyncReport r = await syncer().syncSites(
      sites: <Map<String, Object?>>[
        lxSite(key: 'bad', pluginPath: 'sources/lx/daxe.json'),
      ],
      baseURL: 'https://example.com/cfg',
    );
    expect(r.failed, <String>['bad']);
    expect(requested, isEmpty);
  });

  test('绝对 URL pluginPath → 直接下载', () async {
    final List<int> body = List<int>.generate(150, (int i) => 1);
    responses['https://cdn.example.com/lx/nianxin.js'] = body;
    final LxPluginSyncReport r = await syncer().syncSites(
      sites: <Map<String, Object?>>[
        lxSite(
          key: 'nodejs_musicainianxin',
          pluginPath: 'https://cdn.example.com/lx/nianxin.js',
        ),
      ],
      baseURL: 'https://example.com/cfg',
    );
    expect(r.synced, <String>['nodejs_musicainianxin']);
    expect(
      requested.single.toString(),
      'https://cdn.example.com/lx/nianxin.js',
    );
  });

  test('./ 前缀相对路径 → 去前缀拼接', () async {
    final List<int> body = List<int>.generate(150, (int i) => 2);
    responses['https://example.com/cfg/sources/lx/daxe.js'] = body;
    final LxPluginSyncReport r = await syncer().syncSites(
      sites: <Map<String, Object?>>[
        lxSite(pluginPath: './sources/lx/daxe.js'),
      ],
      baseURL: 'https://example.com/cfg',
    );
    expect(r.synced, isNotEmpty);
    expect(
      requested.single.toString(),
      'https://example.com/cfg/sources/lx/daxe.js',
    );
  });

  test('下载异常 → failed 不抛 + 旧文件保留', () async {
    final File old = File('${tempDir.path}/daxe.js')
      ..writeAsStringSync('// old', flush: true);
    final LxPluginSyncReport r = await syncer().syncSites(
      sites: <Map<String, Object?>>[lxSite()], // 无响应路由 → fetch 抛 404
      baseURL: 'https://example.com/cfg',
    );
    expect(r.failed, <String>['nodejs_musicaidaxe']);
    expect(r.ok, isFalse);
    expect(old.readAsStringSync(), '// old');
  });

  test('未下发 md5 → 不做完整性校验直接落盘', () async {
    final List<int> body = List<int>.generate(120, (int i) => 3);
    responses['https://example.com/cfg/sources/lx/daxe.js'] = body;
    final LxPluginSyncReport r = await syncer().syncSites(
      sites: <Map<String, Object?>>[lxSite()],
      baseURL: 'https://example.com/cfg',
    );
    expect(r.synced, isNotEmpty);
    expect(File('${tempDir.path}/daxe.js').existsSync(), isTrue);
  });
}
