/// 平台层单测：`spider_js_globals.dart`（B-05a · 6 项逐项）。
///
/// 「与引擎无关」验证方式：prelude 是纯 JS，用 **Node** 作为任意 JS 引擎
/// （`node -e` 子进程）真实 eval，断言 6 项能力逐一生效 —— 证明任何能跑 JS
/// 的引擎（QuickJS FFI / JSC / Node 桥）注入 prelude 即获得全部能力；
/// Dart 参考实现（atob/btoa/options/parseLogs）另行对拍。
///
/// 注意：prelude 接管了 `console`（缓冲进 `__vboxLogs`），因此检查脚本统一用
/// `process.stdout.write` 输出结果（Node 专属，与被测能力无关）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/spider/spider_js_globals.dart';

/// 在 Node 中 eval [SpiderJsGlobals.prelude] + [checks]，返回 stdout。
Future<String> _runInNode(String checks) async {
  final ProcessResult r = await Process.run(
    'node',
    <String>['-e', '${SpiderJsGlobals.prelude()}\n$checks'],
  );
  expect(r.exitCode, 0, reason: 'prelude 在任意 JS 引擎中必须零异常可跑');
  return (r.stdout as String).trim();
}

void main() {
  group('B-05a · prelude 注入任意 JS 引擎（Node 真实执行）', () {
    test('① console 四级 + ② print：无宿主时缓冲 __vboxLogs，格式化参数', () async {
      final String out = await _runInNode('''
        console.log('a', 1, null, undefined);
        console.info('infoMsg');
        console.warn('warnMsg');
        console.error('errMsg');
        print('printed');
        console.log({k: 'v'});
        process.stdout.write(JSON.stringify(globalThis.__vboxLogs));
      ''');
      final List<dynamic> logs = jsonDecode(out) as List<dynamic>;
      expect(logs, <String>[
        'LOG|a 1 null undefined',
        'INFO|infoMsg',
        'WARN|warnMsg',
        'ERROR|errMsg',
        'LOG|printed',
        'LOG|{"k":"v"}',
      ]);
    });

    test('①② 宿主通道：注册 __vboxLog 后直发宿主，不再缓冲', () async {
      final String out = await _runInNode('''
        globalThis.__vboxHost = [];
        globalThis.__vboxLog = function (level, text) {
          globalThis.__vboxHost.push(level + '#' + text);
        };
        // 宿主函数注册晚于 prelude 也必须生效（emit 调用时动态判定通道）
        console.log('late');
        print('p');
        process.stdout.write(JSON.stringify(globalThis.__vboxHost));
      ''');
      expect(
        jsonDecode(out),
        <String>['LOG#late', 'LOG#p'],
        reason: 'prelude 先于宿主函数注册时，emit 应改为直发（两级通道）',
      );
    });

    test('③ atob：标准 + URL-safe 归一 + padding 补齐 + 容错', () async {
      final String out = await _runInNode('''
        process.stdout.write(JSON.stringify([
          atob('aGVsbG8='),
          atob('aGVsbG8'),
          atob('-_8=') === atob('+/8='),
          atob('!!')
        ]));
      ''');
      final List<dynamic> r = jsonDecode(out) as List<dynamic>;
      expect(r[0], 'hello');
      expect(r[1], 'hello');
      expect(r[2], isTrue);
      expect((r[3] as String).isEmpty, isTrue);
    });

    test('④ btoa：Latin-1 语义 + 与 atob 往返', () async {
      final String out = await _runInNode('''
        process.stdout.write(JSON.stringify([
          btoa('hello'),
          btoa('hell'),
          btoa('hel'),
          atob(btoa('\\u00ff\\u0080')),
          btoa('') === ''
        ]));
      ''');
      final List<dynamic> r = jsonDecode(out) as List<dynamic>;
      expect(r[0], 'aGVsbG8=');
      expect(r[1], 'aGVsbA==');
      expect(r[2], 'aGVs');
      expect(r[3], 'ÿ');
      expect(r[4], isTrue);
    });

    test('⑤ req 别名：宿主注册 http 后（再注入 prelude）req 可用且 options 归一', () async {
      final String out = await _runInNode('''
        globalThis.__calls = [];
        globalThis.http = function (url, options) {
          globalThis.__calls.push([url, options]);
          return 'resp:' + url;
        };
        // 宿主注册 http 晚于首次 prelude → 再次注入（幂等），包装与 req 别名生效
        ${SpiderJsGlobals.prelude()}
        var r1 = http('https://a.com/1', {method: 'GET', async: true});
        var r2 = req('https://a.com/2');
        process.stdout.write(JSON.stringify([r1, r2, globalThis.__calls]));
      ''');
      final List<dynamic> r = jsonDecode(out) as List<dynamic>;
      expect(r[0], 'resp:https://a.com/1');
      expect(r[1], 'resp:https://a.com/2');
      final List<dynamic> calls = r[2] as List<dynamic>;
      expect((calls[0] as List<dynamic>)[1],
          <String, Object?>{'method': 'GET', 'async': false});
      expect((calls[1] as List<dynamic>)[1],
          <String, Object?>{'async': false});
    });

    test('⑥ 对象式 options 归一：缺省/非对象 → {}；强制 async=false', () async {
      final String out = await _runInNode('''
        process.stdout.write(JSON.stringify([
          __vboxNormalizeOptions(null),
          __vboxNormalizeOptions(),
          __vboxNormalizeOptions('string'),
          __vboxNormalizeOptions(42),
          __vboxNormalizeOptions({headers: {'a': 'b'}, async: true})
        ]));
      ''');
      final List<dynamic> r = jsonDecode(out) as List<dynamic>;
      expect(r[0], <String, Object?>{'async': false});
      expect(r[1], <String, Object?>{'async': false});
      expect(r[2], <String, Object?>{'async': false});
      expect(r[3], <String, Object?>{'async': false});
      expect(r[4], <String, Object?>{
        'headers': <String, String>{'a': 'b'},
        'async': false,
      });
    });

    test('幂等：prelude 连续注入两次不抛异常、能力不失效', () async {
      final String out = await _runInNode('''
        ${SpiderJsGlobals.prelude()}
        print('again');
        process.stdout.write(JSON.stringify(globalThis.__vboxLogs));
      ''');
      expect(jsonDecode(out), <String>['LOG|again']);
    });

    test('内置脚本零改动可跑：直接调用全局能力不 ReferenceError', () async {
      final String out = await _runInNode('''
        globalThis.__vboxLog = function () {};
        process.stdout.write(JSON.stringify([
          typeof console.log, typeof print,
          typeof atob, typeof btoa
        ]));
      ''');
      expect(jsonDecode(out), everyElement('function'));
    });
  });

  group('B-05a · Dart 参考实现', () {
    test('atob：标准 / URL-safe / padding / 非法输入', () {
      expect(SpiderJsGlobals.atob('aGVsbG8='), 'hello');
      expect(SpiderJsGlobals.atob('aGVsbG8'), 'hello');
      expect(SpiderJsGlobals.atob('-_8='), SpiderJsGlobals.atob('+/8='));
      expect(SpiderJsGlobals.atob('!!!'), '');
    });

    test('btoa：Latin-1 语义 + 与 atob 往返', () {
      expect(SpiderJsGlobals.btoa('hello'), 'aGVsbG8=');
      expect(SpiderJsGlobals.btoa('hel'), 'aGVs');
      expect(SpiderJsGlobals.btoa(''), '');
      final String bin = String.fromCharCodes(<int>[0xff, 0x80, 0x41]);
      expect(SpiderJsGlobals.atob(SpiderJsGlobals.btoa(bin)), bin);
    });

    test('normalizeHttpOptions：null/非对象 → {}；强制同步', () {
      expect(SpiderJsGlobals.normalizeHttpOptions(null),
          <String, Object?>{'async': false});
      expect(SpiderJsGlobals.normalizeHttpOptions('str'),
          <String, Object?>{'async': false});
      expect(
        SpiderJsGlobals.normalizeHttpOptions(
          <String, Object?>{'method': 'GET', 'async': true},
        ),
        <String, Object?>{'method': 'GET', 'async': false},
      );
    });

    test('parseLogs：级别前缀按 iOS 语义；容错空/非 JSON/非数组', () {
      expect(
        SpiderJsGlobals.parseLogs('["LOG|a","ERROR|b","WARN|c","INFO|d","|e"]'),
        <String>['a', 'ERROR: b', 'WARN: c', 'INFO: d', '|e'],
      );
      expect(SpiderJsGlobals.parseLogs(''), isEmpty);
      expect(SpiderJsGlobals.parseLogs('not json'), isEmpty);
      expect(SpiderJsGlobals.parseLogs('{"a":1}'), isEmpty);
    });

    test('prelude 版本标记稳定（注入排障用）', () {
      expect(SpiderJsGlobals.preludeVersion, '__VBOX_JS_GLOBALS_V1__');
      expect(
        SpiderJsGlobals.prelude().contains(SpiderJsGlobals.preludeVersion),
        isTrue,
      );
    });
  });
}
