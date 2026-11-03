/// 平台层单测：网盘下载执行侧装配链（A1 · P0-1）。
///
/// 验证生产装配组合（对齐 [lib/app.dart](../../../../lib/app.dart) 下载管理器
/// 装配点）：`DefaultDownloadUrlResolver(delegate: CloudDownloadUrlResolver)`。
///
/// 对齐 iOS `DownloadManager.swift` 解析链语义：
///   ① 普通记录（入队前已预解析直链）→ `isDirectMediaUrl` 直接命中，不触网盘取链；
///   ② 网盘记录（`sourceType=='cloud'`，入队时仅存分享链）→ 执行时委托
///      `resolveCloudDriveURL`（L238-L256）取链，m3u8 直链 + 鉴权头透传；
///   ③ 取链失败（token 过期等）→ unsupported 下载失败态（可重试）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/models/download.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/cloud_play_item.dart';
import 'package:vbox/domain/entities/cloud/node_pan.dart';
import 'package:vbox/platform/download/download.dart';

/// 记录型 prepare 假件（与 resolver 单测同款）。
class _RecordingPrepare {
  _RecordingPrepare({this.item, this.error});

  CloudPlayItem? item;
  Object? error;
  int calls = 0;

  Future<CloudPlayItem> call({
    required CloudDriveType type,
    required String shareUrl,
    required NodePanEntry entry,
    String? sourceKey,
  }) async {
    calls++;
    final Object? e = error;
    if (e != null) throw e;
    return item!;
  }
}

CloudPlayItem _item(String playURL) => CloudPlayItem(
      provider: CloudDriveType.quark.id,
      sourceKey: 'share-x',
      playURL: playURL,
      headers: const <String, String>{'User-Agent': 'vbox-test'},
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

/// 生产装配的解析链（与 app.dart 装配点同构；prepare 注入假件）。
DownloadUrlResolver _buildWiredResolver(_RecordingPrepare prepare) =>
    DefaultDownloadUrlResolver(
      delegate: CloudDownloadUrlResolver(prepare: prepare.call),
    );

void main() {
  group('网盘下载装配链（DefaultDownloadUrlResolver + CloudDownloadUrlResolver）', () {
    test('云源记录：执行时取链 → m3u8 直链 + 鉴权头透传', () async {
      const String playUrl = 'https://dl.quark.example/1.m3u8';
      final _RecordingPrepare prepare = _RecordingPrepare(item: _item(playUrl));
      final DownloadUrlResolver resolver = _buildWiredResolver(prepare);

      final ResolvedDownloadUrl r = await resolver.resolve(const Download(
        name: '测试剧集',
        playurl: 'https://pan.quark.cn/s/abc#vbox_fid=123',
        addedAt: 1000,
        sourceType: 'cloud',
      ));

      expect(r.url, playUrl);
      expect(r.type, DownloadType.m3u8);
      expect(r.headers['User-Agent'], 'vbox-test');
      expect(prepare.calls, 1);
    });

    test('普通直链记录：默认链直接命中，不触发网盘取链', () async {
      final _RecordingPrepare prepare = _RecordingPrepare(item: _item(''));
      final DownloadUrlResolver resolver = _buildWiredResolver(prepare);

      final ResolvedDownloadUrl r = await resolver.resolve(const Download(
        name: '普通资源',
        playurl: 'https://cdn.example.com/a.mp4',
        addedAt: 1,
        sourceType: 'normal',
      ));

      expect(r.url, 'https://cdn.example.com/a.mp4');
      expect(r.type, DownloadType.directFile);
      expect(prepare.calls, 0);
    });

    test('取链抛异常 → unsupported（下载失败态，可重试）', () async {
      final _RecordingPrepare prepare =
          _RecordingPrepare(error: StateError('token 过期'));
      final DownloadUrlResolver resolver = _buildWiredResolver(prepare);

      final ResolvedDownloadUrl r = await resolver.resolve(const Download(
        name: '测试剧集',
        playurl: 'https://pan.quark.cn/s/abc#vbox_fid=1',
        addedAt: 1,
        sourceType: 'cloud',
      ));

      expect(r.url, isEmpty);
      expect(r.type, DownloadType.unsupported);
      expect(prepare.calls, 1);
    });

    test('云源分享链无定位键 → unsupported（不外溢异常）', () async {
      final _RecordingPrepare prepare = _RecordingPrepare(item: _item(''));
      final DownloadUrlResolver resolver = _buildWiredResolver(prepare);

      final ResolvedDownloadUrl r = await resolver.resolve(const Download(
        name: '测试剧集',
        playurl: 'https://pan.quark.cn/s/abc',
        addedAt: 1,
        sourceType: 'cloud',
      ));

      expect(r.url, isEmpty);
      expect(r.type, DownloadType.unsupported);
      expect(prepare.calls, 0);
    });
  });
}
