import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/local_llm_service.dart';
import '../services/llm_model_preset.dart'
    show LlmInferencePreset, LlmModelChoice;
import '../services/llm_summary_cache_service.dart';
import '../services/llm_summary_service.dart';

/// 小説のAI要約を表示するボトムシート（実験機能）。
///
/// 開いた時点で生成を開始する。ストリーミング中のテキストをリアルタイム表示し、
/// 完了後に3セクション（あらすじ / 紹介 / タグ候補）として整形表示する。
/// キャンセル・リトライに対応。シート閉じ（dispose）時にサービスも破棄する。
///
/// M1: 生成元は小説本文のみ（[resolveBody] で解決）。
/// 本文取得失敗時は作者説明へのフォールバックなしでエラー表示する。
/// 作者説明は「作者による紹介」として別途表示し、プロンプトには含めない。
class LlmSummarySheet extends StatefulWidget {
  const LlmSummarySheet({
    super.key,
    required this.modelPath,
    required this.title,
    required this.description,
    this.tags = const [],
    required this.resolveBody,
    this.workId,
    this.availableModels = const <LlmModelChoice>[],
    this.serviceFactory,
  });

  /// 使用する GGUF モデルの絶対パス（初期値。「別モデルで再生成」で更新）。
  final String modelPath;

  /// 切替候補モデル一覧（M5）。空なら「別モデルで再生成」を表示しない。
  final List<LlmModelChoice> availableModels;

  /// サービス生成ファクトリ（テストで fake エンジン注入に使用）。
  final LocalLlmService Function()? serviceFactory;

  final String title;

  /// 作者の説明（表示・コピー検出専用 — AI生成プロンプトには含めない）。
  final String description;
  final List<String> tags;

  /// 小説本文を解決する（キャッシュ → 取得 + 保存）。
  ///
  /// null / 空を返すと「小説本文を取得できないため、AI要約を生成できません。」
  /// を表示する（作者説明へのフォールバックはしない）。
  final Future<String?> Function() resolveBody;

  /// 作品ID（M6・要約キャッシュ用）。null ならキャッシュしない。
  final int? workId;

  @override
  State<LlmSummarySheet> createState() => _LlmSummarySheetState();
}

enum _SheetPhase { loading, generating, done, error }

class _LlmSummarySheetState extends State<LlmSummarySheet> {
  LocalLlmService? _service;
  _SheetPhase _phase = _SheetPhase.loading;
  String _streamText = '';
  LlmSummaryResult? _result;
  String? _errorMessage;
  bool _noteCancelled = false;
  bool _busy = false;

  /// B: 本文解決の所要時間（ミリ秒）。「本文を処理中」表示とメタ計測用。
  int? _bodyMs;

  /// B: キャッシュヒットの有無（メタ計測用）。
  bool _cacheHit = false;

  /// B: 自動再生成（コピー検知リトライ）の回数。
  int _regenerations = 0;

  /// B: loading 中に表示する進行ステージ（本文処理 / モデル準備）。
  String _stageText = 'モデルを準備中…（初回は数秒〜数十秒かかることがあります）';

  /// 現在選択中のモデルパス（M5）。「別モデルで再生成」で更新される。
  String _activeModelPath = '';

