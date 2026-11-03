/// 核心层：最小 XPath 子集引擎（B-11 站源原生搜索）。
///
/// 逆向来源：iOS `vbox/Services/ZhanyuanSearchService.swift` —— 其经 Kanna
/// （libxml2 XPath 1.0）使用的全部 XPath 形态已盘点，本引擎只实现该子集，
/// 不追求通用（超出子集的表达式返回空结果，与 Kanna 求值失败行为一致）：
///
/// - **轴**：`//`（后代）与 `/`（子）；文档级 `//x` 含根元素自身
///   （descendant-or-self）；`/x` 首步匹配文档根元素；
/// - **上下文相对**：`.//x`（后代，不含自身）、`./x`（子）；
/// - **节点测试**：元素名（大小写不敏感，HTML 解析器统一小写）或 `*`；
/// - **谓词**（可链写多个，AND 语义）：
///   `[@attr]`（存在）/ `[@attr='v']`（相等）/ `[contains(@attr, 'v')]`（子串）；
/// - **终端提取**（仅允许尾步，对齐 iOS `extractStrings` 的后缀剥离）：
///   `/text()` 与 `/@attr`；
/// - **text 语义**：Kanna `.text` = `xmlNodeGetContent`（**全后代文本拼接**），
///   package:html 的 `Element.text` 同为后代拼接 —— 直接复用，消除双份实现。
///
/// 求值语义对齐：节点按**文档序**返回、去重（XPath 节点集语义）。
library;

import 'package:html/dom.dart' as dom;

/// 谓词种类。
enum _PredKind { exists, equals, contains }

class _Pred {
  const _Pred(this.kind, this.attr, this.value);

  final _PredKind kind;

  /// 属性名（小写；HTML 解析器对属性名统一小写）。
  final String attr;

  /// 相等/子串比较值（保留原大小写）。
  final String? value;
}

class _Step {
  const _Step(this.descendant, this.name, this.preds);

  /// `//`（后代）为 true；`/`（子）为 false。
  final bool descendant;

  /// 元素名（小写）或 `*`。
  final String name;

  final List<_Pred> preds;
}

/// 尾步终端：`text()` / `@attr`。
enum _Terminal { none, text, attr }

class _Parsed {
  const _Parsed({
    required this.fromDocument,
    required this.steps,
    required this.terminal,
    this.terminalAttr,
  });

  /// 是否文档级绝对路径（`//x` / `/x` 前缀）。
  final bool fromDocument;

  final List<_Step> steps;
  final _Terminal terminal;
  final String? terminalAttr;
}

/// 最小 XPath 子集引擎（不可实例化）。
///
/// 消费方：B-11 站源原生搜索（`ZhanyuanSearchService`）；测试离线覆盖
/// 子集全部形态（轴/谓词/终端/去重/文档序）。
class XPathEngine {
  XPathEngine._();

  // ─────────────── 公开 API ───────────────

  /// 文档级元素查询（对齐 iOS `doc.xpath(...)`）。
  ///
  /// 不支持终端（`text()` / `@attr`）——终端提取走 [extractStrings]；
  /// 传入终端路径返回空（对齐 Kanna 求值失败）。
  static List<dom.Element> queryDocument(dom.Document doc, String xpath) {
    final _Parsed? p = _parse(xpath);
    if (p == null || p.terminal != _Terminal.none) return const <dom.Element>[];
    final dom.Element? root = doc.documentElement;
    if (root == null) return const <dom.Element>[];
    if (!p.fromDocument) {
      // `.//x` 等相对路径传入文档：等价从根元素出发（对齐 libxml2 相对求值）
      return _evalFrom(<dom.Element>[root], p.steps);
    }
    return _evalDocument(root, p.steps);
  }

  /// 元素上下文查询（对齐 iOS `el.xpath(".//...")`）。
  ///
  /// 传入文档级绝对路径（`//x`）时按 iOS `extractStringsFromElement` 惯例
  /// 降级为后代查找（等价 `.//x`）。
  static List<dom.Element> queryContext(dom.Element context, String xpath) {
    final _Parsed? p = _parse(xpath);
    if (p == null || p.terminal != _Terminal.none) return const <dom.Element>[];
    return _evalFrom(<dom.Element>[context], p.steps);
  }

