import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'database_service.dart';

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

  bool get isLoggedIn => _currentUser != null;
  String? get userEmail => _currentUser?.email;
  String? get signedInEmail => _currentUser?.email;

  /// Googleサインイン
  Future<bool> signIn() async {
    try {
      _currentUser = await _googleSignIn.signIn();
      if (_currentUser == null) return false;

      final authHeaders = await _currentUser!.authHeaders;
      final client = _GoogleAuthClient(authHeaders);
      _driveApi = drive.DriveApi(client);
      return true;
    } catch (e) {
      debugPrint('Googleサインインエラー: $e');
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
      _currentUser = await _googleSignIn.signInSilently();
      if (_currentUser == null) return false;

      final authHeaders = await _currentUser!.authHeaders;
      final client = _GoogleAuthClient(authHeaders);
      _driveApi = drive.DriveApi(client);
      return true;
    } catch (e) {
      debugPrint('Googleサイレントログインエラー: $e');
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

      // ダウンロード
      final mediaResponse =
          await _driveApi!.files.get(
                existingFile.id!,
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
      final summary = await DatabaseService().importAllData(jsonData);

      return summary;
    } catch (e) {
      debugPrint('復元エラー: $e');
      rethrow;
    }
  }
}
