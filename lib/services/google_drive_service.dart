import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'database_service.dart';

// ============================================================================
// サインイン失敗の診断（純粋関数・単体テスト可能）
// ============================================================================

/// GMS の `ApiException: N` から数字コードを抽出する。
int? _parseGmsCode(String text) {
  final m = RegExp(r'ApiException:\s*(\d+)').firstMatch(text);
  if (m != null) return int.tryParse(m.group(1)!);
  return null;
}

/// サインイン失敗の cause からユーザーに表示する短い診断メッセージを生成する。
///
/// 純粋関数（Flutter/DB 依存なし）で単体テスト可能。
/// - [error] が null: 対話式 signIn() でプラグインが null を返すのは
///   ユーザーによるキャンセルの場合（プラグイン仕様の挙動）。
/// - 認証トークン・メール等の個人情報は含まれない（code/message 中心）。
String describeSignInError(Object? error) {
  if (error == null) {
    return 'ログインがキャンセルされました。';
  }

  final code = error is PlatformException ? error.code : null;
  final message = error is PlatformException
      ? (error.message ?? '')
      : error.toString();
  final details = error is PlatformException ? (error.details ?? '') : '';
  final text = '$message $details';

  switch (code) {
    case 'sign_in_canceled':
      return 'ログインがキャンセルされました。';
    case 'network_error':
      return 'ネットワークエラーです。接続を確認して再試行してください。';
    case 'auth_recoverable':
    case 'failed_to_recover_auth':
      return 'Google アプリでのアクセス許可のうえ、再試行してください。';
  }

  // GMS 側の数値エラーコード（ApiException: N）でさらに分類。
  // 10=SIGN_IN_REQUIRED, 12=DEVELOPER_ERROR, 6=NETWORK_ERROR,
  // 7/10009=RESOLUTION_REQUIRED, 8=SIGN_IN_FAILED
  final gmsCode = _parseGmsCode(text);
  if (gmsCode == 12 || text.contains('DEVELOPER_ERROR')) {
    return 'OAuth 設定（パッケージ名・署名鍵 SHA-1）に不整合がある可能性が '
        'あります。Google Cloud Console の Android クライアント設定を確認してください。';
  }
  if (gmsCode == 6 || text.contains('NETWORK_ERROR')) {
    return 'ネットワークエラーです。接続を確認して再試行してください。';
  }
  if (gmsCode == 7 ||
      gmsCode == 10009 ||
      text.contains('RESOLUTION_REQUIRED')) {
    return 'Google Play services の更新が必要です。更新のうえ再試行してください。';
  }
  if (gmsCode == 10 || text.contains('SIGN_IN_REQUIRED')) {
    return '端末にGoogleアカウントがサインインされていないようです。再試行してください。';
  }
  if (code == 'sign_in_failed' || gmsCode == 8) {
    return 'Google Play services の内部エラー（コード8）の可能性が '
        'あります。時間を置いて再試行してください。';
  }

  final detail = message.length > 80 ? '${message.substring(0, 80)}…' : message;
  return 'サインインに失敗しました（${code ?? 'unknown'}）: $detail';
}

/// ログ出力用の例外サマリ（長いメッセージは切り詰める）。
///
/// [PlatformException].toString() は code/message/details のみであり、
/// 認証トークン・個人情報は含まれない。
String summarizeSignInErrorForLog(Object e) {
  final s = e.toString();
  return s.length > 400 ? '${s.substring(0, 400)} …(切り詰め)' : s;
}

/// GoogleSignIn認証ヘッダー付きのHTTPクライアント
class _GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  _GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }
}