  @override
  void dispose() {
    // 生成中・読み込み中でも確実に破棄（dispose 後の setState は起きない）。
    _service?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_busy) return;
    _busy = true;
    setState(() {
      _phase = _SheetPhase.loading;
      _streamText = '';
      _result = null;
      _errorMessage = null;
      _noteCancelled = false;
      _bodyMs = null;
      _cacheHit = false;
      _regenerations = 0;
      _stageText = '本文を処理中…';
    });
    // B: 本文解決の計測開始。
    final bodyWatch = Stopwatch()..start();
    // 切替のたびに新しいサービスを作り、旧エンジンを解放する
    // （同時にロードするモデルは常に1つ・M5）。
    final svc =
        widget.serviceFactory?.call() ?? LocalLlmService(preset: _activePreset);
    final old = _service;
    _service = svc;
    old?.dispose();
    try {
      // M1: まず小説本文を解決（キャッシュ → 取得 + 保存）。
      // 取得失敗時は作者説明へのフォールバックなしでエラーにする。
      final body = (await widget.resolveBody()) ?? '';
      if (!mounted) return;
      bodyWatch.stop();
      setState(() {
        _bodyMs = bodyWatch.elapsedMilliseconds;
        _stageText = 'モデルを準備中…（初回は数秒〜数十秒かかることがあります）';
      });
      if (body.trim().isEmpty) {
        setState(() {
          _phase = _SheetPhase.error;
          _errorMessage = '小説本文を取得できないため、AI要約を生成できません。';
        });
        return;
      }
      final ok = await svc.loadModel(_activeModelPath);
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _phase = _SheetPhase.error;
          _errorMessage = svc.errorMessage ?? 'モデルを読み込めませんでした。';
        });
        return;
      }
      // M6: キャッシュ照会（モデルIDはモデルパスのファイル名）。
      final fingerprint = LlmSummaryService.computeSourceFingerprint(
        title: widget.title,
        tags: widget.tags,
        body: body,
      );
      final modelId = p.basename(_activeModelPath);
      if (widget.workId != null) {
        final cached = await LlmSummaryCacheService().get(
          workId: widget.workId!,
          modelId: modelId,
          sourceFingerprint: fingerprint,
        );
        if (cached != null) {
          if (!mounted) return;
          _cacheHit = true;
          setState(() {
            _phase = _SheetPhase.done;
            _result = cached;
          });
          return;
        }
      }
      final result = await LlmSummaryService.generate(
        service: svc,
        title: widget.title,
        body: body,
        tags: widget.tags,
        description: widget.description, // コピー検出のみ（プロンプトには含めない）
        modelLabel: _activeModelLabel,
        onRegeneration: () => _regenerations++,
        onToken: (piece) {
          if (!mounted) return;
          setState(() {
            if (_phase == _SheetPhase.loading) {
              _phase = _SheetPhase.generating;
            }
            _streamText += piece;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _phase = _SheetPhase.done;
        _result = result;
      });
      // M6: 生成結果をキャッシュに保存（失敗は無視・表示を妨げない）。
      if (widget.workId != null) {
        final modelFileHash = await LlmSummaryCacheService.computeModelFileHash(
          _activeModelPath,
        );
        await LlmSummaryCacheService().save(
          workId: widget.workId!,
          modelId: modelId,
          modelFileHash: modelFileHash,
          sourceFingerprint: fingerprint,
          result: result,
        );
      }
    } on LlmCancelledException {
      if (!mounted) return;
      setState(() {
        _phase = _SheetPhase.loading;
        _noteCancelled = true;
      });
    } on LlmSummaryException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _SheetPhase.error;
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      final firstLine = e.toString().split('\n').first.trim();
      setState(() {
        _phase = _SheetPhase.error;
        _errorMessage =
            '要約の生成に失敗しました: ${firstLine.length > 120 ? '${firstLine.substring(0, 120)}…' : firstLine}';
      });
    } finally {
      _busy = false;
    }
  }

  void _cancel() {
    _service?.cancel();
  }

  /// M5: モデルを切り替えて再生成する。
  void _useModel(LlmModelChoice choice) {
    if (_busy) return;
    setState(() => _activeModelPath = choice.path);
    _start();
  }

  /// M5: 現在のモデルの推論プリセット（候補一致。未登録なら既定値）。
  LlmInferencePreset get _activePreset {
    for (final m in widget.availableModels) {
      if (m.path == _activeModelPath) return m.preset;
    }
    return LlmInferencePreset.defaults;
  }

  /// M5: 現在のモデルの表示ラベル（候補一覧から解決。未登録なら空）。
  String get _activeModelLabel {
    for (final m in widget.availableModels) {
      if (m.path == _activeModelPath) return m.label;
    }
    return '';
  }

  /// M5: 別モデル選択シート → 選択で再生成。
  Future<void> _showModelPicker() async {
    final picked = await showModalBottomSheet<LlmModelChoice>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1C),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '別のモデルで再生成',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            for (final m in widget.availableModels)
              ListTile(
                title: Text(
                  m.label,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: Text(
                  p.basename(m.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                trailing: m.path == _activeModelPath
                    ? const Icon(Icons.check, color: Colors.pinkAccent)
                    : null,
                onTap: () => Navigator.of(context).pop(m),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked.path == _activeModelPath) return;
    _useModel(picked);
  }

  @override
  void initState() {
    super.initState();
    _activeModelPath = widget.modelPath;
    _start();
  }

  @override
  Widget build(BuildContext context) {
    void closeSheet() => Navigator.of(context).pop();
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1C),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                const Text(
                  '🤖 AI要約（実験）',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  tooltip: '閉じる',
                  onPressed: closeSheet,
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _buildBody(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_phase == _SheetPhase.loading ||
                    _phase == _SheetPhase.generating)
                  OutlinedButton(
                    onPressed: _cancel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                    ),
                    child: const Text('キャンセル'),
                  ),
                if (_phase == _SheetPhase.error || _noteCancelled)
                  OutlinedButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(_noteCancelled ? 'もう一度試す' : '再試行'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.pinkAccent,
                      side: const BorderSide(color: Colors.pinkAccent),
                    ),
                  ),
                if (_phase == _SheetPhase.done) ...[
                  if (widget.availableModels.length > 1)
                    OutlinedButton.icon(
                      onPressed: _showModelPicker,
                      icon: const Icon(Icons.swap_horiz, size: 16),
                      label: const Text('別モデルで再生成'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('このモデルで再生成'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.pinkAccent,
                      side: const BorderSide(color: Colors.pinkAccent),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_noteCancelled) {
      return const Text(
        '生成をキャンセルしました。',
        style: TextStyle(color: Colors.white70, fontSize: 13),
      );
    }
    switch (_phase) {
      case _SheetPhase.loading:
        return Column(
          children: [
            const SizedBox(
              height: 32,
              child: CircularProgressIndicator(color: Colors.pinkAccent),
            ),
            const SizedBox(height: 16),
            Text(
              _stageText,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            if (_bodyMs != null) ...[
              const SizedBox(height: 4),
              Text(
                '本文の処理（${(_bodyMs! / 1000).toStringAsFixed(1)} 秒）',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ],
        );
      case _SheetPhase.generating:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.pinkAccent,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '生成中…',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _StreamTextBlock(text: _streamText),
          ],
        );
      case _SheetPhase.done:
        final result = _result;
        if (result == null) {
          return const Text(
            '結果がありません。',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          );
        }
        return _buildDone(result);
      case _SheetPhase.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.redAccent,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _errorMessage ?? '生成に失敗しました。',
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
            if (_streamText.isNotEmpty) ...[
              const SizedBox(height: 12),
              _StreamTextBlock(text: _streamText, muted: true),
            ],
          ],
        );
    }
  }

  Widget _buildDone(LlmSummaryResult result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildModelMeta(result),
        if (result.bodySourceNote != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                const Icon(Icons.article, size: 14, color: Colors.white54),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    result.bodySourceNote!,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        if (result.copyWarning)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: Colors.orange,
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '作者紹介文・本文との重複の多い出力です（参考までに表示）。',
                    style: TextStyle(
                      color: Colors.orange,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        _SectionLabel(label: 'あらすじ'),
        Text(
          result.synopsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 14),
        _SectionLabel(label: '紹介'),
        Text(
          result.intro,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 14),
        _SectionLabel(label: 'タグ候補'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final tag in result.tagSuggestions)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Colors.pinkAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.pinkAccent.withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  tag,
                  style: const TextStyle(
                    color: Colors.pinkAccent,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
        if (widget.description.trim().isNotEmpty) ...[
          const SizedBox(height: 14),
          _SectionLabel(label: '作者による紹介（AI生成に使用せず）'),
          const SizedBox(height: 6),
          Text(
            widget.description.trim(),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
        const SizedBox(height: 14),
        Text(
          '※ 実験機能です。内容の正確性は保証されません。',
          style: TextStyle(color: Colors.grey[500], fontSize: 11),
        ),
      ],
    );
  }

  /// M5: 生成メタ情報（モデル名・日時・所要時間・速度）。
  Widget _buildModelMeta(LlmSummaryResult result) {
    final label = (result.modelLabel?.isNotEmpty ?? false)
        ? result.modelLabel!
        : p.basename(_activeModelPath);
    final dt = result.generatedAt;
    final when = dt == null
        ? null
        : '${dt.year}/${_two(dt.month)}/${_two(dt.day)} '
              '${_two(dt.hour)}:${_two(dt.minute)}';
    final secs = result.generationMs == null
        ? null
        : (result.generationMs! / 1000).toStringAsFixed(1);
    final tps = result.tokensPerSecond;
    final stats = _service?.lastGenerationStats;
    final ttft = (stats?.timeToFirstTokenMs ?? result.timeToFirstTokenMs);
    final loadMs = stats?.loadMs;
    final rows = <(String, String)>[
      ('モデル', label),
      if (when != null) ('生成日時', when),
      if (secs != null) ('処理時間', '$secs 秒'),
      if (ttft != null) ('最初の出力まで', '${(ttft / 1000).toStringAsFixed(1)} 秒'),
      if (loadMs != null)
        (
          'モデルロード',
          loadMs == 0 ? '再利用（0 秒）' : '${(loadMs / 1000).toStringAsFixed(1)} 秒',
        ),
      if (result.inputTokens != null) ('入力トークン', '${result.inputTokens}'),
      if (tps != null) ('速度', '${tps.toStringAsFixed(1)} トークン/秒'),
      if (stats?.backend != null) ('backend', stats!.backend!),
      ('キャッシュ', _cacheHit ? 'ヒット' : 'なし'),
      if (_regenerations > 0) ('自動再生成', '$_regenerations 回'),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      k,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      v,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

/// セクション見出し。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      '【$label】',
      style: const TextStyle(
        color: Colors.pinkAccent,
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

/// ストリーミング中のテキスト表示（選択可能）。
class _StreamTextBlock extends StatelessWidget {
  const _StreamTextBlock({required this.text, this.muted = false});
  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      child: SelectableText(
        text.isEmpty ? '…' : text,
        style: TextStyle(
          color: muted ? Colors.white38 : Colors.white,
          fontSize: 12,
          height: 1.5,
        ),
      ),
    );
  }
}
