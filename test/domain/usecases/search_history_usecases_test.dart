/// 领域层单测：`search_history_usecases.dart`。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/domain/usecases/usecases.dart';

import '../../support/fakes.dart';

void main() {
  group('SearchHistoryUseCases', () {
    late InMemorySearchHistoryRepository repo;
    late SearchHistoryUseCases uc;

    setUp(() {
      repo = InMemorySearchHistoryRepository();
      uc = SearchHistoryUseCases(repo);
    });

    test('recent：按时间倒序 + 去重', () async {
      await uc.add('流浪地球');
      await uc.add('三体');
      await uc.add('流浪地球');

      final Result<List<String>> r = await uc.recent();
      expect(r.isSuccess, isTrue);
      expect(r.valueOrNull, <String>['流浪地球', '三体']);
    });

    test('add：去空白；空关键词拒绝', () async {
      final Result<int> ok = await uc.add('  变形金刚  ');
      expect(ok.isSuccess, isTrue);
      expect((await uc.recent()).valueOrNull, <String>['变形金刚']);

      final Result<int> empty = await uc.add('   ');
      expect(empty.isSuccess, isFalse);
      expect(empty.failureOrNull, isA<ValidationFailure>());
    });

    test('add：仓储故障透传', () async {
      repo.failWith = const UnknownFailure('db down');
      final Result<int> r = await uc.add('x');
      expect(r.isSuccess, isFalse);
      expect(r.failureOrNull, isA<UnknownFailure>());
    });

    test('clear：清空返回删除条数', () async {
      await uc.add('a');
      await uc.add('b');
      final Result<int> r = await uc.clear();
      expect(r.valueOrNull, 2);
      expect((await uc.recent()).valueOrNull, isEmpty);
    });
  });
}