/// 契约层单测：`prefs_keys.dart` 镜像保真度（对照 JSON 唯一真相源）。
///
/// 目的：Python 守卫（`check_contract_sync.py`）之外的**进程内**第二道防线，
/// 任何一侧改动而忘记同步另一侧时，测试立刻失败。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/contract/prefs_keys.dart';

/// JSON 契约里的单个键（含其所属分组名）。
typedef _JsonKey = ({String group, Map<String, Object?> meta});

Map<String, Object?> _readContract() {
  final File f = File('contract/schema/prefs_keys_v1.json');
  expect(f.existsSync(), isTrue, reason: '真相源不存在: ${f.path}（cwd=${Directory.current.path}）');
  return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
}

Map<String, _JsonKey> _flatten(Map<String, Object?> contract) {
  final Map<String, _JsonKey> out = <String, _JsonKey>{};
  final Map<String, Object?> groups =
      (contract['keys'] as Map<Object?, Object?>).cast<String, Object?>();
  groups.forEach((String group, Object? items) {
    (items! as Map<Object?, Object?>).forEach((Object? k, Object? v) {
      out[k! as String] = (
        group: group,
        meta: (v! as Map<Object?, Object?>).cast<String, Object?>(),
      );
    });
  });
  return out;
}

const Map<String, PrefsStorage> _storageByName = <String, PrefsStorage>{
  'userdefaults': PrefsStorage.userDefaults,
  'keychain': PrefsStorage.keychain,
  'credential_extra': PrefsStorage.credentialExtra,
};

void main() {
  late Map<String, Object?> contract;
  late Map<String, _JsonKey> json;

  setUpAll(() {
    contract = _readContract();
    json = _flatten(contract);
  });

  group('键名 / 分组', () {
    test('98 键与 JSON 完全一致且无重复', () {
      final Set<String> dartNames =
          kAllPrefsKeys.map((PrefsKey k) => k.name).toSet();
      expect(kAllPrefsKeys.length, dartNames.length, reason: 'Dart 侧键名重复');
      expect(dartNames, json.keys.toSet());
      expect(dartNames.length, 98);
      expect(kAllKeyNames, dartNames);
    });

    test('21 分组：枚举 ↔ 分组名映射 ↔ JSON 三向一致', () {
      final Set<String> jsonGroups =
          (contract['keys'] as Map<Object?, Object?>).keys.cast<String>().toSet();
      expect(kGroupNameToEnum.keys.toSet(), jsonGroups);
      expect(PrefsGroup.values.length, jsonGroups.length);
      expect(PrefsGroup.values.length, 21);
    });
  });

  group('逐键元数据保真', () {
    test('type 与 JSON 一致', () {
      for (final PrefsKey k in kAllPrefsKeys) {
        final Object? t = json[k.name]!.meta['type'];
        expect(k.type, PrefsType.fromJson(t! as String), reason: k.name);
      }
    });

    test('storage 与 JSON 一致（D19：98/98 键均标注）', () {
      for (final PrefsKey k in kAllPrefsKeys) {
        final Object? raw = json[k.name]!.meta['storage'];
        expect(raw, isNotNull, reason: '${k.name} 缺 storage（违反 D19）');
        expect(k.storage, _storageByName[raw], reason: k.name);
      }
    });

    test('分组归属与 JSON 一致', () {
      for (final PrefsKey k in kAllPrefsKeys) {
        expect(k.group, kGroupNameToEnum[json[k.name]!.group], reason: k.name);
      }
    });

    test('sensitive 标志与 JSON 一致，且等于 kSensitiveKeys', () {
      final Set<String> flags = <String>{
        for (final PrefsKey k in kAllPrefsKeys)
          if (k.sensitive) k.name,
      };
      final Set<String> jsonSensitive =
          (contract['sensitiveKeys']! as List<Object?>).cast<String>().toSet();
      expect(flags, jsonSensitive);
      expect(kSensitiveKeys, jsonSensitive);
      expect(jsonSensitive.length, 7);
    });

    test('JSON 标 sensitive 的键，Dart 标志必须为真（防既有缺陷回归）', () {
      for (final String name in kSensitiveKeys) {
        expect(findPrefsKey(name)?.sensitive, isTrue,
            reason: '$name 在 kSensitiveKeys 内但 PrefsKey.sensitive 未置真'
                '（会被 PrefsManager 写入明文 SharedPreferences）');
      }
    });
  });

  group('辅助函数', () {
    test('findPrefsKey 命中 / 未命中', () {
      expect(findPrefsKey('subscribed_config_urls')?.name, 'subscribed_config_urls');
      expect(findPrefsKey('不存在的键'), isNull);
    });

    test('isSensitiveKey 与 kSensitiveKeys 同源', () {
      for (final String name in kAllKeyNames) {
        expect(isSensitiveKey(name), kSensitiveKeys.contains(name), reason: name);
      }
    });

    test('keysOfGroup 覆盖全部键且不重复', () {
      final List<PrefsKey> all = <PrefsKey>[
        for (final PrefsGroup g in PrefsGroup.values) ...keysOfGroup(g),
      ];
      expect(all.length, kAllPrefsKeys.length);
      expect(all.map((PrefsKey k) => k.name).toSet().length, 98);
    });

    test('PrefsType.fromJson 未知类型抛 ArgumentError', () {
      expect(() => PrefsType.fromJson('dateTime'), throwsArgumentError);
    });
  });
}