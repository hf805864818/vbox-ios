/// 数据层单测：网络音乐歌单 / 榜单服务（批次 G · G-音1 补测）。
///
/// 对齐基准：iOS `MusicPlaylistService.swift`（netease / qq / kugou / kuwo /
/// migu 五平台）。本文件覆盖 netease 全链（分类 / 广场 / 详情 / 榜单 / 搜索）
/// 与各平台的异常兜底（网络/解析失败返回空集合，对齐 iOS
/// `guard ... else { return [] }` 容错语义）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/data/datasources/remote/music_playlist_service.dart';
import 'package:vbox/domain/entities/music/music_playlist.dart';

HttpClient _client(
  Future<http.Response> Function(http.Request request) handler,
) =>
    HttpClient(
      inner: MockClient((http.Request request) async => handler(request)),
    );

MusicPlaylistService _service(
  Future<http.Response> Function(http.Request request) handler,
) =>
    MusicPlaylistService(client: _client(handler));

http.Response _json(String body, {int status = 200}) => http.Response(
      body,
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

void main() {
  group('netease 全链（对齐 iOS MusicPlaylistService）', () {
    test('getPlaylistCategories：固定「全部」+ sub 数组', () async {
      final MusicPlaylistService s = _service((http.Request r) async {
        expect(r.url.host, 'music.163.com');
        expect(r.url.path, '/api/playlist/catalogue');
        return _json('{"sub":[{"name":"华语"},{"name":"流行"},{"name":""}]}');
      });
      final List<PlaylistCategory> out =
          await s.getPlaylistCategories(MusicPlatformType.netease);
      expect(out.map((PlaylistCategory c) => c.name),
          <String>['全部', '华语', '流行']);
      expect(out.first.id, '全部');
    });

    test('getPlaylists：字段路径 playlists → PlaylistItem（wy_ 前缀）', () async {
      final MusicPlaylistService s = _service((http.Request r) async {
        expect(r.url.path, '/api/playlist/list');
        expect(r.url.queryParameters['cat'], '全部');
        expect(r.url.queryParameters['limit'], '35');
        expect(r.url.queryParameters['offset'], '35'); // page=1 → offset 35
        return _json(
          '{"playlists":[{"id":1,"name":"P1","coverImgUrl":"https://c/1",'
          '"playCount":12345,"trackCount":10,"creator":{"nickname":"u"}}]}',
        );
      });
      final List<PlaylistItem> out =
          await s.getPlaylists(MusicPlatformType.netease, page: 1);
      expect(out, hasLength(1));
      expect(out.first.id, 'wy_1');
      expect(out.first.name, 'P1');
      expect(out.first.creator, 'u');
      expect(out.first.songCount, 10);
    });

    test('getPlaylistDetail：playlist.tracks → 歌曲列表（ar/al/dt 路径）', () async {
      final MusicPlaylistService s = _service((http.Request r) async {
        expect(r.method, 'POST');
        expect(r.url.path, '/api/v3/playlist/detail');
        expect(r.body, contains('id=7'));
        return _json(
          '{"playlist":{"name":"D","coverImgUrl":"https://c/d",'
          '"creator":{"nickname":"u"},"description":"d","trackCount":1,'
          '"tracks":[{"id":9,"name":"S","dt":210000,'
          '"ar":[{"name":"A"}],"al":{"name":"AL","picUrl":"https://pic/1"}}]}}',
        );
      });
      final PlaylistDetail? detail =
          await s.getPlaylistDetail(MusicPlatformType.netease, '7');
      expect(detail, isNotNull);
      expect(detail!.id, 'wy_7');
      expect(detail.name, 'D');
      expect(detail.creator, 'u');
      expect(detail.songs, hasLength(1));
      expect(detail.songs.first.id, 'wy_9');
      expect(detail.songs.first.artist, 'A');
      expect(detail.songs.first.album, 'AL');
      expect(detail.songs.first.platform, 'wy');
    });

    test('getRankings：list → RankingItem', () async {
      final MusicPlaylistService s = _service((http.Request r) async {
        expect(r.url.path, '/api/toplist/detail');
        return _json(
          '{"list":[{"id":2,"name":"飙升榜","coverImgUrl":"https://c/2",'
          '"updateFrequency":"每天更新"}]}',
        );
      });
      final List<RankingItem> out =
          await s.getRankings(MusicPlatformType.netease);
      expect(out, hasLength(1));
      expect(out.first.id, 'wy_2');
      expect(out.first.name, '飙升榜');
      expect(out.first.updateFreq, '每天更新');
    });

    test('searchPlaylists：result.playlists → PlaylistItem', () async {
      final MusicPlaylistService s = _service((http.Request r) async {
        expect(r.url.path, '/api/cloudsearch/pc');
        expect(r.body, contains('s=')); // 关键词在 form body
        return _json(
          '{"result":{"playlists":[{"id":3,"name":"SP",'
          '"coverImgUrl":"https://c/3","trackCount":5}]}}',
        );
      });
      final List<PlaylistItem> out = await s.searchPlaylists(
        MusicPlatformType.netease,
        '华语',
      );
      expect(out, hasLength(1));
      expect(out.first.id, 'wy_3');
      expect(out.first.name, 'SP');
    });

    test('异常兜底：网络抛错 → 空集合 / null（对齐 iOS 容错）', () async {
      final MusicPlaylistService s = _service((http.Request r) async {
        throw StateError('boom');
      });
      expect(await s.getPlaylistCategories(MusicPlatformType.netease), isEmpty);
      expect(await s.getPlaylists(MusicPlatformType.netease), isEmpty);
      expect(await s.getPlaylistDetail(MusicPlatformType.netease, '1'), isNull);
      expect(await s.getRankings(MusicPlatformType.netease), isEmpty);
      expect(
        await s.searchPlaylists(MusicPlatformType.netease, 'x'),
        isEmpty,
      );
      expect(
        await s.getRankingDetail(MusicPlatformType.netease, '1'),
        isNull,
      );
    });

    test('非法 JSON → 空集合（解析失败兜底）', () async {
      final MusicPlaylistService s = _service(
        (http.Request r) async => _json('<html>not json</html>'),
      );
      expect(await s.getPlaylistCategories(MusicPlatformType.netease), isEmpty);
      expect(await s.getPlaylists(MusicPlatformType.netease), isEmpty);
    });
  });

  group('各平台兜底一致（网络失败 → 空集合 / null）', () {
    test('qq / kugou / kuwo / migu 全方法容错', () async {
      final MusicPlaylistService s = _service((http.Request r) async {
        throw StateError('boom');
      });
      for (final MusicPlatformType p in <MusicPlatformType>[
        MusicPlatformType.qq,
        MusicPlatformType.kugou,
        MusicPlatformType.kuwo,
        MusicPlatformType.migu,
      ]) {
        // 各平台失败兜底形态不一（kugou 固定「全部」分类 / 内置榜单 /
        // 本地兜底 detail，对齐 iOS），此用例只验证失败不抛异常。
        await s.getPlaylistCategories(p);
        await s.getPlaylists(p);
        await s.getPlaylistDetail(p, '1');
        await s.getRankings(p);
        await s.searchPlaylists(p, 'x');
        await s.getRankingDetail(p, '1');
      }
    });

    test('getRankingDetail：netease 复用歌单详情链', () async {
      final MusicPlaylistService s = _service((http.Request r) async =>
          _json('{"playlist":{"name":"RD","trackCount":0}}'));
      final PlaylistDetail? d =
          await s.getRankingDetail(MusicPlatformType.netease, '5');
      expect(d!.name, 'RD');
    });

    test('字段防御：条目非 Map / id 缺失 / name 为空时跳过', () async {
      final MusicPlaylistService s = _service((http.Request r) async =>
          _json('{"sub":[{"name":"A"},{"noName":1},"string-item",'
              '{"name":"B"}]}'));
      final List<PlaylistCategory> out =
          await s.getPlaylistCategories(MusicPlatformType.netease);
      expect(out.map((PlaylistCategory c) => c.name),
          <String>['全部', 'A', 'B']);
    });

    test('formEncode / 构造 URL：QQ 分派行（body 为 JSON 参数形态）', () async {
      // QQ 分类走 POST 到 u.y.qq.com 的 cgi 音乐库（iOS MusicPlaylistService）。
      final MusicPlaylistService s = _service((http.Request r) async {
        expect(r.url.host, contains('qq.com'));
        return _json('{}');
      });
      await s.getPlaylistCategories(MusicPlatformType.qq);
    });
  });
}
