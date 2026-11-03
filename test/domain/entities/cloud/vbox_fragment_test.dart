/// 网盘 `vbox_*` fragment 编解码单测（F-P27）。
///
/// 对齐基准（唯一真相源）：iOS `CloudDriveManager.splitVboxFragment`
/// （`vbox/Services/CloudDriveManager.swift:10243`）与
/// `VideoPlayerViewV2.splitVboxFragment` / `appendVboxFragment`
/// （`vbox/Views/PlayerViewsV2.swift:2982/3006`）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/vbox_fragment.dart';

void main() {
  group('VboxFragment · 参数集', () {
    test('定位键优先级：node → fsid → fid → pickcode → fileId → contentId', () {
      expect(
        const VboxFragment(node: 'n1', fsid: 'f2', fid: 'f3').locateKey,
        ('vbox_node', 'n1'),
      );
      expect(
        const VboxFragment(fsid: 'f2', fid: 'f3').locateKey,
        ('vbox_fsid', 'f2'),
      );
      expect(const VboxFragment(fid: 'f3').locateKey, ('vbox_fid', 'f3'));
      expect(
        const VboxFragment(pickcode: 'p1').locateKey,
        ('vbox_pickcode', 'p1'),
      );
      expect(
        const VboxFragment(fileId: 'x1').locateKey,
        ('vbox_fileId', 'x1'),
      );
      expect(
        const VboxFragment(contentId: 'c1').locateKey,
        ('vbox_contentId', 'c1'),
      );
    });

    test('无定位键 → locateKey null / locateValue 空串', () {
      const VboxFragment empty = VboxFragment();
      expect(empty.locateKey, isNull);
      expect(empty.locateValue, '');
      expect(empty.isEmpty, isTrue);
      expect(empty.isNotEmpty, isFalse);
    });

    test('空串定位值不参与判定', () {
      expect(const VboxFragment(node: '').locateKey, isNull);
    });

    test('nodeMark / route 单列不影响 isEmpty', () {
      expect(const VboxFragment(nodeMark: true).isEmpty, isFalse);
      expect(const VboxFragment(route: 'original').isEmpty, isFalse);
    });
  });

  group('VboxFragment.fromParams', () {
    test('识别已知键 + 未知 vbox_ 键归入 extra', () {
      final VboxFragment f = VboxFragment.fromParams(<String, String>{
        'vbox_fid': 'a',
        'vbox_node': 'n',
        'vbox_nd': '1',
        'vbox_future': 'z',
        'other': 'ignore',
      });
      expect(f.fid, 'a');
      expect(f.node, 'n');
      expect(f.nodeMark, isTrue);
      expect(f.extra, <String, String>{'vbox_future': 'z'});
    });

    test('vbox_nd 非 "1" → nodeMark false', () {
      expect(
        VboxFragment.fromParams(<String, String>{'vbox_nd': '0'}).nodeMark,
        isFalse,
      );
    });
  });

  group('VboxFragmentCodec.split', () {
    test('无 fragment → 原样返回，参数为空', () {
      final VboxFragmentSplit s =
          VboxFragmentCodec.split('https://pan.quark.cn/s/abc');
      expect(s.baseUrl, 'https://pan.quark.cn/s/abc');
      expect(s.params.isEmpty, isTrue);
      expect(s.hasParams, isFalse);
    });

    test('剥离 vbox_* 参数得干净分享链接', () {
      final VboxFragmentSplit s = VboxFragmentCodec.split(
        'https://pan.quark.cn/s/abc#vbox_fid=FILE1&vbox_route=original',
      );
      expect(s.baseUrl, 'https://pan.quark.cn/s/abc');
      expect(s.params.fid, 'FILE1');
      expect(s.params.route, 'original');
      expect(s.hasParams, isTrue);
    });

    test('非 vbox 参数透传保留在 baseUrl（含无 = 段）', () {
      final VboxFragmentSplit s = VboxFragmentCodec.split(
        'https://pan.quark.cn/s/abc#flag&foo=1&vbox_fid=FILE1',
      );
      expect(s.baseUrl, 'https://pan.quark.cn/s/abc#flag&foo=1');
      expect(s.params.fid, 'FILE1');
    });

    test('percent-decode：非法编码回退原值', () {
      expect(
        VboxFragmentCodec.split('https://x/a#vbox_node=a%2Bb').params.node,
        'a+b',
      );
      expect(
        VboxFragmentCodec.split('https://x/a#vbox_node=%zz').params.node,
        '%zz',
      );
    });

    test('strip == split().baseUrl', () {
      const String url = 'https://pan.baidu.com/s/1x#vbox_fsid=99';
      expect(VboxFragmentCodec.strip(url), 'https://pan.baidu.com/s/1x');
    });
  });

  group('VboxFragmentCodec.append', () {
    test('无 # → 以 # 追加', () {
      expect(
        VboxFragmentCodec.append(
          'https://pan.quark.cn/s/abc',
          <String, String>{'vbox_fid': 'F1'},
        ),
        'https://pan.quark.cn/s/abc#vbox_fid=F1',
      );
    });

    test('已有 # → 以 & 追加', () {
      expect(
        VboxFragmentCodec.append(
          'https://x/a#foo=1',
          <String, String>{'vbox_fid': 'F1'},
        ),
        'https://x/a#foo=1&vbox_fid=F1',
      );
    });

    test('空参数 → 原样返回', () {
      expect(
        VboxFragmentCodec.append('https://x/a', const <String, String>{}),
        'https://x/a',
      );
    });

    test('append → split 往返稳定（内含特殊字符）', () {
      const String base = 'https://pan.quark.cn/s/abc';
      final String appended = VboxFragmentCodec.append(
        base,
        <String, String>{'vbox_node': 'a+b=c d'},
      );
      final VboxFragmentSplit s = VboxFragmentCodec.split(appended);
      expect(s.baseUrl, base);
      expect(s.params.node, 'a+b=c d');
    });
  });

  group('VboxFragmentCodec.appendNodeMark', () {
    test('无 fragment → #vbox_nd=1', () {
      expect(
        VboxFragmentCodec.appendNodeMark('https://pan.quark.cn/s/abc'),
        'https://pan.quark.cn/s/abc#vbox_nd=1',
      );
    });

    test('已带 vbox_nd=1 → 幂等', () {
      const String url = 'https://pan.quark.cn/s/abc#vbox_nd=1';
      expect(VboxFragmentCodec.appendNodeMark(url), url);
    });

    test('已有其它 fragment → 前置 vbox_nd=1', () {
      expect(
        VboxFragmentCodec.appendNodeMark('https://x/a#vbox_fid=F1'),
        'https://x/a#vbox_nd=1&vbox_fid=F1',
      );
    });
  });

  group('VboxFragmentCodec.resolveShareType', () {
    test('null / 空 → null', () {
      expect(VboxFragmentCodec.resolveShareType(null), isNull);
      expect(VboxFragmentCodec.resolveShareType(''), isNull);
    });

    test('未识别域名 → null', () {
      expect(
        VboxFragmentCodec.resolveShareType('https://unknown.example/x'),
        isNull,
      );
    });

    test('原生盘：夸克 / 百度 / UC', () {
      expect(
        VboxFragmentCodec.resolveShareType('https://pan.quark.cn/s/abc'),
        CloudDriveType.quark,
      );
      expect(
        VboxFragmentCodec.resolveShareType('https://pan.baidu.com/s/1x'),
        CloudDriveType.baidu,
      );
      expect(
        VboxFragmentCodec.resolveShareType('https://drive.uc.cn/s/abc'),
        CloudDriveType.uc,
      );
    });

    test('#vbox_nd=1 → 映射为对应 Node 派生盘（其余盘不变）', () {
      expect(
        VboxFragmentCodec.resolveShareType(
          'https://pan.quark.cn/s/abc#vbox_nd=1',
        ),
        CloudDriveType.quarkNode,
      );
      expect(
        VboxFragmentCodec.resolveShareType(
          'https://drive.uc.cn/s/abc#vbox_nd=1',
        ),
        CloudDriveType.ucNode,
      );
      expect(
        VboxFragmentCodec.resolveShareType(
          'https://pan.baidu.com/s/1x#vbox_nd=1',
        ),
        CloudDriveType.baiduNode,
      );
      // 阿里不属于三张 Node 托管映射 → 保持原生。
      expect(
        VboxFragmentCodec.resolveShareType(
          'https://www.alipan.com/s/abc#vbox_nd=1',
        ),
        CloudDriveType.ali,
      );
    });
  });
}