import 'package:flutter/material.dart';
import '../services/ai_index_maintenance_service.dart';
import '../services/rerank_model_manager.dart';
import '../services/ruri_model_manager.dart';

/// タブレット判定閾値（feeling_discovery_screen.dart と同一値）。
const double _kTabletBreakpoint = 700.0;
const double _kTabletContentMaxWidth = 800.0;

/// AIインデックス管理画面（診断・修復）。
///
/// 元々 [FeelingDiscoveryScreen] に常駐していた診断・修復UIを分離した。
/// この画面を開いたときにのみ診断を実行する（検索画面側での自動診断は廃止）。
class AiIndexMaintenanceScreen extends StatefulWidget {
  const AiIndexMaintenanceScreen({super.key});

  @override
  State<AiIndexMaintenanceScreen> createState() =>
      _AiIndexMaintenanceScreenState();
}

class _AiIndexMaintenanceScreenState extends State<AiIndexMaintenanceScreen> {
  AiIndexDiagnosisResult? _diagnosis;
  bool _isDiagnosing = false;
  bool _isRepairing = false;
  String _repairStatus = '';
  int _repairCurrent = 0;
  int _repairTotal = 0;
  final ValueNotifier<bool> _repairCancel = ValueNotifier<bool>(false);

  // Reranker（高精度モード用）の導入状態
  bool _rerankModelReady = false;
  // reranker が依存するトークナイザ（embedding 側）の導入状態（K3）
  bool _rerankTokenizerReady = false;
  bool _isRerankDownloading = false;
  int _rerankReceived = 0;
  int _rerankTotal = 0;
  String? _rerankDlError;
  ValueNotifier<bool>? _rerankDlCancel;
  String _rerankStatus = '';

  @override
  void initState() {
    super.initState();
    // 画面を開いたときだけ診断する（検索画面側の自動診断は廃止）。
    _runDiagnose();
    _refreshRerankState();
    _refreshModelStates();
  }

  @override
  void dispose() {
    _repairCancel.dispose();
    _rerankDlCancel?.dispose();
    _modelDlCancel?.dispose();
    super.dispose();
  }

  /// Reranker モデルの導入状態を更新する。
  Future<void> _refreshRerankState() async {
    final mgr = RerankModelManager();
    final ready = await mgr.isModelReady();
    final tokReady = await mgr.isTokenizerAvailable();
    if (!mounted) return;
    setState(() {
      _rerankModelReady = ready;
      _rerankTokenizerReady = tokReady;
    });
  }

