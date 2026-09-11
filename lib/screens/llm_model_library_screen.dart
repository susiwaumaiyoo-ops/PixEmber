// モデルライブラリ画面（M3）。
//
// 設定 → ローカルAI（実験）→「モデルライブラリ」から開く。
// - 推奨モデル: assets/llm_models.json の厳選カタログ（未ダウンロード分）
// - ダウンロード済み: 既定モデルディレクトリにカタログのファイル名が存在する分
// - インポート済みカスタムモデル: カタログ外の GGUF
//
// 初回表示時に abliterated（安全アライメント軽減）モデルの同意ダイアログ
// を表示し、SharedPreferences に永続化する（同意なしでは画面を閉じる）。
// ダウンロードは LlmModelDownloadService（M4）が担当し、
// 本画面は「確認ダイアログ→キュー投入→進捗/キャンセル/再試行表示」を行う。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/llm_model_catalog_entry.dart';
import '../services/llm_model_catalog_service.dart';
import '../services/llm_model_download_service.dart';
import '../services/llm_model_import_service.dart';
import '../services/local_llm_service.dart';
import '../widgets/llm_model_card.dart';

/// abliterated 同意の SharedPreferences キー。
const String kLlmAbliteratedConsentKey = 'llm_abliterated_consent_v1';

/// ダウンロード済みカタログモデルのパスペア。
class _CatalogModelOnDisk {
  const _CatalogModelOnDisk({required this.entry, required this.path});

  final LlmModelCatalogEntry entry;
  final String path;
}

class LlmModelLibraryScreen extends StatefulWidget {
  const LlmModelLibraryScreen({
    super.key,
    this.catalogService,
    this.modelDirProvider,
    this.managedDirProvider,
    this.downloadService,
  });

  /// テスト注入（既定: assets/llm_models.json を読み込む実サービス）。
  final LlmModelCatalogService? catalogService;

  /// テスト注入: 既定モデルディレクトリの提供
  /// （既定: LlmModelPaths.defaultDir() = .../models/llm）。
  final Future<Directory> Function()? modelDirProvider;

  /// テスト注入: 管理ダウンロードディレクトリの提供
  /// （既定: LlmModelPaths.managedDir() = app cache /models/llm/managed）。
  /// プラグイン未登録（テスト等）で取得に失敗した場合はスキップする。
  final Future<Directory> Function()? managedDirProvider;

  /// テスト注入: ダウンロードサービス
  /// （既定: LlmModelDownloadService.instance）。
  final LlmModelDownloadService? downloadService;

  @override
  State<LlmModelLibraryScreen> createState() => _LlmModelLibraryScreenState();
}

class _LlmModelLibraryScreenState extends State<LlmModelLibraryScreen> {
  LlmModelCatalog? _catalog;
  List<String> _localFiles = const [];
  String? _selectedPath;
  bool _consentGiven = false;
  bool _loading = true;
  String? _loadError;

  StreamSubscription<LlmModelDownloadTask>? _taskSub;

