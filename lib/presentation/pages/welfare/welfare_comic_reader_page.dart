/// 表现层：福利漫画 / 套图长卷阅读器（UI-C1 · 漫画阅读器）。
///
/// 唯一真相源：iOS
///   · `vbox/Views/ComicDetailBridgeView.swift` 的 `ComicDirectReaderView`
///     （L185-L273）：进入即加载详情 → 取首集 `images` → 呈现长卷阅读器；
///     无图 / 失败 → 明确错误态 + 重试；有效 Referer = `imageReferer` ?? `currentHost`；
///   · `vbox/Views/MangaReaderView.swift`（L21-L315）：沉浸式黑底长卷，
///     图片宽度自适应、点击切换工具栏、进度指示（第 X 张 / 共 Y 张 + 进度条）、
///     顶部/底部快速跳转、双击缩放、加载中 / 失败态保留高度避免塌缩；
///     长按图片弹「保存图片」菜单（contextMenu，L209-L213）→
///     `UIImageWriteToSavedPhotosAlbum` 写入相册（L311-L315）。
///
/// 移植口径与差异登记：
///   · 图片经 [PlatformAsyncImage.sourceCover] 加载，Referer + 桌面 UA +
///     `X-VBox-SSL-Bypass` 后缀与 iOS `MangaImageView.loadImage` 1:1；
///   · 页码跟随「首屏可见项」（Flutter `ListView.builder` 懒构建 ≈ iOS `LazyVStack`
///     `onAppear`），以子项 `initState` 回调对齐；
///   · 长按保存：长按图片弹「保存图片」菜单（对齐 iOS contextMenu）→
///     带 Referer/UA 头下载字节 → `saver_gallery` 写入相册（Android /
///     iOS，对齐 iOS `UIImageWriteToSavedPhotosAlbum`）；桌面端无相册
///     概念，不触发该入口（差异登记）。
library;

import 'dart:convert';
import 'dart:io' show HttpClient, HttpClientRequest, HttpClientResponse, Platform;
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:saver_gallery/saver_gallery.dart';

import '../../../domain/entities/welfare/fuli_models.dart';
import '../../../domain/services/fuli_base_service.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import '../../widgets/vbox/vbox.dart';

/// 福利漫画 / 套图长卷阅读器（分类页点击漫画卡片后进入）。
class WelfareComicReaderPage extends StatefulWidget {
  /// 构造。
  const WelfareComicReaderPage({
    super.key,
    required this.service,
    required this.video,
  });

  /// 驱动详情 / 图片列表的福利平台服务。
  final FuliBaseService service;

  /// 被点击的漫画条目（`vodId` 用于加载详情）。
  final FuliVideo video;

  @override
  State<WelfareComicReaderPage> createState() => _WelfareComicReaderPageState();
}

class _WelfareComicReaderPageState extends State<WelfareComicReaderPage> {
  final ScrollController _scroll = ScrollController();

  List<String> _images = <String>[];
  String _title = '';
  String? _errorMsg;
  bool _showBars = true;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 有效 Referer（对齐 iOS `ComicDirectReaderView.effectiveReferer`）：
  /// 平台配置的 `imageReferer` 优先，为空时回退当前域名（避免默认 Referer 触发 403）。
  String? get _effectiveReferer {
    final String? referer = widget.service.imageReferer;
    if (referer != null && referer.isNotEmpty) return referer;
    final String host = widget.service.currentHost;
    return host.isEmpty ? null : host;
  }

  /// 加载详情并提取首集图片列表（对齐 iOS `loadImages`）。
  Future<void> _load() async {
    setState(() {
      _errorMsg = null;
      _images = <String>[];
      _currentIndex = 0;
    });

    final FuliDetail detail = await widget.service.fetchDetail(widget.video.vodId);
    if (!mounted) return;

    final List<String>? images =
        detail.episodes.isNotEmpty ? detail.episodes.first.images : null;
    setState(() {
      if (images != null && images.isNotEmpty) {
        _title = detail.vodName.isEmpty ? widget.video.vodName : detail.vodName;
        _images = images;
      } else {
        _errorMsg = '未解析到套图图片';
      }
    });
  }

