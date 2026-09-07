import 'package:flutter/material.dart';

import '../services/local_llm_service.dart';
import '../services/llm_summary_service.dart';

/// 小説のAI要約を表示するボトムシート（実験機能）。
///
/// 開いた時点で生成を開始する。ストリーミング中のテキストをリアルタイム表示し、
/// 完了後に3セクション（あらすじ / 紹介 / タグ候補）として整形表示する。
/// キャンセル・リトライに対応。シート閉じ（dispose）時にサービスも破棄する。
class LlmSummarySheet extends StatefulWidget {
  const LlmSummarySheet({
    super.key,
    required this.modelPath,
    required this.title,
    required this.description,
    this.tags = const [],
    required this.body,
  });

  /// 使用する GGUF モデルの絶対パス。
  final String modelPath;

  final String title;
  final String description;
  final List<String> tags;
  final String body;

  @override
  State<LlmSummarySheet> createState() => _LlmSummarySheetState();
}

enum _SheetPhase { loading, generating, done, error }

class _LlmSummarySheetState extends State<LlmSummarySheet> {
  final LocalLlmService _service = LocalLlmService();
  _SheetPhase _phase = _SheetPhase.loading;
  String _streamText = '';
  LlmSummaryResult? _result;
  String? _errorMessage;
  bool _noteCancelled = false;
  bool _busy = false;

  @override
  void dispose() {
    // 生成中・読み込み中でも確実に破棄（dispose 後の setState は起きない）。
    _service.dispose();
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
    });
    try {
      final ok = await _service.loadModel(widget.modelPath);
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _phase = _SheetPhase.error;
          _errorMessage = _service.errorMessage ?? 'モデルを読み込めませんでした。';
        });
        return;
      }
      final result = await LlmSummaryService.generate(
        service: _service,
        title: widget.title,
        description: widget.description,
        tags: widget.tags,
        body: widget.body,
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
    _service.cancel();
  }

  @override
  void initState() {
    super.initState();
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
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
            const Text(
              'モデルを準備中…（初回は数秒〜数十秒かかることがあります）',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
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
        const SizedBox(height: 14),
        Text(
          '※ 実験機能です。内容の正確性は保証されません。',
          style: TextStyle(color: Colors.grey[500], fontSize: 11),
        ),
      ],
    );
  }
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