  LlmModelDownloadService get _dlService =>
      widget.downloadService ?? LlmModelDownloadService.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _taskSub?.cancel();
    _taskSub = _dlService.tasks.listen((task) {
      if (!mounted) return;
      setState(() {});
      // 完了したらファイルを再収集し「ダウンロード済み」へ移動させる。
      if (task.stage == LlmModelDownloadStage.ready) {
        _load();
      }
    });
  }

  @override
  void dispose() {
    _taskSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final baseDir =
          await (widget.modelDirProvider ?? LlmModelPaths.defaultDir)();
      final managedDir = await _safeDir(
        widget.managedDirProvider ?? LlmModelPaths.managedDir,
      );
      final catalog = await (widget.catalogService ?? LlmModelCatalogService())
          .load();
      // 同期 I/O を使う: testWidgets の FakeAsync ゾーンでは非同期ファイル I/O
      // は pump されず pumpAndSettle が永遠に待機する。
      // 既定ディレクトリ（imported/ サブディレクトリ含む）と管理ディレクトリ
      // を再帰収集し重複排除する。
      final files = _collectFiles([baseDir, ?managedDir]);
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _localFiles = files;
        _selectedPath = prefs.getString(LlmModelPaths.prefsKey);
        _consentGiven = prefs.getBool(kLlmAbliteratedConsentKey) ?? false;
        _loading = false;
        _loadError = null;
      });
      if (!_consentGiven) {
        await _ensureConsent();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'モデル一覧の読み込みに失敗しました: $e';
      });
    }
  }

  /// ディレクトリ取得に失敗した場合は null（プラグイン未登録のテスト等）。
  Future<Directory?> _safeDir(Future<Directory> Function() provider) async {
    try {
      return await provider();
    } catch (_) {
      return null;
    }
  }

  /// 複数ディレクトリの *.gguf を同期 I/O で再帰収集する
  /// （重複排除・ソート済み）。
  List<String> _collectFiles(List<Directory> dirs) {
    final found = <String>{};
    for (final dir in dirs) {
      if (!dir.existsSync()) continue;
      try {
        for (final e in dir.listSync(recursive: true, followLinks: false)) {
          if (e is File && e.path.toLowerCase().endsWith('.gguf')) {
            found.add(e.path);
          }
        }
      } catch (_) {
        // 読み取りできないディレクトリはスキップ。
      }
    }
    return found.toList()..sort((a, b) => a.compareTo(b));
  }

  /// abliterated（安全アライメント軽減）モデルの初回同意。
  /// 同意しない場合は画面を閉じる。
  Future<void> _ensureConsent() async {
    if (!mounted) return;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1C),
        title: const Text(
          'abliterated モデルについて',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: const SizedBox(
          width: 300,
          child: Text(
            'モデルライブラリの推奨モデルは「abliterated」モデルです。\n\n'
            '・安全アライメントが意図的に軽減されています\n'
            '・すべての処理はこの端末内で完結します（外部送信なし）\n'
            '・実験機能であり、出力品質は保証されません\n\n'
            'ご理解のうえダウンロードください。',
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              '了解しました',
              style: TextStyle(color: Colors.pinkAccent),
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (agreed == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kLlmAbliteratedConsentKey, true);
      if (!mounted) return;
      setState(() => _consentGiven = true);
    } else {
      // 同意なしで閉じる。
      Navigator.of(context).pop();
    }
  }

  /// カタログ外 GGUF のファイル名セット。
  Set<String> get _knownCatalogFileNames {
    final catalog = _catalog;
    if (catalog == null) return const {};
    return catalog.entries.map((e) => e.fileName).toSet();
  }

  /// 未ダウンロードの推奨（カタログ）モデル。
  List<LlmModelCatalogEntry> get _pendingCatalog {
    final catalog = _catalog;
    if (catalog == null) return const [];
    final names = _localFiles.map(p.basename).toSet();
    return catalog.downloadable
        .where((e) => !names.contains(e.fileName))
        .toList(growable: false);
  }

  /// ファイル名 → 実ファイルパス（ローカルコレクション）。
  Map<String, String> get _pathByBasename => {
    for (final f in _localFiles) p.basename(f): f,
  };

  /// ダウンロード済み（カタログ）モデル（実ファイルパスで表示）。
  List<_CatalogModelOnDisk> get _downloadedCatalog {
    final catalog = _catalog;
    if (catalog == null) return const [];
    final byName = _pathByBasename;
    return catalog.downloadable
        .where((e) => byName.containsKey(e.fileName))
        .map((e) => _CatalogModelOnDisk(entry: e, path: byName[e.fileName]!))
        .toList(growable: false);
  }

  /// カスタム（取り込み）GGUF。
  List<String> get _customFiles {
    final known = _knownCatalogFileNames;
    return _localFiles
        .where((f) => !known.contains(p.basename(f)))
        .toList(growable: false);
  }

  Future<void> _selectModel(String path) async {
    try {
      final abs = await LlmModelPaths.setModelPath(path);
      if (!mounted) return;
      setState(() => _selectedPath = abs);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('モデルを選択しました: ${p.basename(abs)}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('モデルの選択に失敗しました: $e')));
    }
  }

  /// 推奨（未ダウンロード）モデルのカード（ダウンロード状態を反映）。
  Widget _pendingCard(LlmModelCatalogEntry e) {
    final t = _dlService.taskFor(e.id);
    final inFlight = t != null && (t.isQueued || t.isRunning);
    final retryable =
        t != null &&
        (t.stage == LlmModelDownloadStage.failed ||
            t.stage == LlmModelDownloadStage.cancelled);
    return LlmModelCard(
      title: e.displayName,
      subtitle:
          '${e.quantization}・${LlmModelCatalogService.formatBytes(e.expectedSizeBytes)}・${e.licenseId}',
      description: e.description,
      badge: e.isRecommended ? '推奨' : null,
      npuBadge: e.npuCompatible,
      warning: e.highRamWarning ? 'RAM使用量が大きいです（3GB以上推奨）' : null,
      progress: inFlight ? t.progress : null,
      progressLabel: inFlight || retryable ? _taskProgressLabel(t) : null,
      error: t?.stage == LlmModelDownloadStage.failed ? t?.errorMessage : null,
      onDownload: (inFlight || retryable) ? null : () => _onDownload(e),
      onRetry: retryable ? () => _dlService.retry(e.id) : null,
      onCancel: inFlight ? () => _dlService.cancel(e.id) : null,
      onDetails: () => _showEntryDetails(e),
    );
  }

  /// タスク状態の進捗ラベルテキスト。
  String? _taskProgressLabel(LlmModelDownloadTask? t) {
    if (t == null) return null;
    switch (t.stage) {
      case LlmModelDownloadStage.queued:
        return '待機中…';
      case LlmModelDownloadStage.resolving:
        return 'モデル情報を解析中…';
      case LlmModelDownloadStage.checkingCache:
        return 'キャッシュを確認中…';
      case LlmModelDownloadStage.downloading:
        final pct = (t.progress ?? 0.0) * 100;
        final total = t.totalBytes;
        final suffix = (total != null && total > 0)
            ? '（${LlmModelCatalogService.formatBytes(t.receivedBytes ?? 0)} / '
                  '${LlmModelCatalogService.formatBytes(total)}）'
            : '';
        return 'ダウンロード中 ${pct.toStringAsFixed(0)}%$suffix';
      case LlmModelDownloadStage.verifying:
        return 'SHA-256・サイズ検証中…';
      case LlmModelDownloadStage.failed:
        return null;
      case LlmModelDownloadStage.cancelled:
        return 'キャンセルしました。再試行できます。';
      case LlmModelDownloadStage.idle:
      case LlmModelDownloadStage.ready:
        return null;
    }
  }

  /// ダウンロード確認ダイアログ → キュー投入（M4）。
  Future<void> _onDownload(LlmModelCatalogEntry e) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1C),
        title: const Text(
          'ダウンロードを確認',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: SizedBox(
          width: 300,
          child: Text(
            '「${e.displayName}」を端末にダウンロードします。\n\n'
            'ダウンロードサイズ: ${LlmModelCatalogService.formatBytes(e.expectedSizeBytes)}\n'
            'RAM目安: ${LlmModelCatalogService.formatBytes(e.estimatedRamBytes)}\n\n'
            '・SHA-256 とサイズを検証して安全に保存します\n'
            '・中断しても再開できます（1件ずつ FIFO）\n'
            '・すべての処理は端末内で完結します',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.pinkAccent,
              foregroundColor: Colors.black,
            ),
            child: const Text('ダウンロードする'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      _dlService.enqueue(e);
    }
  }

  void _showEntryDetails(LlmModelCatalogEntry e) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1C),
        title: Text(
          e.displayName,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Text(
              'ファミリー: ${e.family}\n'
              'パラメータ: ${e.parameterCount}\n'
              '量子化: ${e.quantization}\n'
              'サイズ: ${LlmModelCatalogService.formatBytes(e.expectedSizeBytes)}\n'
              'RAM目安: ${LlmModelCatalogService.formatBytes(e.estimatedRamBytes)}\n'
              'ライセンス: ${e.licenseId}\n'
              'リポジトリ: ${e.repositoryId}\n'
              'Revision: ${e.revision}\n'
              'SHA-256: ${e.sha256}\n\n'
              '${e.description}\n\n'
              '${e.attribution}',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK', style: TextStyle(color: Colors.pinkAccent)),
          ),
        ],
      ),
    );
  }

  /// カスタムモデルの subtitle（ファイル名から検出した量子化形式を付与、C-3）。
  String _customSubtitle(String path) {
    final q = LlmModelImportService.detectQuantization(p.basename(path));
    return q == null ? 'カスタムモデル（ファイルピッカー取り込み）' : 'カスタムモデル（$q・ファイルピッカー取り込み）';
  }

  void _showCustomDetails(String path) {
    final size = File(path).lengthSync();
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1C),
        title: Text(
          p.basename(path),
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: SizedBox(
          width: 300,
          child: Text(
            'カスタムモデル（ファイルピッカー取り込み）\n'
            'サイズ: ${LlmModelCatalogService.formatBytes(size)}\n\n'
            'ピン留めメタデータ（リポジトリ/revision/SHA-256）はありません。',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK', style: TextStyle(color: Colors.pinkAccent)),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 16, bottom: 6),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _emptyText() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        'モデルはありません。',
        style: TextStyle(color: Colors.white38, fontSize: 12.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        iconTheme: const IconThemeData(color: Colors.white70),
        title: const Text(
          'モデルライブラリ',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.pinkAccent),
            )
          : _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _loadError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _load,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.pinkAccent,
                        foregroundColor: Colors.black,
                      ),
                      child: const Text('再読み込み'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF20242C),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.lock, size: 16, color: Colors.tealAccent),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'すべての処理は端末内で完結し、外部へ送信されません。',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                _sectionHeader('推奨モデル'),
                if (_pendingCatalog.isEmpty)
                  _emptyText()
                else
                  for (final e in _pendingCatalog) _pendingCard(e),
                _sectionHeader('ダウンロード済み'),
                if (_downloadedCatalog.isEmpty)
                  _emptyText()
                else
                  for (final m in _downloadedCatalog)
                    LlmModelCard(
                      title: m.entry.displayName,
                      subtitle:
                          '${m.entry.quantization}・ダウンロード済み・${p.basename(m.path)}',
                      description: m.entry.description,
                      badge: 'ダウンロード済み',
                      npuBadge: m.entry.npuCompatible,
                      warning: m.entry.highRamWarning
                          ? 'RAM使用量が大きいです（3GB以上推奨）'
                          : null,
                      isSelected: _selectedPath == m.path,
                      onSelect: () => _selectModel(m.path),
                      onDetails: () => _showEntryDetails(m.entry),
                    ),
                _sectionHeader('インポート済みカスタムモデル'),
                if (_customFiles.isEmpty)
                  _emptyText()
                else
                  for (final f in _customFiles)
                    LlmModelCard(
                      title: p.basename(f),
                      subtitle: _customSubtitle(f),
                      badge: 'カスタム',
                      npuBadge: LlmModelImportService.npuCompatibleForQuant(
                        LlmModelImportService.detectQuantization(p.basename(f)),
                      ),
                      isSelected: _selectedPath == f,
                      onSelect: () => _selectModel(f),
                      onDetails: () => _showCustomDetails(f),
                    ),
              ],
            ),
    );
  }
}
