// Phase 9c-1: _get の PixivHttpClient.get 委譲と境界例外変換の契約テスト。
//
// 確認すること（外向きの例外型が従来と同一であること）:
//   429 → RateLimitException が呼び出し元に届く
//   401 → AuthException が届き、トークンキャッシュが破棄される（B-6）
//   404 → 従来どおり生 Exception（NovelNotFoundException にはしない）
//   403 → 従来どおり生 Exception
//   200 → 従来どおり body 文字列が返る
//
// 手段: MockClient で共有クライアントを差し替える（実サーバー不使用・実待ちゼロ）。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_viewer/services/pixiv_api/pixiv_api_service.dart';
import 'package:pixiv_viewer/services/pixiv_api_http.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late PixivHttpClient httpClient;
  late PixivApiService apiService;
  late List<http.Request> apiCalls;
  late List<http.Request> tokenCalls;
  late int tokenCallSnapshot;

  setUpAll(() {
    // テスト環境用の FFI データベースファクトリを初期化する（他の DB 系
    // テストと同じ手法）。本テストは直接 _get を観測するので DB は使わないが、
    // テストプロセス全体のファクトリ設定として行っておく。
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'PIXIV_REFRESH_TOKEN': 'test-refresh-token-A',
    });
    httpClient = PixivHttpClient();
    httpClient.clearTokenCache();
    httpClient.setTestNow(null);
    apiService = PixivApiService();
  });

  tearDown(() {
    httpClient.setTestClient(null);
    httpClient.setTestNow(null);
    httpClient.clearTokenCache();
  });

  /// トークン取得は成功させ、API GET だけを指定ステータスで返すモック。
  /// URL でトークンエンドポイントと API エンドポイントを振り分ける
  /// （そうしないと 401/404/429 がトークンリフレッシュに誤ヒットする）。
  void setApiOnlyClient({required int statusCode, String body = ''}) {
    apiCalls = [];
    tokenCalls = [];
    httpClient.setTestClient(
      MockClient((request) async {
        if (request.url.host == 'oauth.secure.pixiv.net') {
          tokenCalls.add(request);
          return http.Response(
            jsonEncode({
              'response': {'access_token': 'access-1', 'expires_in': 3600},
            }),
            200,
          );
        }
        apiCalls.add(request);
        return http.Response(body, statusCode);
      }),
    );
  }

  /// 非同期 throw を検証する。
  Future<void> expectThrowsAsync<T extends Object>(
    Future<Object> Function() fn,
  ) async {
    try {
      await fn();
      fail('expected to throw but completed normally');
    } on T {
      // expected
    }
  }

  group('9c-1 _get の境界例外変換', () {
    test('200 なら body 文字列をそのまま返す', () async {
      setApiOnlyClient(statusCode: 200, body: '{"ok":true}');

      final body = await apiService.testGet('/v1/user/detail');
      expect(body, '{"ok":true}');
      expect(apiCalls.length, 1);
    });

    test('429 は RateLimitException に変換されて届く', () async {
      setApiOnlyClient(statusCode: 429);

      await expectThrowsAsync<RateLimitException>(
        () => apiService.testGet('/v1/user/detail'),
      );
    });

    test('401 は AuthException に変換され、トークンキャッシュを破棄する', () async {
      setApiOnlyClient(statusCode: 401);
      final token = await apiService.getAccessToken('test-refresh-token-A');
      expect(token, 'access-1');
      tokenCallSnapshot = tokenCalls.length;

      await expectThrowsAsync<AuthException>(
        () => apiService.testGet('/v1/user/detail'),
      );

      // B-6: 401 でキャッシュが破棄されているため、次の取得でトークンを
      // 再取得する（トークンエンドポイントへのリクエストが増える）。
      final token2 = await apiService.getAccessToken('test-refresh-token-A');
      expect(token2, 'access-1');
      expect(tokenCalls.length, greaterThan(tokenCallSnapshot));
    });

    test('404 は生 Exception のままで NovelNotFoundException にはしない', () async {
      setApiOnlyClient(statusCode: 404);

      // 従来 _get は 404 を生 Exception として投げていた。NovelNotFoundException は
      // getNovelById の data==null 判定で作る既存ロジックのまま据え置く。
      Object? caught;
      try {
        await apiService.testGet('/v1/user/detail');
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught, isNot(isA<NovelNotFoundException>()));
    });

    test('403 は生 Exception のまま', () async {
      setApiOnlyClient(statusCode: 403);

      Object? caught;
      try {
        await apiService.testGet('/v1/user/detail');
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught, isNot(isA<RateLimitException>()));
      expect(caught, isNot(isA<AuthException>()));
      expect(caught, isNot(isA<NovelNotFoundException>()));
    });
  });
}
