/// 数据层单测：`secure_store_adapter.dart`（核心层 SecureStore 的插件适配）。
///
/// 覆盖适配器到 `flutter_secure_storage` 的完整映射：read / write /
/// containsKey / delete（返回存在性）/ clear。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/local/secure_store_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('read / write / containsKey 往返', () async {
    final FlutterSecureStoreAdapter store = FlutterSecureStoreAdapter();
    expect(await store.read('k'), isNull);
    expect(await store.containsKey('k'), isFalse);

    await store.write('k', 'v');
    expect(await store.read('k'), 'v');
    expect(await store.containsKey('k'), isTrue);
  });

  test('delete 返回是否存在（命中 true / 未命中 false）', () async {
    final FlutterSecureStoreAdapter store = FlutterSecureStoreAdapter();
    await store.write('k', 'v');
    expect(await store.delete('k'), isTrue);
    expect(await store.read('k'), isNull);
    expect(await store.delete('k'), isFalse);
  });

  test('clear 清空全部键', () async {
    final FlutterSecureStoreAdapter store = FlutterSecureStoreAdapter();
    await store.write('a', '1');
    await store.write('b', '2');
    await store.clear();
    expect(await store.containsKey('a'), isFalse);
    expect(await store.containsKey('b'), isFalse);
  });
}