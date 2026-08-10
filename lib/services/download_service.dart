import 'dart:io';
import 'dart:isolate';
// import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';

import '../illust_model.dart';
import 'pixiv_api_service.dart';

/// ダウンロードキュー内のアイテム
class DownloadItem {
  final int workId;
  final String title;
  final String url;
  final String type; // 'illust' or 'ugoira'
  final bool isGifExport; // ugoira のみ、GIFエクスポートかどうか

  DownloadItem({
    required this.workId,
    required this.title,
    required this.url,
    required this.type,
    this.isGifExport = false,
  });
}

/// ダウンロードサービス（シングルトンパターン）
class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  final List<DownloadItem> _downloadQueue = [];
  bool _isProcessing = false;

  /// ダウンロードキューにアイテムを追加
  void addToQueue(Illust illust, {bool asGif = false}) {
    final List<PageImage> images = illust.metaPages.isNotEmpty
        ? illust.metaPages
        : [
            PageImage(
              page: 1,
              preview: illust.urls.preview,
              original: illust.urls.original,
            ),
          ];

    for (final page in images) {
      final item = DownloadItem(
        workId: illust.id,
        title: '${illust.title}_page${page.page}',
        url: page.original ?? '',
        type: 'illust',
      );
      _downloadQueue.add(item);
    }
  }

  /// ウゴイラのダウンロードをキューに追加（GIFまたはZIP）
  void addUgoiraToQueue(int illustId, {bool asGif = false}) {
    final item = DownloadItem(
      workId: illustId,
      title: 'ugoira_$illustId',
      url: '',
      type: 'ugoira',
      isGifExport: asGif,
    );
    _downloadQueue.add(item);
  }

  /// ダウンロードキューの処理を開始（Isolate.runでバックグラウンド化）
  Future<void> processQueue({
    required void Function(int workId, double progress) onProgress,
    required void Function(int workId, String path) onSuccess,
    required void Function(int workId, String error) onError,
  }) async {
    if (_isProcessing || _downloadQueue.isEmpty) return;

    _isProcessing = true;

    // Isolate.runでバックグラウンド処理
    await Isolate.run(() async {
      try {
        final api = PixivApiService();
        final token = await api.getAccessToken(await api.getRefreshToken());

        for (int i = 0; i < _downloadQueue.length; i++) {
          final item = _downloadQueue[i];
          // final progress = (i + 1) / _downloadQueue.length;

          try {
            String? savePath;

            if (item.type == 'ugoira') {
              savePath = await _downloadUgoira(
                illustId: item.workId,
                token: token,
                asGif: item.isGifExport,
              );
            } else {
              final response = await http.get(
                Uri.parse(item.url),
                headers: {
                  'User-Agent': 'PixivAndroidApp/6.71.1 (Android 11; Pixel 5)',
                  'Authorization': 'Bearer $token',
                },
              );

              if (response.statusCode != 200) {
                throw Exception('ダウンロード失敗: ${response.statusCode}');
              }

              savePath = await _saveImage(response.bodyBytes, item.title);
            }

            if (savePath != null) {
              onProgress(item.workId, 1.0);
              onSuccess(item.workId, savePath);
            } else {
              throw Exception('保存に失敗しました');
            }
          } catch (e) {
            onProgress(item.workId, 0.0);
            onError(item.workId, e.toString());
          }
        }
      } finally {
        _isProcessing = false;
      }
    });
  }

  /// 画像を保存（プラットフォーム固有処理付き）
  Future<String?> _saveImage(Uint8List bytes, String fileName) async {
    try {
      final dir = await _getDownloadDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final safeFileName = fileName.replaceAll(RegExp(r'[\\/*?:"<>|]'), '_');
      final filePath = path.join(dir.path, '$safeFileName\\_$timestamp.png');

      final file = File(filePath);
      await file.writeAsBytes(bytes);

      // プラットフォーム固有処理
      await _saveToGallery(filePath, fileName);

      return filePath;
    } catch (e) {
      debugPrint('画像保存エラー: $e');
      return null;
    }
  }

  /// ダウンロードディレクトリを取得
  Future<Directory> _getDownloadDirectory() async {
    if (Platform.isAndroid) {
      // Android: 公開ストレージへの書き込み権限が必要
      final status = await Permission.storage.request();
      if (!status.isGranted) {
        throw Exception('ストレージアクセス許可が必要です');
      }
      final dir = await getExternalStorageDirectory();
      if (dir == null) {
        throw Exception('外部ストレージが見つかりません');
      }
      final downloadsDir = Directory('${dir.parent.path}/Download');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      return downloadsDir;
    } else if (Platform.isIOS) {
      // iOS: ギャラリーに保存
      final dir = await getApplicationDocumentsDirectory();
      final downloadsDir = Directory('${dir.path}/Downloads');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      return downloadsDir;
    } else {
      // Desktop: Downloads フォルダ
      final dir = await getDownloadsDirectory();
      if (dir == null) {
        throw Exception('ダウンロードフォルダが見つかりません');
      }
      return dir;
    }
  }

  /// ギャラリーに保存
  Future<void> _saveToGallery(String filePath, String fileName) async {
    try {
      if (Platform.isAndroid) {
        // Android: ストレージ権限が必要
        final status = await Permission.storage.request();
        if (!status.isGranted) return;

        final file = File(filePath);
        final bytes = await file.readAsBytes();

        final result = await ImageGallerySaverPlus.saveImage(
          bytes,
          name: fileName,
          quality: 100,
        );

        if (!result['isSuccess']) {
          debugPrint('ギャラリー保存失敗: $result');
        }
      } else if (Platform.isIOS) {
        // iOS: ギャラリーに直接保存
        final file = File(filePath);
        final bytes = await file.readAsBytes();

        final result = await ImageGallerySaverPlus.saveImage(
          bytes,
          quality: 100,
        );

        if (!result['isSuccess']) {
          debugPrint('ギャラリー保存失敗: $result');
        }
      }
      // Desktop はファイルシステムに保存するだけで、ギャラリーへの保存は不要
    } catch (e) {
      debugPrint('ギャラリー保存エラー: $e');
    }
  }

  /// ウゴイラをダウンロードして保存
  Future<String?> _downloadUgoira({
    required int illustId,
    required String token,
    required bool asGif,
  }) async {
    final api = PixivApiService();
    final metaResponse = await api.getUgoiraMetadata(illustId);

    final metaData = metaResponse['ugoira_metadata'] as Map<String, dynamic>?;
    final frames = metaData?['frames'] as List<dynamic>?;
    final zipUrls = metaData?['zip_urls'] as Map<String, dynamic>?;
    final String zipUrl = zipUrls?['large'] ?? zipUrls?['medium'] ?? '';

    if (zipUrl.isEmpty || frames == null || frames.isEmpty) {
      throw Exception('ウゴイラのメタデータが取得できません');
    }

    // ZIPをダウンロード
    final zipResponse = await http.get(
      Uri.parse(zipUrl),
      headers: {
        'User-Agent': 'PixivAndroidApp/6.71.1 (Android 11; Pixel 5)',
        'Authorization': 'Bearer $token',
      },
    );

    if (zipResponse.statusCode != 200) {
      throw Exception('ウゴイラZIPのダウンロード失敗: ${zipResponse.statusCode}');
    }

    // GIFまたはZIPとして保存
    return asGif
        ? await _saveUgoiraAsGif(zipResponse.bodyBytes, 'ugoira_$illustId')
        : await _saveUgoiraAsZip(zipResponse.bodyBytes, 'ugoira_$illustId');
  }

  /// ウゴイラをZIPとして保存
  Future<String?> _saveUgoiraAsZip(List<int> zipBytes, String fileName) async {
    try {
      final dir = await _getDownloadDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final zipPath = path.join(dir.path, '$fileName\\_$timestamp.zip');

      final file = File(zipPath);
      await file.writeAsBytes(zipBytes);

      // ギャラリーに保存
      await _saveToGallery(zipPath, '$fileName.zip');

      return zipPath;
    } catch (e) {
      debugPrint('ZIP保存エラー: $e');
      return null;
    }
  }

  /// ウゴイラをGIFとして保存
  Future<String?> _saveUgoiraAsGif(List<int> zipBytes, String fileName) async {
    try {
      final dir = await _getDownloadDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempPath = path.join(dir.path, '$fileName\\_temp.zip');
      final gifPath = path.join(dir.path, '$fileName\\_$timestamp.gif');

      // ZIPを一時ファイルに保存
      final tempFile = File(tempPath);
      await tempFile.writeAsBytes(zipBytes);

      // ZIPを展開
      final archive = ZipDecoder().decodeBytes(zipBytes);
      final List<ArchiveFile> files = archive.files;

      if (files.isEmpty) {
        throw Exception('ZIPにファイルが含まれていません');
      }

      // 画像ファイルを抽出
      final List<Uint8List> frameImages = [];
      for (final file in files) {
        if (!file.isFile) continue;
        final content = file.content as List<int>;
        frameImages.add(Uint8List.fromList(content));
      }

      // GIFに変換
      if (frameImages.isEmpty) {
        throw Exception('GIFに変換する画像がありません');
      }

      final gifBytes = await _convertToGif(frameImages);

      // GIFを保存
      final gifFile = File(gifPath);
      await gifFile.writeAsBytes(gifBytes);

      // 一時ファイルを削除
      await tempFile.delete();

      // ギャラリーに保存
      await _saveToGallery(gifPath, '$fileName.gif');

      return gifPath;
    } catch (e) {
      debugPrint('GIF保存エラー: $e');
      return null;
    }
  }

  /// 画像リストをGIFに変換
  Future<Uint8List> _convertToGif(List<Uint8List> frameImages) async {
    // GIF変換には gif パッケージが必要
    // ここでは簡易的な実装として、最初のフレームを返す
    // 完全な実装には gif パッケージの追加が必要
    return frameImages.first;
  }

  /// キューをクリア
  void clearQueue() {
    _downloadQueue.clear();
  }

  /// ダウンロード中かどうかを取得
  bool get isProcessing => _isProcessing;

  /// キューの長さを取得
  int get queueLength => _downloadQueue.length;

  /// 指定したイラストをダウンロード
  Future<void> downloadIllust(Illust illust, {bool asGif = false}) async {
    addToQueue(illust, asGif: asGif);
  }

  /// 指定したウゴイラをダウンロード
  Future<void> downloadUgoira(int illustId, {bool asGif = false}) async {
    addUgoiraToQueue(illustId, asGif: asGif);
  }
}
