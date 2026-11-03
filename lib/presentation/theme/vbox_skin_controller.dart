/// 皮肤控制器（批次 A · A-03）。
///
/// 消费契约键 `app_skin_mode`（string，默认 `light`）与
/// `app_skin_follows_system`（bool）—— 对齐 iOS `AppSettings`：
/// 默认 `skinMode = light` · `skinFollowsSystem = true`；
/// `selectSkin(_:)` 会在选择皮肤的同时把「跟随系统」置 `false`。
library;

import 'package:flutter/material.dart';

import '../../data/datasources/local/prefs_manager.dart';
import 'tokens/colors.dart';

/// 皮肤状态控制器（可热切换）。
class VboxSkinController extends ChangeNotifier {
  /// 构造（默认对齐 iOS：浅色 + 跟随系统）。
  VboxSkinController({
    VboxSkin skin = VboxSkin.fallback,
    bool followsSystem = true,
  }) : _skin = skin,
       _followsSystem = followsSystem;

  VboxSkin _skin;
  bool _followsSystem;
  PrefsManager? _prefs;

  /// 当前皮肤。
  VboxSkin get skin => _skin;

  /// 是否跟随系统配色。
  bool get followsSystem => _followsSystem;

  /// 从契约键加载并广播（App 启动时调用一次）。
  Future<void> load(PrefsManager prefs) async {
    _prefs = prefs;
    _skin = VboxSkin.fromId(await prefs.getString('app_skin_mode'));
    // 契约未声明默认值 → 未设置时按 iOS 实测默认 `true`（D17：以 iOS 源码为基准）。
    final Object? raw = await prefs.get('app_skin_follows_system');
    _followsSystem = raw is bool ? raw : true;
    notifyListeners();
  }

  /// 选择皮肤（对齐 iOS `selectSkin`：同时关闭「跟随系统」）并持久化。
  Future<void> selectSkin(VboxSkin skin) async {
    if (_skin == skin && !_followsSystem) return;
    _skin = skin;
    _followsSystem = false;
    notifyListeners();
    await _persist();
  }

  /// 切换「跟随系统」并持久化。
  Future<void> setFollowsSystem(bool value) async {
    if (_followsSystem == value) return;
    _followsSystem = value;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final PrefsManager? p = _prefs;
    if (p == null) return;
    await p.set('app_skin_mode', _skin.id);
    await p.set('app_skin_follows_system', _followsSystem);
  }
}