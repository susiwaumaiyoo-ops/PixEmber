// Phase 9b-1: logout() の後始末（バグ B-1 / B-3）。
//
// 確認すること:
//   B-1: ログアウトで SharedPreferences の PIXIV_REFRESH_TOKEN が削除される。
//   B-3: ログアウトで PixivHttpClient のアクセストークンキャッシュが破棄される。
//   副作用: 削除後は getRefreshToken() が失敗する（再ログインが必要な状態）。
//
// テスト方法の工夫: PixivViewerHomeState は直接インスタンス化可能なため
// WidgetTester 不要（home_encyclopedia_card_test.dart と同じ手法）。
// setState は mounted チェックで保護し、本番動作は変えない。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_viewer/screens/home_screen_state.dart';
import 'package:pixiv_viewer/services/pixiv_api_http.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late PixivHttpClient httpClient;
  late List<http.Request> tokenCalls;

  /// OAuth トークンエンドポイントのモックレスポンスを構築する。
  String tokenResponseBody({required String accessToken, int expiresIn = 3600}) {
    return jsonEncode({
      'response': {
        'access_token': accessToken,
        'expires_in': expiresIn,
      },
    });
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'PIXIV_REFRESH_TOKEN': 'refresh-A',
    });
    tokenCalls = [];
    httpClient = PixivHttpClient();
    httpClient.clearTokenCache();
    httpClient.setTestNow(null);
  });

  tearDown(() {
    httpClient.setTestClient(null);
    httpClient.setTestNow(null);
    httpClient.clearTokenCache();
  });

  group('9b-1 logout の後始末', () {
    test('B-1: 保存済みリフレッシュトークンを削除する', () async {
      // 即値でトークンが保存されている状態。
      expect(
        (await SharedPreferences.getInstance()).getString('PIXIV_REFRESH_TOKEN'),
        'refresh-A',
      );

      final state = PixivViewerHomeState();
      state.logout();
      // ファイア＆フォーゲットの prefs 処理完了を待つ。
      await Future<void>.delayed(Duration.zero);

      expect(
        (await SharedPreferences.getInstance()).getString('PIXIV_REFRESH_TOKEN'),
        isNull,
      );
    });

    test('B-1: 削除後は getRefreshToken が失敗する（再ログインが必要な状態）',
        () async {
      final state = PixivViewerHomeState();
      state.logout();
      await Future<void>.delayed(Duration.zero);

      // prefs に空文字ではなくキー自体が無いことを remove で検証する。
      expect(
        (await SharedPreferences.getInstance()).containsKey('PIXIV_REFRESH_TOKEN'),
        isFalse,
      );

      try {
        await httpClient.getRefreshToken();
        fail('expected to throw but completed normally');
      } on Exception {
        // expected: トークン未設定の例外。
      }
    });

    test('B-3: アクセストークンキャッシュを破棄する', () async {
      // 1) トークンを取得してキャッシュに access-1 を保持させる。
      httpClient.setTestClient(
        MockClient((request) async {
          tokenCalls.add(request);
          return http.Response(
            tokenResponseBody(accessToken: 'access-1', expiresIn: 3600),
            200,
          );
        }),
      );
      expect(await httpClient.getAccessToken('refresh-A'), 'access-1');
      expect(tokenCalls.length, 1);

      // 2) logout でキャッシュが破棄される。
      final state = PixivViewerHomeState();
      state.logout();
      await Future<void>.delayed(Duration.zero);

      // 3) 同一トークンで再要求するとキャッシュではなく再取得される。
      expect(await httpClient.getAccessToken('refresh-A'), 'access-1');
      expect(tokenCalls.length, 2);
    });
  });
}
