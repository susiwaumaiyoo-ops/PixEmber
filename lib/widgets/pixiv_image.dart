import 'package:flutter/material.dart';

class PixivImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final bool
  isThumbnail; // サムネイル一覧表示用かどうか。true の場合は cacheWidth: 300 を指定してインメモリ圧縮
  final Widget? errorWidget;
  final Widget? placeholder;

  const PixivImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.isThumbnail = false,
    this.errorWidget,
    this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return _buildErrorWidget();
    }

    // リファラなどのセキュリティヘッダーを付与してPixivのアセットサーバーからの直リンク403エラーを回避
    final Map<String, String> headers = {
      'Referer': 'https://app-api.pixiv.net/',
      'User-Agent': 'PixivAndroidApp/6.71.1 (Android 11; Pixel 5)',
    };

    return Image.network(
      url,
      headers: headers,
      fit: fit,
      width: width,
      height: height,
      // cacheWidth を指定するとデコード後のビットマップメモリを縮小でき、メモリ発熱・スクロール時のカクつきを完全に防止できます
      // サムネイルは 300、オリジナル高画質でも 1200 に制限して巨大画像のメモリバースト（発熱・クラッシュ）を防ぐ
      cacheWidth: isThumbnail ? 300 : 1200,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) {
          return child;
        }
        return placeholder ??
            Container(
              width: width,
              height: height,
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
