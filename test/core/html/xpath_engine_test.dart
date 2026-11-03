/// 核心层单测：最小 XPath 子集引擎（B-11 站源原生搜索）。
///
/// 覆盖子集全部形态（对照 iOS `ZhanyuanSearchService` 经 Kanna 用到的 XPath）：
/// 轴（`//`/`/`/`.//`/`./`）、谓词（存在/相等/contains/多步）、终端
/// （`text()`/`@attr`）、文档序去重、`&&&` 语法的归一由 service 层测试覆盖。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parse;
import 'package:vbox/core/html/xpath_engine.dart';

const String _html = '''
<html><body>
  <h1>标题</h1>
  <ul class="vodlist">
    <li><a href="/x/1" class="item">第一集<span>HD</span></a></li>
    <li><a href="/x/2" class="item">第二集</a></li>
  </ul>
  <div class="playlist"><a href="/p/1">预告片</a></div>
</body></html>
''';

dom.Document _doc() => parse(_html);

void main() {
  group('axis（轴）', () {
    test('//a 后代查找（文档序）', () {
      final List<dom.Element> els = XPathEngine.queryDocument(_doc(), '//a');
      expect(els.map((e) => e.attributes['href']),
          <String?>['/x/1', '/x/2', '/p/1']);
    });

    test('/html 子轴首步匹配根元素', () {
      final List<dom.Element> els = XPathEngine.queryDocument(_doc(), '/html');
      expect(els, hasLength(1));
      expect(els.single.localName, 'html');
    });

    test('相对 .//a（queryContext）', () {
      final dom.Document doc = _doc();
      final dom.Element ul =
          XPathEngine.queryDocument(doc, '//ul').single;
      final List<dom.Element> els = XPathEngine.queryContext(ul, './/a');
      expect(els.map((e) => e.attributes['href']), <String?>['/x/1', '/x/2']);
    });
  });

  group('predicate（谓词）', () {
    test('[@attr] 存在', () {
      final List<dom.Element> els =
          XPathEngine.queryDocument(_doc(), '//a[@class]');
      expect(els.map((e) => e.attributes['href']), <String?>['/x/1', '/x/2']);
    });

    test("[@attr='v'] 相等", () {
      final List<dom.Element> els =
          XPathEngine.queryDocument(_doc(), "//a[@href='/x/2']");
      expect(els, hasLength(1));
      expect(els.single.attributes['href'], '/x/2');
    });

    test("[contains(@attr, 'v')] 子串", () {
      final List<dom.Element> els =
          XPathEngine.queryDocument(_doc(), "//ul[contains(@class, 'vodlist')]//a");
      expect(els.map((e) => e.attributes['href']), <String?>['/x/1', '/x/2']);

      // contains 用于属性值
      final List<dom.Element> hrefs =
          XPathEngine.queryDocument(_doc(), "//a[contains(@href, '/x/1')]");
      expect(hrefs, hasLength(1));
    });

    test('多步 + 谓词（//ul/li/a）', () {
      final List<dom.Element> els =
          XPathEngine.queryDocument(_doc(), "//ul[contains(@class,'vodlist')]/li/a");
      expect(els, hasLength(2));
    });
  });

  group('terminal（终端）', () {
    test('/text() 提取元素文本（后代拼接）', () {
      // 与 Kanna `.text` = xmlNodeGetContent 一致：'第一集HD'
      final List<String> texts =
          XPathEngine.extractStrings(_doc(), '//a/text()');
      expect(texts, <String>['第一集HD', '第二集', '预告片']);
    });

    test('/@attr 提取属性值', () {
      final List<String> hrefs =
          XPathEngine.extractStrings(_doc(), '//a/@href');
      expect(hrefs, <String>['/x/1', '/x/2', '/p/1']);
    });

    test('无终端 → 元素文本', () {
      final List<String> names =
          XPathEngine.extractStrings(_doc(), '//h1');
      expect(names, <String>['标题']);
    });
  });

  group('extractStringsFromElement（容器内归一）', () {
    test("'//a/text()' → './/a' 容器内查询", () {
      final dom.Document doc = _doc();
      final dom.Element ul =
          XPathEngine.queryDocument(doc, '//ul').single;
      final List<String> texts =
          XPathEngine.extractStringsFromElement(ul, '//a/text()');
      expect(texts, <String>['第一集HD', '第二集']);
    });

    test("裸名 'a' → './/a'", () {
      final dom.Document doc = _doc();
      final dom.Element ul =
          XPathEngine.queryDocument(doc, '//ul').single;
      final List<String> hrefs =
          XPathEngine.extractStringsFromElement(ul, 'a/@href');
      expect(hrefs, <String>['/x/1', '/x/2']);
    });
  });

  group('边界', () {
    test('空 / 非法表达式返回空结果', () {
      expect(XPathEngine.queryDocument(_doc(), ''), isEmpty);
      expect(XPathEngine.queryDocument(_doc(), '///'), isEmpty);
      expect(XPathEngine.extractStrings(_doc(), ''), isEmpty);
      // 终端写在非尾步 → 求值失败（对齐 Kanna）
      expect(XPathEngine.queryDocument(_doc(), '//a/text()'), isEmpty);
    });

    test('文档序去重（同节点多路径不重复）', () {
      final List<dom.Element> els = XPathEngine.queryDocument(_doc(), '//li//a');
      expect(els.map((e) => e.attributes['href']), <String?>['/x/1', '/x/2']);
    });
  });
}