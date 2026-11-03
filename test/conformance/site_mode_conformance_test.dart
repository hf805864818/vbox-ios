/// conformance 测试：站点模式判定（fixture ↔ Dart 实现）。
///
/// 消费 `conformance/fixtures/spider_io_v1.json` 的 `$comment_siteMode` 用例，
/// 验证 Dart 侧 `SiteConfig.resolveSiteMode` 与 `ResolveSiteModeUseCase`
/// 与本 fixture（三端唯一真相源）判定完全一致。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/site_config.dart';
import 'package:vbox/domain/usecases/resolve_site_mode.dart';

void main() {
  final Map<String, Object?> fixture =
      (jsonDecode(File('conformance/fixtures/spider_io_v1.json').readAsStringSync())
              as Map)
          .cast<String, Object?>();
  final List<Object?> cases =
      (((fixture['\$comment_siteMode'] as Map)['cases']) as List).cast<Object?>();

  test('\$comment_siteMode 用例非空且结构完整', () {
    expect(cases, isNotEmpty);
    for (final Object? c in cases) {
      final Map<String, Object?> m = (c as Map).cast<String, Object?>();
      expect(m.containsKey('site'), isTrue);
      expect(m.containsKey('mode'), isTrue);
      expect(m.containsKey('isNodeHosted'), isTrue);
    }
  });

  test('站点模式判定与 fixture 一致（实体 + 用例双层）', () {
    for (final Object? c in cases) {
      final Map<String, Object?> m = (c as Map).cast<String, Object?>();
      final SiteConfig site =
          SiteConfig.fromJson((m['site'] as Map).cast<String, Object?>());
      final String expectedMode = m['mode'] as String;
      final bool expectedNodeHosted = m['isNodeHosted'] as bool;

      // 实体层判定
      expect(site.resolveSiteMode().name, expectedMode,
          reason: 'site=${m['site']}');

      // 用例层判定（含 isNodeHosted / engineType）
      final ResolvedSiteMode r = const ResolveSiteModeUseCase().call(site);
      expect(r.mode.name, expectedMode, reason: 'site=${m['site']}');
      expect(r.isNodeHosted, expectedNodeHosted, reason: 'site=${m['site']}');
    }
  });
}