class GoogleDriveService {
  static final GoogleDriveService _instance = GoogleDriveService._internal();
  factory GoogleDriveService() => _instance;
  GoogleDriveService._internal();

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'email',
      'https://www.googleapis.com/auth/drive.file',
      'https://www.googleapis.com/auth/drive.appdata',
    ],
  );

  GoogleSignInAccount? _currentUser;
  drive.DriveApi? _driveApi;

  /// 直前のサインイン失敗の cause（PlatformException 等）。
  /// 成功時・新しい試行の開始時に null 化する。
  ///
  /// プラグインの signIn() はキャンセルのみ null 返却し、その他の失敗は
  /// 例外として伝播するため、ここで捕まえて UI が [describeSignInError] で
  /// 診断メッセージを生成できるようにする。
  Object? lastSignInError;

  bool get isLoggedIn => _currentUser != null;
  String? get userEmail => _currentUser?.email;
  String? get signedInEmail => _currentUser?.email;

  /// Googleサインイン
  Future<bool> signIn() async {
    lastSignInError = null;
    try {
      _currentUser = await _googleSignIn.signIn();
      if (_currentUser == null) {
        // プラグイン仕様: null はユーザーによるキャンセル。
        return false;
      }

      final authHeaders = await _currentUser!.authHeaders;
      final client = _GoogleAuthClient(authHeaders);
      _driveApi = drive.DriveApi(client);
      return true;
    } catch (e, st) {
      lastSignInError = e;
      // 実エラー（code/message/details）とスタックトレースをログに出す。
      // 認証トークン・個人情報は含まれない（summarizeSignInErrorForLog 参照）。
      debugPrint('Googleサインインエラー: ${summarizeSignInErrorForLog(e)}');
      debugPrint('Googleサインインエラー スタックトレース: $st');
      return false;
    }
  }

  /// Googleサインアウト
  Future<void> signOut() async {
    _driveApi = null;
    _currentUser = null;
    await _googleSignIn.signOut();
  }

  /// サイレントログイン（前回の認証情報を復元）
  Future<bool> signInSilently() async {
    try {
      // suppressErrors デフォルト(true): 失敗は null 返却で例外を投げない。
      _currentUser = await _googleSignIn.signInSilently();
      if (_currentUser == null) return false;

      final authHeaders = await _currentUser!.authHeaders;
      final client = _GoogleAuthClient(authHeaders);
      _driveApi = drive.DriveApi(client);
      return true;
    } catch (e, st) {
      // authHeaders 取得失敗などの非プラグイン由来の例外のみここに来る。
      lastSignInError = e;
      debugPrint('Googleサイレントログインエラー: ${summarizeSignInErrorForLog(e)}');
      debugPrint('Googleサイレントログインエラー スタックトレース: $st');
      return false;
    }
  }

  /// appDataFolder内のバックアップJSONファイルを検索
  Future<drive.File?> _findBackupFile() async {
    if (_driveApi == null) return null;
    try {
      final fileList = await _driveApi!.files.list(
        q: "name = 'pixember_backup.json' and trashed = false",
        spaces: 'appDataFolder',
        $fields: 'files(id, name, size, modifiedTime)',
      );
      if (fileList.files?.isNotEmpty == true) {
        return fileList.files!.first;
      }
      return null;
    } catch (e, stack) {
      debugPrint('バックアップファイル検索エラー: $e');
      debugPrint('スタックトレース: $stack');
      return null;
    }
  }

  /// バックアップ（JSONエクスポート → アップロード）
  Future<bool> backupJSON() async {
    if (_driveApi == null) {
      throw Exception('Drive API not initialized');
    }
    try {
      // データをエクスポート
      final exportData = await DatabaseService().exportAllData();
      final jsonString = const JsonEncoder.withIndent('  ').convert(exportData);
      final jsonBytes = utf8.encode(jsonString);

      // 既存ファイルを検索
      final existingFile = await _findBackupFile();
      final media = drive.Media(
        Stream<List<int>>.fromIterable([jsonBytes]),
        jsonBytes.length,
      );

      if (existingFile != null && existingFile.id != null) {
        // Update
        await _driveApi!.files.update(
          drive.File()..name = 'pixember_backup.json',
          existingFile.id!,
          uploadMedia: media,
        );
      } else {
        // Create
        final fileMetadata = drive.File()
          ..name = 'pixember_backup.json'
          ..mimeType = 'application/json'
          ..parents = ['appDataFolder'];
        await _driveApi!.files.create(fileMetadata, uploadMedia: media);
      }
      return true;
    } catch (e) {
      debugPrint('バックアップエラー: $e');
      rethrow;
    }
  }

  /// 復元（JSONダウンロード → マージインポート → 結果返却）
  /// 戻り値: マージ結果のサマリー（各テーブルの追加/更新件数）、失敗時はnull
  Future<Map<String, int>?> restoreJSON() async {
    if (_driveApi == null) {
      throw Exception('Drive API not initialized');
    }
    try {
      final existingFile = await _findBackupFile();
      if (existingFile == null || existingFile.id == null) {
        throw Exception('バックアップファイルが見つかりません');
      }
      return await _restoreFromId(existingFile.id!);
    } catch (e) {
      debugPrint('復元エラー: $e');
      rethrow;
    }
  }

  /// 指定ファイルIDのバックアップをダウンロード→マージインポートする共通処理。
  Future<Map<String, int>?> _restoreFromId(String fileId) async {
    if (_driveApi == null) {
      throw Exception('Drive API not initialized');
    }
    // ダウンロード
    final mediaResponse =
        await _driveApi!.files.get(
              fileId,
              downloadOptions: drive.DownloadOptions.fullMedia,
            )
            as drive.Media;

    // ストリームを文字列に変換
    final byteChunks = <int>[];
    await for (final chunk in mediaResponse.stream) {
      byteChunks.addAll(chunk);
    }
    final jsonString = utf8.decode(byteChunks);
    final jsonData = jsonDecode(jsonString) as Map<String, dynamic>;

    // マージインポート実行
    return await DatabaseService().importAllData(jsonData);
  }

  /// バックアップ一覧を取得する（複数バックアップ対応）。
  ///
  /// ファイル名が 'pixember_backup' で始まるものを appDataFolder から全件取得する。
  /// 固定名 'pixember_backup.json' も後方互換として含まれる。
  /// 戻り値: 作成日時(newest→oldest)順のメタデータリスト。
  Future<List<drive.File>> listBackups() async {
    if (_driveApi == null) {
      throw Exception('Drive API not initialized');
    }
    try {
      final fileList = await _driveApi!.files.list(
        q: "name contains 'pixember_backup' and trashed = false",
        spaces: 'appDataFolder',
        orderBy: 'modifiedTime desc',
        $fields: 'files(id, name, size, modifiedTime, createdTime)',
      );
      return fileList.files ?? <drive.File>[];
    } catch (e) {
      debugPrint('バックアップ一覧取得エラー: $e');
      rethrow;
    }
  }

  /// タイムスタンプ付きファイル名で新規バックアップを作成する（複数バックアップ対応）。
  /// 例: pixember_backup_20260812_193000.json
  Future<bool> backupNamed() async {
    if (_driveApi == null) {
      throw Exception('Drive API not initialized');
    }
    try {
      final exportData = await DatabaseService().exportAllData();
      final jsonString = const JsonEncoder.withIndent('  ').convert(exportData);
      final jsonBytes = utf8.encode(jsonString);
      final media = drive.Media(
        Stream<List<int>>.fromIterable([jsonBytes]),
        jsonBytes.length,
      );
      final ts = _timestamp();
      final fileMetadata = drive.File()
        ..name = 'pixember_backup_$ts.json'
        ..mimeType = 'application/json'
        ..parents = ['appDataFolder'];
      await _driveApi!.files.create(fileMetadata, uploadMedia: media);
      return true;
    } catch (e) {
      debugPrint('バックアップ(命名)エラー: $e');
      rethrow;
    }
  }

  /// 指定ファイルIDのバックアップから復元する。
  /// [restoreJSON] と同じマージインポート処理を使う。
  Future<Map<String, int>?> restoreFromId(String fileId) async {
    if (_driveApi == null) {
      throw Exception('Drive API not initialized');
    }
    try {
      return await _restoreFromId(fileId);
    } catch (e) {
      debugPrint('復元(指定ID)エラー: $e');
      rethrow;
    }
  }

  /// 指定ファイルIDのバックアップを削除する（取り消し不可）。
  Future<bool> deleteBackup(String fileId) async {
    if (_driveApi == null) {
      throw Exception('Drive API not initialized');
    }
    try {
      await _driveApi!.files.delete(fileId);
      return true;
    } catch (e) {
      debugPrint('バックアップ削除エラー: $e');
      rethrow;
    }
  }

  /// ローカル時刻から 'YYYYMMDD_HHMMSS' 形式のタイムスタンプを生成する。
  String _timestamp() {
    final now = DateTime.now().toLocal();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${p(now.month)}${p(now.day)}_'
        '${p(now.hour)}${p(now.minute)}${p(now.second)}';
  }
}
