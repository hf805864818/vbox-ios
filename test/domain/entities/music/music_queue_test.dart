/// 音乐播放队列领域模型单测（批次 G · G-01 首段）。
///
/// 对齐基准（唯一真相源）：iOS `AudioPlayerManager`
/// （`vbox/Services/AudioPlayerManager.swift`）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/music/music.dart';

MusicQueueItem _item(String id, {String? url, String artist = '来源'}) {
  return MusicQueueItem(
    id: id,
    name: '歌$id',
    artist: artist,
    coverURL: 'https://cover/$id.jpg',
    playURL: url ?? 'https://play/$id.mp3',
    sourceName: '测试源',
    engineKey: 'lx_test',
  );
}

void main() {
  group('MusicRepeatMode（对齐 iOS rawValue 0/1/2）', () {
    test('归档值与展示名', () {
      expect(MusicRepeatMode.sequential.id, 0);
      expect(MusicRepeatMode.single.id, 1);
      expect(MusicRepeatMode.shuffle.id, 2);
      expect(MusicRepeatMode.sequential.displayName, '顺序播放');
      expect(MusicRepeatMode.single.displayName, '单曲循环');
      expect(MusicRepeatMode.shuffle.displayName, '随机播放');
    });

    test('fromId 命中 / 越界回退顺序播放', () {
      expect(MusicRepeatMode.fromId(1), MusicRepeatMode.single);
      expect(MusicRepeatMode.fromId(2), MusicRepeatMode.shuffle);
      expect(MusicRepeatMode.fromId(99), MusicRepeatMode.sequential);
      expect(MusicRepeatMode.fromId(null), MusicRepeatMode.sequential);
    });

    test('next 循环三档', () {
      expect(MusicRepeatMode.sequential.next, MusicRepeatMode.single);
      expect(MusicRepeatMode.single.next, MusicRepeatMode.shuffle);
      expect(MusicRepeatMode.shuffle.next, MusicRepeatMode.sequential);
    });
  });

  group('MusicQueueItem JSON（键名对齐 iOS CodingKeys）', () {
    test('全字段往返', () {
      const MusicQueueItem item = MusicQueueItem(
        id: 'a1',
        name: '歌名',
        artist: '歌手',
        coverURL: 'https://c/1.jpg',
        playURL: 'https://p/1.mp3',
        sourceName: '源',
        engineKey: 'lx_kuwo',
        quality: '320k',
        qualityIndex: 1,
        lyric: '[00:01.00]歌词',
        duration: 240,
        albumName: '专辑',
        availQualities: <String>['128k', '320k'],
        musicPlatform: 'kw',
        lxMusicInfo: '{"singer":"歌手"}',
      );
      final MusicQueueItem back =
          MusicQueueItem.fromJson(jsonDecode(jsonEncode(item.toJson())))!;
      expect(back, item);
    });

    test('缺扩展字段可解码（对齐 decodeIfPresent）', () {
      final MusicQueueItem item = MusicQueueItem.fromJson(<String, Object?>{
        'id': 'a2',
        'name': 'n',
        'artist': 'ar',
        'coverURL': '',
        'playURL': 'https://p/2.mp3',
        'sourceName': 's',
        'engineKey': 'lx_netease',
      })!;
      expect(item.quality, isNull);
      expect(item.duration, isNull);
      expect(item.availQualities, isEmpty);
      expect(item.musicPlatform, isNull);
    });

    test('缺 id / 非 Map / 空 id → null', () {
      expect(MusicQueueItem.fromJson(<String, Object?>{'name': 'n'}), isNull);
      expect(MusicQueueItem.fromJson('not-a-map'), isNull);
      expect(
        MusicQueueItem.fromJson(<String, Object?>{'id': '', 'name': 'n'}),
        isNull,
      );
    });

    test('copying 保留除 playURL / quality 外全部字段', () {
      final MusicQueueItem base = _item('a3').copyWith(
        quality: '128k',
        qualityIndex: 0,
        duration: 200,
        availQualities: const <String>['128k', '320k'],
        musicPlatform: 'wy',
      );
      final MusicQueueItem next =
          base.copying(playURL: 'https://p/new.flac', quality: 'flac');
      expect(next.playURL, 'https://p/new.flac');
      expect(next.quality, 'flac');
      expect(next.qualityIndex, base.qualityIndex);
      expect(next.duration, base.duration);
      expect(next.availQualities, base.availQualities);
      expect(next.musicPlatform, base.musicPlatform);
      expect(next.id, base.id);
    });

    test('相等性：全字段参与（availQualities 逐项比较）', () {
      expect(_item('a4') == _item('a4'), isTrue);
      expect(_item('a4') == _item('a4', url: 'https://other.mp3'), isFalse);
      expect(_item('a4').hashCode, _item('a4').hashCode);
    });
  });

  group('MusicQueue 队列内核（对齐 iOS setQueue / play / remove / stop）', () {
    test('setQueue 定位下标并收敛越界', () {
      final MusicQueue q = MusicQueue.empty
          .setQueue(<MusicQueueItem>[_item('1'), _item('2'), _item('3')], startIndex: 2);
      expect(q.current?.id, '3');
      expect(q.setQueue(<MusicQueueItem>[_item('1')], startIndex: 9).currentIndex, 0);
      expect(MusicQueue.empty.setQueue(<MusicQueueItem>[]).currentIndex, -1);
    });

    test('空队列 current 为空', () {
      expect(MusicQueue.empty.current, isNull);
      expect(MusicQueue.empty.hasRestorable, isFalse);
    });

    test('addToQueue 不改当前下标', () {
      final MusicQueue q =
          MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1')]).addToQueue(_item('2'));
      expect(q.length, 2);
      expect(q.currentIndex, 0);
    });

    test('play：已存在定位，不存在追加到末尾', () {
      final MusicQueue base = MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1'), _item('2')]);
      final MusicQueue hit = base.play(_item('2'));
      expect(hit.currentIndex, 1);
      expect(hit.length, 2);

      final MusicQueue miss = base.play(_item('3'));
      expect(miss.length, 3);
      expect(miss.currentIndex, 2);
    });

    test('removeFromQueue：越界原样返回', () {
      final MusicQueue base = MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1')]);
      expect(base.removeFromQueue(5), base);
      expect(base.removeFromQueue(-1), base);
    });

    test('removeFromQueue：移除当前项之前 → 下标前移', () {
      final MusicQueue base =
          MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1'), _item('2'), _item('3')], startIndex: 2);
      final MusicQueue q = base.removeFromQueue(0);
      expect(q.length, 2);
      expect(q.current?.id, '3');
      expect(q.currentIndex, 1);
    });

    test('removeFromQueue：移除当前项 → stop 语义清空队列', () {
      final MusicQueue base =
          MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1'), _item('2')], startIndex: 1);
      final MusicQueue q = base.removeFromQueue(1);
      expect(q.isEmpty, isTrue);
      expect(q.currentIndex, -1);
    });

    test('replaceAt 保持下标（音质切换）', () {
      final MusicQueue base =
          MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1'), _item('2')], startIndex: 1);
      final MusicQueue q = base.replaceAt(1, _item('2', url: 'https://p/new.flac'));
      expect(q.currentIndex, 1);
      expect(q.current?.playURL, 'https://p/new.flac');
      expect(base.replaceAt(9, _item('x')), base);
    });

    test('nextIndex：顺序环绕 / 单曲重播 / 随机可注入', () {
      final MusicQueue q =
          MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1'), _item('2'), _item('3')], startIndex: 2);
      expect(q.nextIndex(MusicRepeatMode.sequential), 0);
      expect(q.nextIndex(MusicRepeatMode.single), 2);
      expect(q.nextIndex(MusicRepeatMode.shuffle, randomInt: (int max) => 1), 1);
      expect(MusicQueue.empty.nextIndex(MusicRepeatMode.sequential), isNull);
    });

    test('previousIndex：顺序环绕 / 随机可注入', () {
      final MusicQueue q =
          MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1'), _item('2'), _item('3')], startIndex: 0);
      expect(q.previousIndex(MusicRepeatMode.sequential), 2);
      expect(q.previousIndex(MusicRepeatMode.shuffle, randomInt: (int max) => 0), 0);
      expect(MusicQueue.empty.previousIndex(MusicRepeatMode.sequential), isNull);
    });

    test('单曲队列随机下标恒为 0', () {
      final MusicQueue q = MusicQueue.empty.setQueue(<MusicQueueItem>[_item('only')]);
      expect(q.nextIndex(MusicRepeatMode.shuffle), 0);
      expect(q.previousIndex(MusicRepeatMode.shuffle), 0);
    });

    test('withCurrentIndex 收敛越界', () {
      final MusicQueue base =
          MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1'), _item('2')]);
      expect(base.withCurrentIndex(9).currentIndex, 1);
      expect(base.withCurrentIndex(-3).currentIndex, 0);
      expect(MusicQueue.empty.withCurrentIndex(3).currentIndex, -1);
    });

    test('cleared 清空（对齐 stop）', () {
      final MusicQueue q = MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1')]);
      expect(q.cleared(), MusicQueue.empty);
    });

    test('相等性', () {
      final MusicQueue a = MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1')]);
      final MusicQueue b = MusicQueue.empty.setQueue(<MusicQueueItem>[_item('1')]);
      expect(a, b);
      expect(a, isNot(b.addToQueue(_item('2'))));
    });

    test('encodeItems / decodeItems 往返 + 容错', () {
      final MusicQueue q = MusicQueue.empty
          .setQueue(<MusicQueueItem>[_item('1'), _item('2')], startIndex: 1);
      final String raw = q.encodeItems();
      expect(MusicQueue.decodeItems(raw), q.items);
      expect(MusicQueue.decodeItems(''), isEmpty);
      expect(MusicQueue.decodeItems('not-json'), isEmpty);
      expect(MusicQueue.decodeItems('{"a":1}'), isEmpty);
      // 数组中含缺 id 项 → 跳过该项，保留其余
      final List<MusicQueueItem> partial = MusicQueue.decodeItems(
        '[{"id":"ok","name":"n"},{"name":"no-id"}]',
      );
      expect(partial.length, 1);
      expect(partial.first.id, 'ok');
    });
  });
}
