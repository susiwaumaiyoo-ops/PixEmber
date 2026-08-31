// Google Drive サインイン失敗の診断ロジック（describeSignInError）のユニットテスト。
//
// 対象:
// - null（対話式 signIn のキャンセル）
// - PlatformException の code（sign_in_canceled / network_error /
//   auth_recoverable / failed_to_recover_auth / sign_in_failed）
// - GMS 数値コード（ApiException: N）: 8/12/10/6/7/10009
// - 未知エラーのフォールバック（code 付きサマリー）
// - summarizeSignInErrorForLog の切り詰め
//
// 実機で確認された
// PlatformException(sign_in_failed, com.google.android.gms.common.api.ApiException: 8: , null, null)
// への分類を含む。
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_viewer/services/google_drive_service.dart';

void main() {
  group('describeSignInError', () {
    test('null（対話式サインインのキャンセル）はキャンセル表示', () {
      expect(describeSignInError(null), 'ログインがキャンセルされました。');
    });

    test('sign_in_canceled はキャンセル表示', () {
      final e = PlatformException(code: 'sign_in_canceled');
      expect(describeSignInError(e), 'ログインがキャンセルされました。');
    });

    test('network_error はネットワークエラー表示', () {
      final e = PlatformException(code: 'network_error', message: 'boom');
      expect(describeSignInError(e), contains('ネットワークエラー'));
    });

    test('auth_recoverable / failed_to_recover_auth は回復可能エラー表示', () {
      expect(
        describeSignInError(PlatformException(code: 'auth_recoverable')),
        contains('再試行'),
      );
      expect(
        describeSignInError(PlatformException(code: 'failed_to_recover_auth')),
        contains('再試行'),
      );
    });

    test('sign_in_failed / ApiException: 8 は Play services 内部エラー表示', () {
      // 実機で確認されたエラー形状。
      final e = PlatformException(
        code: 'sign_in_failed',
        message: 'com.google.android.gms.common.api.ApiException: 8: ',
      );
      expect(describeSignInError(e), contains('内部エラー'));
      expect(describeSignInError(e), contains('再試行'));
    });

    test('ApiException: 12 (DEVELOPER_ERROR) は OAuth 設定不整合表示', () {
      final e = PlatformException(
        code: 'sign_in_failed',
        message: 'com.google.android.gms.common.api.ApiException: 12: ',
      );
      expect(describeSignInError(e), contains('OAuth 設定'));
      expect(describeSignInError(e), contains('SHA-1'));
    });

    test('ApiException: 10 (SIGN_IN_REQUIRED) はアカウント未サインイン表示', () {
      final e = PlatformException(
        code: 'sign_in_failed',
        message: 'com.google.android.gms.common.api.ApiException: 10: ',
      );
      expect(describeSignInError(e), contains('Googleアカウント'));
    });

    test('ApiException: 6 (NETWORK_ERROR) はネットワークエラー表示', () {
      final e = PlatformException(
        code: 'sign_in_failed',
        message: 'com.google.android.gms.common.api.ApiException: 6: ',
      );
      expect(describeSignInError(e), contains('ネットワークエラー'));
    });

    test('ApiException: 7 / 10009 (RESOLUTION_REQUIRED) は更新表示', () {
      expect(
        describeSignInError(
          PlatformException(
            code: 'sign_in_failed',
            message: 'com.google.android.gms.common.api.ApiException: 7: ',
          ),
        ),
        contains('Google Play services の更新'),
      );
      expect(
        describeSignInError(
          PlatformException(
            code: 'sign_in_failed',
            message: 'com.google.android.gms.common.api.ApiException: 10009: ',
          ),
        ),
        contains('Google Play services の更新'),
      );
    });

    test('未分類のエラーは code を含めて表示', () {
      final e = PlatformException(code: 'some_new_code', message: 'xyz');
      final msg = describeSignInError(e);
      expect(msg, contains('some_new_code'));
      expect(msg, contains('xyz'));
    });

    test('long message は 80 文字で切り詰め', () {
      final longMsg = 'a' * 200;
      final e = PlatformException(code: 'weird', message: longMsg);
      final msg = describeSignInError(e);
      // codePart + message(80) + 切り詰め記号 + 前後の文言
      expect(msg.length, lessThan(130));
      expect(msg, contains('…'));
    });

    test('PlatformException 以外の例外は toString で処理される', () {
      final msg = describeSignInError(Exception('unexpected'));
      expect(msg, contains('unexpected'));
    });
  });

  group('summarizeSignInErrorForLog', () {
    test('短い例外はそのまま', () {
      expect(summarizeSignInErrorForLog(Exception('ok')), 'Exception: ok');
    });

    test('長い例外は 400 文字で切り詰め', () {
      final e = Exception('x' * 1000);
      final s = summarizeSignInErrorForLog(e);
      expect(s.length, lessThanOrEqualTo(410));
      expect(s, contains('切り詰め'));
    });

    test('PlatformException は code/message/details のみ（トークン等なし）', () {
      final e = PlatformException(
        code: 'sign_in_failed',
        message: 'ApiException: 8: ',
        details: 'detail-line',
      );
      final s = summarizeSignInErrorForLog(e);
      expect(s, contains('sign_in_failed'));
      expect(s, contains('ApiException: 8'));
      expect(s, contains('detail-line'));
    });
  });
}