  void _toggleBars() => setState(() => _showBars = !_showBars);

  // ─────────────── 长按保存图片（对齐 iOS `MangaReaderView.saveImage`） ───────────────

  /// 是否支持写入相册（对齐 iOS：保存语义只存在于移动端）。
  bool get _canSaveToAlbum => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// 长按图片弹「保存图片」菜单（对齐 iOS contextMenu L209-L213）。
  Future<void> _showSaveMenu(String url) async {
    if (!_canSaveToAlbum) return;
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('保存图片'),
              onTap: () => Navigator.of(context).pop('save'),
            ),
          ],
        ),
      ),
    );
    if (action != 'save' || !mounted) return;
    await _saveImage(url);
  }

  /// 下载图片字节（带 Referer / 桌面 UA 头，对齐 iOS `MangaImageView.loadImage`
  /// 的请求头口径；URL 可携带 `@key=value` 显式头后缀，优先级低于显式拼装值）。
  Future<Uint8List?> _downloadImage(String url) async {
    final ParsedImageUrl parsed = PlatformAsyncImage.parseHeaderSuffix(url);
    // `data:` 内嵌图（对齐 iOS `loadDataImage`）。
    if (parsed.url.startsWith('data:')) {
      final int comma = parsed.url.indexOf(',');
      if (comma < 0) return null;
      try {
        return base64Decode(parsed.url.substring(comma + 1));
      } on FormatException {
        return null;
      }
    }
    final String? referer = _effectiveReferer;
    final Map<String, String> headers = <String, String>{
      if (referer != null && referer.isNotEmpty) ...<String, String>{
        'User-Agent': kPlatformImageDefaultUA,
        'Referer': referer.endsWith('/') ? referer : '$referer/',
      },
      ...parsed.headers,
    };
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(
        Uri.parse(parsed.url),
      );
      // `headers.set`（覆盖）而非 `add`，避免双值 UA（对齐 PlatformAsyncImage）。
      for (final MapEntry<String, String> entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      final HttpClientResponse response = await request.close();
      if (response.statusCode != 200) return null;
      final BytesBuilder builder = BytesBuilder(copy: false);
      await for (final List<int> chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } on Exception {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 保存到相册（对齐 iOS `UIImageWriteToSavedPhotosAlbum`；Android 落
  /// `Pictures/VBox` 相册目录）。
  Future<void> _saveImage(String url) async {
    VboxToast.show(context, '正在保存图片...');
    final Uint8List? bytes = await _downloadImage(url);
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      VboxToast.show(context, '图片下载失败');
      return;
    }
    try {
      final SaveResult result = await SaverGallery.saveImage(
        bytes,
        fileName: 'vbox_manga_${DateTime.now().millisecondsSinceEpoch}.jpg',
        // saver_gallery 5.x：albumPath 相对相册层级；image/* 自动前缀
        // `Pictures/`（Android relativePath = Pictures/VBox，对齐 iOS 相册「VBox」）。
        albumPath: 'VBox',
        skipIfExists: false,
      );
      if (!mounted) return;
      VboxToast.show(
        context,
        result.isSuccess ? '已保存到相册' : '保存失败：${result.errorMessage ?? '未知错误'}',
      );
    } on Exception catch (e) {
      if (!mounted) return;
      VboxToast.show(context, '保存失败：$e');
    }
  }

  /// 子项构建（≈ 首屏可见）→ 更新页码（对齐 iOS `MangaImageView.onAppear`）。
  void _onItemBuilt(int index) {
    if (_currentIndex == index) return;
    WidgetsBinding.instance.addPostFrameCallback((void _) {
      if (mounted && _currentIndex != index) {
        setState(() => _currentIndex = index);
      }
    });
  }

  void _scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_images.isNotEmpty) return _reader(context);
    if (_errorMsg != null) return _errorState(context);
    return _loadingState(context);
  }

  // ─────────────── 长卷阅读器（对齐 iOS `MangaReaderView`）───────────────

  Widget _reader(BuildContext context) {
    return Stack(
      children: <Widget>[
        GestureDetector(
          onTap: _toggleBars,
          child: ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.zero,
            itemCount: _images.length,
            itemBuilder: (BuildContext context, int index) => _MangaImage(
              key: ValueKey<String>('manga-$index-${_images[index]}'),
              url: _images[index],
              referer: _effectiveReferer,
              sslBypass: widget.service.imageSSLBypass,
              onBuilt: () => _onItemBuilt(index),
              // 长按弹「保存图片」菜单（对齐 iOS contextMenu；桌面端不触发）。
              onLongPress:
                  _canSaveToAlbum ? () => _showSaveMenu(_images[index]) : null,
            ),
          ),
        ),
        // 工具栏（点击切换显示 / 隐藏）。
        IgnorePointer(
          ignoring: !_showBars,
          child: AnimatedOpacity(
            opacity: _showBars ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: Column(
              children: <Widget>[
                _topBar(context),
                const Spacer(),
                _bottomBar(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _topBar(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Colors.black87, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VboxSpacing.sm,
            vertical: VboxSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.chevron_left, color: Colors.white),
                tooltip: '返回',
              ),
              Expanded(
                child: Text(
                  _title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: VboxTypography.s15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    final Color accent = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Colors.transparent, Colors.black87],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VboxSpacing.lg,
            vertical: VboxSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              LinearProgressIndicator(
                value: _images.isEmpty
                    ? 0
                    : (_currentIndex + 1) / _images.length,
                minHeight: 3,
                color: accent,
                backgroundColor: Colors.white24,
              ),
              const SizedBox(height: VboxSpacing.sm),
              Row(
                children: <Widget>[
                  Text(
                    '第 ${_currentIndex + 1} 张 / 共 ${_images.length} 张',
                    style: const TextStyle(
                      fontSize: VboxTypography.s13,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _scrollToTop,
                    icon: const Icon(Icons.vertical_align_top, color: Colors.white),
                    tooltip: '回到顶部',
                  ),
                  IconButton(
                    onPressed: _scrollToBottom,
                    icon: const Icon(Icons.vertical_align_bottom, color: Colors.white),
                    tooltip: '回到底部',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────── 加载 / 失败态 ───────────────

  Widget _loadingState(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          ),
          SizedBox(height: VboxSpacing.md),
          Text(
            '加载中...',
            style: TextStyle(fontSize: VboxTypography.s13, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _errorState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.photo_outlined,
              size: 48,
              color: Colors.white54,
            ),
            const SizedBox(height: VboxSpacing.md),
            Text(
              _errorMsg ?? '加载失败',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: VboxTypography.s14,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: VboxSpacing.md),
            FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
            const SizedBox(height: VboxSpacing.lg),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('返回', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单张漫画图片（对齐 iOS `MangaImageView`：宽度撑满 + 双击缩放 +
/// 长按菜单入口 + 加载中 / 失败态保留最小高度避免塌缩）。
class _MangaImage extends StatefulWidget {
  const _MangaImage({
    super.key,
    required this.url,
    required this.referer,
    required this.sslBypass,
    required this.onBuilt,
    this.onLongPress,
  });

  final String url;
  final String? referer;
  final bool sslBypass;
  final VoidCallback onBuilt;

  /// 长按回调（保存图片菜单；null = 不启用）。
  final VoidCallback? onLongPress;

  @override
  State<_MangaImage> createState() => _MangaImageState();
}

class _MangaImageState extends State<_MangaImage> {
  double _scale = 1.0;

  @override
  void initState() {
    super.initState();
    widget.onBuilt();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: () => setState(() => _scale = _scale > 1 ? 1.0 : 2.0),
      onLongPress: widget.onLongPress,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 200),
        child: Transform.scale(
          scale: _scale,
          child: PlatformAsyncImage.sourceCover(
            widget.url,
            referer: widget.referer,
            sslBypass: widget.sslBypass,
            fit: BoxFit.fitWidth,
          ),
        ),
      ),
    );
  }
}