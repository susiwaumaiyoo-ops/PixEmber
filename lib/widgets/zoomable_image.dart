import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vector_math;

import '../widgets/pixiv_image.dart';

class ZoomableImage extends StatefulWidget {
  final String url;
  final bool isLargeScreen;
  final double maxHeight;
  final ValueChanged<bool>? onZoomChanged;

  const ZoomableImage({
    super.key,
    required this.url,
    required this.isLargeScreen,
    required this.maxHeight,
    this.onZoomChanged,
  });

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> {
  final TransformationController _transformationController =
      TransformationController();
  TapDownDetails? _doubleTapDetails;

  // 確実にオリジナル高画質画像（クエリパラメータ width/quality なし）を要求するようにクリーニングする
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
      widget.onZoomChanged?.call(false);
    } else {
      final position = _doubleTapDetails?.localPosition ?? Offset.zero;
      _transformationController.value = Matrix4.identity()
        ..translateByVector3(vector_math.Vector3(-position.dx * 1.5, -position.dy * 1.5, 0))
        ..scaleByVector3(vector_math.Vector3(2.5, 2.5, 1));
      widget.onZoomChanged?.call(true);
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

    Widget imageWidget = PixivImage(
      url: cleanedUrl,
      fit: BoxFit.contain,
      isThumbnail: false,
      errorWidget: Container(
        height: 300,
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

    if (widget.isLargeScreen) {
      imageWidget = Container(
        constraints: BoxConstraints(maxWidth: 500, maxHeight: widget.maxHeight),
        alignment: Alignment.center,
        child: imageWidget,
      );
    }

    return GestureDetector(
      onDoubleTapDown: (details) => _doubleTapDetails = details,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _transformationController,
        maxScale: 4.0,
        minScale: 1.0,
        onInteractionStart: (details) {
          if (details.pointerCount >= 2) {
            widget.onZoomChanged?.call(true);
          }
        },
        onInteractionEnd: (details) {
          // スケールが1.0に戻っていればズーム終了とする
          final double scale = _transformationController.value.getMaxScaleOnAxis();
          if (scale <= 1.05) {
            widget.onZoomChanged?.call(false);
          }
        },
        child: widget.isLargeScreen ? Center(child: imageWidget) : imageWidget,
      ),
    );
  }
}
