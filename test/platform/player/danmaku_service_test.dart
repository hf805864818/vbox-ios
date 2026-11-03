/// 批次 C · C-03：弹幕数据源（解析 / 匹配拉取 / 发送）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/platform/player/danmaku/danmaku_item.dart';
import 'package:vbox/platform/player/danmaku/danmaku_service.dart';

void main() {
  group('DanmakuService 纯解析', () {
    test('parseMatchedEpisodeId 取首个命中', () {
      expect(
        DanmakuService.parseMatchedEpisodeId(
          '{"success":true,"matches":[{"episodeId":123,"animeTitle":"剧"}]}',
        ),
        123,
      );
      expect(
        DanmakuService.parseMatchedEpisodeId('{"success":false,"matches":[]}'),
        isNull,
      );
      expect(DanmakuService.parseMatchedEpisodeId('not-json'), isNull);
    });

    test('parseAnimeId 兼容 animes / 数组', () {
      expect(
        DanmakuService.parseAnimeId('{"animes":[{"animeId":9}]}'),
        9,
      );
      expect(
        DanmakuService.parseAnimeId('[{"anime_id":"11"}]'),
        11,
      );
    });

    test('parseEpisodeIdByNumber 按集数取 id，缺省回落首集', () {
      const String body = '{"bangumi":{"episodes":['
          '{"episodeId":1,"episodeNumber":1},'
          '{"episodeId":5,"episodeNumber":5}]}}';
      expect(DanmakuService.parseEpisodeIdByNumber(body, 5), 5);
      expect(DanmakuService.parseEpisodeIdByNumber(body, 99), 1);
    });

    test('parseComments 解析 {comments:[...]}（p 字段）', () {
      const String body = '{"comments":['
          '{"cid":1,"p":"12.5,1,25,16711680","m":"滚动弹幕"},'
          '{"cid":2,"p":"3,5,25,16777215","m":"顶部弹幕"}]}';
      final List<DanmakuItem> items = DanmakuService.parseComments(body);
      expect(items, hasLength(2));
      expect(items[0].content, '滚动弹幕');
      expect(items[0].timeMs, 12500);
      expect(items[0].mode, DanmakuMode.scroll);
      expect(items[0].argb, 0xFFFF0000);
      expect(items[1].mode, DanmakuMode.top);
    });

    test('parseComments 兼容 progress（毫秒）/ time（秒）', () {
      final List<DanmakuItem> items = DanmakuService.parseComments(
        '{"comments":[{"content":"A","progress":5000},'
        '{"content":"B","time":7.2}]}',
      );
      expect(items[0].timeMs, 5000);
      expect(items[1].timeMs, 7200);
    });

    test('parseComments 空文本丢弃 / 非 comments 结构回落通用解析', () {
      expect(
        DanmakuService.parseComments('{"comments":[{"m":"  "},{"m":"ok","p":"1,1,25,16777215"}]}'),
        hasLength(1),
      );
      // JSON 数组形态交回 DanmakuParser。
      expect(
        DanmakuService.parseComments(
          '[{"time":1.5,"content":"数组弹幕","mode":1,"color":16777215}]',
        ),
        hasLength(1),
      );
    });

    // ── UI-F3 弹幕搜索：多候选 + 分集列表 ──
    test('parseAnimeMatches 保留完整候选（animes 形态）', () {
      const String body = '{"animes":['
          '{"animeId":1,"animeTitle":"剧A","type":"TV动画"},'
          '{"anime_id":"2","title":"剧B","imageUrl":"http://x/y.jpg"}]}';
      final List<DanmakuAnimeMatch> list =
          DanmakuService.parseAnimeMatches(body);
      expect(list, hasLength(2));
      expect(list[0].animeId, 1);
      expect(list[0].title, '剧A');
      expect(list[0].type, 'TV动画');
      expect(list[1].animeId, 2);
      expect(list[1].title, '剧B');
      expect(list[1].imageUrl, 'http://x/y.jpg');
    });

    test('parseAnimeMatches 兼容裸数组 / 无 id 条目跳过', () {
      const String body = '[{"animeId":7,"animeTitle":"剧C"},{"animeTitle":"无 id"}]';
      final List<DanmakuAnimeMatch> list =
          DanmakuService.parseAnimeMatches(body);
      expect(list, hasLength(1));
      expect(list.single.animeId, 7);
    });

    test('parseAnimeMatches 非法输入 → 空列表', () {
      expect(DanmakuService.parseAnimeMatches('not-json'), isEmpty);
      expect(DanmakuService.parseAnimeMatches('{}'), isEmpty);
    });

    test('parseEpisodes 解析分集列表', () {
      const String body = '{"bangumi":{"episodes":['
          '{"episodeId":11,"episodeNumber":1,"episodeTitle":"第一话"},'
          '{"episode_id":12,"episode_number":2}]}}';
      final List<DanmakuEpisodeInfo> list = DanmakuService.parseEpisodes(body);
      expect(list, hasLength(2));
      expect(list[0].episodeId, 11);
      expect(list[0].episodeNumber, 1);
      expect(list[0].title, '第一话');
    });

    test('parseEpisodes 非法输入 / 缺 bangumi → 空列表', () {
      expect(DanmakuService.parseEpisodes('not-json'), isEmpty);
      expect(DanmakuService.parseEpisodes('{"bangumi":{}}'), isEmpty);
    });
  });

  group('DanmakuService 网络（MockClient）', () {
    test('matchAndFetch：match 命中即拉取', () async {
      String? seenFileName;
      final MockClient client = MockClient((http.Request req) async {
        if (req.url.path == '/api/v2/match') {
          seenFileName =
              (jsonDecode(req.body) as Map<String, dynamic>)['fileName'] as String?;
          return _json('{"success":true,"matches":[{"episodeId":7}]}');
        }
        if (req.url.path == '/api/v2/comment/7') {
          return _json(
            '{"comments":[{"cid":1,"p":"1,1,25,16777215","m":"弹幕一"}]}',
          );
        }
        return http.Response('', 404);
      });
      final DanmakuService svc =
          DanmakuService(client: client, baseUrl: 'https://dm.test');
      final DanmakuFetchResult r = await svc.matchAndFetch('剧名 第1集');
      expect(seenFileName, '剧名 第1集');
      expect(r.episodeId, 7);
      expect(r.items.single.content, '弹幕一');
    });

    test('matchAndFetch：match 未命中 → 回落剧名搜索', () async {
      String? seenKeyword;
      final MockClient client = MockClient((http.Request req) async {
        if (req.url.path == '/api/v2/match') {
          return _json('{"success":false,"matches":[]}');
        }
        if (req.url.path == '/api/v2/search/anime') {
          seenKeyword = req.url.queryParameters['keyword'];
          return _json('{"animes":[{"animeId":3}]}');
        }
        if (req.url.path == '/api/v2/bangumi/3') {
          return _json(
            '{"bangumi":{"episodes":[{"episodeId":33,"episodeNumber":2}]}}',
          );
        }
        if (req.url.path == '/api/v2/comment/33') {
          return _json(
            '{"comments":[{"cid":9,"p":"2,1,25,16777215","m":"回落弹幕"}]}',
          );
        }
        return http.Response('', 404);
      });
      final DanmakuService svc =
          DanmakuService(client: client, baseUrl: 'https://dm.test');
      final DanmakuFetchResult r = await svc.matchAndFetch('剧名 E02.mkv');
      expect(seenKeyword, '剧名');
      expect(r.items.single.content, '回落弹幕');
    });

    test('网络异常降级为空 / false（不抛）', () async {
      final MockClient client = MockClient(
        (http.Request req) async => throw const SocketExceptionStub(),
      );
      final DanmakuService svc =
          DanmakuService(client: client, baseUrl: 'https://dm.test');
      expect(await svc.matchEpisode('x'), isNull);
      expect(await svc.fetchByEpisodeId(1), isEmpty);
      expect(
        await svc.send(episodeId: 1, content: 'a', timeSec: 1),
        isFalse,
      );
    });

    test('send 提交成功', () async {
      late http.Request captured;
      final MockClient client = MockClient((http.Request req) async {
        captured = req;
        return http.Response('{"code":0}', 200);
      });
      final DanmakuService svc =
          DanmakuService(client: client, baseUrl: 'https://dm.test');
      expect(
        await svc.send(episodeId: 7, content: '你好', timeSec: 12.5),
        isTrue,
      );
      expect(captured.url.path, '/api/v2/comment/7');
      final Map<String, dynamic> body =
          jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['comment'], '你好');
      expect(body['time'], 12.5);
      expect(body['mode'], 1);
    });

    test('send 空内容直接失败（不请求）', () async {
      bool called = false;
      final MockClient client = MockClient((http.Request req) async {
        called = true;
        return http.Response('', 200);
      });
      final DanmakuService svc =
          DanmakuService(client: client, baseUrl: 'https://dm.test');
      expect(
        await svc.send(episodeId: 1, content: '   ', timeSec: 1),
        isFalse,
      );
      expect(called, isFalse);
    });
  });
}

/// 构造带 UTF-8 声明的 JSON 响应（否则 [http.Response] 默认按 latin1 编解码，
/// 中文响应体会被破坏）。
http.Response _json(String body, [int status = 200]) => http.Response(
      body,
      status,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

/// 用于模拟网络异常（`http` 内部按异常捕获处理）。
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}