  /// Reranker モデルをダウンロードする。
  Future<void> _startRerankDownload() async {
    if (_isRerankDownloading) return;
    final cancel = ValueNotifier<bool>(false);
    _rerankDlCancel?.dispose();
    _rerankDlCancel = cancel;
    setState(() {
      _isRerankDownloading = true;
      _rerankDlError = null;
      _rerankReceived = 0;
      _rerankTotal = 0;
      _rerankStatus = '';
    });
    try {
      await RerankModelManager().download(
        cancel: cancel,
        onProgress: (received, total, label) {
          if (!mounted) return;
          setState(() {
            _rerankReceived = received;
            _rerankTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() => _isRerankDownloading = false);
      await _refreshRerankState();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isRerankDownloading = false;
        _rerankDlError = e.toString();
      });
    }
  }

  void _cancelRerankDownload() {
    _rerankDlCancel?.value = true;
  }

  Future<void> _deleteRerankModel() async {
    if (_isRerankDownloading) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rerankerを削除'),
        content: const Text(
          '高精度モード用の Reranker モデルを削除します。\n'
          '削除しても意味検索（embedding）自体はそのまま使えます。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await RerankModelManager().deleteAll();
    await _refreshRerankState();
  }

  // ---- AI モデル（Ruri v3）管理状態 ----
  Map<String, bool> _modelDownloaded = <String, bool>{};
  String? _downloadingModelId;
  int _modelReceived = 0;
  int _modelTotal = 0;
  String? _modelDlError;
  ValueNotifier<bool>? _modelDlCancel;

  /// 各 AI モデルの導入状態・アクティブモデルを更新する。
  Future<void> _refreshModelStates() async {
    final mgr = RuriModelManager();
    await mgr.getActiveModelId();
    if (!mounted) return;
    final downloaded = <String, bool>{};
    for (final spec in RuriModelSpec.all) {
      downloaded[spec.id] = await mgr.isModelPresentFor(spec.id);
    }
    if (!mounted) return;
    setState(() {
      _modelDownloaded = downloaded;
    });
  }

  /// 指定モデルをダウンロードする。
  Future<void> _startModelDownload(String id) async {
    if (_downloadingModelId != null) return;
    final cancel = ValueNotifier<bool>(false);
    _modelDlCancel?.dispose();
    _modelDlCancel = cancel;
    setState(() {
      _downloadingModelId = id;
      _modelDlError = null;
      _modelReceived = 0;
      _modelTotal = 0;
    });
    try {
      await RuriModelManager().downloadModel(
        id,
        cancel: cancel,
        onProgress: (received, total, label) {
          if (!mounted) return;
          setState(() {
            _modelReceived = received;
            _modelTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() => _downloadingModelId = null);
      await _refreshModelStates();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloadingModelId = null;
        _modelDlError = e.toString();
      });
    }
  }

  void _cancelModelDownload() {
    _modelDlCancel?.value = true;
  }

  /// アクティブモデルを切り替える（既存インデックスは非互換になるため再インデックス確認）。
  Future<void> _switchModel(String id) async {
    if (_downloadingModelId != null) return;
    if (_isRepairing || _isDiagnosing) return;
    if (RuriModelManager.embeddingModelId == id) return;
    if (!(_modelDownloaded[id] ?? false)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AIモデルを切り替え'),
        content: Text(
          '「${RuriModelSpec.specById(id).displayName}」に切り替えます。\n'
          '切り替え後、既存の意味検索インデックスは互換性がなくなるため再インデックス（埋め込み再生成）が必要です。\n'
          'いま再インデックスを実行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('切り替え＋再インデックス'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await RuriModelManager().setActiveModelId(id);
    if (!mounted) return;
    await _refreshModelStates();
    await _runLocalRepair();
  }

  /// 指定モデルを削除する（アクティブモデルは削除不可）。
  Future<void> _deleteModel(String id) async {
    if (_downloadingModelId != null) return;
    if (RuriModelManager.embeddingModelId == id) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('アクティブなモデルは削除できません。ほかのモデルに切り替えてから削除してください。'),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AIモデルを削除'),
        content: Text(
          '「${RuriModelSpec.specById(id).displayName}」を削除します。\n'
          '再度使うには再ダウンロードが必要です。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await RuriModelManager().deleteModel(id);
    await _refreshModelStates();
  }

  /// アクティブ以外のすべてのモデルを削除する。
  Future<void> _deleteInactiveModels() async {
    if (_downloadingModelId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未使用モデルを一括削除'),
        content: const Text(
          'アクティブでない AI モデルをすべて削除します。\n'
          '削除してもアクティブなモデルでの意味検索はそのまま使えます。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await RuriModelManager().deleteInactiveModels();
    await _refreshModelStates();
  }

  String _formatModelBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// AI モデル（Ruri v3）管理 UI。
  Widget _buildModelManagementSection(ColorScheme colorScheme) {
    final subColor = colorScheme.onSurfaceVariant;
    final activeId = RuriModelManager.embeddingModelId;
    final cards = <Widget>[];
    for (final spec in RuriModelSpec.all) {
      final isActive = activeId == spec.id;
      final downloaded = _modelDownloaded[spec.id] ?? false;
      final isDownloading = _downloadingModelId == spec.id;
      final progress = (_modelTotal > 0 && isDownloading)
          ? (_modelReceived / _modelTotal).clamp(0.0, 1.0)
          : null;
      Widget statusChip;
      if (isActive) {
        statusChip = _modelChip('アクティブ', colorScheme.secondary);
      } else if (isDownloading) {
        statusChip = _modelChip('ダウンロード中', colorScheme.tertiary);
      } else if (downloaded) {
        statusChip = _modelChip('導入済み', colorScheme.primaryContainer);
      } else {
        statusChip = _modelChip('未ダウンロード', colorScheme.onSurfaceVariant);
      }
      cards.add(
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(8),
            border: isActive
                ? Border.all(color: colorScheme.secondary, width: 1.5)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      spec.displayName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  statusChip,
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '次元: ${spec.dimension} ・ サイズ: ${spec.sizeLabel} ・ ${_formatModelBytes(spec.modelSizeBytes)}',
                style: TextStyle(fontSize: 12, color: subColor),
              ),
              const SizedBox(height: 2),
              Text(spec.notes, style: TextStyle(fontSize: 11, color: subColor)),
              if (isDownloading && progress != null) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 4),
                Text(
                  '${_formatModelBytes(_modelReceived)} / ${_formatModelBytes(_modelTotal)}',
                  style: TextStyle(fontSize: 11, color: subColor),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!downloaded && !isDownloading)
                    ElevatedButton.icon(
                      onPressed: () => _startModelDownload(spec.id),
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('ダウンロード'),
                    )
                  else if (isDownloading)
                    TextButton.icon(
                      onPressed: _cancelModelDownload,
                      icon: const Icon(Icons.stop, size: 16),
                      label: const Text('キャンセル'),
                    )
                  else ...[
                    if (!isActive)
                      ElevatedButton.icon(
                        onPressed: () => _switchModel(spec.id),
                        icon: const Icon(Icons.swap_horiz, size: 16),
                        label: const Text('切り替え'),
                      ),
                    if (!isActive)
                      TextButton.icon(
                        onPressed: () => _deleteModel(spec.id),
                        icon: const Icon(Icons.delete, size: 16),
                        label: const Text('削除'),
                      ),
                  ],
                ],
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.model_training, color: colorScheme.secondary, size: 22),
            const SizedBox(width: 8),
            const Text(
              'AIモデル（Ruri v3）',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            if (_modelDownloaded.values.where((v) => v).length > 1)
              TextButton.icon(
                onPressed: _deleteInactiveModels,
                icon: const Icon(Icons.cleaning_services, size: 16),
                label: const Text('未使用を削除'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        ...cards,
        if (_modelDlError != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'ダウンロードエラー: $_modelDlError',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          '※ モデルを切り替えると既存の意味検索インデックスは互換性がなくなり再インデックスが必要です。トークナイザは全サイズで共有されます。',
          style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _modelChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  String _formatRerankBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Reranker（高精度モード用）導入 UI。
  Widget _buildRerankSection(ColorScheme colorScheme) {
    final progress = (_rerankTotal > 0)
        ? (_rerankReceived / _rerankTotal).clamp(0.0, 1.0)
        : null;
    final subColor = colorScheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 18, color: colorScheme.secondary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Reranker（高精度モード用）',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
              if (_rerankModelReady)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('導入済み', style: TextStyle(fontSize: 11)),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.tertiary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('未導入', style: TextStyle(fontSize: 11)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '高精度モード（semantic + rerank）で候補順位をさらに最適化します。'
            'サイズ: ${RerankModelManager.modelSizeDescription}',
            style: TextStyle(fontSize: 12, color: subColor),
          ),
          const SizedBox(height: 8),
          if (!_rerankTokenizerReady) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colorScheme.tertiary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: colorScheme.tertiary.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: colorScheme.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Reranker には意味検索モデル（トークナイザ）が必要です。'
                      '先に「意味検索モデル」を導入してください。',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.tertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (_isRerankDownloading) ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text(
              progress != null
                  ? 'ダウンロード中... ${_formatRerankBytes(_rerankReceived)} / '
                        '${_formatRerankBytes(_rerankTotal)} '
                        '(${(progress * 100).toStringAsFixed(1)}%)'
                  : 'ダウンロード中... ${_formatRerankBytes(_rerankReceived)}',
              style: TextStyle(fontSize: 12, color: subColor),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _cancelRerankDownload,
                child: const Text('キャンセル'),
              ),
            ),
          ] else if (_rerankDlError != null) ...[
            Text(
              'ダウンロードに失敗しました: $_rerankDlError',
              style: TextStyle(fontSize: 12, color: colorScheme.error),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _startRerankDownload,
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            ),
          ] else if (_rerankModelReady)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _deleteRerankModel,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('削除'),
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: _rerankTokenizerReady ? _startRerankDownload : null,
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Rerankerをダウンロード'),
            ),
          if (_rerankStatus.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _rerankStatus,
              style: TextStyle(fontSize: 12, color: subColor),
            ),
          ],
        ],
      ),
    );
  }

  /// インデックス状態を診断し、件数サマリを更新する。
  Future<void> _runDiagnose() async {
    if (_isDiagnosing || _isRepairing) return;
    if (!mounted) return;
    setState(() => _isDiagnosing = true);
    try {
      final result = await AiIndexMaintenanceService().diagnoseAll();
      if (!mounted) return;
      setState(() => _diagnosis = result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('診断エラー: $e')));
      }
    } finally {
      if (mounted) setState(() => _isDiagnosing = false);
    }
  }

  /// ローカルデータだけで修復可能な部分を修復する（API 非呼び出し）。
  Future<void> _runLocalRepair() async {
    if (_isRepairing || _isDiagnosing) return;
    if (!mounted) return;
    _repairCancel.value = false;
    setState(() {
      _isRepairing = true;
      _repairStatus = 'ローカル修復中...';
      _repairCurrent = 0;
      _repairTotal = 0;
    });
    try {
      final result = await AiIndexMaintenanceService().repairLocal(
        onProgress: (cur, total) async {
          if (!mounted) return;
          setState(() {
            _repairCurrent = cur;
            _repairTotal = total;
            _repairStatus = 'ローカル修復中... ($cur / $total)';
          });
        },
        cancel: () => _repairCancel.value,
      );
      if (!mounted) return;
      setState(() {
        _isRepairing = false;
        final buf = StringBuffer();
        buf.write(
          result.requireModel
              ? 'ローカル修復完了（対象:${result.totalTargets}件 / 本文再計算+メタ更新:${result.metaUpdated} 埋め込み再生成:${result.embeddingsRegenerated} / 要モデル: 埋め込み再生成にはAIモデル導入が必要）'
              : 'ローカル修復完了（対象:${result.totalTargets}件 / メタ更新:${result.metaUpdated} 埋め込み再生成:${result.embeddingsRegenerated} スキップ:${result.skipped} 失敗:${result.failed}）',
        );
        if (result.illustEmbeddingsRegenerated > 0 ||
            result.illustMetaUpdated > 0 ||
            result.illustSkipped > 0 ||
            result.illustFailed > 0) {
          buf.write(
            ' [イラスト: 埋め込み再生成:${result.illustEmbeddingsRegenerated} メタ更新:${result.illustMetaUpdated} スキップ:${result.illustSkipped} 失敗:${result.illustFailed}]',
          );
        }
        _repairStatus = buf.toString();
      });
      await _runDiagnose();
    } catch (e) {
      if (mounted) {
        setState(() => _isRepairing = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('ローカル修復エラー: $e')));
      }
    }
  }

  /// ローカルでは補えない作品を Pixiv API から取得・補完する（明示実行のみ）。
  Future<void> _runApiRepair() async {
    if (_isRepairing || _isDiagnosing) return;
    if (!mounted) return;
    final targets = await AiIndexMaintenanceService().selectApiTargets();
    if (targets.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('API取得が必要な作品はありません')));
      }
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('不足情報をPixivから取得'),
        content: Text(
          '${targets.length} 件の作品をPixivから取得し、メタデータ・本文・埋め込みを補完します。\n'
          '（レート制限に配慮して順次取得します。モデル未導入の場合は埋め込みは生成されません）',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('取得する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    _repairCancel.value = false;
    setState(() {
      _isRepairing = true;
      _repairStatus = 'Pixivから取得中...';
      _repairCurrent = 0;
      _repairTotal = targets.length;
    });
    try {
      final result = await AiIndexMaintenanceService().repairViaApi(
        workIds: targets,
        onProgress: (cur, total) async {
          if (!mounted) return;
          setState(() {
            _repairCurrent = cur;
            _repairTotal = total;
            _repairStatus = 'Pixivから取得中... ($cur / $total)';
          });
        },
        cancel: () => _repairCancel.value,
      );
      if (!mounted) return;
      setState(() {
        _isRepairing = false;
        final buf = StringBuffer();
        buf.write('取得完了（対象:${result.totalTargets} ');
        buf.write('成功:${result.success} スキップ:${result.skipped} ');
        buf.write('404/削除済:${result.notFound} ');
        buf.write('認証(401):${result.authErrors} ');
        buf.write('レート制限(429):${result.rateLimited} ');
        buf.write('その他失敗:${result.failed}');
        if (result.requireModel) buf.write(' / 埋め込み再生成にはAIモデル導入が必要');
        buf.write('）');
        if (result.authErrors > 0) {
          buf.write(' [認証エラー: 再ログインが必要です]');
        }
        _repairStatus = buf.toString();
      });
      await _runDiagnose();
    } catch (e) {
      if (mounted) {
        setState(() => _isRepairing = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('API取得エラー: $e')));
      }
    }
  }

