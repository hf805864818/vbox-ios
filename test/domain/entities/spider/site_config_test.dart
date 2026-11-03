/// 单元测试：SiteConfig 解析、序列化与引擎选择规则。
///
/// 对应源码：lib/domain/entities/spider/site_config.dart
/// 契约：contract/docs/abi_v1.md §8 + §1.1，contract/schema/site_v1.json
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/engine_type.dart';
import 'package:vbox/domain/entities/spider/site_config.dart';

void main() {
  group('SiteConfig.fromJson', () {
    test('完整字段解析', () {
      final SiteConfig s = SiteConfig.fromJson(<String, Object?>{
        'key': 'js_剧迷',
        'name': '剧迷',
        'type': 3,
        'api': 'https://example.com/js/jumi.js',
        'searchable': 1,
        'quickSearch': 0,
        'filterable': 1,
        'ext': '{}',
        'playerType': 2,
        'jar': 'x.jar',
        'changeable': 1,
        'playStrategy': 'direct',
        'playMode': 'pan',
        'panHosts': <Object?>['quark', 'ali'],
        'group': 'video',
        'engineType': 'lxMusic',
        'pluginPath': 'sources/lx/daxe.js',
        'version': '1.0.0',
        'md5': 'abc123',
      });
      expect(s.key, 'js_剧迷');
      expect(s.name, '剧迷');
      expect(s.type, 3);
      expect(s.api, 'https://example.com/js/jumi.js');
      expect(s.searchable, 1);
      expect(s.quickSearch, 0);
      expect(s.filterable, 1);
      expect(s.ext, '{}');
      expect(s.playerType, 2);
      expect(s.jar, 'x.jar');
      expect(s.changeable, 1);
      expect(s.playStrategy, 'direct');
      expect(s.playMode, 'pan');
      expect(s.panHosts, <String>['quark', 'ali']);
      expect(s.group, 'video');
      expect(s.engineType, 'lxMusic');
      expect(s.pluginPath, 'sources/lx/daxe.js');
      expect(s.version, '1.0.0');
      expect(s.md5, 'abc123');
    });

    test('缺省字段：key/name 为空串，type 为 0，其余皆 null', () {
      final SiteConfig s = SiteConfig.fromJson(const <String, Object?>{});
      expect(s.key, '');
      expect(s.name, '');
      expect(s.type, 0);
      expect(s.api, isNull);
      expect(s.searchable, isNull);
      expect(s.quickSearch, isNull);
      expect(s.filterable, isNull);
      expect(s.ext, isNull);
      expect(s.playerType, isNull);
      expect(s.jar, isNull);
      expect(s.changeable, isNull);
      expect(s.playStrategy, isNull);
      expect(s.playMode, isNull);
      expect(s.panHosts, isNull);
      expect(s.group, isNull);
      expect(s.engineType, isNull);
      expect(s.pluginPath, isNull);
      expect(s.version, isNull);
      expect(s.md5, isNull);
    });

    test('宽松数值：type 为数字字符串 / double，整数与非数字转换', () {
      expect(SiteConfig.fromJson(<String, Object?>{'type': '3'}).type, 3);
      expect(SiteConfig.fromJson(<String, Object?>{'type': 3.0}).type, 3);
      expect(SiteConfig.fromJson(<String, Object?>{'type': 3.9}).type, 3);
      // 非数字 → null → 兜底 0
      expect(SiteConfig.fromJson(<String, Object?>{'type': 'x'}).type, 0);
      expect(SiteConfig.fromJson(<String, Object?>{'type': true}).type, 0);
      // 可空整数字段：非法值保持 null
      expect(
        SiteConfig.fromJson(<String, Object?>{'searchable': 'NaN'}).searchable,
        isNull,
      );
    });

    test('非字符串的 key/name 通过 toString 归一化', () {
      final SiteConfig s =
          SiteConfig.fromJson(<String, Object?>{'key': 123, 'name': 4.5});
      expect(s.key, '123');
      expect(s.name, '4.5');
    });

    test('panHosts 各元素通过 toString 归一化（含数字元素）', () {
      final SiteConfig s = SiteConfig.fromJson(<String, Object?>{
        'panHosts': <Object?>['quark', 42, 3.5],
      });
      expect(s.panHosts, <String>['quark', '42', '3.5']);
    });

    test('panHosts 类型不符（非 List）时抛 TypeError（强转失败）', () {
      expect(
        () => SiteConfig.fromJson(<String, Object?>{'panHosts': 'quark'}),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('SiteConfig.toJson', () {
    test('key/name/type 始终输出，可空字段为 null 时省略', () {
      const SiteConfig s = SiteConfig(key: 'k', name: 'n', type: 0);
      expect(s.toJson(), <String, Object?>{'key': 'k', 'name': 'n', 'type': 0});
    });

    test('非空可空字段全部输出', () {
      const SiteConfig s = SiteConfig(
        key: 'k',
        name: 'n',
        type: 3,
        api: 'a.js',
        searchable: 1,
        panHosts: <String>['quark'],
        playMode: 'pan',
      );
      final Map<String, Object?> j = s.toJson();
      expect(j['api'], 'a.js');
      expect(j['searchable'], 1);
      expect(j['panHosts'], <String>['quark']);
      expect(j['playMode'], 'pan');
      expect(j.containsKey('jar'), isFalse);
      expect(j.containsKey('md5'), isFalse);
    });

    test('toJson → fromJson 往返稳定', () {
      const SiteConfig s = SiteConfig(
        key: 'nodejs_foo',
        name: 'Foo',
        type: 3,
        api: 'http://127.0.0.1:58080/spider/foo',
        searchable: 1,
        quickSearch: 0,
        filterable: 1,
        ext: '{"a":1}',
        playerType: 2,
        jar: 'x.jar',
        changeable: 1,
        playStrategy: 'p',
        playMode: 'hybrid',
        panHosts: <String>['quark', 'ali'],
        group: 'node',
        engineType: 'lxMusic',
        pluginPath: 'p.js',
        version: '1.0.0',
        md5: 'm',
      );
      final SiteConfig back = SiteConfig.fromJson(s.toJson());
      expect(back.key, s.key);
      expect(back.name, s.name);
      expect(back.type, s.type);
      expect(back.api, s.api);
      expect(back.searchable, s.searchable);
      expect(back.quickSearch, s.quickSearch);
      expect(back.filterable, s.filterable);
      expect(back.ext, s.ext);
      expect(back.playerType, s.playerType);
      expect(back.jar, s.jar);
      expect(back.changeable, s.changeable);
      expect(back.playStrategy, s.playStrategy);
      expect(back.playMode, s.playMode);
      expect(back.panHosts, s.panHosts);
      expect(back.group, s.group);
      expect(back.engineType, s.engineType);
      expect(back.pluginPath, s.pluginPath);
      expect(back.version, s.version);
      expect(back.md5, s.md5);
    });
  });

  group('SiteConfig.isNodeSite', () {
    test('group == "node" 命中', () {
      const SiteConfig s = SiteConfig(key: 'x', name: 'x', type: 3, group: 'node');
      expect(s.isNodeSite, isTrue);
    });

    test('key 前缀 nodejs_ 命中', () {
      const SiteConfig s =
          SiteConfig(key: 'nodejs_abc', name: 'x', type: 3);
      expect(s.isNodeSite, isTrue);
    });

    test('key 前缀 csp_ 且 type==3 命中', () {
      const SiteConfig s = SiteConfig(key: 'csp_demo', name: 'x', type: 3);
      expect(s.isNodeSite, isTrue);
    });

    test('key 前缀 csp_ 但 type!=3 不命中', () {
      const SiteConfig s = SiteConfig(key: 'csp_demo', name: 'x', type: 2);
      expect(s.isNodeSite, isFalse);
    });

    test('api 前缀 nodejs_ 命中', () {
      const SiteConfig s = SiteConfig(
          key: 'x', name: 'x', type: 3, api: 'nodejs_remote');
      expect(s.isNodeSite, isTrue);
    });

    test('api 前缀 csp_ 且 type==3 命中', () {
      const SiteConfig s = SiteConfig(
          key: 'x', name: 'x', type: 3, api: 'csp_className');
      expect(s.isNodeSite, isTrue);
    });

    test('api 含 127.0.0.1 且含 /spider/ 命中', () {
      const SiteConfig s = SiteConfig(
        key: 'x',
        name: 'x',
        type: 3,
        api: 'http://127.0.0.1:58080/spider/foo',
      );
      expect(s.isNodeSite, isTrue);
    });

    test('api 仅含 127.0.0.1 但无 /spider/ 不命中', () {
      const SiteConfig s = SiteConfig(
        key: 'x',
        name: 'x',
        type: 3,
        api: 'http://127.0.0.1:58080/other',
      );
      expect(s.isNodeSite, isFalse);
    });

    test('普通 JS 站点不命中', () {
      const SiteConfig s = SiteConfig(
          key: 'js_a', name: 'x', type: 3, api: 'https://a.com/a.js');
      expect(s.isNodeSite, isFalse);
    });
  });

  group('SiteConfig.resolveSiteMode', () {
    test('① isNodeSite 优先级最高（即使 type==1）', () {
      const SiteConfig s = SiteConfig(
          key: 'nodejs_x', name: 'x', type: 1, api: 'https://a.com');
      expect(s.resolveSiteMode(), SiteMode.node);
    });

    test('② type 0 / 1 → apiEndpoint', () {
      expect(
        const SiteConfig(key: 'k', name: 'n', type: 0).resolveSiteMode(),
        SiteMode.apiEndpoint,
      );
      expect(
        const SiteConfig(key: 'k', name: 'n', type: 1).resolveSiteMode(),
        SiteMode.apiEndpoint,
      );
    });

    test('③ type 2 → zhanyuan', () {
      expect(
        const SiteConfig(key: 'k', name: 'n', type: 2).resolveSiteMode(),
        SiteMode.zhanyuan,
      );
    });

    test('④ type 3 含 ".jar" → unsupported（优先级高于 .js 判定）', () {
      const SiteConfig s = SiteConfig(
          key: 'k', name: 'n', type: 3, api: 'https://a.com/x.jar');
      expect(s.resolveSiteMode(), SiteMode.unsupported);
    });

    test('④ type 3 后缀 ".py" → pythonSpider', () {
      const SiteConfig s = SiteConfig(
          key: 'k', name: 'n', type: 3, api: 'https://a.com/x.py');
      expect(s.resolveSiteMode(), SiteMode.pythonSpider);
    });

    test('④ type 3 http(s):// 且后缀 ".js" → jsSpider', () {
      const SiteConfig s = SiteConfig(
          key: 'k', name: 'n', type: 3, api: 'https://a.com/x.js');
      expect(s.resolveSiteMode(), SiteMode.jsSpider);
    });

    test('④ type 3 http(s):// 且非 .js → apiEndpoint', () {
      const SiteConfig s = SiteConfig(
          key: 'k', name: 'n', type: 3, api: 'https://a.com/api');
      expect(s.resolveSiteMode(), SiteMode.apiEndpoint);
    });

    test('④ type 3 相对路径后缀 ".js" → jsSpider', () {
      const SiteConfig s =
          SiteConfig(key: 'k', name: 'n', type: 3, api: 'foo.js');
      expect(s.resolveSiteMode(), SiteMode.jsSpider);
    });

    test('④ type 3 "./" 前缀（即使无 .js）→ jsSpider', () {
      const SiteConfig s =
          SiteConfig(key: 'k', name: 'n', type: 3, api: './local/path');
      expect(s.resolveSiteMode(), SiteMode.jsSpider);
    });

    test('④ type 3 纯类名 → unsupported', () {
      const SiteConfig s =
          SiteConfig(key: 'k', name: 'n', type: 3, api: 'ClassName');
      expect(s.resolveSiteMode(), SiteMode.unsupported);
    });

    test('④ type 3 api 为空 → unsupported', () {
      const SiteConfig s = SiteConfig(key: 'k', name: 'n', type: 3);
      expect(s.resolveSiteMode(), SiteMode.unsupported);
    });

    test('⑤ 其他 type（4）→ unsupported', () {
      const SiteConfig s = SiteConfig(key: 'k', name: 'n', type: 4);
      expect(s.resolveSiteMode(), SiteMode.unsupported);
    });
  });

  group('SiteConfig.resolveEngineType', () {
    test('node 普通源 → SpiderEngineType.node', () {
      const SiteConfig s = SiteConfig(
          key: 'nodejs_abc', name: 'n', type: 3, group: 'video');
      expect(s.resolveEngineType(), SpiderEngineType.node);
    });

    test('group==node 且 engineType==lxMusic → nodeLX', () {
      const SiteConfig s = SiteConfig(
        key: 'nodejs_lx',
        name: 'n',
        type: 3,
        group: 'node',
        engineType: 'lxMusic',
      );
      expect(s.resolveEngineType(), SpiderEngineType.nodeLX);
    });

    test('group==node 且 api 含 "lx" → nodeLX', () {
      const SiteConfig s = SiteConfig(
        key: 'nodejs_lx',
        name: 'n',
        type: 3,
        group: 'node',
        api: 'nodejs_lx_source',
      );
      expect(s.resolveEngineType(), SpiderEngineType.nodeLX);
    });

    test('jsSpider → javaScriptCore', () {
      const SiteConfig s = SiteConfig(
          key: 'k', name: 'n', type: 3, api: 'https://a.com/x.js');
      expect(s.resolveEngineType(), SpiderEngineType.javaScriptCore);
    });

    test('pythonSpider → python', () {
      const SiteConfig s = SiteConfig(
          key: 'k', name: 'n', type: 3, api: 'https://a.com/x.py');
      expect(s.resolveEngineType(), SpiderEngineType.python);
    });

    test('apiEndpoint / zhanyuan / unsupported → null（非脚本引擎）', () {
      expect(
        const SiteConfig(key: 'k', name: 'n', type: 1).resolveEngineType(),
        isNull,
      );
      expect(
        const SiteConfig(key: 'k', name: 'n', type: 2).resolveEngineType(),
        isNull,
      );
      expect(
        const SiteConfig(key: 'k', name: 'n', type: 4).resolveEngineType(),
        isNull,
      );
    });
  });
}