/// 福利门控控制器（批次 A · A8 / 批次 H · H-05）。
///
/// 唯一真相源：iOS `AppSettings.swift` L104-L118 · L163-L165 与
/// `ContentView.swift` L50-L57 · `ProfileView.swift` L168-L171 · L580-L584。
///
/// 消费三个契约键：
///   · `app_welfare_enabled` （bool，默认 `true`）—— 总开关（图16「启用福利专区」）
///   · `app_welfare_unlocked`（bool，默认 `false`）—— 密码解锁态
///   · `app_welfare_password`（string，默认 `"888888"`）—— 解锁密码
///
/// 关键语义（对齐 iOS，R-10 / R-13）：
///   1. 底栏「福利」Tab 显示条件 = `enabled && unlocked`（`tabVisible`）；
///   2. 密码校验通过**只**置 `unlocked = true`，**不**自动置 `enabled`；
///   3. 关闭总开关（`setEnabled(false)`）**连带**重置 `unlocked = false`。
///
/// `tabBarHidden` 为运行时态（iOS `AppSettings.isTabBarHidden`，**不落盘**），
/// 供 L 批次播放页整体隐藏底栏使用（A8 ④）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/datasources/local/prefs_manager.dart';

/// 福利门控状态控制器（可热切换）。
class WelfareController extends ChangeNotifier {
  /// 构造（缺省对齐 iOS：启用 + 未解锁 + `888888`）。
  WelfareController({
    bool enabled = true,
    bool unlocked = false,
    String password = defaultPassword,
  })  : _enabled = enabled,
        _unlocked = unlocked,
        _password = password;

  /// 契约默认密码（iOS `AppSettings.welfarePassword` 缺省值）。
  static const String defaultPassword = '888888';

  static const String kEnabledKey = 'app_welfare_enabled';
  static const String kUnlockedKey = 'app_welfare_unlocked';
  static const String kPasswordKey = 'app_welfare_password';

  bool _enabled;
  bool _unlocked;
  String _password;
  bool _tabBarHidden = false;
  PrefsManager? _prefs;

  /// 总开关（`app_welfare_enabled`）。
  bool get enabled => _enabled;

  /// 密码解锁态（`app_welfare_unlocked`）。
  bool get unlocked => _unlocked;

  /// 解锁密码（`app_welfare_password`）。
  String get password => _password;

  /// 底栏是否整体隐藏（运行时态，对应 iOS `isTabBarHidden`）。
  bool get tabBarHidden => _tabBarHidden;

  /// 底栏「福利」Tab 显示条件（对齐 iOS `ContentView.visibleTabs`）。
  bool get tabVisible => _enabled && _unlocked;

  /// 从契约键加载并广播（App 启动 / I-01 进入时调用）。
  Future<void> load(PrefsManager prefs) async {
    _prefs = prefs;
    final Object? enabled = await prefs.get(kEnabledKey);
    _enabled = enabled is bool ? enabled : true;
    final Object? unlocked = await prefs.get(kUnlockedKey);
    _unlocked = unlocked is bool ? unlocked : false;
    final Object? password = await prefs.get(kPasswordKey);
    _password = password is String && password.isNotEmpty ? password : defaultPassword;
    notifyListeners();
  }

  /// 校验密码：通过则**只**置解锁态（语义 2），返回是否通过。
  Future<bool> unlock(String input) async {
    if (input != _password) return false;
    if (_unlocked) return true;
    _unlocked = true;
    notifyListeners();
    await _persist(kUnlockedKey, true);
    return true;
  }

  /// 设置总开关；关闭时**连带**重置解锁态（语义 3）。
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) _unlocked = false;
    notifyListeners();
    await _persist(kEnabledKey, value);
    if (!value) await _persist(kUnlockedKey, false);
  }

  /// 运行时隐藏 / 显示底栏（不落盘）。
  void setTabBarHidden(bool value) {
    if (_tabBarHidden == value) return;
    _tabBarHidden = value;
    notifyListeners();
  }

  Future<void> _persist(String key, Object value) async {
    await _prefs?.set(key, value);
  }
}