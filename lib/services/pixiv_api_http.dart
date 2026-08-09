import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 429 Rate Limit エラー用のカスタム例外クラス
class PixivRateLimitException implements Exception {
  final String message;
  final int statusCode;

  PixivRateLimitException(this.message, {this.statusCode = 429});

  @override
  String toString() =>
      'PixivRateLimitException: $message (Status: $statusCode)';
}

/// Pixiv App-API への共通 HTTP クライアント。
/// トークン取得・共通ヘッダー・GET/POST を一元化する。
class PixivHttpClient {
  static final PixivHttpClient _instance = PixivHttpClient._internal();
  factory PixivHttpClient() => _instance;
  PixivHttpClient._internal();

  static const String baseUrl = 'https://app-api.pixiv.net';

  static const Map<String, String> clientHeaders = {
    'User-Agent': 'PixivAndroidApp/6.71.1 (Android 11; Pixel 5)',
    'App-OS': 'android',
    'App-OS-Version': '11',
    'App-Version': '6.71.1',
    'Accept-Language': 'ja-JP',
  };

  /// SharedPreferences からリフレッシュトークンを取得（未設定なら例外）
  Future<String> getRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('PIXIV_REFRESH_TOKEN');
    if (token == null || token.isEmpty) {
      throw Exception('Pixivリフレッシュトークンが設定されていません。再ログインが必要です。');
    }
    return token;
  }

  /// リフレッシュトークンからアクセストークンを取得
  Future<String> getAccessToken(String refreshToken) async {
    final now = DateTime.now().toUtc();
    final clientTime =
        "${now.year.toString().padLeft(4, '0')}-"
        "${now.month.toString().padLeft(2, '0')}-"
        "${now.day.toString().padLeft(2, '0')}T"
        "${now.hour.toString().padLeft(2, '0')}:"
        "${now.minute.toString().padLeft(2, '0')}:"
        "${now.second.toString().padLeft(2, '0')}+00:00";

    const salt = '2821213q311543184o13o121o131o1o3';
    final clientHash = md5.convert(utf8.encode(clientTime + salt)).toString();

    final response = await http.post(
      Uri.parse('https://oauth.secure.pixiv.net/auth/token'),
      headers: {
        'User-Agent': 'PixivAndroidApp/5.0.234 (Android 11.0; Pixel 5)',
        'App-OS': 'android',
        'App-OS-Version': '11.0',
        'App-Version': '5.0.234',
        'X-Client-Time': clientTime,
        'X-Client-Hash': clientHash,
        'Accept-Language': 'ja_JP',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'client_id': 'MOBrBDS8blbauoSck0ZfDbtuzpyT',
        'client_secret': 'lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj',
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        'トークンのリフレッシュに失敗しました: ${response.statusCode}\n${response.body}',
      );
    }

    final resData = jsonDecode(response.body) as Map<String, dynamic>;
    final payload = resData['response'] as Map<String, dynamic>?;
    final accessToken = payload?['access_token'] as String?;
    if (accessToken == null) {
      throw Exception('レスポンス内に access_token が見つかりませんでした。');
    }
    return accessToken;
  }

  /// 共通 GET（生のレスポンスボディ文字列を返す）
  Future<String> get(String endpoint, {Map<String, String>? params}) async {
    final token = await getAccessToken(await getRefreshToken());

    var uri = Uri.parse('$baseUrl$endpoint');
    if (params != null && params.isNotEmpty) {
      uri = uri.replace(queryParameters: params);
    }

    final response = await http.get(
      uri,
      headers: {...clientHeaders, 'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 200) {
      return response.body;
    } else if (response.statusCode == 429) {
      throw PixivRateLimitException(
        'Pixiv APIのレート制限（429）に達しました。しばらく時間を置いてから再試行してください。',
      );
    }
    throw Exception('Pixiv APIエラー: ${response.statusCode}\n${response.body}');
  }

  /// 共通 POST（JSON をデコードして返す）
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, String>? body,
  }) async {
    final token = await getAccessToken(await getRefreshToken());

    final response = await http.post(
      Uri.parse('$baseUrl$endpoint'),
      headers: {
        ...clientHeaders,
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: body,
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      if (response.body.isEmpty) return {};
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Exception('Pixiv APIエラー: ${response.statusCode}\n${response.body}');
  }
}
