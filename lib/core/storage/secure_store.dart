/// 核心层：敏感键存储抽象。
///
/// 契约依据：`contract/schema/prefs_keys_v1.json` 中 `storage = keychain`
/// 与 `credentialExtra` 的键（共 4 个）必须走系统安全存储。
///
/// 分层约束：核心层不依赖 `flutter_secure_storage` 插件，
/// 真实实现位于 `lib/platform/system/`（Android Keystore / macOS Keychain /
/// Windows DPAPI），启动时注入；此处提供接口 + 内存实现（单测用）。
library;

/// 敏感键存储。
abstract interface class SecureStore {
  /// 读（不存在返回 null）。
  Future<String?> read(String key);

  /// 写（覆盖）。
  Future<void> write(String key, String value);

  /// 删除（不存在返回 false）。
  Future<bool> delete(String key);

  /// 是否存在。
  Future<bool> containsKey(String key);

  /// 清空全部。
  Future<void> clear();
}

/// 内存实现（**仅用于测试/降级**，不提供任何加密保证）。
class InMemorySecureStore implements SecureStore {
  /// 构造。
  InMemorySecureStore([Map<String, String>? initial])
      : _data = <String, String>{...?initial};

  final Map<String, String> _data;

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<bool> delete(String key) async => _data.remove(key) != null;

  @override
  Future<bool> containsKey(String key) async => _data.containsKey(key);

  @override
  Future<void> clear() async => _data.clear();

  /// 当前键集合（测试断言用）。
  Set<String> get keys => _data.keys.toSet();
}
