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

/// 例外をエラーコード文字列に分類する（純粋関数・単体テスト可能）。
///
/// 既知でない型は例外型名（小文字）を返すため、
/// 一般的な 'unknown' は返さなくなる（例: 'unsupportederror'）。
String classifyDownloadError(Object e) {
  if (e is PixivAuthException) return 'auth_401';
  if (e is PixivForbiddenException) return 'forbidden_403';
  if (e is PixivNotFoundException) return 'not_found_404';
  if (e is PixivRateLimitException) return 'rate_limit_429';
  if (e is SocketException ||
      e is TimeoutException ||
      e is http.ClientException) {
    return 'network_error';
  }
  if (e is UnsupportedError) return 'unsupported_error';
  if (e is FileSystemException || e is PathNotFoundException) {
    return 'file_error';
  }
  return e.runtimeType.toString().toLowerCase();
}

/// DB に保存するエラーメッセージを構築する。
///
/// 例外型名・メッセージ・スタックトレース先頭（3行）を含め、
/// 最大500文字に切り詰める。
String buildDownloadErrorMessage(Object e, StackTrace st) {
  final stackHead = st.toString().split('\n').take(3).join('\n');
  final message = '${e.runtimeType}: ${e.toString()}\n$stackHead';
  return message.length > 500 ? message.substring(0, 500) : message;
}

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
    debugPrint(
      '[DownloadService] enqueue: illust=${illust.id} '
      'pages=${images.length} group=$groupId',
    );

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
    debugPrint('[DownloadService] enqueue: ugoira=$illustId group=$groupId');

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
    debugPrint('[DownloadService] enqueue: novel=${novel.id} group=$groupId');

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
    // 親グループが pending または running の子アイテムを取得する。
    // 注意: 初回取得でグループが running に遷移するため、条件を
    // dg.status='pending' のみにすると複数ページ作品の残りページが
    // 永久に取得されず completed に到達しない（バグ修正）。
    final rows = await db.rawQuery('''
      SELECT dq.*
      FROM download_queues dq
      INNER JOIN download_queue_groups dg ON dq.group_id = dg.id
      WHERE dq.status = 'pending' AND dg.status IN ('pending', 'running')
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
    debugPrint(
      '[DownloadService] runningへ: item=$itemId group=$groupId '
      'type=${item['work_type']} page=${item['page_index']} '
      'url=${(item['url'] as String?)?.length ?? 0}bytes',
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

    debugPrint(
      '[DownloadService] ダウンロード開始: item=$itemId group=$groupId '
      'work=$workId type=$workType',
    );
    try {
      // クエリ結果の Map は読み取り専用なので変更しない。
      // local_path はハンドラの戻り値として取得し DB に記録する。
      String localPath;
      if (workType == 'illust') {
        localPath = await _downloadIllustItem(item);
      } else if (workType == 'ugoira') {
        localPath = await _downloadUgoiraItem(item);
      } else if (workType == 'novel') {
        localPath = await _downloadNovelItem(item);
      } else {
        throw Exception('サポートされないダウンロード種別: $workType');
      }

      // アイテム完了
      await _db.updateDownloadQueueItem(
        itemId: itemId,
        status: 'completed',
        localPath: localPath,
      );
      debugPrint('[DownloadService] completed: item=$itemId path=$localPath');
      await _updateGroupProgress(groupId);
    } catch (e, st) {
      final errorCode = classifyDownloadError(e);
      final errorMsg = buildDownloadErrorMessage(e, st);
      debugPrint('[DownloadService] エラー: item=$itemId code=$errorCode $e\n$st');

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
        debugPrint(
          '[DownloadService] リトライ: item=$itemId '
          '(${retryCount + 1}/$maxRetry)',
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
  /// 最終保存パスを返す（クエリ結果の Map は読み取り専用なので変更しない）。
  Future<String> _downloadIllustItem(Map<String, dynamic> item) async {
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
    );

    // DB に local_path を記録（クエリ結果 Map の変更は行わない）
    await _db.updateDownloadQueueItem(itemId: itemId, localPath: finalPath);
    return finalPath;
  }

  /// うごイラ ZIP をダウンロードする。
  /// GIF 変換はスコープ外。ZIP をそのまま保存する。
  /// 最終保存パスを返す（クエリ結果の Map は読み取り専用なので変更しない）。
  Future<String> _downloadUgoiraItem(Map<String, dynamic> item) async {
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
    );

    await _db.updateDownloadQueueItem(itemId: itemId, localPath: finalPath);
    return finalPath;
  }

  /// 小説本文を取得して novel_text テーブルに保存する。
  /// 保存先識別子（`novel_text:<workId>`）を返す。
  Future<String> _downloadNovelItem(Map<String, dynamic> item) async {
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
    return 'novel_text:$workId';
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
  }) async {
    final tempFile = File(tempPath);

    // 書き込み前に保存ディレクトリの存在を確保する（防御的）。
    // 実機ではディレクトリが存在しない場合、一時ファイルの作成に失敗し、
    // rename が PathNotFoundException（ENOENT, errno=2）を投じる。
    final targetDir = tempFile.parent;
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
      debugPrint('[DownloadService] ディレクトリ作成: ${targetDir.path}');
    }

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

    // レスポンスヘッダ待ちのタイムアウト（接続確立〜応答ヘッダ受信）。
    // タイムアウトなしだとサーバーが応答しなくなった場合無期限にハングし、
    // running のまま完了も失敗もエラーも出ない状態になる（バグ修正）。
    final streamedResponse = await client
        .send(request)
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw TimeoutException('レスポンス待ちタイムアウト（30秒）: $url'),
        );

    final statusCode = streamedResponse.statusCode;
    debugPrint(
      '[DownloadService] HTTP送信完了: item=$itemId status=$statusCode '
      'size=${streamedResponse.contentLength ?? -1} '
      'range=${existingBytes > 0}',
    );

    // 416 Range Not Satisfiable: 一時ファイルが完全なのでそのままリネーム
    if (statusCode == 416) {
      if (!await tempFile.exists()) {
        throw Exception('416 受信だが一時ファイルが存在しません: $tempPath');
      }
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
    late StreamSubscription<List<int>> subscription;
    var sinkClosed = false;

    // 二重 close 防止（inactivity タイマーと onDone の両方が close しようとする）。
    Future<void> closeSinkOnce() async {
      if (sinkClosed) return;
      sinkClosed = true;
      await sink.close();
    }

    // 失敗時の一時ファイル掃除（ベストエフォート）。
    // 0 バイト（壊れた空ファイル）は削除。部分書き込みは Range リジューム用に保持。
    Future<void> cleanupTemp() async {
      try {
        if (!await tempFile.exists()) return;
        if (await tempFile.length() == 0) {
          await tempFile.delete();
          debugPrint('[DownloadService] 一時ファイルを削除: $tempPath');
        }
      } catch (_) {}
    }

    // データ受信のインアクティビティ監視。応答ヘッダ後のボディ受信が
    // 60秒間停滞したらタイムアウトとして扱い、running 永久ハングを防ぐ。
    const inactivityTimeout = Duration(seconds: 60);
    Timer? inactivityTimer;
    var receivedBytes = 0;
    var inactivityFired = false;

    void resetInactivityTimer() {
      inactivityTimer?.cancel();
      inactivityTimer = Timer(inactivityTimeout, () async {
        inactivityFired = true;
        final err = TimeoutException('ダウンロード中タイムアウト（60秒間データなし）: $url');
        await subscription.cancel();
        await closeSinkOnce();
        if (!completer.isCompleted) {
          completer.completeError(err);
        }
      });
    }

    resetInactivityTimer();

    bool writeFailed = false;
    Object? writeError;
    try {
      subscription = streamedResponse.stream.listen(
        (List<int> data) async {
          if (_cancelRequested.contains(itemId)) {
            inactivityTimer?.cancel();
            await subscription.cancel();
            await closeSinkOnce();
            if (!completer.isCompleted) {
              completer.completeError(Exception('ダウンロードがキャンセルされました'));
            }
            return;
          }
          resetInactivityTimer();
          receivedBytes += data.length;
          // writeFromSync は同期 API（await 不要・fire-and-forget なし）。
          sink.writeFromSync(data);
        },
        onError: (Object e) {
          inactivityTimer?.cancel();
          if (!completer.isCompleted) {
            completer.completeError(e);
          }
        },
        onDone: () async {
          inactivityTimer?.cancel();
          await closeSinkOnce();
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
        cancelOnError: true,
      );

      await completer.future;
    } catch (e) {
      writeFailed = true;
      writeError = e;
    } finally {
      inactivityTimer?.cancel();
      await subscription.cancel();
      await closeSinkOnce();
    }

    if (inactivityFired) {
      await cleanupTemp();
      throw TimeoutException('ダウンロード中タイムアウト（60秒間データなし）: $url');
    }
    if (writeFailed) {
      // 書き込み失敗（キャンセル含む）は一時ファイルを掃除して再送出。
      await cleanupTemp();
      throw writeError!;
    }

    // リネーム前に一時ファイルの存在を確認（書き込み未完了を検出）。
    if (!await tempFile.exists()) {
      throw Exception('一時ファイルの書き込みに失敗しました: $tempPath');
    }

    debugPrint(
      '[DownloadService] 書き込み完了: item=$itemId '
      'bytes=$receivedBytes -> $tempPath',
    );

    // アトミックリネーム（既に最終パスにファイルがある場合は上書き）。
    // リネーム失敗時も一時ファイルを掃除して例外は伝播。
    try {
      if (await File(finalPath).exists()) {
        await File(finalPath).delete();
      }
      await tempFile.rename(finalPath);
    } catch (e) {
      await cleanupTemp();
      rethrow;
    }
    debugPrint('[DownloadService] リネーム完了: item=$itemId -> $finalPath');
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
      debugPrint('[DownloadService] グループ完了: group=$groupId $completed/$total');
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

  /// エラーコードがリトライ可能かどうか。
  bool _isRetryable(String errorCode) {
    switch (errorCode) {
      case 'auth_401':
      case 'rate_limit_429':
      case 'network_error':
        return true;
      case 'forbidden_403':
      case 'not_found_404':
      case 'unsupported_error':
      case 'file_error':
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
