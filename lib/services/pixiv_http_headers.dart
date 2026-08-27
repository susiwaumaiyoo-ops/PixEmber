/// UI 非依存の HTTP ヘッダー定数。
///
/// PixivImage ウィジェットと DownloadService の双方で共有し、
/// Pixiv アセット/CDN へのリクエスト時に同一のヘッダーを付与する。
/// Referer を付けないと Pixiv の画像サーバーから 403 が返る。
class PixivHttpHeaders {
  PixivHttpHeaders._();

  /// 画像/CDN アクセス用ヘッダー（PixivImage と同一の値）。
  static const Map<String, String> image = {
    'Referer': 'https://www.pixiv.net/',
    'User-Agent': 'PixivAndroidApp/6.71.1 (Android 11; Pixel 5)',
  };

  /// 画像 CDN/アセットへの単一リクエスト用ヘッダー（Referer 必須）。
  static Map<String, String> imageHeaders({String? authorization}) {
    final headers = <String, String>{
      'Referer': 'https://www.pixiv.net/',
      'User-Agent': 'PixivAndroidApp/6.71.1 (Android 11; Pixel 5)',
    };
    return headers;
  }
}
