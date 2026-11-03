/// 表现层：首页站点内容轮播（UI-E4 接入生命周期）。
///
/// 对齐 iOS `BannerCarousel`（[DoubanHomeView.swift](../../../../vbox/Views/DoubanHomeView.swift#L195)）：
///  - `onAppear` 启动自动播放（4s 间隔循环翻页，到尾部回 0）；
///  - `onDisappear` / 失活 / 退后台停止自动播放；
///  - 手动拖动时停播、松手后续播（对齐 iOS `DragGesture` onChanged/onEnded）；
///  - 数据源变化后保持当前页合法（页数收缩时回退到最后一页）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/entities/spider/spider.dart';
import '../../lifecycle/vbox_lifecycle_mixin.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';

/// 首页轮播。
class HomeBannerCarousel extends StatefulWidget {
  /// 构造。
  const HomeBannerCarousel({super.key, required this.items});

  /// 最大轮播数（对齐 iOS `min(8, items.count)` 的展示上限口径）。
  static const int maxCount = 5;

  final List<VodItem> items;

  @override
  State<HomeBannerCarousel> createState() => _HomeBannerCarouselState();
}

class _HomeBannerCarouselState extends State<HomeBannerCarousel>
    with VboxLifecycleMixin {
  /// 自动播放间隔（对齐 iOS `startAutoPlay` 的 4s）。
  static const Duration _autoPlayInterval = Duration(seconds: 4);

  /// 翻页动画时长（对齐 iOS `withAnimation(.easeOut(duration: 0.35))`）。
  static const Duration _pageAnimDuration = Duration(milliseconds: 350);

  int _page = 0;
  Timer? _autoPlayTimer;
  bool _userInteracting = false;
  late final PageController _pageController;

  bool get _autoPlayable => widget.items.length > 1;

  /// 启动自动播放（对齐 iOS `startAutoPlay`：先停旧 Timer 再建）。
  void _startAutoPlay() {
    _stopAutoPlay();
    if (!_autoPlayable) return;
    _autoPlayTimer = Timer.periodic(_autoPlayInterval, (Timer _) {
      if (!mounted || _userInteracting) return;
      // 循环翻页（对齐 iOS 到尾部回 0）。
      final int next = (_page + 1) % widget.items.length;
      _pageController.animateToPage(
        next,
        duration: _pageAnimDuration,
        curve: Curves.easeOut,
      );
    });
  }

  /// 停止自动播放（对齐 iOS `stopAutoPlay`）。
  void _stopAutoPlay() {
    _autoPlayTimer?.cancel();
    _autoPlayTimer = null;
  }

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    // 对齐 iOS `onAppear`：出现即启动自动播放。
    _startAutoPlay();
  }

  @override
  void didUpdateWidget(covariant HomeBannerCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 数据源变化后保持当前页合法；不可轮播则停。
    if (!_autoPlayable) {
      _stopAutoPlay();
      if (_page != 0) {
        setState(() => _page = 0);
      }
    } else if (_page >= widget.items.length) {
      setState(() => _page = widget.items.length - 1);
    }
  }

  @override
  void dispose() {
    _stopAutoPlay();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void onAppResumed() {
    // 回前台恢复轮播（对齐 iOS onAppear startAutoPlay）。
    if (!_userInteracting) _startAutoPlay();
  }

  @override
  void onAppInactive() {
    // 失活暂停轮播（对齐 iOS onDisappear stopAutoPlay / willResignActive）。
    _stopAutoPlay();
  }

  @override
  void onAppPaused() => _stopAutoPlay();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      children: <Widget>[
        SizedBox(
          height: 200,
          // 手动拖动时停播、松手续播（对齐 iOS DragGesture onChanged/onEnded）。
          child: NotificationListener<ScrollNotification>(
            onNotification: (ScrollNotification n) {
              if (n is ScrollStartNotification && n.dragDetails != null) {
                _userInteracting = true;
                _stopAutoPlay();
              } else if (n is ScrollEndNotification && _userInteracting) {
                _userInteracting = false;
                _startAutoPlay();
              }
              return false;
            },
            child: PageView.builder(
              controller: _pageController,
              itemCount: widget.items.length,
              onPageChanged: (int i) => setState(() => _page = i),
              itemBuilder: (BuildContext context, int i) {
                final VodItem vod = widget.items[i];
                return Padding(
                  padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        _CarouselImage(url: vod.vodPic),
                        Align(
                          alignment: Alignment.bottomLeft,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(VboxSpacing.md),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: <Color>[
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.72),
                                ],
                              ),
                            ),
                            child: Text(
                              vod.vodName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: VboxTypography.s16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: VboxSpacing.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            for (int i = 0; i < widget.items.length; i++)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == _page ? scheme.primary : scheme.outlineVariant,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 轮播封面（空地址 → 占位盒）。
class _CarouselImage extends StatelessWidget {
  const _CarouselImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return PlatformAsyncImage(url: url, fit: BoxFit.cover);
  }
}