  /// 文档级字符串提取（对齐 iOS `extractStrings`）。
  ///
  /// 规则：尾步 `text()` → 元素文本；尾步 `/@attr` → 属性值（不修剪）；
  /// 无终端 → 元素文本。文本经 trim 且**空串跳过**；属性空值跳过。
  static List<String> extractStrings(dom.Document doc, String xpath) {
    final _Parsed? p = _parse(xpath);
    if (p == null || p.steps.isEmpty) return const <String>[];
    final dom.Element? root = doc.documentElement;
    if (root == null) return const <String>[];
    final List<dom.Element> els = _evalDocument(root, p.steps);
    return _extract(els, p);
  }

  /// 元素上下文字符串提取（对齐 iOS `extractStringsFromElement`）。
  ///
  /// 归一规则（iOS 原文语义）：`//x` → `.//x`；裸名 `x` → `.//x`；
  /// `.//x` / `./x` 原样。
  static List<String> extractStringsFromElement(
    dom.Element context,
    String xpath,
  ) {
    String xp = xpath;
    if (xp.startsWith('//')) {
      xp = '.$xp';
    } else if (!xp.startsWith('.') && !xp.startsWith('/')) {
      xp = './/$xp';
    }
    final _Parsed? p = _parse(xp);
    if (p == null || p.steps.isEmpty) return const <String>[];
    final List<dom.Element> els = _evalFrom(<dom.Element>[context], p.steps);
    return _extract(els, p);
  }

  // ─────────────── 求值 ───────────────

  /// 按节点集语义求值：文档序、去重（嵌套上下文会重复触达同一后代）。
  static List<dom.Element> _evalFrom(
    List<dom.Element> start,
    List<_Step> steps,
  ) {
    List<dom.Element> current = start;
    for (final _Step step in steps) {
      final Set<dom.Element> next = <dom.Element>{};
      if (step.descendant) {
        for (final dom.Element el in current) {
          _collectDescendants(el, step, next);
        }
      } else {
        for (final dom.Element el in current) {
          for (final dom.Element child in el.children) {
            if (_matchStep(child, step)) next.add(child);
          }
        }
      }
      current = next.toList();
      if (current.isEmpty) break;
    }
    return current;
  }

  /// 文档级求值：`//x` 首步含根自身（descendant-or-self），`/x` 首步即根。
  static List<dom.Element> _evalDocument(
    dom.Element root,
    List<_Step> steps,
  ) {
    if (steps.isEmpty) return <dom.Element>[root];
    List<dom.Element> current = <dom.Element>[root];
    for (int i = 0; i < steps.length; i++) {
      final _Step step = steps[i];
      final Set<dom.Element> next = <dom.Element>{};
      if (step.descendant) {
        // self 分支：根元素自身先入（文档序在前），再走后代
        if (i == 0 && _matchStep(root, step)) next.add(root);
        for (final dom.Element el in current) {
          _collectDescendants(el, step, next);
        }
      } else {
        if (i == 0) {
          // `/x`：文档根元素本身
          if (_matchStep(root, step)) next.add(root);
        } else {
          for (final dom.Element el in current) {
            for (final dom.Element child in el.children) {
              if (_matchStep(child, step)) next.add(child);
            }
          }
        }
      }
      current = next.toList();
      if (current.isEmpty) break;
    }
    return current;
  }

  /// 先序 DFS 收集后代匹配（文档序）。
  static void _collectDescendants(
    dom.Element el,
    _Step step,
    Set<dom.Element> out,
  ) {
    for (final dom.Element child in el.children) {
      if (_matchStep(child, step)) out.add(child);
      _collectDescendants(child, step, out);
    }
  }

  static bool _matchStep(dom.Element el, _Step step) {
    if (step.name != '*') {
      final String tag = (el.localName ?? '').toLowerCase();
      if (tag != step.name) return false;
    }
    for (final _Pred pred in step.preds) {
      final String? value = el.attributes[pred.attr];
      switch (pred.kind) {
        case _PredKind.exists:
          if (value == null) return false;
          break;
        case _PredKind.equals:
          if (value != pred.value) return false;
          break;
        case _PredKind.contains:
          if (value == null || !value.contains(pred.value!)) return false;
          break;
      }
    }
    return true;
  }

  static List<String> _extract(List<dom.Element> els, _Parsed p) {
    final List<String> out = <String>[];
    for (final dom.Element el in els) {
      String? v;
      switch (p.terminal) {
        case _Terminal.none:
        case _Terminal.text:
          // Kanna `.text` = xmlNodeGetContent（全后代文本拼接），package:html 同
          v = el.text.trim();
          break;
        case _Terminal.attr:
          v = el.attributes[p.terminalAttr!];
          break;
      }
      if (v != null && v.isNotEmpty) out.add(v);
    }
    return out;
  }

