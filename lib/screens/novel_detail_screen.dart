import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../novel_model.dart';
import 'author_profile_screen.dart';
import 'novel_reader_screen.dart';
import 'novel_series_episodes_screen.dart';
import 'read_later_screen.dart';
import '../services/companion/companion_service.dart';
import '../services/database_service.dart';
import '../services/embedding_service.dart';
import '../services/emotion_curve_service.dart';
import '../models/llm_model_catalog_entry.dart';
import '../services/llm_model_catalog_service.dart';
import '../services/llm_model_preset.dart'
    show LlmInferencePreset, LlmModelChoice;
import '../services/llm_summary_service.dart';
import '../services/local_llm_service.dart';
import '../services/novel_document_text.dart';
import '../services/pixiv_api_service.dart';
import '../services/reading_speed_service.dart';
import '../services/ruri_model_manager.dart';
import '../services/series_progress_service.dart';
import '../services/similar_works_service.dart';
import '../theme/app_theme.dart';
import '../utils/datetime_format.dart';
import '../widgets/llm_summary_sheet.dart';
import '../widgets/pixiv_image.dart';

class NovelDetailScreen extends StatefulWidget {
  final Novel novel;
  final ValueChanged<String>? onTagTap;
  final ValueChanged<bool>? onBookmarkChanged;

  const NovelDetailScreen({
    super.key,
    required this.novel,
    this.onTagTap,
    this.onBookmarkChanged,
  });

  @override
  State<NovelDetailScreen> createState() => _NovelDetailScreenState();
}

class _NovelDetailScreenState extends State<NovelDetailScreen> {
  late bool _isBookmarked;
  int _bookmarkCountOffset = 0;
  bool _isToggling = false;
  double? _readingProgress;
  bool _isReadLater = false;
  // 読了目安（Phase A）
  int? _estReadingMinutes;
  bool _estReadingIsDefault = false;
  // 感情曲線（Phase C）
  EmotionCurveResult? _emotionCurve;
  bool _emotionGenerating = false;
  String _emotionProgressLabel = '';
  bool _emotionModelAvailable = false;
  String? _emotionNote;
  // 似た作品（Phase D）
  SimilarWorksResult? _similar;
  bool _similarLoading = false;
  String? _similarNote;
  // シリーズ進捗（Phase N3）
  SeriesProgress? _seriesProgress;
  // AI要約（実験）: プラットフォーム対応 + モデル配置済みなら true
  bool _llmSummaryAvailable = false;

  @override
  void initState() {
    debugPrint('📍 [DEBUG Detail] initState 開始: ${widget.novel.title}');
    super.initState();
    _isBookmarked = widget.novel.isBookmarked;
    _loadReadLaterState();
    _loadReadingProgress();
    _loadReadingEstimate();
    _loadSeriesProgress();
    _loadEmotionCurveState();
    _loadSimilarWorks();
    _loadLlmSummaryAvailability();
    _recordHistory();
    debugPrint('📍 [DEBUG Detail] initState 終了');
  }

  /// AI要約（実験）の可用性を確認（Android かつ GGUF 配置済みのときのみ有効）。
  Future<void> _loadLlmSummaryAvailability() async {
    if (!LlmModelPaths.isSupportedPlatform()) return;
    try {
      final path = await LlmModelPaths.resolveModelPath();
      if (!mounted) return;
      setState(() => _llmSummaryAvailable = path != null);
    } catch (e) {
      debugPrint('AI要約状態の読み込みに失敗（無視）: $e');
    }
  }

