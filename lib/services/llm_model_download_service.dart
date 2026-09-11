// LLM モデルのアプリ内ダウンロードサービス（M4）。
//
// 純Dart再実装の DefaultModelDownloadManager（ModelDownloadManager 実装・
// llm_model_download_manager.dart）を使い、カタログ（M2）の「検証済み」エントリ（isVerified: pin revision +
// SHA-256 + 正確なサイズ）を HuggingFace の pin revision から端末にダウンロードする。
//
// 仕様:
// - 同時ダウンロードは 1 件。それ以上は FIFO キューで待機。
// - 中断は HTTP Range（.part ファイル）で再開可能（マネージャ側で実装）。
// - SHA-256 検証はマネージャが実施。本サービスは加えてカタログの正確な
//   サイズ検証を行う（不一致は failed）。
// - 保存先: LlmModelPaths.managedDir()
//   （= getApplicationCacheDirectory()/models/llm/managed）。ファイルは
//   マネージャの既定レイアウト {safeStem}-{cacheKey[:12]}/ 配下に入り、
//   コピーせずその場で利用する。
// - 未検証エントリ（isVerified != true）の enqueue は ArgumentError で拒否。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'llm_model_download_manager.dart'
    show
        DefaultModelDownloadManager,
        ModelCacheEntry,
        ModelDownloadCancelToken,
        ModelDownloadManager,
        ModelDownloadProgress,
        ModelLoadOptions,
        ModelSource;

import '../models/llm_model_catalog_entry.dart';
import 'local_llm_service.dart' show LlmModelPaths;

/// LLM モデルダウンロードのステージ。
enum LlmModelDownloadStage {
  /// 初期状態（タスク未作成）。
  idle,

  /// キュー待機中。
  queued,

  /// ソース解決中（pin revision の HuggingFace URL 構築）。
  resolving,

  /// キャッシュ確認中（マネージャの cacheKey ルックアップ）。
  checkingCache,

  /// ダウンロード中（HTTP Range / .part / 再開）。
  downloading,

  /// 検証中（SHA-256 はマネージャ・サイズは本サービス）。
  verifying,

  /// 完了（ローカルファイル利用可能）。
  ready,

  /// 失敗（retry で再開可能）。
  failed,

  /// キャンセル（retry で再開可能）。
  cancelled,
}

/// ダウンロードタスクのスナップショット（UI 表示用・不変）。
class LlmModelDownloadTask {
  const LlmModelDownloadTask({
    required this.entryId,
    required this.displayName,
    required this.stage,
    this.progress,
    this.receivedBytes,
    this.totalBytes,
    this.errorMessage,
    this.localPath,
  });

  /// カタログエントリ ID（LlmModelCatalogEntry.id）。
  final String entryId;

  final String displayName;

  final LlmModelDownloadStage stage;

  /// 進捗（0.0-1.0）。unknown の場合は null。
  final double? progress;

  final int? receivedBytes;
  final int? totalBytes;

  /// failed 時のユーザー向けエラーメッセージ。
  final String? errorMessage;

  /// ready の場合のローカル GGUF パス。
  final String? localPath;

  bool get isQueued => stage == LlmModelDownloadStage.queued;

  bool get isRunning =>
      stage == LlmModelDownloadStage.resolving ||
      stage == LlmModelDownloadStage.checkingCache ||
      stage == LlmModelDownloadStage.downloading ||
      stage == LlmModelDownloadStage.verifying;

  bool get isDone =>
      stage == LlmModelDownloadStage.ready ||
      stage == LlmModelDownloadStage.failed ||
      stage == LlmModelDownloadStage.cancelled;
}

/// アプリ生存期間のシングルトンサービス（画面は [instance] を使用）。
class LlmModelDownloadService {
  LlmModelDownloadService({this.manager, this.managedDirProvider});

  static LlmModelDownloadService? _instance;

  /// アプリ生存期間のシングルトン（初回アクセス時に生成）。
  static LlmModelDownloadService get instance =>
      _instance ??= LlmModelDownloadService();