  // ─────────────── 解析 ───────────────

  static _Parsed? _parse(String xpath) {
    final String s = xpath.trim();
    if (s.isEmpty) return null;

    bool fromDocument = false;
    bool firstDescendant = false;
    int i = 0;
    if (s.startsWith('//')) {
      fromDocument = true;
      firstDescendant = true;
      i = 2;
    } else if (s.startsWith('/')) {
      fromDocument = true;
      firstDescendant = false;
      i = 1;
    } else if (s.startsWith('.//')) {
      firstDescendant = true;
      i = 3;
    } else if (s.startsWith('./')) {
      firstDescendant = false;
      i = 2;
    } else if (s == '.') {
      return null; // 孤立 `.` 无意义（子集外）
    }

    final List<_Step> steps = <_Step>[];
    _Terminal terminal = _Terminal.none;
    String? terminalAttr;

    while (i < s.length) {
      bool descendant;
      if (steps.isEmpty && terminal == _Terminal.none) {
        // 首步：轴由前缀（`//`/`/`/`.//`/`./`）决定
        descendant = firstDescendant;
      } else if (s.startsWith('//', i)) {
        descendant = true;
        i += 2;
      } else if (s[i] == '/') {
        descendant = false;
        i += 1;
      } else {
        descendant = false; // 裸名连续（子轴）
      }

      final int nameStart = i;
      while (i < s.length && s[i] != '[' && s[i] != '/') {
        i++;
      }
      final String name = s.substring(nameStart, i).trim().toLowerCase();
      if (name.isEmpty) return null; // 连续分隔符 / 空步 → 非法

      final List<_Pred> preds = <_Pred>[];
      while (i < s.length && s[i] == '[') {
        final (String, int)? read = _readBracket(s, i);
        if (read == null) return null; // 括号不闭合
        final _Pred? pred = _parsePredicate(read.$1);
        if (pred == null) return null; // 谓词子集外 → 整体求值失败
        preds.add(pred);
        i = read.$2;
      }

      if (name == 'text()') {
        if (i < s.length) return null; // 终端只允许尾步
        terminal = _Terminal.text;
      } else if (name.startsWith('@')) {
        if (i < s.length || name.length < 2) return null;
        terminal = _Terminal.attr;
        terminalAttr = name.substring(1);
      } else {
        steps.add(_Step(descendant, name, preds));
      }
    }

    if (steps.isEmpty && terminal == _Terminal.none) return null;
    return _Parsed(
      fromDocument: fromDocument,
      steps: steps,
      terminal: terminal,
      terminalAttr: terminalAttr,
    );
  }

  /// 读取 `[...]` 内层（引号内 `]` 不闭合），返回 `(内层文本, 右括号后下标)`。
  static (String, int)? _readBracket(String s, int open) {
    int depth = 0;
    String quote = '';
    for (int j = open; j < s.length; j++) {
      final String c = s[j];
      if (quote.isNotEmpty) {
        if (c == quote) quote = '';
      } else if (c == "'" || c == '"') {
        quote = c;
      } else if (c == '[') {
        depth++;
      } else if (c == ']') {
        depth--;
        if (depth == 0) {
          return (s.substring(open + 1, j), j + 1);
        }
      }
    }
    return null;
  }

  static _Pred? _parsePredicate(String src) {
    final String t = src.trim();
    final RegExp reContains = RegExp(
      '^contains\\(\\s*@([\\w-]+)\\s*,\\s*([\'"])(.*?)\\2\\s*\\)\$',
      dotAll: true,
    );
    final RegExpMatch? mContains = reContains.firstMatch(t);
    if (mContains != null) {
      return _Pred(
        _PredKind.contains,
        mContains.group(1)!.toLowerCase(),
        mContains.group(3),
      );
    }
    final RegExp reEquals =
        RegExp('^@([\\w-]+)\\s*=\\s*([\'"])(.*?)\\2\$', dotAll: true);
    final RegExpMatch? mEquals = reEquals.firstMatch(t);
    if (mEquals != null) {
      return _Pred(
        _PredKind.equals,
        mEquals.group(1)!.toLowerCase(),
        mEquals.group(3),
      );
    }
    final RegExp reExists = RegExp(r'^@([\w-]+)$');
    final RegExpMatch? mExists = reExists.firstMatch(t);
    if (mExists != null) {
      return _Pred(_PredKind.exists, mExists.group(1)!.toLowerCase(), null);
    }
    return null;
  }
}
