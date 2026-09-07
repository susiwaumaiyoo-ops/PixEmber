// モデルライブラリ画面（M3）。
//
// 設定 → ローカルAI（実験）→「モデルライブラリ」から開く。
// - 推奨モデル: assets/llm_models.json の厳選カタログ（未ダウンロード分）
// - ダウンロード済み: 既定モデルディレクトリにカタログのファイル名が存在する分
// - インポート済みカスタムモデル: カタログ外の GGUF
//
// 初回表示時に abliterated（安全アライメント軽減）モデルの同意ダイアログ
// を表示し、SharedPreferences に永続化する（同意なしでは画面を閉じる）。
// ダウンロード本体は M4 で実装。本画面の「ダウンロード」は案内のみ。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/llm_model_catalog_entry.dart';
import '../services/llm_model_catalog_service.dart';
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
  });

  /// テスト注入（既定: assets/llm_models.json を読み込む実サービス）。
  final LlmModelCatalogService? catalogService;

  /// テスト注入: モデルファイルのディレクトリ
  /// （既定: LlmModelPaths.defaultDir() = .../models/llm）。
  final Future<Directory> Function()? modelDirProvider;

  @override
  State<LlmModelLibraryScreen> createState() => _LlmModelLibraryScreenState();
}

class _LlmModelLibraryScreenState extends State<LlmModelLibraryScreen> {
  LlmModelCatalog? _catalog;
  String? _modelDir;
  List<String> _localFiles = const [];
  String? _selectedPath;
  bool _consentGiven = false;
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dir = await (widget.modelDirProvider ?? LlmModelPaths.defaultDir)();
      final catalog = await (widget.catalogService ?? LlmModelCatalogService())
          .load();
      // 同期 I/O を使う: testWidgets の FakeAsync ゾーンでは非同期ファイル I/O
      // は pump されず pumpAndSettle が永遠に待機する。
      final files = <String>[
        if (dir.existsSync())
          for (final e in dir.listSync())
            if (e is File && e.path.toLowerCase().endsWith('.gguf')) e.path,
      ]..sort((a, b) => a.compareTo(b));
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _modelDir = dir.path;
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

  /// ダウンロード済み（カタログ）モデル。
  List<_CatalogModelOnDisk> get _downloadedCatalog {
    final catalog = _catalog;
    final dir = _modelDir;
    if (catalog == null || dir == null) return const [];
    final names = _localFiles.map(p.basename).toSet();
    return catalog.downloadable
        .where((e) => names.contains(e.fileName))
        .map(
          (e) => _CatalogModelOnDisk(entry: e, path: p.join(dir, e.fileName)),
        )
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

  /// ダウンロード（M3 では案内のみ。実装は M4）。
  void _onDownload(LlmModelCatalogEntry e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '「${e.displayName}」のアプリ内ダウンロードは今後の更新で利用できます。'
          '現在は「小説AI要約（実験）」のモデル選択シートからGGUFを取り込めます。',
        ),
      ),
    );
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
                  for (final e in _pendingCatalog)
                    LlmModelCard(
                      title: e.displayName,
                      subtitle:
                          '${e.quantization}・${LlmModelCatalogService.formatBytes(e.expectedSizeBytes)}・${e.licenseId}',
                      description: e.description,
                      badge: e.isRecommended ? '推奨' : null,
                      warning: e.highRamWarning
                          ? 'RAM使用量が大きいです（3GB以上推奨）'
                          : null,
                      onDownload: () => _onDownload(e),
                      onDetails: () => _showEntryDetails(e),
                    ),
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
                      subtitle: 'カスタムモデル（ファイルピッカー取り込み）',
                      badge: 'カスタム',
                      isSelected: _selectedPath == f,
                      onSelect: () => _selectModel(f),
                      onDetails: () => _showCustomDetails(f),
                    ),
              ],
            ),
    );
  }
}