  /// すべて再インデックス（ローカル修復と同じ。互換ベクトルは保持）。
  Future<void> _runReindexAll() async {
    await _runLocalRepair();
  }

  void _cancelRepair() {
    if (!_isRepairing) return;
    _repairCancel.value = true;
    setState(() {
      _repairStatus = 'キャンセル中...';
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('AIインデックス管理'),
        foregroundColor: colorScheme.onSurface,
        elevation: 0.5,
      ),
      body: _buildBody(colorScheme),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    final d = _diagnosis;
    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth >= _kTabletBreakpoint;

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: isTablet ? 24 : 16,
        vertical: 16,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isTablet ? _kTabletContentMaxWidth : double.infinity,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.health_and_safety,
                  color: colorScheme.secondary,
                  size: 22,
                ),
                const SizedBox(width: 8),
                const Text(
                  'AI検索インデックス状態',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (!_isDiagnosing && !_isRepairing)
                  TextButton.icon(
                    onPressed: _runDiagnose,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('再診断'),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // サマリカード
            if (_isDiagnosing)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (d != null)
              _buildDiagnosisSummaryCards(d, colorScheme),

            const SizedBox(height: 16),

            // Reranker（高精度モード用）導入 UI
            _buildRerankSection(colorScheme),

            const SizedBox(height: 16),

            // AI モデル（Ruri v3）管理 UI
            _buildModelManagementSection(colorScheme),

            const SizedBox(height: 16),

            // 進捗 / 修復状態
            if (_isRepairing) ...[
              LinearProgressIndicator(
                value: _repairTotal > 0 ? _repairCurrent / _repairTotal : null,
              ),
              const SizedBox(height: 8),
              Text(_repairStatus),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _cancelRepair,
                  child: const Text('キャンセル'),
                ),
              ),
            ] else if (_repairStatus.isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _repairStatus,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // アクションボタン
            if (!_isRepairing) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: _runLocalRepair,
                    icon: const Icon(Icons.build, size: 16),
                    label: const Text('ローカル修復'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _runApiRepair,
                    icon: const Icon(Icons.cloud_download, size: 16),
                    label: const Text('不足情報をPixivから取得'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _runReindexAll,
                    icon: const Icon(Icons.autorenew, size: 16),
                    label: const Text('すべて再インデックス'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '※ ローカル修復は端末内データのみで実行。Pixivから取得は確認ダイアログ後に順次実行します（レート制限配慮）。',
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 診断サマリをカード群で表示する（5つの数値）。
  Widget _buildDiagnosisSummaryCards(
    AiIndexDiagnosisResult d,
    ColorScheme colorScheme,
  ) {
    final items = <_DiagItem>[
      _DiagItem('AI検索可能', d.aiSearchable, colorScheme.secondary),
      _DiagItem('埋め込み不足', d.embeddingDeficient, colorScheme.tertiary),
      _DiagItem('メタデータ不足', d.metadataDeficient, colorScheme.tertiary),
      _DiagItem('本文あり・再生成可能', d.localRepairable, colorScheme.primary),
      _DiagItem('API取得が必要', d.apiRequired, colorScheme.error),
      _DiagItem('イラスト総数', d.totalIllusts, colorScheme.primary),
      _DiagItem('イラスト埋め込み不足', d.illustEmbeddingDeficient, colorScheme.tertiary),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items
          .map(
            (it) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(
                  color: it.color.withValues(alpha: 0.5),
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    it.label,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${it.count}件',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: it.color,
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}

/// 診断サマリカードの1項目（ラベル・件数・色）。
class _DiagItem {
  final String label;
  final int count;
  final Color color;
  const _DiagItem(this.label, this.count, this.color);
}