  /// AI要約ボトムシートを開く。
  ///
  /// M1: 本文は [_resolveLlmBody]（キャッシュ → 取得 + 保存）で解決。
  /// 取得失敗時はシート内で「小説本文を取得できないため、AI要約を生成できません。」
  /// を表示する（作者説明へのフォールバックはしない）。
  Future<void> _showLlmSummarySheet() async {
    final modelPath = await LlmModelPaths.resolveModelPath();
    if (!mounted || modelPath == null) return;
    final choices = await _collectLlmModelChoices();
    if (!mounted) return;
    // 10-B1: ペアリング済みなら PCサーバー経由を有効化（未ペアリングなら null）。
    CompanionService? companion;
    try {
      final svc = CompanionService();
      if (await svc.init()) {
        companion = svc;
      }
    } catch (_) {
      companion = null;
    }
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => LlmSummarySheet(
        modelPath: modelPath,
        title: widget.novel.title,
        description: widget.novel.caption,
        tags: widget.novel.tags,
        resolveBody: _resolveLlmBody,
        workId: widget.novel.id,
        availableModels: choices,
        companionService: companion,
        // FGS 経由（デフォルト: bridgeController 未指定 → シート内部で生成）。
      ),
    );
  }

  /// M5: 切替候補モデル一覧（発見済み GGUF + カタログ表示名 + 推論プリセット）。
  ///
  /// カタログ読み込みに失敗してもファイル名ラベル・既定プリセットで続行する
  /// （空にはしない）。
  Future<List<LlmModelChoice>> _collectLlmModelChoices() async {
    final paths = await LlmModelPaths.discover();
    if (paths.isEmpty) return const [];
    LlmModelCatalog? catalog;
    try {
      catalog = await LlmModelCatalogService().load();
    } catch (_) {
      // カタログ未読はファイル名ラベル・既定プリセットで続行。
    }
    final entries = catalog?.entries ?? const <LlmModelCatalogEntry>[];
    return [
      for (final path in paths)
        LlmModelChoice(
          path: path,
          label: () {
            for (final e in entries) {
              if (e.fileName.toLowerCase() == p.basename(path).toLowerCase()) {
                return e.displayName.isNotEmpty
                    ? e.displayName
                    : p.basename(path);
              }
            }
            return p.basename(path);
          }(),
          preset: LlmInferencePreset.resolveForFileName(path, entries),
        ),
    ];
  }

  /// 小説本文を解決する（M1: キャッシュ → 取得 + 保存 → null）。
  ///
  /// 取得失敗・空本文は null を返す（シート側でエラー表示）。
  Future<String?> _resolveLlmBody() {
    final novel = widget.novel;
    return LlmSummaryService.resolveNovelBody(
      workId: novel.id,
      getCached: DatabaseService().getNovelText,
      fetchText: PixivApiService().getNovelText,
      saveToCache: (data) => DatabaseService().saveNovelText(
        workId: data.id,
        title: novel.title,
        authorName: novel.author.name,
        text: data.novelText,
        pagesJson: jsonEncode(data.novelPages),
      ),
    );
  }

  Future<void> _loadReadLaterState() async {
    try {
      final registered = await DatabaseService().isReadLater(widget.novel.id);
      if (mounted) {
        setState(() => _isReadLater = registered);
      }
    } catch (e) {
      debugPrint('あとで読む状態の取得に失敗しました（無視）: $e');
    }
  }

  /// 読了目安の算出（Phase A）。文字数不明なら表示しない。失敗しても無視。
  Future<void> _loadReadingEstimate() async {
    final chars = widget.novel.textLength;
    if (chars <= 0) return;
    try {
      final speed = await ReadingSpeedService().getPersonalSpeed();
      if (!mounted) return;
      setState(() {
        _estReadingMinutes = estimateRemainingMinutes(
          chars,
          speed.charsPerMinute,
        );
        _estReadingIsDefault = speed.isEstimated;
      });
    } catch (e) {
      debugPrint('読了目安の算出に失敗（無視）: $e');
    }
  }

  /// 感情曲線状態の読み込み（Phase C）。キャッシュがあれば表示、なければ生成ボタン/注記。
  Future<void> _loadEmotionCurveState() async {
    try {
      final cached = await EmotionCurveService().loadFromCache(widget.novel.id);
      if (!mounted) return;
      if (cached != null) {
        setState(() => _emotionCurve = cached);
        return;
      }
      final available = await EmotionCurveService().isModelAvailable();
      if (!mounted) return;
      setState(() {
        _emotionModelAvailable = available;
        if (!available) {
          _emotionNote = 'AIモデルが未導入のため感情曲線を生成できません';
        }
      });
    } catch (e) {
      debugPrint('感情曲線状態の読み込みに失敗（無視）: $e');
    }
  }

  /// 感情曲線の生成（Phase C）。進捗表示付き・キャンセル可能。
  Future<void> _generateEmotionCurve() async {
    if (_emotionGenerating) return;
    setState(() {
      _emotionGenerating = true;
      _emotionProgressLabel = '準備中…';
      _emotionNote = null;
    });
    try {
      final row = await DatabaseService().getNovelText(widget.novel.id);
      if (!mounted) return;
      if (row == null) {
        setState(() {
          _emotionGenerating = false;
          _emotionProgressLabel = '';
          _emotionNote = '本文が未キャッシュです。一度リーダーを開いてから生成できます';
        });
        return;
      }
      final text = (row['text'] as String?) ?? '';
      var pages = <String>[];
      try {
        final pagesJson = row['pages_json'] as String?;
        if (pagesJson != null && pagesJson.isNotEmpty) {
          pages = List<String>.from(jsonDecode(pagesJson) as List);
        }
      } catch (_) {
        // pages_json 破損時は空扱いにする
      }
      final curve = await EmotionCurveService().compute(
        workId: widget.novel.id,
        text: text,
        pages: pages,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() => _emotionProgressLabel = '生成中… $done/$total');
        },
      );
      if (!mounted) return;
      setState(() {
        _emotionGenerating = false;
        _emotionProgressLabel = '';
        if (curve == null) {
          _emotionNote = '本文が短すぎて感情曲線を生成できません';
        } else {
          _emotionCurve = curve;
        }
      });
    } on StateError catch (e) {
      if (!mounted) return;
      final canceled = e.message.contains('キャンセル');
      setState(() {
        _emotionGenerating = false;
        _emotionProgressLabel = '';
        _emotionNote = canceled ? '生成をキャンセルしました' : '感情曲線の生成に失敗しました';
      });
      debugPrint('感情曲線生成 StateError: $e');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _emotionGenerating = false;
        _emotionProgressLabel = '';
        _emotionNote = '感情曲線の生成に失敗しました';
      });
      debugPrint('感情曲線生成に失敗: $e');
    }
  }

  /// 似た作品の読み込み（Phase D）。失敗しても注記のみで落とさない。
  Future<void> _loadSimilarWorks() async {
    if (_similarLoading) return;
    setState(() => _similarLoading = true);
    try {
      final result = await SimilarWorksService.resolve().buildForNovel(
        widget.novel,
        limit: 12,
      );
      if (!mounted) return;
      setState(() {
        _similar = result;
        _similarLoading = false;
        if (result.works.isEmpty &&
            result.sameAuthor.isEmpty &&
            result.sameSeries.isEmpty) {
          _similarNote = result.modelReady
              ? '似た作品が見つかりませんでした（データ不足またはオフライン）'
              : 'AIモデル未導入のためタグベースの候補のみ表示しています';
        }
      });
    } catch (e) {
      // エラー時は「似た作品」セクションを静かに非表示にするだけ。
      // 画面全体には一切影響を与えない（エラー表示も出さない）。
      if (!mounted) return;
      setState(() {
        _similarLoading = false;
        _similarNote = null;
      });
      debugPrint('似た作品読み込みに失敗（無視・セクション非表示）: $e');
    }
  }

  /// 似た作品カード（Phase D）。横スクロール + 「なぜ似ているか」+ もっと見る。
  Widget _buildSimilarWorksCard() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '📚 似た作品',
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (_similar != null &&
                  (_similar!.works.isNotEmpty ||
                      _similar!.sameAuthor.isNotEmpty ||
                      _similar!.sameSeries.isNotEmpty))
                TextButton(
                  onPressed: _showSimilarWorksScreen,
                  child: Text(
                    'もっと見る',
                    style: TextStyle(color: colorScheme.primary, fontSize: 12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_similarLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: CircularProgressIndicator(color: colorScheme.primary),
              ),
            )
          else if (_similar == null)
            Text(
              '読み込み中…',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            )
          else if (_similar!.works.isEmpty &&
              _similar!.sameAuthor.isEmpty &&
              _similar!.sameSeries.isEmpty)
            Text(
              _similarNote ?? '似た作品はありません',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            )
          else ...[
            if (_similar!.works.isNotEmpty)
              _buildSimilarHorizontal(_similar!.works),
            if (_similar!.sameSeries.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '同じシリーズ',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              _buildSimilarHorizontal(_similar!.sameSeries),
            ],
            if (_similar!.sameAuthor.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '同じ作者',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              _buildSimilarHorizontal(_similar!.sameAuthor),
            ],
          ],
        ],
      ),
    );
  }

  /// 似た作品の横スクロール列（「なぜ似ているか」の一行理由付き）。
  Widget _buildSimilarHorizontal(List<SimilarWork> works) {
    return SizedBox(
      height: 150,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: works.length,
        itemBuilder: (context, index) {
          final w = works[index];
          return _SimilarWorkCard(work: w, onTap: () => _openSimilar(w));
        },
      ),
    );
  }

  /// 似た作品を開く（local=DB行 / api=APIモデル）。
  void _openSimilar(SimilarWork w) {
    try {
      if (w.type == 'novel') {
        final novel = Novel.fromJson(Map<String, dynamic>.from(w.row));
        // 17b: 詳細画面は root Navigator に積みボトムナビを隠す。
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(builder: (_) => NovelDetailScreen(novel: novel)),
        );
      }
    } catch (e) {
      debugPrint('似た作品を開けませんでした: $e');
    }
  }

  /// 似た作品の一覧画面（軸タブ付き）。
  void _showSimilarWorksScreen() {
    final result = _similar;
    if (result == null) return;
    // 17b: 詳細から派生する一覧画面も root Navigator に積む。
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => SimilarWorksScreen(
          baseTitle: widget.novel.title,
          result: result,
          onOpen: _openSimilar,
        ),
      ),
    );
  }

  /// 感情曲線カード（Phase C）。空状態（モデル未導入/データ不足）は注記と生成ボタン。
  Widget _buildEmotionCurveCard() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '💗 感情曲線',
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              if (_emotionCurve?.isSimpleMode ?? false)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.tertiary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '簡易モード',
                    style: TextStyle(color: colorScheme.tertiary, fontSize: 10),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_emotionGenerating) ...[
            LinearProgressIndicator(
              minHeight: 4,
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _emotionProgressLabel,
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => EmotionCurveService().cancel(),
                  child: Text(
                    'キャンセル',
                    style: TextStyle(color: colorScheme.error, fontSize: 12),
                  ),
                ),
              ],
            ),
          ] else if (_emotionCurve != null) ...[
            GestureDetector(
              onTap: _showEmotionCurveDialog,
              child: Tooltip(
                message: 'タップで拡大',
                child: SizedBox(
                  height: 110,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _EmotionCurvePainter(curve: _emotionCurve!),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '物語の色: ${_emotionCurve!.storyColor}',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'グラフをタップで拡大 / 位置をタップで該当本文へジャンプ',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
          ] else if (_emotionNote != null) ...[
            Text(
              _emotionNote!,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            if (_emotionModelAvailable) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _generateEmotionCurve,
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('感情曲線を生成する'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colorScheme.primary,
                  side: BorderSide(color: colorScheme.primary),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ],
          ] else if (_emotionModelAvailable) ...[
            Text(
              'AIが本文を解析し、感情（喜・悲・怖・怒・穏・切なさ）の移ろいを曲線で表示します',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _generateEmotionCurve,
              icon: const Icon(Icons.auto_awesome, size: 16),
              label: const Text('感情曲線を生成する'),
              style: OutlinedButton.styleFrom(
                foregroundColor: colorScheme.primary,
                side: BorderSide(color: colorScheme.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 感情曲線の拡大ダイアログ（Phase C）。タップ位置 → 本文ページへジャンプ。
  void _showEmotionCurveDialog() {
    final curve = _emotionCurve;
    if (curve == null) return;
    final colorScheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: colorScheme.surfaceContainerHigh,
          title: Text(
            '💗 感情曲線${curve.isSimpleMode ? '（簡易モード）' : ''}',
            style: TextStyle(color: colorScheme.onSurface, fontSize: 16),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    return GestureDetector(
                      onTapDown: (details) {
                        _jumpFromChartTap(
                          curve,
                          details.localPosition.dx,
                          width,
                        );
                      },
                      child: SizedBox(
                        height: 240,
                        width: width,
                        child: CustomPaint(
                          painter: _EmotionCurvePainter(curve: curve),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    for (final label in kEmotionLabels)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: Color(
                                kEmotionColorValues[label] ?? 0xFF9E9E9E,
                              ),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            kEmotionNames[label] ?? label,
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'グラフをタップすると、その位置の本文にジャンプします',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(
                '閉じる',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        );
      },
    );
  }

  /// グラフタップ → チャンク → 対応ページのリーダーへジャンプ（Phase C）。
  void _jumpFromChartTap(EmotionCurveResult curve, double dx, double width) {
    if (curve.chunks.isEmpty || width <= 0) return;
    final idx = (dx / width * curve.chunks.length).floor().clamp(
      0,
      curve.chunks.length - 1,
    );
    final page = curve.chunks[idx].pageStart;
    Navigator.pop(context);
    // 17b: リーダーは root Navigator に積みボトムナビを隠す。
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (context) =>
            NovelReaderScreen(novel: widget.novel, initialPage: page),
      ),
    );
  }

  Future<void> _toggleReadLater() async {
    if (_isReadLater) {
      await DatabaseService().removeReadLater(widget.novel.id);
      if (mounted) setState(() => _isReadLater = false);
      _showSuccessSnackBar('「あとで読む」から削除しました');
    } else {
      await DatabaseService().addReadLater(widget.novel);
      if (mounted) setState(() => _isReadLater = true);
      _showSuccessSnackBar('「あとで読む」に追加しました');
      // オフライン本棚用に本文をバックグラウンドでキャッシュ（失敗は無視）
      _cacheNovelTextInBackground(widget.novel);
    }
  }

  /// 「あとで読む」登録時のバックグラウンド本文キャッシュ。
  /// PixivApiService で本文を取得し、DatabaseService に保存を委譲する。
  /// 例外は一切投げない（UI ブロック禁止）。
  Future<void> _cacheNovelTextInBackground(Novel novel) async {
    try {
      final api = PixivApiService();
      final textData = await api.getNovelText(novel.id);
      if (textData.novelText.isEmpty) return;
      await DatabaseService().saveNovelText(
        workId: textData.id,
        title: novel.title,
        authorName: novel.author.name,
        text: textData.novelText,
        pagesJson: jsonEncode(textData.novelPages),
      );
      try {
        await DatabaseService().saveNovel(novel);
      } catch (e) {
        debugPrint('オフラインキャッシュ用メタ保存に失敗（無視）: $e');
      }
    } catch (e) {
      debugPrint('オフラインキャッシュのバックグラウンド取得に失敗（無視）: $e');
    }
  }

  Future<void> _recordHistory() async {
    debugPrint('📍 [DEBUG Detail] _recordHistory 開始 (SQLite書き込み前)');
    try {
      final db = DatabaseService();
      await db.insertOrUpdateHistory(
        workId: widget.novel.id,
        title: widget.novel.title,
        authorName: widget.novel.author.name,
        previewUrl: widget.novel.coverUrl,
        type: 'novel',
      );
      debugPrint('📍 [DEBUG Detail] _recordHistory 終了 (SQLite書き込み成功)');

      // ベクトル生成・保存（キャプションを使用、バックグラウンドで実行）
      // AIモデル未ダウンロード時はスキップ（裏処理なのでユーザー動作をブロックしない）
      try {
        if (await RuriModelManager().isModelPresent()) {
          final embeddingService = EmbeddingService();
          final textForEmbedding = buildNovelDocumentText(widget.novel);
          final embedding = await embeddingService.encodeDocument(
            textForEmbedding,
          );
          await DatabaseService().saveNovelEmbedding(
            workId: widget.novel.id,
            embedding: embedding,
          );
          // フィーリング検索用メタデータを novels テーブルに保存
          await DatabaseService().saveNovel(widget.novel);
        }
      } catch (e) {
        debugPrint('ベクトル生成・保存に失敗しました（無視して続行）: $e');
      }
    } catch (e) {
      debugPrint("⚠️ [History Save Error] 履歴の保存に失敗しました（処理は続行します）: $e");
    }
  }

  // 購読（サブスクリプション）ダイアログを表示し登録を行う
  void _showSubscriptionDialog(String tag) {
    final colorScheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: colorScheme.surfaceContainerHigh,
          title: Text(
            'タグ「$tag」の購読登録',
            style: TextStyle(
              color: colorScheme.onSurface,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'このタグを購読登録しますか？\n端末内のローカルデータベースに保存され、購読タグ一覧からタップで検索できます。',
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'キャンセル',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                try {
                  final db = DatabaseService();
                  await db.addSubscribedTag(tag, 'novel');
                  _showSuccessSnackBar('「$tag」を購読登録しました！');
                } catch (e) {
                  _showErrorSnackBar('購読登録に失敗しました: $e');
                }
              },
              child: Text(
                '購読する',
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showSuccessSnackBar(String message) {
    if (!mounted) return;
    final colorScheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: colorScheme.primaryContainer,
        duration: const Duration(seconds: 4),
        // 「あとで読む」追加時は一覧へ直接飛べるアクションを付与
        action: _isReadLaterAction,
      ),
    );
  }

  /// 「あとで読む」登録時のみ表示する「一覧を見る」アクション。
  /// 未登録の成功メッセージ（削除等）には null を返してアクション非表示。
  SnackBarAction? get _isReadLaterAction {
    if (!_isReadLater) return null;
    final colorScheme = Theme.of(context).colorScheme;
    return SnackBarAction(
      label: '一覧を見る',
      textColor: colorScheme.onPrimaryContainer,
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ReadLaterScreen()),
        );
      },
    );
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    final colorScheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: colorScheme.errorContainer,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// シリーズ進捗を読み込む（Phase N3）。シリーズ作品・取得成功時のみ表示。
  Future<void> _loadSeriesProgress() async {
    final seriesId = widget.novel.series?.id ?? 0;
    if (seriesId <= 0) return;
    try {
      final progress = await SeriesProgressService().fetch(
        seriesId,
        currentWorkId: widget.novel.id,
      );
      if (!mounted || progress == null) return;
      setState(() => _seriesProgress = progress);
    } catch (e) {
      debugPrint('シリーズ進捗の取得に失敗（無視）: $e');
    }
  }

  /// 次の未読話を開く（Phase N3）。全話読了時は SnackBar で通知。
  Future<void> _openNextSeriesWork() async {
    final progress = _seriesProgress;
    final next = progress?.nextUnreadWork;
    if (next == null) {
      _showSuccessSnackBar('このシリーズは全話読了済みです');
      return;
    }
    try {
      final novel = await PixivApiService().getNovelById(next.id);
      if (!mounted) return;
      // 17b: 詳細画面は root Navigator に積みボトムナビを隠す。
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => NovelDetailScreen(novel: novel)),
      );
    } catch (e) {
      if (mounted) _showErrorSnackBar('次の作品の取得に失敗しました: $e');
    }
  }

  /// シリーズ進捗カード（B5 コンパクト化）。
  /// 「シリーズ 3/12話 ▶ 次: 第4話」＋細い進捗バー。
  Widget _buildSeriesProgressCard() {
    final progress = _seriesProgress!;
    final next = progress.nextUnreadWork;
    final isComplete = progress.readCount >= progress.totalCount;
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_stories, size: 14, color: colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                '${progress.readCount}/${progress.totalCount}話',
                style: TextStyle(
                  color: colorScheme.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress.progressRatio,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      colorScheme.primary,
                    ),
                    minHeight: 3,
                  ),
                ),
              ),
              if (isComplete) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_circle, size: 14, color: colorScheme.primary),
                const SizedBox(width: 2),
                Text(
                  '読了',
                  style: TextStyle(
                    color: colorScheme.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ] else if (next != null) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: _openNextSeriesWork,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '次: ${next.title}',
                          style: TextStyle(
                            color: colorScheme.primary,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.play_arrow,
                          size: 14,
                          color: colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _loadReadingProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final progress = prefs.getDouble('novel_progress_${widget.novel.id}');
      if (progress != null && progress > 0.0) {
        if (!mounted) return;
        setState(() {
          // 保存値はパーセント(0〜100)なので、表示用(0.0〜1.0)に変換
          _readingProgress = progress / 100.0;
        });
      }
    } catch (e) {
      debugPrint('進捗の取得に失敗しました: $e');
    }
  }

  /// しおり（読書進捗）削除の確認ダイアログを表示
  Future<void> _confirmDeleteBookmark() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('しおりを削除'),
        content: const Text('保存されている読書進捗（しおり）を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _deleteBookmark();
    }
  }

  /// しおり関連の SharedPreferences キーをすべて削除する
  Future<void> _deleteBookmark() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('novel_progress_${widget.novel.id}');
      await prefs.remove('novel_page_${widget.novel.id}');
      await prefs.remove('novel_offset_${widget.novel.id}');
      if (!mounted) return;
      setState(() {
        _readingProgress = null;
      });
    } catch (e) {
      debugPrint('しおりの削除に失敗しました: $e');
    }
  }

  Future<void> _toggleBookmark() async {
    if (_isToggling) return;
    setState(() => _isToggling = true);

    final toAdd = !_isBookmarked;
    final api = PixivApiService();

    // Phase 10a (B-7): Service が投げた例外を型別に受け、理由を伝える。
    // 成功（例外なし）の場合のみブックマーク状態を更新する。
    String? errorMessage;
    try {
      await api.toggleBookmark(widget.novel.id, true, toAdd);
    } on RateLimitException {
      errorMessage = 'レート制限です。少し待ってから再試行してください。';
    } on AuthException {
      errorMessage = '認証が切れました。再ログインしてください。';
    } catch (e) {
      errorMessage = '通信に失敗しました。再度お試しください。';
    }

    if (!mounted) return;

    if (errorMessage == null) {
      setState(() {
        _isBookmarked = toAdd;
        _bookmarkCountOffset += toAdd ? 1 : -1;
        widget.onBookmarkChanged?.call(toAdd);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(toAdd ? 'ブックマークに追加しました' : 'ブックマークを解除しました'),
          duration: const Duration(seconds: 1),
        ),
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorMessage)));
    }
    if (!mounted) return;
    setState(() => _isToggling = false);
  }

  Future<void> _muteAuthor() async {
    try {
      final db = DatabaseService();
      await db.insertOrUpdateMute(
        muteType: 'user',
        value: widget.novel.author.id.toString(),
        label: widget.novel.author.name,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${widget.novel.author.name} さんをミュートしました。'),
          duration: const Duration(seconds: 2),
        ),
      );
      Navigator.pop(context, true); // ミュート成功として前の画面に戻り再ロードを促す
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラーが発生しました: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('📍 [DEBUG Detail] build 開始');
    final colorScheme = Theme.of(context).colorScheme;
    final String caption = widget.novel.caption;
    final Widget result = Scaffold(
      appBar: AppBar(
        title: const Text('小説詳細'),
        actions: [
          IconButton(
            icon: _isToggling
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.primary,
                    ),
                  )
                : Icon(
                    _isBookmarked ? Icons.favorite : Icons.favorite_border,
                    color: _isBookmarked
                        ? colorScheme.primary
                        : colorScheme.onSurface,
                  ),
            onPressed: _toggleBookmark,
            tooltip: 'ブックマーク',
          ),
          IconButton(
            icon: Icon(
              _isReadLater ? Icons.bookmark_added : Icons.bookmark_add_outlined,
              color: _isReadLater ? colorScheme.primary : colorScheme.onSurface,
            ),
            onPressed: _toggleReadLater,
            tooltip: _isReadLater ? 'あとで読むから削除' : 'あとで読むに追加',
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // 1. 小説カバーと簡易紹介
            Container(
              padding: const EdgeInsets.all(20.0),
              color: colorScheme.surfaceContainer,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 90,
                    height: 125,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: widget.novel.coverUrl.isNotEmpty
                        ? PixivImage(
                            url: widget.novel.coverUrl,
                            fit: BoxFit.cover,
                            isThumbnail: true,
                            errorWidget: Icon(
                              Icons.book,
                              size: 40,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          )
                        : Icon(
                            Icons.book,
                            size: 40,
                            color: colorScheme.onSurfaceVariant,
                          ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.novel.title,
                          style: TextStyle(
                            color: colorScheme.onSurface,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        InkWell(
                          onTap: () {
                            // 17b: 作者画面も root Navigator に積む。
                            Navigator.of(context, rootNavigator: true).push(
                              MaterialPageRoute(
                                builder: (context) => AuthorProfileScreen(
                                  userId: widget.novel.author.id,
                                ),
                              ),
                            );
                          },
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 12,
                                backgroundImage:
                                    widget.novel.author.avatar != null &&
                                        widget.novel.author.avatar!.isNotEmpty
                                    ? NetworkImage(
                                        widget.novel.author.avatar!,
                                        headers: const {
                                          'Referer':
                                              'https://app-api.pixiv.net/',
                                        },
                                      )
                                    : null,
                                child:
                                    (widget.novel.author.avatar == null ||
                                        widget.novel.author.avatar!.isEmpty)
                                    ? const Icon(Icons.person, size: 12)
                                    : null,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  widget.novel.author.name,
                                  style: TextStyle(
                                    color: colorScheme.primary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '📄 ${widget.novel.pageCount}P  |  ✍️ ${widget.novel.textLength}文字',
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        // 読了目安バッジ（Phase A）
                        if (_estReadingMinutes != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            '⏱ 読了目安 ${formatReadingTime(_estReadingMinutes!)}'
                            '${_estReadingIsDefault ? '（推定）' : ''}',
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        if (_readingProgress != null) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Icon(
                                Icons.bookmark_added,
                                size: 14,
                                color: colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '読書進捗: ${((_readingProgress ?? 0.0) * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                                  color: colorScheme.primary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: Icon(
                                  Icons.delete_outline,
                                  size: 16,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                tooltip: 'しおりを削除',
                                onPressed: () => _confirmDeleteBookmark(),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: () async {
                            // 17b: リーダーは root Navigator に積みボトムナビを隠す。
                            final res =
                                await Navigator.of(
                                  context,
                                  rootNavigator: true,
                                ).push(
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        NovelReaderScreen(novel: widget.novel),
                                  ),
                                );
                            if (!mounted) return;
                            if (res == true) {
                              _loadReadingProgress();
                            }
                          },
                          icon: const Icon(Icons.chrome_reader_mode, size: 16),
                          label: Text(
                            _readingProgress != null ? '続きから読む' : '小説を読む',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: colorScheme.primary,
                            foregroundColor: colorScheme.onPrimary,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                        ),
                        // AI要約（実験）: 対応プラットフォーム + GGUF配置済みのみ表示
                        if (_llmSummaryAvailable) ...[
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: _showLlmSummarySheet,
                            icon: const Icon(Icons.auto_awesome, size: 16),
                            label: const Text('AI要約（実験）'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: colorScheme.primary,
                              side: BorderSide(color: colorScheme.primary),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                          ),
                        ],
                        // シリーズ進捗カード（Phase N3）
                        if (_seriesProgress != null) ...[
                          const SizedBox(height: 12),
                          _buildSeriesProgressCard(),
                        ],
                        // シリーズ作品の場合のみ「話数の一覧」へ遷移するボタンを表示
                        if (widget.novel.series != null &&
                            widget.novel.series!.id != 0) ...[
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: () {
                              // 17b: 話数一覧も root Navigator に積む。
                              Navigator.of(context, rootNavigator: true).push(
                                MaterialPageRoute(
                                  builder: (context) =>
                                      NovelSeriesEpisodesScreen(
                                        series: widget.novel.series!,
                                        coverUrl: widget.novel.coverUrl,
                                        author: widget.novel.author,
                                      ),
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.format_list_bulleted,
                              size: 16,
                            ),
                            label: const Text('話数の一覧を見る'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: colorScheme.primary,
                              side: BorderSide(color: colorScheme.primary),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // B4: AIモデル未導入時は感情曲線カードを丸ごと非表示（導入案内も出さない）。
            if (_emotionModelAvailable) ...[
              _buildEmotionCurveCard(),
              const SizedBox(height: 12),
            ],
            // B4: AIモデル未導入時は似た作品セクションを丸ごと非表示。
            if (_similar?.modelReady ?? false) ...[
              _buildSimilarWorksCard(),
              const SizedBox(height: 12),
            ],

            // 2. 詳細メタ情報
            Container(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ミュートボタン
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              backgroundColor: colorScheme.surfaceContainerHigh,
                              title: Text(
                                '作者をミュート',
                                style: TextStyle(
                                  color: colorScheme.onSurface,
                                  fontSize: 16,
                                ),
                              ),
                              content: Text(
                                '${widget.novel.author.name} さんをミュートしますか？\n今後この作者の作品は表示されなくなります。',
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 13,
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: Text(
                                    'キャンセル',
                                    style: TextStyle(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    _muteAuthor();
                                  },
                                  child: Text(
                                    'ミュートする',
                                    style: TextStyle(color: colorScheme.error),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                        icon: Icon(
                          Icons.block,
                          size: 14,
                          color: colorScheme.error,
                        ),
                        label: Text(
                          '作者をミュート',
                          style: TextStyle(
                            color: colorScheme.error,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          backgroundColor: colorScheme.error.withValues(
                            alpha: 0.1,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // あらすじ
                  if (caption.isNotEmpty) ...[
                    Text(
                      '📖 あらすじ',
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _cleanHTML(caption),
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // 統計情報
                  Row(
                    children: [
                      Icon(
                        Icons.remove_red_eye_outlined,
                        size: 16,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${widget.novel.totalView}',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Icon(
                        Icons.favorite,
                        size: 16,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${widget.novel.totalBookmarks + _bookmarkCountOffset}',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _formatDate(widget.novel.createDate),
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  Divider(color: colorScheme.outlineVariant, height: 32),

                  // タグ
                  Text(
                    '🏷️ タグ一覧 (タップで検索 / 長押しで自動同期・購読登録)',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8.0,
                    runSpacing: 4.0,
                    children: widget.novel.tags.map((tag) {
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          widget.onTagTap?.call(tag);
                        },
                        onLongPress: () {
                          _showSubscriptionDialog(tag);
                        },
                        child: Chip(
                          label: Text(
                            tag,
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          backgroundColor: colorScheme.primary.withValues(
                            alpha: 0.1,
                          ),
                          side: BorderSide(
                            color: colorScheme.primary.withValues(alpha: 0.5),
                            width: 0.5,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    debugPrint('📍 [DEBUG Detail] build 終了');
    return result;
  }

  String _cleanHTML(String htmlString) {
    return htmlString.replaceAll(RegExp(r'<[^>]*>'), '');
  }

  String _formatDate(String isoDate) {
    // Phase 10b: 共通 DateTimeFormat.formatDateOnly に集約（日付のみ表示）。
    return DateTimeFormat.formatDateOnly(isoDate);
  }
}

/// 感情曲線ペインター（Phase C）。感情ごとの z スコア曲線を折れ線で描画する。
class _EmotionCurvePainter extends CustomPainter {
  final EmotionCurveResult curve;

  _EmotionCurvePainter({required this.curve});

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = _bgColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      bgPaint,
    );

    // 0 ライン（中心線）
    final midY = size.height / 2;
    final baselinePaint = Paint()
      ..color = _baselineColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), baselinePaint);

    final chunks = curve.chunks.length;
    if (chunks < 2) return;
    final stepX = size.width / (chunks - 1);
    const zMax = 3.0;

    for (
      var i = 0;
      i < curve.zScores.length && i < kEmotionLabels.length;
      i++
    ) {
      final colorValue = kEmotionColorValues[kEmotionLabels[i]] ?? 0xFF9E9E9E;
      final paint = Paint()
        ..color = Color(colorValue)
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke;
      final path = Path();
      final series = curve.zScores[i];
      for (var j = 0; j < series.length; j++) {
        final x = j * stepX;
        final z = series[j].clamp(-zMax, zMax);
        final y = midY - (z / zMax) * (size.height / 2 - 6);
        if (j == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EmotionCurvePainter oldDelegate) {
    return oldDelegate.curve != curve;
  }

  /// 17d: キャンバス描画色も ColorScheme トークンから取る。ダーク/ライト両対応。
  static Color get _bgColor =>
      AppTheme.darkTheme.colorScheme.surfaceContainerHighest;
  static Color get _baselineColor =>
      AppTheme.darkTheme.colorScheme.onSurface.withValues(alpha: 0.15);
}

/// 似た作品カード（Phase D）。表紙 + タイトル + 「なぜ似ているか」の一行理由。
class _SimilarWorkCard extends StatelessWidget {
  final SimilarWork work;
  final VoidCallback onTap;

  const _SimilarWorkCard({required this.work, required this.onTap});

  String _coverUrl() {
    // DB 行: cover_url / API モデル: image_urls.large 等
    final cu = work.row['cover_url'];
    if (cu is String && cu.isNotEmpty) return cu;
    final iu = work.row['image_urls'];
    if (iu is Map) {
      for (final k in const ['large', 'medium', 'square_medium']) {
        final v = iu[k];
        if (v is String && v.isNotEmpty) return v;
      }
    }
    return '';
  }

  String _title() {
    final t = work.row['title'];
    return t is String && t.isNotEmpty ? t : '無題';
  }

  @override
  Widget build(BuildContext context) {
    final cover = _coverUrl();
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 100,
      margin: const EdgeInsets.only(right: 10),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 100,
                height: 88,
                child: cover.isNotEmpty
                    ? PixivImage(
                        url: cover,
                        fit: BoxFit.cover,
                        isThumbnail: true,
                        errorWidget: Container(
                          color: colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.book,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : Container(
                        color: colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.book,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _title(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colorScheme.onSurface, fontSize: 11),
            ),
            Text(
              work.reason,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colorScheme.primary, fontSize: 9),
            ),
          ],
        ),
      ),
    );
  }
}

/// 似た作品の一覧画面（Phase D）。軸タブ（総合 / 意味 / タグ）で並べ替え。
class SimilarWorksScreen extends StatefulWidget {
  final String baseTitle;
  final SimilarWorksResult result;
  final ValueChanged<SimilarWork> onOpen;

  const SimilarWorksScreen({
    super.key,
    required this.baseTitle,
    required this.result,
    required this.onOpen,
  });

  @override
  State<SimilarWorksScreen> createState() => _SimilarWorksScreenState();
}

class _SimilarWorksScreenState extends State<SimilarWorksScreen> {
  String _axis = '総合';

  List<SimilarWork> _sorted() {
    final list = List<SimilarWork>.from(widget.result.works);
    double key(SimilarWork w) {
      switch (_axis) {
        case '意味':
          return w.semanticScore;
        case 'タグ':
          return w.tagScore;
        case '視覚':
          return w.visualScore;
        default:
          return w.score;
      }
    }

    list.sort((a, b) => key(b).compareTo(key(a)));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final axes = ['総合', '意味', 'タグ', '視覚'];
    final works = _sorted();
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '「${widget.baseTitle}」に似た作品',
          style: TextStyle(color: colorScheme.onSurface, fontSize: 15),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final a in axes)
                  ChoiceChip(
                    label: Text(a),
                    selected: _axis == a,
                    onSelected: (_) => setState(() => _axis = a),
                    selectedColor: colorScheme.primary.withValues(alpha: 0.25),
                    labelStyle: TextStyle(
                      color: _axis == a
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: works.isEmpty
                ? Center(
                    child: Text(
                      '似た作品はありません',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    itemCount: works.length,
                    itemBuilder: (context, i) {
                      final w = works[i];
                      return ListTile(
                        onTap: () => widget.onOpen(w),
                        title: Text(
                          w.row['title']?.toString() ?? '無題',
                          style: TextStyle(
                            color: colorScheme.onSurface,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          'スコア ${(w.score * 100).toStringAsFixed(0)}% / '
                          '意味 ${(w.semanticScore * 100).toStringAsFixed(0)} '
                          'タグ ${(w.tagScore * 100).toStringAsFixed(0)} '
                          '視覚 ${(w.visualScore * 100).toStringAsFixed(0)}',
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                        trailing: Text(
                          w.reason,
                          style: TextStyle(
                            color: colorScheme.primary,
                            fontSize: 10,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
