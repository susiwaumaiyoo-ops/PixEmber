// Phase 10: UX 衛生管理のリグレッションテスト。
//
// 10a (B-7): toggleBookmark が例外を投げるようになった（catch-all 削除）。
//   - 200/204 → true（例外なし）
//   - 429     → RateLimitException がそのまま上がる
//   - 401     → AuthException がそのまま上がる（キャッシュ破棄も発動）
//   - 404/403 → 生 Exception がそのまま上がる
// 10b: DateTimeFormat.formatDateOnly / tryParseLocal の契約。
// 10c: getNovelRanking が失敗時 hasError=true の FetchResult を返す。
//
// 手段: MockClient で共有 HTTP クライアントを差し替える（実サーバー不使用・実待ちゼロ）。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_viewer/services/pixiv_api/pixiv_api_service.dart';
import 'package:pixiv_viewer/services/pixiv_api_http.dart';
import 'package:pixiv_viewer/utils/datetime_format.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late PixivHttpClient httpClient;
  late PixivApiService apiService;

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

  /// トークン取得は成功させ、API POST だけを指定ステータスで返すモック。
  void setApiOnlyClient({required int statusCode, String body = ''}) {
    httpClient.setTestClient(
      MockClient((request) async {
        if (request.url.host == 'oauth.secure.pixiv.net') {
          return http.Response(
            jsonEncode({
              'response': {'access_token': 'access-1', 'expires_in': 3600},
            }),
            200,
          );
        }
        return http.Response(body, statusCode);
      }),
    );
  }

  group('Phase 10a (B-7): toggleBookmark が例外を投げる', () {
    test('200 → true（例外なし）', () async {
      setApiOnlyClient(statusCode: 200);
      expect(await apiService.toggleBookmark(1, false, true), isTrue);
    });

    test('429 → RateLimitException がそのまま上がる（握り潰されない）', () async {
      setApiOnlyClient(statusCode: 429);
      await expectLater(
        apiService.toggleBookmark(1, false, true),
        throwsA(isA<RateLimitException>()),
      );
    });

    test('401 → AuthException がそのまま上がる（握り潰されない）', () async {
      setApiOnlyClient(statusCode: 401);
      await expectLater(
        apiService.toggleBookmark(1, true, true),
        throwsA(isA<AuthException>()),
      );
    });

    test('404/403 → 生 Exception がそのまま上がる（型付きにならない）', () async {
      setApiOnlyClient(statusCode: 404);
      await expectLater(
        apiService.toggleBookmark(1, false, false),
        throwsA(isNot(anyOf(isA<RateLimitException>(), isA<AuthException>()))),
      );
    });
  });

  group('Phase 10b: DateTimeFormat の日付処理', () {
    test('formatDateOnly は "yyyy/MM/dd" を返す', () {
      expect(
        DateTimeFormat.formatDateOnly('2026-07-08T19:04:33+09:00'),
        equals('2026/07/08'),
      );
    });

    test('formatDateOnly は解析不能時に元の文字列を返す', () {
      expect(DateTimeFormat.formatDateOnly('not-a-date'), equals('not-a-date'));
    });

    test('formatDateOnly は null/空を空文字で返す', () {
      expect(DateTimeFormat.formatDateOnly(null), equals(''));
      expect(DateTimeFormat.formatDateOnly(''), equals(''));
    });

    test('tryParseLocal はローカル時刻の DateTime を返す', () {
      final dt = DateTimeFormat.tryParseLocal('2026-07-08T19:04:33+09:00');
      expect(dt, isNotNull);
      expect(dt!.year, equals(2026));
    });

    test('tryParseLocal は解析不能時に null を返す', () {
      expect(DateTimeFormat.tryParseLocal('not-a-date'), isNull);
      expect(DateTimeFormat.tryParseLocal(null), isNull);
    });

    test('formatReadable は従来フォーマット "yyyy/MM/dd HH:mm" を維持', () {
      expect(
        DateTimeFormat.formatReadable('2026-07-08T19:04:33+09:00'),
        matches(RegExp(r'^2026/07/08 \d{2}:\d{2}$')),
      );
    });
  });

  group('Phase 10c: FetchResult.hasError', () {
    test('デフォルトは hasError=false', () {
      const result = FetchResult<int>(items: [1, 2]);
      expect(result.hasError, isFalse);
    });

    test('hasError=true を明示的に生成できる', () {
      const result = FetchResult<int>(items: [], hasError: true);
      expect(result.hasError, isTrue);
    });

    test('getNovelRanking が無効 mode で hasError=true の空結果を返す', () async {
      // 存在しない mode は API が 400 系を返す → Service は空結果に hasError を立てる。
      setApiOnlyClient(statusCode: 404, body: '');
      final result = await apiService.getNovelRanking('invalid_mode');
      expect(result.items, isEmpty);
      expect(result.hasError, isTrue);
    });
  });
}
