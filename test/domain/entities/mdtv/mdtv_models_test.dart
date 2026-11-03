/// 领域层单测：MDTV 数据模型反序列化（对齐 iOS `MDTVService.swift` 各模型）。
///
/// iOS 侧未声明 `CodingKeys`，JSON 键即属性名（camelCase）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/mdtv/mdtv.dart';

void main() {
  group('MdtvCategory.fromJson', () {
    test('完整字段', () {
      final MdtvCategory c = MdtvCategory.fromJson(<String, dynamic>{
        'cateId': '1',
        'name': '国产',
        'icon': 'https://img/a.png',
        'sortOrder': 3,
      });
      expect(c.cateId, '1');
      expect(c.name, '国产');
      expect(c.icon, 'https://img/a.png');
      expect(c.sortOrder, 3);
      expect(c.id, '1');
    });

    test('缺省字段回退安全值', () {
      final MdtvCategory c = MdtvCategory.fromJson(<String, dynamic>{});
      expect(c.cateId, '');
      expect(c.name, '');
      expect(c.icon, isNull);
      expect(c.sortOrder, 0);
    });
  });

  group('MdtvVideoItem.fromJson', () {
    test('完整字段（含 tags）', () {
      final MdtvVideoItem v = MdtvVideoItem.fromJson(<String, dynamic>{
        'videoId': 'v1',
        'title': '测试视频',
        'cover': '/cover/1.jpg',
        'duration': '12:34',
        'views': 1024,
        'likes': 7,
        'categoryId': 'c1',
        'categoryName': '国产',
        'tags': <String>['高清', '热门'],
        'rating': '9.5',
      });
      expect(v.videoId, 'v1');
      expect(v.title, '测试视频');
      expect(v.cover, '/cover/1.jpg');
      expect(v.duration, '12:34');
      expect(v.views, 1024);
      expect(v.likes, 7);
      expect(v.categoryId, 'c1');
      expect(v.categoryName, '国产');
      expect(v.tags, <String>['高清', '热门']);
      expect(v.rating, '9.5');
      expect(v.id, 'v1');
    });

    test('缺省字段回退安全值', () {
      final MdtvVideoItem v = MdtvVideoItem.fromJson(<String, dynamic>{});
      expect(v.videoId, '');
      expect(v.duration, '00:00');
      expect(v.views, 0);
      expect(v.likes, 0);
      expect(v.tags, isEmpty);
      expect(v.categoryName, isNull);
    });

    test('views/likes 类型兼容 int 数值', () {
      final MdtvVideoItem v = MdtvVideoItem.fromJson(<String, dynamic>{
        'videoId': 'v2',
        'views': 99,
        'likes': 5.0,
      });
      expect(v.views, 99);
      expect(v.likes, 5);
    });
  });

  group('MdtvPlaySource / MdtvVideoDetail.fromJson', () {
    test('MdtvPlaySource 解析', () {
      final MdtvPlaySource s = MdtvPlaySource.fromJson(
          <String, dynamic>{'name': '线路1', 'url': 'http://p/a.mp4'});
      expect(s.name, '线路1');
      expect(s.url, 'http://p/a.mp4');
      expect(s.id, '线路1');
    });

    test('详情完整字段（单线路 playUrl + 多线路 playUrls）', () {
      final MdtvVideoDetail d = MdtvVideoDetail.fromJson(<String, dynamic>{
        'videoId': 'v3',
        'title': '标题',
        'cover': '/c.jpg',
        'duration': '59:59',
        'views': 1,
        'likes': 2,
        'description': '简介',
        'tags': <String>['t'],
        'actorName': '演员',
        'playUrl': 'http://p/single.m3u8',
        'playUrls': <Map<String, dynamic>>[
          <String, dynamic>{'name': '线路1', 'url': 'http://p/1.m3u8'},
          <String, dynamic>{'name': '线路2', 'url': 'http://p/2.m3u8'},
        ],
      });
      expect(d.videoId, 'v3');
      expect(d.description, '简介');
      expect(d.actorName, '演员');
      expect(d.playUrl, 'http://p/single.m3u8');
      expect(d.playUrls.length, 2);
      expect(d.playUrls.first.name, '线路1');
      expect(d.playUrls.last.url, 'http://p/2.m3u8');
    });

    test('playUrls 非列表 / 含非法元素时安全回退', () {
      final MdtvVideoDetail d = MdtvVideoDetail.fromJson(<String, dynamic>{
        'playUrls': <Object>['oops', 1],
      });
      expect(d.playUrls, isEmpty);
      expect(d.playUrl, isNull);
      expect(d.tags, isEmpty);
    });
  });

  group('MdtvTag', () {
    test('fromJson + id getter', () {
      final MdtvTag t = MdtvTag.fromJson(
          <String, dynamic>{'tagId': 't1', 'name': '高清', 'count': 8});
      expect(t.tagId, 't1');
      expect(t.name, '高清');
      expect(t.count, 8);
      expect(t.id, 't1');
    });

    test('值相等（tagId + name）', () {
      const MdtvTag a = MdtvTag(tagId: 't1', name: '高清', count: 1);
      const MdtvTag b = MdtvTag(tagId: 't1', name: '高清', count: 99);
      const MdtvTag c = MdtvTag(tagId: 't1', name: '标清', count: 1);
      expect(a, b, reason: 'count 不参与相等判定');
      expect(a, isNot(c));
      expect(a.hashCode, b.hashCode);
    });
  });

  group('MdtvEncryptMode', () {
    test('label 与枚举一一对应', () {
      expect(MdtvEncryptMode.cbc.label, 'AES-CBC');
      expect(MdtvEncryptMode.cfb.label, 'AES-CFB');
      expect(MdtvEncryptMode.ctr.label, 'AES-CTR');
      expect(MdtvEncryptMode.ofb.label, 'AES-OFB');
      expect(MdtvEncryptMode.ecb.label, 'AES-ECB');
    });
  });
}