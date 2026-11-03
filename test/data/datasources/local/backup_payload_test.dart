/// 数据层单测：#B4 —— `backup_payload.dart`（BackupPayload 编解码）。
///
/// 契约要点（`contract/docs/backup_v1.md` §5.1）：
///   `categories` 的值是 **Base64(类目 JSON 的 UTF-8 字节)**，对应 Swift `Data`，
///   而非内嵌 JSON 对象。本文件逐项实测该约定与容错路径。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/local/backup_manager.dart';
import 'package:vbox/data/datasources/local/backup_payload.dart';

void main() {
  test('putCategory / readCategory：List 往返', () {
    final BackupPayload p = BackupPayload(account: 'acc');
    p.putCategory(BackupCategory.favorites, <Object?>[
      <String, Object?>{'id': 1, 'name': '片A'},
    ]);
    expect(p.contains(BackupCategory.favorites), isTrue);
    final Object? back = p.readCategory(BackupCategory.favorites);
    expect(back, isA<List<dynamic>>());
    expect((back! as List<dynamic>).first, <String, Object?>{'id': 1, 'name': '片A'});
  });

  test('putCategory / readCategory：Map 往返（siteConfigs 快照）', () {
    final BackupPayload p = BackupPayload();
    p.putCategory(BackupCategory.siteConfigs, <String, Object?>{
      'zhanyuan': <Object?>[],
      'apiyuan': <Object?>[],
      'jiexi': <Object?>[],
    });
    final Object? back = p.readCategory(BackupCategory.siteConfigs);
    expect(back, isA<Map<dynamic, dynamic>>());
    expect((back! as Map<dynamic, dynamic>)['zhanyuan'], isEmpty);
  });

  test('categories 值按契约存为 Base64(UTF-8 JSON)', () {
    final BackupPayload p = BackupPayload();
    p.putCategory(BackupCategory.searchHistory, <Object?>[]);
    // 空数组 JSON = "[]" → base64 = "W10="
    expect(p.categories['searchHistory'], base64.encode(utf8.encode('[]')));
    expect(p.categories['searchHistory'], 'W10=');
  });

  test('toJson / fromJson 往返，account 与类目保真', () {
    final BackupPayload p = BackupPayload(account: '张三');
    p.putCategory(BackupCategory.subscriptions, <Object?>[
      <String, Object?>{'dyname': '源', 'dyurl': 'https://x'},
    ]);
    final BackupPayload back = BackupPayload.fromJson(p.toJson());
    expect(back.account, '张三');
    expect(back.readCategory(BackupCategory.subscriptions), isA<List<dynamic>>());
  });

  test('encode / decode 往返', () {
    final BackupPayload p = BackupPayload(account: 'a');
    p.putCategory(BackupCategory.downloads, <Object?>[]);
    final BackupPayload back = BackupPayload.decode(p.encode());
    expect(back.account, 'a');
    expect(back.contains(BackupCategory.downloads), isTrue);
  });

  test('decode 顶层非对象 → InvalidFormatException', () {
    expect(() => BackupPayload.decode('[1,2,3]'),
        throwsA(isA<InvalidFormatException>()));
    expect(() => BackupPayload.decode('not json'),
        throwsA(isA<FormatException>()));
  });

  test('缺失类目 → readCategory 返回 null；contains 为 false', () {
    final BackupPayload p = BackupPayload();
    expect(p.contains(BackupCategory.favorites), isFalse);
    expect(p.readCategory(BackupCategory.favorites), isNull);
  });

  test('非法 Base64 / 非法 JSON → readCategory 返回 null（容错）', () {
    final BackupPayload p = BackupPayload(
      categories: <String, String>{'favorites': '!!!not-base64!!!'},
    );
    expect(p.readCategory(BackupCategory.favorites), isNull);
  });

  test('fromJson 容忍非法 categories（非 Map → 空集合）', () {
    final BackupPayload p = BackupPayload.fromJson(<String, Object?>{
      'account': 'x',
      'categories': 'bad',
    });
    expect(p.account, 'x');
    expect(p.categories, isEmpty);
  });

  test('subset 仅保留指定类目', () {
    final BackupPayload p = BackupPayload();
    p.putCategory(BackupCategory.favorites, <Object?>[]);
    p.putCategory(BackupCategory.downloads, <Object?>[]);
    final BackupPayload sub =
        p.subset(<BackupCategory>{BackupCategory.favorites});
    expect(sub.contains(BackupCategory.favorites), isTrue);
    expect(sub.contains(BackupCategory.downloads), isFalse);
  });
}