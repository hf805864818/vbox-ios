/// 本地账号会话控制器（批次 I · I-02）。
///
/// 唯一真相源：iOS `ProfileView.swift`
///   · L808-L839（`performLogout` / `loadInitialState`）；
///   · L1072-L1125（`isRegistered` / `performLogin` / `loginSuccess`）。
///
/// 语义（**纯本地账号，无服务端**，对齐 iOS）：
///   · 登录标识 = `account`（不可改）；展示名 = `username`（可改，见 EditNicknameSheet）；
///   · 密码**按账号分键**存 `password_<account>`，首次登录即注册（无独立注册流程）；
///   · 登出**只**清 `isLoggedIn` / `account` / `username`，**保留** `password_<账号>`
///     与 `avatar_image`（iOS 文案：「本机已保存的密码不会删除」）；
///   · 读取时兼容旧版本：`account` 为空则用 `username` 兜底迁移（L827）。
///
/// 落盘走 SQLite `settings` 表（[SettingsStore]）而非 `SharedPreferences` ——
/// 与 iOS `DatabaseManager.getSetting/setSetting` 一致（见 [SettingsStore] 头注）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/datasources/local/settings_store.dart';

/// 本地账号会话状态控制器（可热切换）。
class SessionController extends ChangeNotifier {
  /// 构造（可注入 [SettingsStore] / 登录延迟以隔离单测）。
  SessionController({
    SettingsStore? store,
    this.loginDelay = const Duration(milliseconds: 300),
  }) : _store = store ?? DatabaseSettingsStore();

  /// SQLite `settings` 表键名（对齐 iOS `DatabaseManager` 调用字面量）。
  static const String kAccountKey = 'account';
  static const String kUsernameKey = 'username';
  static const String kLoggedInKey = 'isLoggedIn';
  static const String kAvatarKey = 'avatar_image';

  /// 上级用户推荐码键（M-账1：登录/注册时填写，本机保存）。
  static const String kReferralKey = 'referrer';

  /// 密码键（按账号分键，对齐 iOS `password_\(trimmed)`）。
  static String passwordKey(String account) => 'password_$account';

  /// 登录延迟（对齐 iOS `asyncAfter(0.5)` 的交互节奏；单测传 [Duration.zero]）。
  final Duration loginDelay;

  final SettingsStore _store;

  bool _loggedIn = false;
  String _account = '';
  String _username = '';
  String? _avatarBase64;
  String _referral = '';
  bool _loading = false;

  /// 是否已登录。
  bool get isLoggedIn => _loggedIn;

  /// 登录账号（不可改）。
  String get account => _account;

  /// 展示名（可改）。
  String get username => _username;

  /// 头像 Base64（未设置时 `null`）。
  String? get avatarBase64 => _avatarBase64;

  /// 上级用户推荐码（未填写时为空串）。
  String get referral => _referral;

  /// 是否登录中（主按钮展示进度圈）。
  bool get loading => _loading;

  /// 头部展示名（未登录固定「未登录」，对齐 iOS `loginSection`）。
  String get displayName =>
      _loggedIn ? (_username.isEmpty ? _account : _username) : '未登录';

  /// 从落盘键加载初始态（App 启动 / 进入个人中心时调用）。
  Future<void> load() async {
    final String? savedAccount = await _store.get(kAccountKey);
    if (savedAccount != null && savedAccount.isNotEmpty) {
      _account = savedAccount;
    }
    final String? savedUsername = await _store.get(kUsernameKey);
    if (savedUsername != null && savedUsername.isNotEmpty) {
      _username = savedUsername;
      // 旧版本无 account 时，用老 username 兜底迁移（对齐 iOS L827）。
      if (_account.isEmpty) _account = savedUsername;
    }
    _loggedIn = (await _store.get(kLoggedInKey)) == 'true';
    _avatarBase64 = await _store.get(kAvatarKey);
    _referral = await _store.get(kReferralKey) ?? '';
    notifyListeners();
  }

  /// 该账号是否已注册（存在非空 `password_<account>`），决定按钮文案。
  Future<bool> isRegistered(String account) async {
    final String trimmed = account.trim();
    if (trimmed.isEmpty) return false;
    final String? saved = await _store.get(passwordKey(trimmed));
    return saved != null && saved.isNotEmpty;
  }

  /// 登录 / 注册（首次即注册）。返回错误文案，`null` 表示成功。
  ///
  /// [referral] 为可选的上级推荐码（M-账1）：非空时随登录一并落库。
  Future<String?> login({
    required String account,
    required String password,
    String referral = '',
  }) async {
    final String trimmedAccount = account.trim();
    if (trimmedAccount.isEmpty) return '请输入用户名';
    final String trimmedPassword = password.trim();
    if (trimmedPassword.isEmpty) return '请输入密码';

    _loading = true;
    notifyListeners();
    if (loginDelay > Duration.zero) {
      await Future<void>.delayed(loginDelay);
    }

    final String? saved = await _store.get(passwordKey(trimmedAccount));
    final bool registered = saved != null && saved.isNotEmpty;
    if (registered && saved != trimmedPassword) {
      _loading = false;
      notifyListeners();
      return '密码错误，请重试';
    }
    // 未注册 → 直接注册（对齐 iOS performLogin 的 else 分支）。
    if (!registered) {
      await _store.set(passwordKey(trimmedAccount), trimmedPassword);
    }
    await _applyLogin(trimmedAccount);
    if (referral.trim().isNotEmpty) {
      await setReferral(referral);
    }
    return null;
  }

  /// 落库登录态（对齐 iOS `loginSuccess`）。
  Future<void> _applyLogin(String account) async {
    _account = account;
    // 首次登录用户名取账号；已有展示名则保留（账号与用户名分离）。
    if (_username.isEmpty) _username = account;
    _loggedIn = true;
    _loading = false;
    notifyListeners();
    await _store.set(kAccountKey, account);
    await _store.set(kUsernameKey, _username);
    await _store.set(kLoggedInKey, 'true');
  }

  /// 退出登录（清除登录态，**保留**本机密码与头像）。
  Future<void> logout() async {
    _loggedIn = false;
    _account = '';
    _username = '';
    notifyListeners();
    await _store.set(kLoggedInKey, 'false');
    await _store.set(kAccountKey, '');
    await _store.set(kUsernameKey, '');
  }

  /// 修改展示名（仅改展示名，不影响登录账号）。
  Future<void> rename(String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == _username) return;
    _username = trimmed;
    notifyListeners();
    await _store.set(kUsernameKey, trimmed);
  }

  /// 保存头像（Base64 图片；`null` / 空串表示清除）。
  ///
  /// 对齐 iOS：落 `avatar_image` 设置项，登出时**保留**。
  Future<void> setAvatar(String? base64) async {
    final String value = base64?.trim() ?? '';
    _avatarBase64 = value.isEmpty ? null : value;
    notifyListeners();
    await _store.set(kAvatarKey, value);
  }

  /// 保存上级推荐码（M-账1；空串表示未填写）。
  Future<void> setReferral(String code) async {
    final String trimmed = code.trim();
    if (trimmed == _referral) return;
    _referral = trimmed;
    notifyListeners();
    await _store.set(kReferralKey, trimmed);
  }
}