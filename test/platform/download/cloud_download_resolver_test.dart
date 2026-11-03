/// 平台层单测：`cloud_download_resolver.dart`（P2b 网盘下载取链）。
///
/// 对齐 iOS `DownloadManager.resolveCloudDriveURL`
/// （DownloadManager.swift L238-L256）的判定分支：
///   ① 非 `cloud` 记录不负责（返回空串，交回默认解析链）；
///   ② 无法识别盘别 / 缺定位键 → unsupported；
///   ③ 执行时经 prepare 取链成功 → 直链 + 鉴权头 + 按地址判型；
///   ④ playURL 为空 / prepare 抛异常 → unsupported（下载失败态）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/models/download.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/cloud_play_item.dart';
import 'package:vbox/domain/entities/cloud/node_pan.dart';
import 'package:vbox/platform/download/download.dart';

/// 记录型 prepare 假件：返回预置结果 / 抛出预置异常，并记录调用参数。
class _RecordingPrepare {
  _RecordingPrepare({this.item, this.error});

  CloudPlayItem? item;
  Object? error;
  int calls = 0;
  CloudDriveType? lastType;
  String? lastShareUrl;
  NodePanEntry? lastEntry;
  String? lastSourceKey;

  Future<CloudPlayItem> call({
    required CloudDriveType type,
    required String shareUrl,
    required NodePanEntry entry,
    String? sourceKey,
  }) async {
    calls++;
    lastType = type;
    lastShareUrl = shareUrl;
    lastEntry = entry;
    lastSourceKey = sourceKey;
    final Object? e = error;
    if (e != null) throw e;
    return item!;
  }
}

Download _cloudRecord(String playurl, {int? id}) => Download(
      id: id,
      name: '测试剧集',
      playurl: playurl,
      addedAt: 1000,
      sourceType: 'cloud',
    );

CloudPlayItem _item(String playURL) => CloudPlayItem(
      provider: CloudDriveType.quark.id,
      sourceKey: 'share-x',
      playURL: playURL,
      headers: const <String, String>{'User-Agent': 'vbox-test'},
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

void main() {
  group('CloudDownloadUrlResolver', () {
    test('非 cloud 记录不负责（不触发取链）', () async {
      final _RecordingPrepare prepare = _RecordingPrepare(item: _item(''));
      final CloudDownloadUrlResolver resolver =
          CloudDownloadUrlResolver(prepare: prepare.call);
      const Download record = Download(
        name: '普通直链',
        playurl: 'https://cdn.example.com/a.mp4',
        addedAt: 1,
        sourceType: 'normal',
      );

      final ResolvedDownloadUrl r = await resolver.resolve(record);

      expect(r.url, isEmpty);
      expect(r.type, DownloadType.unsupported);
      expect(prepare.calls, 0);
    });

    test('无法识别盘别 → unsupported', () async {
      final _RecordingPrepare prepare = _RecordingPrepare(item: _item(''));
      final CloudDownloadUrlResolver resolver =
          CloudDownloadUrlResolver(prepare: prepare.call);

      final ResolvedDownloadUrl r = await resolver
          .resolve(_cloudRecord('https://example.com/s/abc#vbox_fid=1'));

      expect(r.url, isEmpty);
      expect(r.type, DownloadType.unsupported);
      expect(prepare.calls, 0);
    });

    test('识别盘别但缺定位键 → unsupported', () async {
      final _RecordingPrepare prepare = _RecordingPrepare(item: _item(''));
      final CloudDownloadUrlResolver resolver =
          CloudDownloadUrlResolver(prepare: prepare.call);

      // 夸克分享链但未携带 vbox_fid。
      final ResolvedDownloadUrl r = await resolver
          .resolve(_cloudRecord('https://pan.quark.cn/s/abc'));

      expect(r.url, isEmpty);
      expect(r.type, DownloadType.unsupported);
      expect(prepare.calls, 0);
    });

    test('夸克 vbox_fid：取链成功 → m3u8 直链 + 鉴权头', () async {
      const String playUrl = 'https://dl.quark.example/1.m3u8';
      final _RecordingPrepare prepare = _RecordingPrepare(item: _item(playUrl));
      final CloudDownloadUrlResolver resolver =
          CloudDownloadUrlResolver(prepare: prepare.call);

      final ResolvedDownloadUrl r = await resolver.resolve(
        _cloudRecord('https://pan.quark.cn/s/abc#vbox_fid=123', id: 7),
      );

      expect(r.url, playUrl);
      expect(r.type, DownloadType.m3u8);
      expect(r.headers['User-Agent'], 'vbox-test');
      expect(prepare.calls, 1);
      expect(prepare.lastType, CloudDriveType.quark);
      expect(prepare.lastShareUrl, 'https://pan.quark.cn/s/abc');
      expect(prepare.lastEntry?.playID, '123');
      expect(prepare.lastEntry?.name, '测试剧集');
      expect(prepare.lastSourceKey, 'dl_7');
    });

    test('vbox_nd=1 派生 Node 盘别 + vbox_node 定位键', () async {
      const String playUrl = 'https://dl.node.example/2.m3u8';
      final _RecordingPrepare prepare = _RecordingPrepare(item: _item(playUrl));
      final CloudDownloadUrlResolver resolver =
          CloudDownloadUrlResolver(prepare: prepare.call);

      final ResolvedDownloadUrl r = await resolver.resolve(
        _cloudRecord('https://pan.quark.cn/s/xyz#vbox_nd=1&vbox_node=456'),
      );

      expect(r.url, playUrl);
      expect(r.type, DownloadType.m3u8);
      expect(prepare.lastType, CloudDriveType.quarkNode);
      expect(prepare.lastEntry?.playID, '456');
    });

    test('mp4 直链 → directFile 判型', () async {
      const String playUrl = 'https://dl.quark.example/3.mp4';
      final _RecordingPrepare prepare = _RecordingPrepare(item: _item(playUrl));
      final CloudDownloadUrlResolver resolver =
          CloudDownloadUrlResolver(prepare: prepare.call);

      final ResolvedDownloadUrl r = await resolver
          .resolve(_cloudRecord('https://pan.quark.cn/s/abc#vbox_fid=1'));

      expect(r.url, playUrl);
      expect(r.type, DownloadType.directFile);
    });

    test('playURL 为空 → unsupported', () async {
      final _RecordingPrepare prepare = _RecordingPrepare(item: _item(''));
      final CloudDownloadUrlResolver resolver =
          CloudDownloadUrlResolver(prepare: prepare.call);

      final ResolvedDownloadUrl r = await resolver
          .resolve(_cloudRecord('https://pan.quark.cn/s/abc#vbox_fid=1'));

      expect(r.url, isEmpty);
      expect(r.type, DownloadType.unsupported);
      expect(prepare.calls, 1);
    });

    test('取链抛异常 → unsupported（下载失败态，不外溢）', () async {
      final _RecordingPrepare prepare =
          _RecordingPrepare(error: StateError('token 过期'));
      final CloudDownloadUrlResolver resolver =
          CloudDownloadUrlResolver(prepare: prepare.call);

      final ResolvedDownloadUrl r = await resolver
          .resolve(_cloudRecord('https://pan.quark.cn/s/abc#vbox_fid=1'));

      expect(r.url, isEmpty);
      expect(r.type, DownloadType.unsupported);
      expect(prepare.calls, 1);
    });
  });
}
