/// 设计令牌 · 圆角（批次 A · A-02）。
///
/// 唯一真相源：`docs/UI对齐基准_v1.0.md` §2.4。
///
/// 实测档位集合：`{ 4, 6, 8, 10, 12, 14, 16, 20 }`，一律使用 `.continuous`
/// （连续曲率）风格。Flutter 无内建连续曲率，本层固化**档位值**并以
/// [BorderRadius.circular] 近似；逐像素曲率差异不计入「不达标」（UI 守卫 R-2）。
library;

import 'package:flutter/widgets.dart';

/// 圆角令牌。
class VboxRadii {
  const VboxRadii._();

  /// 4 · 小标签 / 角标。
  static const double r4 = 4;

  /// 6 · 按钮、列表项内小块。
  static const double r6 = 6;

  /// 8 · 按钮、列表项内小块。
  static const double r8 = 8;

  /// 10 · 分组卡片、sheet。
  static const double r10 = 10;

  /// 12 · 分组卡片、sheet。
  static const double r12 = 12;

  /// 14 · 筛选 chip、中号卡。
  static const double r14 = 14;

  /// 16 · 筛选 chip、中号卡。
  static const double r16 = 16;

  /// 20 · 大卡片 / 面板（主角）。
  static const double r20 = 20;

  /// 40 · 胶囊全圆角近似（对齐 iOS `Capsule()`；非档位采样值，专属）。
  ///
  /// 语义等同「圆角 = 高度一半」的胶囊；不进 [scale]（守卫 R-2 档位
  /// 仅约束常规圆角，胶囊属形状语义而非档位采样）。
  static const double capsule = 40;

  /// 1.5 · 细进度条圆角（对齐 iOS 香蕉秀短视频 3pt 进度条，专属）。
  ///
  /// 语义等同「圆角 = 条高一半」；非档位采样值，不进 [scale]（同 [capsule]）。
  static const double progressBar = 1.5;

  /// 全部圆角档位（升序；供守卫 R-2 白名单与单测断言）。
  static const List<double> scale = <double>[r4, r6, r8, r10, r12, r14, r16, r20];

  /// 小标签 / 角标。
  static const BorderRadius badge = BorderRadius.all(Radius.circular(r4));

  /// 按钮 / 列表项内小块。
  static const BorderRadius button = BorderRadius.all(Radius.circular(r8));

  /// 分组卡片 / sheet。
  static const BorderRadius card = BorderRadius.all(Radius.circular(r12));

  /// 筛选 chip / 中号卡。
  static const BorderRadius chip = BorderRadius.all(Radius.circular(r16));

  /// 大卡片 / 面板。
  static const BorderRadius panel = BorderRadius.all(Radius.circular(r20));
}