/// 领域层单测：LiveSourceType（序列化 / id / displayName / sourceURL）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/live/live_source_type.dart';

void main() {
  group('LiveSourceKind', () {
    test('fromId：遗留 yangshipin 归一为 defaultM3U', () {
      expect(LiveSourceKind.fromId('defaultM3U'), LiveSourceKind.defaultM3U);
      expect(LiveSourceKind.fromId('yangshipin'), LiveSourceKind.defaultM3U);
      expect(LiveSourceKind.fromId('defaultIPTV2'), LiveSourceKind.defaultIPTV2);
      expect(LiveSourceKind.fromId('subscribe'), LiveSourceKind.subscribe);
      expect(LiveSourceKind.fromId('custom'), LiveSourceKind.custom);
    });

    test('fromId：未知类型抛 ArgumentError', () {
      expect(() => LiveSourceKind.fromId('nope'), throwsArgumentError);
    });
  });

  group('LiveSourceType 内置源', () {
    test('defaultM3U：id / displayName / isDefault / sourceURL / toDictionary', () {
      const LiveSourceType s = LiveSourceType.defaultM3U;
      expect(s.id, 'default_m3u');
      expect(s.displayName, '默认源1 (秒播)');
      expect(s.isDefault, isTrue);
      expect(s.isCustom, isFalse);
      expect(s.sourceURL, isNotNull);
      expect(s.sourceURL, contains('iptv4.m3u'));
      expect(s.toDictionary(), const <String, String>{'type': 'defaultM3U'});
    });

    test('defaultIptv2：id / displayName / sourceURL', () {
      const LiveSourceType s = LiveSourceType.defaultIptv2;
      expect(s.id, 'default_iptv_2');
      expect(s.displayName, '默认源2 (运营商IPTV)');
      expect(s.isDefault, isTrue);
      expect(s.sourceURL, isNotNull);
    });
  });

  group('LiveSourceType 用户源序列化', () {
    test('subscribe 往返', () {
      const LiveSourceType s = LiveSourceType(
        kind: LiveSourceKind.subscribe,
        name: '我的订阅',
        url: 'http://example.com/tv.m3u',
      );
      expect(s.displayName, '我的订阅');
      expect(s.sourceURL, 'http://example.com/tv.m3u');
      expect(s.isDefault, isFalse);

      final LiveSourceType? r = LiveSourceType.fromDictionary(s.toDictionary());
      expect(r, isNotNull);
      expect(r!.kind, LiveSourceKind.subscribe);
      expect(r.name, '我的订阅');
      expect(r.url, 'http://example.com/tv.m3u');
    });

    test('custom 往返', () {
      const LiveSourceType s = LiveSourceType(
        kind: LiveSourceKind.custom,
        name: '本地源',
        url: 'local://本地源',
      );
      final LiveSourceType? r = LiveSourceType.fromDictionary(s.toDictionary());
      expect(r, isNotNull);
      expect(r!.kind, LiveSourceKind.custom);
      expect(r.isCustom, isTrue);
      expect(r.sourceURL, 'local://本地源');
    });

    test('fromDictionary：未知 type 返回 null', () {
      expect(
        LiveSourceType.fromDictionary(const <String, String>{'type': 'bad'}),
        isNull,
      );
      expect(LiveSourceType.fromDictionary(const <String, String>{}), isNull);
    });

    test('fromDictionary：subscribe/custom 缺 name 或 url 返回 null', () {
      expect(
        LiveSourceType.fromDictionary(const <String, String>{'type': 'subscribe'}),
        isNull,
      );
      expect(
        LiveSourceType.fromDictionary(const <String, String>{
          'type': 'custom',
          'name': 'x',
        }),
        isNull,
      );
    });
  });
}