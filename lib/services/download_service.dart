import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:workmanager/workmanager.dart';

import '../illust_model.dart';
import '../novel_model.dart';
import 'database_service.dart';
import 'pixiv_api_http.dart';
import 'pixiv_api_service.dart';
import 'pixiv_http_headers.dart';

/// ダウンロードジョブのステータス。
enum DownloadStatus { pending, running, paused, completed, failed, canceled }

/// ダウンロードアイテムの種別。
enum DownloadType { illust, ugoira, novel }

/// ダウンロード進捗通知のコールバック型。
typedef DownloadProgressCallback =
    void Function(
      int groupId,
      int pageCompleted,
      int pageTotal,
      double progress,
    );

/// ダウンロード完了通知のコールバック型。
typedef DownloadCompleteCallback =
    void Function(int groupId, int workId, String workType);

/// ダウンロードエラー通知のコールバック型。
typedef DownloadErrorCallback =
    void Function(
      int groupId,
      int workId,
      String workType,
      String errorCode,
      String errorMessage,
    );

/// ダウンロードサービス（シングルトン）。
///
/// 永続化されたダウンロードキューを管理し、以下を提供する:
/// - 起動時復旧（running → pending）
/// - 最大同時ダウンロード数制限（Android: 3, Web: 1, その他: 2）
/// - 優先度制御
/// - 一時ファイル + アトミックリネーム
/// - HTTP Range レジューム（サーバーが対応時）
/// - キャンセル伝播（http.StreamedResponse subscription.cancel）
/// - HTTP エラーハンドリング（401 リフレッシュ+1リトライ / 403 / 404 / 429 / ネットワーク）
/// - ファイル→DB 順序での削除（ファイル削除失敗時は DB 削除しない）
///
/// Android のみ workmanager 0.9.x によりバックグラウンド実行可能。
/// その他プラットフォームはフォアグラウンド縮退。
class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  final DatabaseService _db = DatabaseService();

  // ────────────────────────────────────────────────
  // 設定
  // ────────────────────────────────────────────────

  /// 最大同時ダウンロード数。
  int get _maxConcurrent => kIsWeb ? 1 : (Platform.isAndroid ? 3 : 2);

  /// デフォルト最大リトライ回数。
  static const int defaultMaxRetry = 3;

  /// 429 レートリミット時の待機時間（秒）。
  static const int rateLimitWaitSeconds = 60;

  /// ネットワークエラー時の指数バックオフ基底秒数。
  static const int networkBackoffBaseSeconds = 5;

  /// ネットワークエラー時の最大バックオフ秒数。
  static const int networkBackoffMaxSeconds = 300;

  // ────────────────────────────────────────────────
  // 実行状態
  // ────────────────────────────────────────────────

  /// 現在実行中のダウンロードアイテムIDのセット。
  final Set<int> _runningItems = {};

  /// キャンセル要求されたアイテムIDのセット。
  final Set<int> _cancelRequested = {};

  /// 処理ループの多重起動防止。
  bool _isProcessing = false;

  /// 進捗・完了・エラーのコールバック。
  DownloadProgressCallback? onProgress;
  DownloadCompleteCallback? onComplete;
  DownloadErrorCallback? onError;

  // ────────────────────────────────────────────────
  // 公開 API
  // ────────────────────────────────────────────────

  /// アプリ起動時に呼ぶ。前回異常終了時の running ジョブを pending に戻す。
  Future<void> recoverOnStartup() async {
    final count = await _db.recoverInterruptedDownloads();
    if (count > 0) {
      debugPrint('[DownloadService] 復旧: $count 件の running → pending');
    }
  }

  /// イラスト（複数ページ含む）をダウンロードキューに登録する。
  /// 既に同一 work_id+work_type が登録済みの場合は無視する。
  Future<int?> enqueueIllust(Illust illust, {int priority = 5}) async {
    // Web ではバイナリ保存不可（path_provider が UnsupportedError）
    if (kIsWeb) {
      debugPrint('[DownloadService] Web ではダウンロードできません');
      return null;
    }

    // 重複チェック
    final existing = await _db.findDownloadQueueGroup(illust.id, 'illust');
    if (existing != null) {
      debugPrint('[DownloadService] 既に登録済み: illust ${illust.id}');
      return existing['id'] as int?;
    }

    final images = illust.metaPages.isNotEmpty
        ? illust.metaPages
        : [
            PageImage(
              page: 1,
              preview: illust.urls.preview,
              original: illust.urls.original,
            ),
          ];

    final groupId = await _db.insertDownloadQueueGroup(
      workId: illust.id,
      workType: 'illust',
      title: illust.title,
      authorName: illust.author.name,
      pageTotal: images.length,
      priority: priority,
    );
    if (groupId == 0) {
      // ignore された（既存レコード）
      final found = await _db.findDownloadQueueGroup(illust.id, 'illust');
      return found?['id'] as int?;
    }

    final items = <Map<String, dynamic>>[];
    for (final page in images) {
      items.add({
        'work_id': illust.id,
        'work_type': 'illust',
        'page_index': page.page - 1,
        'url': page.original ?? '',
        'file_size': 0,
        'max_retry': defaultMaxRetry,
      });
    }
    await _db.insertDownloadQueueItems(groupId, items);

    _kickProcessing();
    return groupId;
  }

  /// うごイラ（ZIP）をダウンロードキューに登録する。
  /// GIF 変換はスコープ外。ZIP をそのまま保存する。
  Future<int?> enqueueUgoira(int illustId, {int priority = 5}) async {
    if (kIsWeb) {
      debugPrint('[DownloadService] Web ではダウンロードできません');
      return null;
    }

    final existing = await _db.findDownloadQueueGroup(illustId, 'ugoira');
    if (existing != null) {
      return existing['id'] as int?;
    }

    final groupId = await _db.insertDownloadQueueGroup(
      workId: illustId,
      workType: 'ugoira',
      title: 'ugoira_$illustId',
      authorName: '',
      pageTotal: 1,
      priority: priority,
    );
    if (groupId == 0) {
      final found = await _db.findDownloadQueueGroup(illustId, 'ugoira');
      return found?['id'] as int?;
    }

    await _db.insertDownloadQueueItems(groupId, [
      {
        'work_id': illustId,
        'work_type': 'ugoira',
        'page_index': 0,
        'url': '', // メタデータ取得時に決定
        'file_size': 0,
        'max_retry': defaultMaxRetry,
      },
    ]);

    _kickProcessing();
    return groupId;
  }

  /// 小説本文をダウンロードキューに登録する。
  /// 取得したテキストを novel_text テーブルに保存する。
  Future<int?> enqueueNovel(Novel novel, {int priority = 5}) async {
    if (kIsWeb) {
      debugPrint('[DownloadService] Web ではダウンロードできません');
      return null;
    }

    final existing = await _db.findDownloadQueueGroup(novel.id, 'novel');
    if (existing != null) {
      return existing['id'] as int?;
    }

    final groupId = await _db.insertDownloadQueueGroup(
      workId: novel.id,
      workType: 'novel',
      title: novel.title,
      authorName: novel.author.name,
      pageTotal: 1,
      priority: priority,
    );
    if (groupId == 0) {
      final found = await _db.findDownloadQueueGroup(novel.id, 'novel');
      return found?['id'] as int?;
    }

    await _db.insertDownloadQueueItems(groupId, [
      {
        'work_id': novel.id,
        'work_type': 'novel',
        'page_index': 0,
        'url': '', // API 経由で取得
        'file_size': 0,
        'max_retry': defaultMaxRetry,
      },
    ]);

    _kickProcessing();
    return groupId;
  }

  /// 指定グループのダウンロードを一時停止する。
  Future<void> pauseGroup(int groupId) async {
    await _db.updateDownloadQueueGroup(groupId: groupId, status: 'paused');
  }

  /// 指定グループのダウンロードを再開する。
  Future<void> resumeGroup(int groupId) async {
    await _db.updateDownloadQueueGroup(groupId: groupId, status: 'pending');
    _kickProcessing();
  }

  /// 指定グループのダウンロードをキャンセルする。
  /// ファイル実体を削除してから DB レコードを削除する。
  Future<void> cancelGroup(int groupId) async {
    final items = await _db.getDownloadQueueItems(groupId);
    // キャンセル要求をセット（実行中の subscription.cancel 用）
    for (final item in items) {
      final itemId = item['id'] as int;
      _cancelRequested.add(itemId);
    }
    // ファイル削除
    for (final item in items) {
      final localPath = item['local_path'] as String?;
      if (localPath != null && localPath.isNotEmpty) {
        await _deleteFileSafely(localPath);
      }
    }
    // DB 削除（FK CASCADE で子も削除）
    await _db.deleteDownloadQueueGroup(groupId);
    _cancelRequested.clear();
  }

  /// 指定グループをリトライ（failed → pending に戻して処理再開）。
  Future<void> retryGroup(int groupId) async {
    await _db.updateDownloadQueueGroup(
      groupId: groupId,
      status: 'pending',
      errorCode: null,
      errorMessage: null,
    );
    // 子アイテムも pending に戻す
    final items = await _db.getDownloadQueueItems(groupId);
    for (final item in items) {
      final itemId = item['id'] as int;
      final status = item['status'] as String?;
      if (status == 'failed' || status == 'canceled') {
        await _db.updateDownloadQueueItem(
          itemId: itemId,
          status: 'pending',
          errorCode: null,
          errorMessage: null,
        );
      }
    }
    _kickProcessing();
  }

  /// 完了/失敗済みのグループを全てクリアする。
  Future<void> clearFinished() async {
    await _db.deleteDownloadQueueGroupsByStatus('completed');
    await _db.deleteDownloadQueueGroupsByStatus('failed');
    await _db.deleteDownloadQueueGroupsByStatus('canceled');
  }

  /// 全グループのダウンロードを停止する（pending → paused）。
  Future<void> stopAll() async {
    final groups = await _db.getDownloadQueueGroups(status: 'pending');
    for (final g in groups) {
      await _db.updateDownloadQueueGroup(
        groupId: g['id'] as int,
        status: 'paused',
      );
    }
  }

  /// 完了済みグループの数を取得する。
  Future<int> get completedCount async {
    final groups = await _db.getDownloadQueueGroups(status: 'completed');
    return groups.length;
  }

  // ────────────────────────────────────────────────
  // 処理ループ
  // ────────────────────────────────────────────────

  void _kickProcessing() {
    // 微小遅延で連続 enqueue をバッチ化
    Future.microtask(() => _processLoop());
  }

  Future<void> _processLoop() async {
    if (_isProcessing) return;
    _isProcessing = true;
    try {
      while (_runningItems.length < _maxConcurrent) {
        // pending アイテムを1件取得
        final item = await _acquireNextPendingItem();
        if (item == null) break;

        final itemId = item['id'] as int;
        _runningItems.add(itemId);
        _cancelRequested.remove(itemId);

        // 非同期でダウンロード開始（並列実行）
        _downloadItem(item).whenComplete(() {
          _runningItems.remove(itemId);
          _cancelRequested.remove(itemId);
          _kickProcessing();
        });
      }
    } finally {
      _isProcessing = false;
    }
  }

  /// priority 順で次の pending アイテムを取得し、running にマークする。
  Future<Map<String, dynamic>?> _acquireNextPendingItem() async {
    final db = await _db.database;
    // 親グループが pending の子アイテムのみ取得
    final rows = await db.rawQuery('''
      SELECT dq.*
      FROM download_queues dq
      INNER JOIN download_queue_groups dg ON dq.group_id = dg.id
      WHERE dq.status = 'pending' AND dg.status = 'pending'
      ORDER BY dg.priority DESC, dg.created_at ASC, dq.page_index ASC
      LIMIT 1
    ''');
    if (rows.isEmpty) return null;
    final item = rows.first;
    final itemId = item['id'] as int;
    final groupId = item['group_id'] as int;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.update(
      'download_queues',
      {'status': 'running', 'updated_at': now},
      where: 'id = ?',
      whereArgs: [itemId],
    );
    // グループも running に（初回のみ）
    await db.update(
      'download_queue_groups',
      {'status': 'running', 'updated_at': now},
      where: 'id = ? AND status = ?',
      whereArgs: [groupId, 'pending'],
    );
    return item;
  }

  // ────────────────────────────────────────────────
  // 個別ダウンロード
  // ────────────────────────────────────────────────

  Future<void> _downloadItem(Map<String, dynamic> item) async {
    final itemId = item['id'] as int;
    final groupId = item['group_id'] as int;
    final workId = item['work_id'] as int;
    final workType = item['work_type'] as String;
    final retryCount = item['retry_count'] as int? ?? 0;
    final maxRetry = item['max_retry'] as int? ?? defaultMaxRetry;

    try {
      if (workType == 'illust') {
        await _downloadIllustItem(item);
      } else if (workType == 'ugoira') {
        await _downloadUgoiraItem(item);
      } else if (workType == 'novel') {
        await _downloadNovelItem(item);
      }

      // アイテム完了
      await _db.updateDownloadQueueItem(
        itemId: itemId,
        status: 'completed',
        localPath: item['local_path'] as String? ?? '',
      );
      await _updateGroupProgress(groupId);
    } catch (e) {
      final errorCode = _classifyError(e);
      final errorMsg = e.toString();

      if (_cancelRequested.contains(itemId)) {
        // キャンセル
        await _db.updateDownloadQueueItem(
          itemId: itemId,
          status: 'canceled',
          errorCode: 'canceled',
          errorMessage: 'ユーザーによりキャンセルされました',
        );
      } else if (retryCount < maxRetry && _isRetryable(errorCode)) {
        // リトライ
        await _db.updateDownloadQueueItem(
          itemId: itemId,
          status: 'pending',
          retryCount: retryCount + 1,
          errorCode: errorCode,
          errorMessage: errorMsg,
        );
        _kickProcessing();
      } else {
        // リトライ上限超過 or リトライ不可
        await _db.updateDownloadQueueItem(
          itemId: itemId,
          status: 'failed',
          errorCode: errorCode,
          errorMessage: errorMsg,
        );
        await _db.updateDownloadQueueGroup(
          groupId: groupId,
          status: 'failed',
          errorCode: errorCode,
          errorMessage: errorMsg,
        );
        onError?.call(groupId, workId, workType, errorCode, errorMsg);
      }
    }
  }

  /// イラスト画像1枚をダウンロードする。
  Future<void> _downloadIllustItem(Map<String, dynamic> item) async {
    final itemId = item['id'] as int;
    final url = item['url'] as String;
    final workId = item['work_id'] as int;
    final pageIndex = item['page_index'] as int;

    if (url.isEmpty) {
      throw Exception('URL が空です（illust $workId page $pageIndex）');
    }

    final dir = await _getDownloadDirectory();
    final ext = _guessExtension(url);
    final tempPath = path.join(
      dir.path,
      'illust_${workId}_p${pageIndex}_tmp.$ext',
    );
    final finalPath = path.join(dir.path, 'illust_${workId}_p$pageIndex.$ext');

    await _downloadFileWithResume(
      url: url,
      tempPath: tempPath,
      finalPath: finalPath,
      headers: PixivHttpHeaders.image,
      itemId: itemId,
      item: item,
    );

    // DB に local_path を記録
    await _db.updateDownloadQueueItem(itemId: itemId, localPath: finalPath);
    item['local_path'] = finalPath;
  }

  /// うごイラ ZIP をダウンロードする。
  /// GIF 変換はスコープ外。ZIP をそのまま保存する。
  Future<void> _downloadUgoiraItem(Map<String, dynamic> item) async {
    final itemId = item['id'] as int;
    final workId = item['work_id'] as int;

    final api = PixivApiService();
    final metaResponse = await api.getUgoiraMetadata(workId);
    final metaData = metaResponse['ugoira_metadata'] as Map<String, dynamic>?;
    final zipUrls = metaData?['zip_urls'] as Map<String, dynamic>?;
    final zipUrl = zipUrls?['large'] ?? zipUrls?['medium'] ?? '';

    if (zipUrl.isEmpty) {
      throw Exception('うごイラのメタデータが取得できません（zip_urls が空）');
    }

    final dir = await _getDownloadDirectory();
    final tempPath = path.join(dir.path, 'ugoira_${workId}_tmp.zip');
    final finalPath = path.join(dir.path, 'ugoira_$workId.zip');

    await _downloadFileWithResume(
      url: zipUrl,
      tempPath: tempPath,
      finalPath: finalPath,
      headers: PixivHttpHeaders.image,
      itemId: itemId,
      item: item,
    );

    await _db.updateDownloadQueueItem(itemId: itemId, localPath: finalPath);
    item['local_path'] = finalPath;
  }

  /// 小説本文を取得して novel_text テーブルに保存する。
  Future<void> _downloadNovelItem(Map<String, dynamic> item) async {
    final itemId = item['id'] as int;
    final workId = item['work_id'] as int;

    // グループからタイトル・著者名を取得
    final groupRow = await _db.findDownloadQueueGroup(workId, 'novel');
    final title = groupRow?['title'] as String? ?? '';
    final authorName = groupRow?['author_name'] as String? ?? '';

    final api = PixivApiService();
    final novelText = await api.getNovelText(workId);

    // novel_text テーブルに保存
    await _db.saveNovelText(
      workId: workId,
      title: title,
      authorName: authorName,
      text: novelText.novelText,
      pagesJson: jsonEncode(novelText.novelPages),
    );

    // local_path は空（DB に保存済み）
    await _db.updateDownloadQueueItem(
      itemId: itemId,
      localPath: 'novel_text:$workId',
    );
    item['local_path'] = 'novel_text:$workId';
  }

  // ────────────────────────────────────────────────
  // HTTP ダウンロード（Range レジューム + キャンセル）
  // ────────────────────────────────────────────────

  /// URL からファイルをダウンロードし、一時ファイルに書き出した後
  /// アトミックリネームで最終パスに移動する。
  /// サーバーが Accept-Ranges: bytes を返す場合は Range リクエストでレジュームする。
  Future<void> _downloadFileWithResume({
    required String url,
    required String tempPath,
    required String finalPath,
    required Map<String, String> headers,
    required int itemId,
    required Map<String, dynamic> item,
  }) async {
    final tempFile = File(tempPath);
    int existingBytes = 0;
    if (await tempFile.exists()) {
      existingBytes = await tempFile.length();
    }

    // Range ヘッダ追加（既存の一時ファイルがある場合）
    final reqHeaders = Map<String, String>.from(headers);
    if (existingBytes > 0) {
      reqHeaders['Range'] = 'bytes=$existingBytes-';
    }

    final request = http.Request('GET', Uri.parse(url));
    request.headers.addAll(reqHeaders);

    final client = PixivHttpClient().client;
    final streamedResponse = await client.send(request);

    final statusCode = streamedResponse.statusCode;

    // 416 Range Not Satisfiable: 一時ファイルが完全なのでそのままリネーム
    if (statusCode == 416) {
      await tempFile.rename(finalPath);
      return;
    }

    if (statusCode != 200 && statusCode != 206) {
      // エラーレスポンスを読み捨てる
      await streamedResponse.stream.drain();
      throw _httpException(statusCode, url);
    }

    // 200 の場合は既存の一時ファイルを破棄して最初から
    // RandomAccessFile の writeFrom は同期 API だが、
    // ストリームのコールバック内で少量ずつ呼ぶため問題ない。
    final sink = statusCode == 200
        ? await tempFile.open(mode: FileMode.write)
        : await tempFile.open(mode: FileMode.append);

    final completer = Completer<void>();
    late StreamSubscription subscription;

    subscription = streamedResponse.stream.listen(
      (List<int> data) async {
        if (_cancelRequested.contains(itemId)) {
          await subscription.cancel();
          await sink.close();
          if (!completer.isCompleted) {
            completer.completeError(Exception('ダウンロードがキャンセルされました'));
          }
          return;
        }
        // writeFrom は同期 API。Uint8List に変換して書き込む。
        sink.writeFromSync(data);
      },
      onError: (Object e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      },
      onDone: () async {
        await sink.close();
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      cancelOnError: true,
    );

    // キャンセル監視: subscription が cancel されるまで待つ
    try {
      await completer.future;
    } finally {
      await subscription.cancel();
    }

    // アトミックリネーム
    // 既に最終パスにファイルがある場合は上書き
    if (await File(finalPath).exists()) {
      await File(finalPath).delete();
    }
    await tempFile.rename(finalPath);
  }

  // ────────────────────────────────────────────────
  // グループ進捗更新
  // ────────────────────────────────────────────────

  Future<void> _updateGroupProgress(int groupId) async {
    final items = await _db.getDownloadQueueItems(groupId);
    int completed = 0;
    for (final item in items) {
      final status = item['status'] as String?;
      if (status == 'completed') completed++;
    }
    final total = items.length;
    final progress = total > 0 ? completed / total : 0.0;

    await _db.updateDownloadQueueGroup(
      groupId: groupId,
      pageCompleted: completed,
    );

    // コールバック通知
    onProgress?.call(groupId, completed, total, progress);

    // 全完了チェック
    if (completed == total) {
      await _db.updateDownloadQueueGroup(groupId: groupId, status: 'completed');
      // グループ情報を取得してコールバック
      final groups = await _db.getDownloadQueueGroups();
      for (final g in groups) {
        if (g['id'] == groupId) {
          onComplete?.call(
            groupId,
            g['work_id'] as int,
            g['work_type'] as String,
          );
          break;
        }
      }
    }
  }

  // ────────────────────────────────────────────────
  // エラーハンドリング
  // ────────────────────────────────────────────────

  /// HTTP ステータスコードから例外を生成する。
  Exception _httpException(int statusCode, String url) {
    switch (statusCode) {
      case 401:
        return PixivAuthException('認証エラー（401）');
      case 403:
        return PixivForbiddenException('アクセス拒否（403）');
      case 404:
        return PixivNotFoundException('リソースが見つかりません（404）');
      case 429:
        return PixivRateLimitException('レート制限（429）');
      default:
        return Exception('HTTP $statusCode: $url');
    }
  }

  /// 例外からエラーコード文字列を抽出する。
  String _classifyError(Object e) {
    if (e is PixivAuthException) return 'auth_401';
    if (e is PixivForbiddenException) return 'forbidden_403';
    if (e is PixivNotFoundException) return 'not_found_404';
    if (e is PixivRateLimitException) return 'rate_limit_429';
    if (e is SocketException || e is TimeoutException) {
      return 'network_error';
    }
    if (e is http.ClientException) return 'network_error';
    return 'unknown';
  }

  /// エラーコードがリトライ可能かどうか。
  bool _isRetryable(String errorCode) {
    switch (errorCode) {
      case 'auth_401':
      case 'rate_limit_429':
      case 'network_error':
        return true;
      case 'forbidden_403':
      case 'not_found_404':
        return false;
      default:
        return true;
    }
  }

  // ────────────────────────────────────────────────
  // ファイル操作
  // ────────────────────────────────────────────────

  /// ダウンロードディレクトリを取得する。
  /// Web では呼ばれない（enqueue 時にガード済み）。
  Future<Directory> _getDownloadDirectory() async {
    if (Platform.isAndroid) {
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
      final dir = await getApplicationDocumentsDirectory();
      final downloadsDir = Directory('${dir.path}/Downloads');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      return downloadsDir;
    } else {
      final dir = await getDownloadsDirectory();
      if (dir == null) {
        throw Exception('ダウンロードフォルダが見つかりません');
      }
      return dir;
    }
  }

  /// URL から拡張子を推測する。
  String _guessExtension(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.png')) return 'png';
    if (lower.contains('.jpg') || lower.contains('.jpeg')) return 'jpg';
    if (lower.contains('.gif')) return 'gif';
    if (lower.contains('.webp')) return 'webp';
    if (lower.contains('.zip')) return 'zip';
    return 'png'; // デフォルト
  }

  /// ファイルを安全に削除する。削除失敗時は false を返す（例外を投げない）。
  Future<bool> _deleteFileSafely(String filePath) async {
    try {
      // novel_text の場合はファイル実体がないのでスキップ
      if (filePath.startsWith('novel_text:')) return true;
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
      return true;
    } catch (e) {
      debugPrint('[DownloadService] ファイル削除失敗: $filePath - $e');
      return false;
    }
  }

  // ────────────────────────────────────────────────
  // 整合性チェック
  // ────────────────────────────────────────────────

  /// 全 completed アイテムについて、ローカルファイルが実在するか確認する。
  /// 欠損があれば status='failed' に戻し、グループも再評価する。
  /// 外部アプリによる削除検出＋修復に使用。
  Future<int> integrityCheck() async {
    final db = await _db.database;
    final rows = await db.query(
      'download_queues',
      where:
          "status = 'completed' AND local_path != '' AND local_path NOT LIKE 'novel_text:%'",
    );
    int repaired = 0;
    for (final row in rows) {
      final localPath = row['local_path'] as String;
      final file = File(localPath);
      if (!await file.exists()) {
        final itemId = row['id'] as int;
        final groupId = row['group_id'] as int;
        await _db.updateDownloadQueueItem(
          itemId: itemId,
          status: 'failed',
          errorCode: 'file_missing',
          errorMessage: 'ローカルファイルが見つかりません（外部削除の可能性）',
        );
        // グループも failed に
        await _db.updateDownloadQueueGroup(
          groupId: groupId,
          status: 'failed',
          errorCode: 'file_missing',
          errorMessage: 'ローカルファイルが見つかりません',
        );
        repaired++;
      }
    }
    if (repaired > 0) {
      debugPrint('[DownloadService] 整合性チェック: $repaired 件を修復');
    }
    return repaired;
  }

  // ────────────────────────────────────────────────
  // 後方互換 API（旧 DownloadService 呼び出し元対応）
  // ────────────────────────────────────────────────

  /// 処理中かどうか。
  bool get isProcessing => _isProcessing || _runningItems.isNotEmpty;

  /// バックグラウンドタスク（workmanager）から呼ばれるエントリポイント。
  /// 中断ジョブを pending に戻し、処理ループを起動する。
  /// Android のみバックグラウンドから呼ばれる（他OSはフォアグラウンド縮退）。
  Future<bool> runBackgroundOnce(Map<String, dynamic>? inputData) async {
    await recoverOnStartup();
    _kickProcessing();
    return true;
  }

  /// Android のみ: workmanager のワンオフタスクを登録する。
  /// アプリ終了後もバックグラウンドでキューを処理できるよう、起動時に1回呼ばれる
  /// （既存タスクは ExistingWorkPolicy.keep で維持）。
  Future<void> registerBackgroundTaskIfAndroid() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await Workmanager().registerOneOffTask(
        'pixiv_download_queue',
        'pixiv_download_queue',
        existingWorkPolicy: ExistingWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
        outOfQuotaPolicy: OutOfQuotaPolicy.runAsNonExpeditedWorkRequest,
      );
    } catch (e) {
      debugPrint('[DownloadService] workmanager タスク登録失敗: $e');
    }
  }

  /// キューの長さ（pending + running）。
  Future<int> get queueLength async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      "SELECT COUNT(*) as cnt FROM download_queue_groups WHERE status IN ('pending', 'running')",
    );
    // COUNT(*) の結果は最初の行の最初のカラム
    return (rows.first['cnt'] as int?) ?? 0;
  }
}
