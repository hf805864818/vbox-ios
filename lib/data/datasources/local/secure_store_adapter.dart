/// 数据层：核心层 `SecureStore` 的插件实现（`flutter_secure_storage`）。
///
/// 分层约束：核心层只定义抽象（`lib/core/storage/secure_store.dart`），
/// 不依赖任何插件；本适配器位于数据层，把插件 API 适配到核心抽象，
/// 由 `PrefsManager.init` 默认注入。
///
/// 过渡说明：设计上系统级实现最终归于平台层 `lib/platform/system/`；
/// 平台层尚未创建（见方案 G-02），故先落在数据层，接口已对齐，迁移成本为零。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/storage/secure_store.dart';

/// 基于 `flutter_secure_storage` 的 [SecureStore] 实现。
///
/// 各平台后端：Android Keystore / iOS & macOS Keychain / Windows DPAPI / Linux libsecret。
class FlutterSecureStoreAdapter implements SecureStore {
  /// 构造（可注入 Android 选项；默认启用 `EncryptedSharedPreferences`）。
  FlutterSecureStoreAdapter({AndroidOptions? androidOptions})
      : _store = FlutterSecureStorage(
          aOptions: androidOptions ??
              const AndroidOptions(encryptedSharedPreferences: true),
        );

  final FlutterSecureStorage _store;

  @override
  Future<String?> read(String key) => _store.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _store.write(key: key, value: value);

  @override
  Future<bool> delete(String key) async {
    final bool existed = await _store.containsKey(key: key);
    await _store.delete(key: key);
    return existed;
  }

  @override
  Future<bool> containsKey(String key) => _store.containsKey(key: key);

  @override
  Future<void> clear() => _store.deleteAll();
}