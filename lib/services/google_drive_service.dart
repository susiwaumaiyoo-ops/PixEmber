import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
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
    scopes: [drive.DriveApi.driveAppdataScope],
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

  /// appDataFolder内の history.db ファイルを検索
  Future<drive.File?> _findBackupFile() async {
    if (_driveApi == null) return null;
    try {
      final fileList = await _driveApi!.files.list(
        q: "name = 'pixiv_history_local.db' and trashed = false",
        spaces: 'appDataFolder',
        $fields: 'files(id, name, size, modifiedTime)',
      );
      if (fileList.files?.isNotEmpty == true) {
        return fileList.files!.first;
      }
      return null;
    } catch (e) {
      debugPrint('バックアップファイル検索エラー: $e');
      return null;
    }
  }

  /// バックアップ（アップロード）
  Future<bool> backupHistoryDb() async {
    if (_driveApi == null) return false;
    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(documentsDir.path, 'pixiv_history_local.db');
      final dbFile = File(dbPath);
      if (!await dbFile.exists()) return false;

final existingFile = await _findBackupFile();
      if (existingFile != null && existingFile.id != null) {
        // Update
        final media = drive.Media(dbFile.openRead(), await dbFile.length());
        await _driveApi!.files.update(
          drive.File()..name = 'pixiv_history_local.db',
          existingFile.id!,
          uploadMedia: media,
        );
      } else {
        // Create
        final fileMetadata = drive.File()
          ..name = 'pixiv_history_local.db'
          ..mimeType = 'application/octet-stream';
        final media = drive.Media(dbFile.openRead(), await dbFile.length());
        await _driveApi!.files.create(
          fileMetadata,
          uploadMedia: media,
        );
      }
      return true;
    } catch (e) {
      debugPrint('バックアップエラー: $e');
      return false;
    }
  }

  /// 復元（ダウンロード → ローカル上書き → DB再起動）
  Future<bool> restoreHistoryDb() async {
    if (_driveApi == null) return false;
    try {
      final existingFile = await _findBackupFile();
      if (existingFile == null || existingFile.id == null) return false;

      // ダウンロード
      final documentsDir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(documentsDir.path, 'pixiv_history_local.db');
      final dbFile = File(dbPath);

      final mediaResponse = await _driveApi!.files.get(
        existingFile.id!,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      // ストリームをバイト配列に変換
      final byteChunks = <int>[];
      await for (final chunk in mediaResponse.stream) {
        byteChunks.addAll(chunk);
      }
      await dbFile.writeAsBytes(byteChunks);

      // DBインスタンス再起動
      await DatabaseService().restartDatabase();

      return true;
    } catch (e) {
      debugPrint('復元エラー: $e');
      return false;
    }
  }
}