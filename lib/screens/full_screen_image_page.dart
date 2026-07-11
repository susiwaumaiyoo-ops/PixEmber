import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vector_math;

import '../illust_model.dart';
import '../widgets/pixiv_image.dart';

/// イラストの全画面表示＋ピンチズーム用ページ
class FullScreenImagePage extends StatefulWidget {
  final List<PageImage> images;
  final int initialIndex;

  const FullScreenImagePage({
    super.key,
    required this.images,
    this.initialIndex = 0,
  });

  @override
  State<FullScreenImagePage> createState() => _FullScreenImagePageState();
}

class _FullScreenImagePageState extends State<FullScreenImagePage> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: widget.images.length > 1
            ? Text('${_currentIndex + 1} / ${widget.images.length}')
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '閉じる',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.images.length,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        itemBuilder: (context, idx) {
          return _FullScreenZoomableImage(
            url: widget.images[idx].original ?? '',
          );
        },
      ),
    );
  }
}

/// 全画面用のズーム可能画像（InteractiveViewer によるピンチ/ドラッグ + ダブルタップ切替）
class _FullScreenZoomableImage extends StatefulWidget {
  final String url;

  const _FullScreenZoomableImage({required this.url});

  @override
  State<_FullScreenZoomableImage> createState() =>
      _FullScreenZoomableImageState();
}

class _FullScreenZoomableImageState extends State<_FullScreenZoomableImage> {
  final TransformationController _transformationController =
      TransformationController();
  TapDownDetails? _doubleTapDetails;

  String _getOriginalHighResUrl(String url) {
    if (url.isEmpty) return url;
    try {
      final uri = Uri.parse(url);
      if (uri.queryParameters.containsKey('width') ||
          uri.queryParameters.containsKey('quality')) {
        final params = Map<String, String>.from(uri.queryParameters);
        params.remove('width');
        params.remove('quality');
        return uri.replace(queryParameters: params).toString();
      }
    } catch (_) {}
    return url;
  }

  void _handleDoubleTap() {
    if (_transformationController.value != Matrix4.identity()) {
      _transformationController.value = Matrix4.identity();
    } else {
      final position = _doubleTapDetails?.localPosition ?? Offset.zero;
      _transformationController.value = Matrix4.identity()
        ..translateByVector3(
          vector_math.Vector3(-position.dx * 1.5, -position.dy * 1.5, 0),
        )
        ..scaleByVector3(vector_math.Vector3(2.5, 2.5, 1));
    }
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cleanedUrl = _getOriginalHighResUrl(widget.url);

    final imageWidget = PixivImage(
      url: cleanedUrl,
      fit: BoxFit.contain,
      isThumbnail: false,
      errorWidget: Container(
        color: Colors.grey[950],
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.broken_image, color: Colors.grey, size: 48),
              SizedBox(height: 8),
              Text('画像の読み込みに失敗しました。', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ),
    );

    return GestureDetector(
      onDoubleTapDown: (details) => _doubleTapDetails = details,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _transformationController,
        maxScale: 4.0,
        minScale: 1.0,
        child: Center(child: imageWidget),
      ),
    );
  }
}