  /// テスト用: シングルトンを破棄。
  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }

  /// テスト注入: ModelDownloadManager（既定: DefaultModelDownloadManager）。
  final ModelDownloadManager? manager;

  /// 管理ダウンロード先ディレクトリの提供
  /// （既定: LlmModelPaths.managedDir = app cache /models/llm/managed）。
  final Future<Directory> Function()? managedDirProvider;

  final Map<String, LlmModelCatalogEntry> _entries = {};
  final Map<String, LlmModelDownloadTask> _tasks = {};
  final List<String> _queue = [];
  final Map<String, ModelDownloadCancelToken> _tokens = {};
  String? _activeId;

  StreamController<LlmModelDownloadTask>? _controller;

  /// タスク状態変化のブロードキャストストリーム（最新スナップショット）。
  Stream<LlmModelDownloadTask> get tasks {
    final c = _controller ??=
        StreamController<LlmModelDownloadTask>.broadcast();
    return c.stream;
  }

  /// [entryId] の現在のタスク（未作成なら null）。
  LlmModelDownloadTask? taskFor(String entryId) => _tasks[entryId];

  /// [entry] のダウンロードを開始（または FIFO キューに追加）する。
  ///
  /// 待機中・実行中・ready の場合は何もしない（重複防止）。
  /// failed / cancelled の場合は再実行として扱う。
  /// 未検証エントリ（[LlmModelCatalogEntry.isVerified] != true）は
  /// [ArgumentError] を送出する（仕様: 未検証モデルの自動DL禁止）。
  void enqueue(LlmModelCatalogEntry entry) {
    if (!entry.isVerified) {
      throw ArgumentError.value(
        entry.id,
        'entry',
        '未検証モデル（pin/SHA-256/サイズ不完全）はダウンロードできません。',
      );
    }
    final existing = _tasks[entry.id];
    if (existing != null && !existing.isDone) return;
    if (existing?.stage == LlmModelDownloadStage.ready) return;
    _entries[entry.id] = entry;
    _tasks[entry.id] = _queuedTask(entry);
    if (!_queue.contains(entry.id)) _queue.add(entry.id);
    _emit();
    _pump();
  }

  LlmModelDownloadTask _queuedTask(LlmModelCatalogEntry entry) =>
      LlmModelDownloadTask(
        entryId: entry.id,
        displayName: entry.displayName,
        stage: LlmModelDownloadStage.queued,
      );

  /// タスクをキャンセルする。
  ///
  /// 実行中: 協力型キャンセル（.part は保持され再開可能）。
  /// 待機中: キューから除外して cancelled へ。
  void cancel(String entryId) {
    final task = _tasks[entryId];
    if (task == null || task.isDone) return;
    if (task.isRunning) {
      _tokens[entryId]?.cancel();
    } else if (task.isQueued) {
      _queue.remove(entryId);
      _update(entryId, stage: LlmModelDownloadStage.cancelled);
    }
  }

  /// failed / cancelled のタスクを再キューイングする。
  void retry(String entryId) {
    final task = _tasks[entryId];
    if (task == null) return;
    if (task.stage != LlmModelDownloadStage.failed &&
        task.stage != LlmModelDownloadStage.cancelled) {
      return;
    }
    _queue.remove(entryId);
    _tasks[entryId] = LlmModelDownloadTask(
      entryId: entryId,
      displayName: task.displayName,
      stage: LlmModelDownloadStage.queued,
    );
    _queue.add(entryId);
    _emit();
    _pump();
  }

  /// キュー先頭を実行に移す（同時 1 件）。
  void _pump() {
    if (_activeId != null) return;
    while (true) {
      if (_queue.isEmpty) return;
      final next = _queue.first;
      final entry = _entries[next];
      if (entry == null) {
        _queue.removeAt(0);
        continue;
      }
      _queue.removeAt(0);
      _activeId = next;
      _run(next, entry).whenComplete(() {
        if (_activeId == next) _activeId = null;
        _pump();
      });
      return;
    }
  }

  Future<void> _run(String entryId, LlmModelCatalogEntry entry) async {
    final token = ModelDownloadCancelToken();
    _tokens[entryId] = token;
    try {
      // 1) ソース解決（pin revision の HuggingFace URL）。
      _update(
        entryId,
        stage: LlmModelDownloadStage.resolving,
        clearError: true,
        clearProgress: true,
      );
      final source = ModelSource.huggingFace(
        repoId: entry.repositoryId,
        filePath: entry.fileName,
        revision: entry.revision,
      );

      // 2) 管理ディレクトリの解決（存在すれば作成）。
      final dir = await (managedDirProvider ?? LlmModelPaths.managedDir)();

      // 3) キャッシュ確認（同一 cacheKey かつサイズ一致なら再利用）。
      _update(entryId, stage: LlmModelDownloadStage.checkingCache);
      ModelCacheEntry? cached;
      try {
        cached = await _managerFor().get(
          source.cacheKey,
          cacheDirectory: dir.path,
        );
      } catch (_) {
        cached = null;
      }
      if (cached != null && File(cached.filePath).existsSync()) {
        final cachedSize = File(cached.filePath).lengthSync();
        if (cachedSize == entry.expectedSizeBytes) {
          _update(
            entryId,
            stage: LlmModelDownloadStage.ready,
            progress: 1.0,
            receivedBytes: cachedSize,
            totalBytes: entry.expectedSizeBytes,
            localPath: cached.filePath,
          );
          return;
        }
        // サイズ不一致 → キャッシュミスとして再ダウンロードへ進む。
      }

      // 4) ダウンロード（Range 再開 / .part / SHA-256 検証はマネージャ側）。
      _update(entryId, stage: LlmModelDownloadStage.downloading);
      final downloaded = await _managerFor().ensureModel(
        source,
        options: ModelLoadOptions(
          cacheDirectory: dir.path,
          sha256: entry.sha256,
          resume: true,
          cancelToken: token,
        ),
        onProgress: (ModelDownloadProgress progress) {
          if (token.isCancelled) return;
          _update(
            entryId,
            progress: progress.fraction,
            receivedBytes: progress.receivedBytes,
            totalBytes: progress.totalBytes,
          );
        },
      );

      // 5) サイズ検証（カタログの正確なバイト数）。
      _update(entryId, stage: LlmModelDownloadStage.verifying);
      final file = File(downloaded.filePath);
      if (!file.existsSync()) {
        throw StateError('ダウンロードされたファイルが存在しません。');
      }
      final size = file.lengthSync();
      if (size != entry.expectedSizeBytes) {
        throw StateError(
          'サイズ不一致（期待 ${entry.expectedSizeBytes} バイト / '
          '実際 $size バイト）。',
        );
      }
      _update(
        entryId,
        stage: LlmModelDownloadStage.ready,
        progress: 1.0,
        receivedBytes: size,
        totalBytes: entry.expectedSizeBytes,
        localPath: downloaded.filePath,
      );
    } catch (e) {
      if (token.isCancelled) {
        _update(
          entryId,
          stage: LlmModelDownloadStage.cancelled,
          errorMessage: 'ダウンロードをキャンセルしました。再開できます。',
        );
      } else {
        _update(
          entryId,
          stage: LlmModelDownloadStage.failed,
          errorMessage: _friendlyError(e),
        );
      }
    } finally {
      _tokens.remove(entryId);
    }
  }

  ModelDownloadManager _managerFor() =>
      manager ?? DefaultModelDownloadManager();

  void _update(
    String entryId, {
    LlmModelDownloadStage? stage,
    double? progress,
    int? receivedBytes,
    int? totalBytes,
    String? errorMessage,
    String? localPath,
    bool clearError = false,
    bool clearProgress = false,
  }) {
    final task = _tasks[entryId];
    if (task == null) return;
    _tasks[entryId] = LlmModelDownloadTask(
      entryId: entryId,
      displayName: task.displayName,
      stage: stage ?? task.stage,
      progress: clearProgress ? null : (progress ?? task.progress),
      receivedBytes: clearProgress
          ? null
          : (receivedBytes ?? task.receivedBytes),
      totalBytes: clearProgress ? null : (totalBytes ?? task.totalBytes),
      errorMessage: clearError ? null : (errorMessage ?? task.errorMessage),
      localPath: localPath ?? task.localPath,
    );
    _emit();
  }

  void _emit() {
    final c = _controller;
    if (c == null || c.isClosed) return;
    for (final t in _tasks.values) {
      c.add(t);
    }
  }

  /// 例外を UI 表示用の短いメッセージへ（内部詳細・認証情報は出さない）。
  static String _friendlyError(Object e) {
    final s = e.toString();
    final clipped = s.length > 160 ? '${s.substring(0, 160)}…' : s;
    return 'ダウンロードに失敗しました: $clipped';
  }
}
