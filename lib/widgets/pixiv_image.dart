import 'dart:io';
import 'package:flutter/material.dart';
import '../services/pixiv_http_headers.dart';

class PixivImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final bool
  isThumbnail; // サムネイル一覧表示用かどうか。true の場合は cacheWidth: 300 を指定してインメモリ圧縮
  final Widget? errorWidget;
  final Widget? placeholder;
  final int? cacheWidth;
  final int? cacheHeight;

  /// ローカルに保存済みのファイルパス（null = ネットワークから取得）。
  /// 指定されている場合はローカルファイルを優先表示する。
  /// ローカルファイルが破損している場合はネットワークにフォールバックする。
  final File? localFile;

  const PixivImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.isThumbnail = false,
    this.errorWidget,
    this.placeholder,
    this.cacheWidth,
    this.cacheHeight,
    this.localFile,
  });

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty && localFile == null) {
      return _buildErrorWidget();
    }

    // リファラなどのセキュリティヘッダーを付与してPixivのアセットサーバーからの直リンク403エラーを回避
    // DownloadService と同一の定数を共有する（pixiv_http_headers.dart）
    final Map<String, String> headers = PixivHttpHeaders.image;

    Widget buildImage(double? w, double? h) {
      // ローカルファイル優先表示
      if (localFile != null && _localFileExists(localFile!)) {
        return Image.file(
          localFile!,
          fit: fit,
          width: w,
          height: h,
          cacheWidth: cacheWidth ?? (isThumbnail ? 300 : 1200),
          cacheHeight: cacheHeight,
          errorBuilder: (context, error, stackTrace) {
            // ローカルファイルが破損している場合はネットワークにフォールバック
            return _buildNetworkImage(headers, w, h);
          },
        );
      }
      return _buildNetworkImage(headers, w, h);
    }

    // width/height が明示指定されていない場合、親の制約（固定枠）を取得して
    // Image に伝える。これにより BoxFit.cover が親枠いっぱいに効き、
    // 画像が引き伸ばされてアスペクト比が崩る（圧縮表示）のを防ぐ。
    if (width != null || height != null) {
      return buildImage(width, height);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final double? w = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : null;
        final double? h = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : null;
        return buildImage(w, h);
      },
    );
  }

  /// ローカルファイルが実在するか確認（同期）。
  bool _localFileExists(File file) {
    try {
      return file.existsSync();
    } catch (_) {
      return false;
    }
  }

  /// ネットワーク画像を構築する（ローカル破損時のフォールバック含む）。
  Widget _buildNetworkImage(Map<String, String> headers, double? w, double? h) {
    return Image.network(
      url,
      headers: headers,
      fit: fit,
      width: w,
      height: h,
      cacheWidth: cacheWidth ?? (isThumbnail ? 300 : 1200),
      cacheHeight: cacheHeight,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) {
          return child;
        }
        return placeholder ??
            Container(
              width: w,
              height: h,
              color: Colors.grey.withValues(alpha: 0.1),
              alignment: Alignment.center,
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.0,
                  value: loadingProgress.expectedTotalBytes != null
                      ? loadingProgress.cumulativeBytesLoaded /
                            loadingProgress.expectedTotalBytes!
                      : null,
                  color: Colors.pinkAccent,
                ),
              ),
            );
      },
      errorBuilder: (context, error, stackTrace) {
        return _buildErrorWidget();
      },
    );
  }

  Widget _buildErrorWidget() {
    return errorWidget ??
        Container(
          width: width,
          height: height,
          color: Colors.grey.withValues(alpha: 0.1),
          alignment: Alignment.center,
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.broken_image_outlined, color: Colors.grey, size: 32),
              SizedBox(height: 4),
              Text('読込失敗', style: TextStyle(color: Colors.grey, fontSize: 10)),
            ],
          ),
        );
  }
}
