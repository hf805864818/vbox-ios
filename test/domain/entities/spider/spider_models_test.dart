/// 单元测试：Spider 返回结构模型与宽松解码。
///
/// 对应源码：lib/domain/entities/spider/spider_models.dart
/// 契约：contract/docs/abi_v1.md §3 + §9
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/spider_models.dart';

void main() {
  group('asLooseString', () {
    test('null → null；String 原样返回', () {
      expect(asLooseString(null), isNull);
      expect(asLooseString('abc'), 'abc');
      expect(asLooseString(''), '');
    });

    test('int → 十进制字符串', () {
      expect(asLooseString(123), '123');
      expect(asLooseString(-7), '-7');
      expect(asLooseString(0), '0');
    });

    test('整数值 double 不输出 ".0"（Node/WEX 源容错）', () {
      expect(asLooseString(3.0), '3');
      expect(asLooseString(-2.0), '-2');
      expect(asLooseString(100.0), '100');
    });

    test('小数 double 保留小数', () {
      expect(asLooseString(3.5), '3.5');
      expect(asLooseString(-0.25), '-0.25');
    });

    test('bool 通过 toString 归一化', () {
      expect(asLooseString(true), 'true');
      expect(asLooseString(false), 'false');
    });
  });

  group('asLooseStringRequired', () {
    test('null → 空串；其余走 loose 逻辑', () {
      expect(asLooseStringRequired(null), '');
      expect(asLooseStringRequired(123), '123');
      expect(asLooseStringRequired(3.0), '3');
      expect(asLooseStringRequired('x'), 'x');
    });
  });

  group('VodCategory', () {
    test('fromJson 支持 String / Int / Double 类型', () {
      expect(
        VodCategory.fromJson(<String, Object?>{'type_id': 1, 'type_name': 2})
            .typeId,
        '1',
      );
      final VodCategory c = VodCategory.fromJson(
          <String, Object?>{'type_id': 3.0, 'type_name': '动作'});
      expect(c.typeId, '3');
      expect(c.typeName, '动作');
    });

    test('fromJson 缺失字段 → 空串', () {
      final VodCategory c = VodCategory.fromJson(const <String, Object?>{});
      expect(c.typeId, '');
      expect(c.typeName, '');
    });

    test('toJson 使用契约 key type_id / type_name', () {
      const VodCategory c = VodCategory(typeId: '1', typeName: '动作');
      expect(c.toJson(), <String, Object?>{
        'type_id': '1',
        'type_name': '动作',
      });
    });

    test('值相等与 hashCode（Equatable 语义）', () {
      const VodCategory a = VodCategory(typeId: '1', typeName: '动作');
      const VodCategory b = VodCategory(typeId: '1', typeName: '动作');
      const VodCategory c = VodCategory(typeId: '2', typeName: '动作');
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
      // 跨类型比较应恒为 false（以上转型为 Object 规避 unrelated_type_equality_checks）
      const Object other = 'not-a-category';
      expect(a == other, isFalse);
    });
  });

  group('VodItem', () {
    test('fromJson 完整解析含扩展字段', () {
      final VodItem item = VodItem.fromJson(<String, Object?>{
        'vod_id': '12345',
        'vod_name': '庆余年',
        'vod_pic': 'https://cdn/pic.jpg',
        'vod_remarks': '更新至36集',
        'vod_year': 2024,
        'vod_area': '大陆',
        'vod_director': '导演',
        'vod_actor': '演员',
        'vod_content': '简介',
        'vod_play_from': '线路1\$\$\$线路2',
        'vod_play_url': '第1集\$url1#第2集\$url2',
        'customHeaders': <String, Object?>{'User-Agent': 'ua'},
        'engineKey': 'nodejs_a',
        'metaDuration': 120,
        'albumName': '专辑',
        'availQualities': <Object?>['flac', '320k'],
        'musicPlatform': 'qq',
        'lxMusicInfo': 'info',
        'musicEntryType': 'song',
      });
      expect(item.vodId, '12345');
      expect(item.vodName, '庆余年');
      expect(item.vodPic, 'https://cdn/pic.jpg');
      expect(item.vodRemarks, '更新至36集');
      expect(item.vodYear, '2024'); // 数字 → 字符串
      expect(item.vodArea, '大陆');
      expect(item.vodDirector, '导演');
      expect(item.vodActor, '演员');
      expect(item.vodContent, '简介');
      expect(item.vodPlayFrom, '线路1\$\$\$线路2');
      expect(item.vodPlayUrl, '第1集\$url1#第2集\$url2');
      expect(item.customHeaders, <String, String>{'User-Agent': 'ua'});
      expect(item.engineKey, 'nodejs_a');
      expect(item.metaDuration, 120);
      expect(item.albumName, '专辑');
      expect(item.availQualities, <String>['flac', '320k']);
      expect(item.musicPlatform, 'qq');
      expect(item.lxMusicInfo, 'info');
      expect(item.musicEntryType, 'song');
    });

    test('fromJson 缺失必需字段 → 空串；availQualities 缺省为空列表', () {
      final VodItem item = VodItem.fromJson(const <String, Object?>{});
      expect(item.vodId, '');
      expect(item.vodName, '');
      expect(item.vodPic, '');
      expect(item.vodRemarks, isNull);
      expect(item.customHeaders, isNull);
      expect(item.metaDuration, isNull);
      expect(item.availQualities, isEmpty);
    });

    test('fromJson 关键字段数字容错（Node/WEX 源数字 id）', () {
      final VodItem item = VodItem.fromJson(<String, Object?>{
        'vod_id': 12345,
        'vod_name': 678,
        'vod_pic': 9.0,
      });
      expect(item.vodId, '12345');
      expect(item.vodName, '678');
      expect(item.vodPic, '9');
    });

    test('fromJson customHeaders 值经 toString 归一化', () {
      final VodItem item = VodItem.fromJson(<String, Object?>{
        'customHeaders': <String, Object?>{'X': 1, 'Y': 2.5},
      });
      expect(item.customHeaders, <String, String>{'X': '1', 'Y': '2.5'});
    });

    test('fromJson metaDuration 宽松整数解析', () {
      expect(
        VodItem.fromJson(<String, Object?>{'metaDuration': '90'}).metaDuration,
        90,
      );
      expect(
        VodItem.fromJson(<String, Object?>{'metaDuration': 90.0}).metaDuration,
        90,
      );
      expect(
        VodItem.fromJson(<String, Object?>{'metaDuration': 'x'}).metaDuration,
        isNull,
      );
    });

    test('toJson 仅输出非空可空字段，必需字段与 availQualities 恒输出', () {
      const VodItem item = VodItem(vodId: '1', vodName: 'n', vodPic: 'p');
      final Map<String, Object?> j = item.toJson();
      expect(j.keys.toSet(), <String>{
        'vod_id',
        'vod_name',
        'vod_pic',
        'availQualities',
      });
      expect(j['availQualities'], isEmpty);
    });

    test('toJson → fromJson 往返稳定（含扩展字段）', () {
      const VodItem item = VodItem(
        vodId: '1',
        vodName: 'n',
        vodPic: 'p',
        vodRemarks: 'r',
        metaDuration: 60,
        availQualities: <String>['flac'],
        customHeaders: <String, String>{'a': 'b'},
      );
      final VodItem back = VodItem.fromJson(item.toJson());
      expect(back.vodId, item.vodId);
      expect(back.vodRemarks, item.vodRemarks);
      expect(back.metaDuration, item.metaDuration);
      expect(back.availQualities, item.availQualities);
      expect(back.customHeaders, item.customHeaders);
    });
  });

  group('HomeContentResult', () {
    test('fromJson 解析 class（JSON key）与 list，跳过非 Map 元素', () {
      final HomeContentResult r = HomeContentResult.fromJson(<String, Object?>{
        'class': <Object?>[
          <String, Object?>{'type_id': '1', 'type_name': '动作'},
          'junk',
          5,
        ],
        'list': <Object?>[
          <String, Object?>{'vod_id': '1', 'vod_name': 'a', 'vod_pic': 'p'},
        ],
      });
      expect(r.classes!.length, 1);
      expect(r.classes!.first.typeName, '动作');
      expect(r.list!.length, 1);
    });

    test('fromJson 空对象 → classes 与 list 皆 null', () {
      final HomeContentResult r = HomeContentResult.fromJson(const <String, Object?>{});
      expect(r.classes, isNull);
      expect(r.list, isNull);
    });

    test('toJson 空结果输出空 Map，填充时输出 class/list', () {
      expect(const HomeContentResult().toJson(), isEmpty);
      const HomeContentResult r = HomeContentResult(
        classes: <VodCategory>[VodCategory(typeId: '1', typeName: 'a')],
        list: <VodItem>[VodItem(vodId: '1', vodName: 'n', vodPic: 'p')],
      );
      final Map<String, Object?> j = r.toJson();
      expect((j['class']! as List).length, 1);
      expect((j['list']! as List).length, 1);
    });
  });

  group('CategoryContentResult', () {
    test('fromJson 解析 page/pagecount/limit/total（宽松 int）与 list', () {
      final CategoryContentResult r =
          CategoryContentResult.fromJson(<String, Object?>{
        'page': '2',
        'pagecount': 10,
        'limit': 20.0,
        'total': 200,
        'list': <Object?>[
          <String, Object?>{'vod_id': '1'},
        ],
      });
      expect(r.page, 2);
      expect(r.pagecount, 10);
      expect(r.limit, 20);
      expect(r.total, 200);
      expect(r.list!.length, 1);
    });

    test('fromJson 空对象 → 全 null', () {
      final CategoryContentResult r =
          CategoryContentResult.fromJson(const <String, Object?>{});
      expect(r.page, isNull);
      expect(r.pagecount, isNull);
      expect(r.limit, isNull);
      expect(r.total, isNull);
      expect(r.list, isNull);
    });

    test('toJson 仅输出非空字段', () {
      expect(const CategoryContentResult().toJson(), isEmpty);
      const CategoryContentResult r = CategoryContentResult(page: 1, total: 5);
      expect(r.toJson(), <String, Object?>{'page': 1, 'total': 5});
    });
  });

  group('SearchContentResult', () {
    test('fromJson 解析 page/pagecount/list', () {
      final SearchContentResult r =
          SearchContentResult.fromJson(<String, Object?>{
        'page': 1,
        'pagecount': 120,
        'list': <Object?>[
          <String, Object?>{'vod_id': '1'},
          <String, Object?>{'vod_id': '2'},
        ],
      });
      expect(r.page, 1);
      expect(r.pagecount, 120);
      expect(r.list!.length, 2);
    });

    test('toJson 空结果为空 Map，填充时输出字段', () {
      expect(const SearchContentResult().toJson(), isEmpty);
      const SearchContentResult r = SearchContentResult(page: 3);
      expect(r.toJson(), <String, Object?>{'page': 3});
    });
  });

  group('DetailContentResult', () {
    test('fromJson 解析 list', () {
      final DetailContentResult r =
          DetailContentResult.fromJson(<String, Object?>{
        'list': <Object?>[
          <String, Object?>{'vod_id': '1', 'vod_name': 'a', 'vod_pic': 'p'},
        ],
      });
      expect(r.list!.length, 1);
    });

    test('toJson 空结果为空 Map', () {
      expect(const DetailContentResult().toJson(), isEmpty);
    });
  });

  group('PlayerContentResult url 回填规则', () {
    test('urls 为 null 且 url 非空 → urls = [url]', () {
      final PlayerContentResult r = PlayerContentResult(url: 'http://a');
      expect(r.urls, <String>['http://a']);
      expect(r.url, 'http://a');
    });

    test('urls 为 null 且 url 为 null → urls = null', () {
      expect(PlayerContentResult().urls, isNull);
    });

    test('urls 为 null 且 url 为空串 → urls = null', () {
      expect(PlayerContentResult(url: '').urls, isNull);
    });

    test('显式提供 urls（含空列表）时保持原值', () {
      final PlayerContentResult r =
          PlayerContentResult(url: 'http://a', urls: <String>['x', 'y']);
      expect(r.urls, <String>['x', 'y']);
      final PlayerContentResult empty =
          PlayerContentResult(urls: <String>[]);
      expect(empty.urls, isNotNull);
      expect(empty.urls, isEmpty);
    });
  });

  group('PlayerContentResult.fromJson / toJson', () {
    test('fromJson 解析全部字段并应用回填', () {
      final PlayerContentResult r =
          PlayerContentResult.fromJson(<String, Object?>{
        'parse': 1,
        'playUrl': 'http://old',
        'url': 'http://new',
        'header': <String, Object?>{'User-Agent': 'ua'},
      });
      expect(r.parse, 1);
      expect(r.playUrl, 'http://old');
      expect(r.url, 'http://new');
      expect(r.urls, <String>['http://new']); // 回填
      expect(r.header, <String, String>{'User-Agent': 'ua'});
    });

    test('fromJson urls 优先于 url', () {
      final PlayerContentResult r =
          PlayerContentResult.fromJson(<String, Object?>{
        'url': 'http://a',
        'urls': <Object?>['u1', 'u2'],
      });
      expect(r.urls, <String>['u1', 'u2']);
    });

    test('fromJson url 为数组（多线路蜘蛛：酷狗/酷我/网易/QQ）→ urls=全列表、url=首元素',
        () {
      final PlayerContentResult r =
          PlayerContentResult.fromJson(<String, Object?>{
        'url': <Object?>['http://l1.m3u8', 'http://l2.m3u8'],
      });
      expect(r.url, 'http://l1.m3u8');
      expect(r.urls, <String>['http://l1.m3u8', 'http://l2.m3u8']);
    });

    test('fromJson url 为数组时 urls 键不再参与（对齐 iOS init(from:) 优先级）', () {
      final PlayerContentResult r =
          PlayerContentResult.fromJson(<String, Object?>{
        'url': <Object?>['http://l1', 'http://l2'],
        'urls': <Object?>['http://stale'],
      });
      expect(r.urls, <String>['http://l1', 'http://l2']);
      expect(r.url, 'http://l1');
    });

    test('fromJson url 数组元素宽松归一（数字/混合类型 toString）', () {
      final PlayerContentResult r =
          PlayerContentResult.fromJson(<String, Object?>{
        'url': <Object?>[123, 'http://l2'],
      });
      expect(r.url, '123');
      expect(r.urls, <String>['123', 'http://l2']);
    });

    test('fromJson url 为空数组 → urls=[]（非 null）、url=null', () {
      final PlayerContentResult r =
          PlayerContentResult.fromJson(<String, Object?>{
        'url': <Object?>[],
      });
      expect(r.url, isNull);
      expect(r.urls, isNotNull);
      expect(r.urls, isEmpty);
    });

    test('fromJson 负向：header 非对象 → null；parse 字符串数字 → int', () {
      final PlayerContentResult r =
          PlayerContentResult.fromJson(<String, Object?>{
        'parse': '1',
        'header': 'not-a-map',
        'url': 'http://a',
      });
      expect(r.parse, 1);
      expect(r.header, isNull);
      expect(r.urls, <String>['http://a']);
    });

    test('fromJson 负向：parse 非数字字符串 → null；urls 键含类型混杂 → toString 归一',
        () {
      final PlayerContentResult r =
          PlayerContentResult.fromJson(<String, Object?>{
        'parse': 'fast',
        'urls': <Object?>[1, 'u', true],
      });
      expect(r.parse, isNull);
      expect(r.urls, <String>['1', 'u', 'true']);
    });

    test('toJson 仅输出非空字段', () {
      expect(PlayerContentResult().toJson(), isEmpty);
      final PlayerContentResult r =
          PlayerContentResult(parse: 0, url: 'http://a');
      final Map<String, Object?> j = r.toJson();
      expect(j['parse'], 0);
      expect(j['url'], 'http://a');
      expect(j['urls'], <String>['http://a']);
      expect(j.containsKey('playUrl'), isFalse);
      expect(j.containsKey('header'), isFalse);
    });
  });
}