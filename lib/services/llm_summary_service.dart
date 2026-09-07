import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart' show LlamaChatMessage, LlamaChatRole;

import '../novel_model.dart' show NovelTextData;
import 'local_llm_service.dart';
import 'novel_parser.dart';

/// 小説のAI要約結果（3セクション + 生成メタ情報）。
class LlmSummaryResult {
  /// 3行あらすじ。
  final String synopsis;

  /// スーパー軽めの導入文（2〜3文）。
  final String intro;

  /// タグ候補（最大5件）。
  final List<String> tagSuggestions;

  /// 最終結果で作者説明・本文との過度な重複を検出したか（M1）。
  ///
  /// true の場合 UI は小さな警告を表示する（結果自体は表示する）。
  final bool copyWarning;

  /// 生成元メモ（例: 「生成元: 小説本文（…文字）」）。
  final String? bodySourceNote;

  /// 使用モデルの表示ラベル（M5）。不明なら null。
  final String? modelLabel;

  /// 生成に要した時間（ミリ秒・M5）。不明なら null。
  final int? generationMs;

  /// 1秒あたりの生成トークン数（M5）。不明なら null。
  final double? tokensPerSecond;

  /// 生成完了日時（M5・ローカル時刻）。不明なら null。
  final DateTime? generatedAt;

  /// 生成開始 → 最初の表示用 content までの実測ミリ秒（B）。不明なら null。
  final int? timeToFirstTokenMs;

  /// プロンプト入力のトークン数（B）。トークナイザで実測できた場合のみ設定。
  final int? inputTokens;

  const LlmSummaryResult({
    required this.synopsis,
    required this.intro,
    required this.tagSuggestions,
    this.copyWarning = false,
    this.bodySourceNote,
    this.modelLabel,
    this.generationMs,
    this.tokensPerSecond,
    this.generatedAt,
    this.timeToFirstTokenMs,
    this.inputTokens,
  });
}

/// 要約生成でユーザーに表示する例外（自然な日本語メッセージを持つ）。
class LlmSummaryException implements Exception {
  final String message;
  const LlmSummaryException(this.message);
  @override
  String toString() => message;
}

/// 小説本文を取得できなかった場合のメッセージ（M1: 作者説明へのフォールバック禁止）。
const String kLlmBodyUnavailableMessage = '小説本文を取得できないため、AI要約を生成できません。';

/// 小説要約サービス（プロンプト構築・出力解析・拒否検知・コピー検出）。
///
/// M1（オウム返し排除）:
/// - 主入力 は**小説本文のみ**（作者説明はプロンプトに含めない。
///   タイトル + タグは補助情報のみ）。
/// - 本文は [normalizeNovelBody] で正規化（挿絵・ルビ・制御タグを除去）。
/// - 長い本文は [extractBalancedBody] で冒頭/中盤/終盤を均衡抽出
///   （合計 [maxBodyChars] 文字）。
/// - コピー検出 [isExcessiveCopy]（n-gram 重複率）: 閾値超過時は
///   言い換え強化プロンプトで**最大1回だけ**再生成。2回目でなお超過なら
///   [LlmSummaryResult.copyWarning] 警告付きで表示（無限再生成しない）。
class LlmSummaryService {
  LlmSummaryService._();

  /// 本文入力予算（文字数）。[extractBalancedBody] の冒頭+中盤+終盤の合計。
  static const int maxBodyChars = 3000;

  /// コピー検出の n（文字数）。
  static const int copyNgram = 5;

  /// コピー検出の最小出力長（これ未満の出力は検出から除外）。
  static const int copyMinLen = 30;

  /// 作者説明との重複閾値（出力 n-gram のうち説明に出現する比率）。
  static const double copyThresholdDescription = 0.4;

  /// 入力本文との重複閾値（出力 n-gram のうち本文に出現する比率）。
  static const double copyThresholdBody = 0.5;

  /// 出力形式のセクションマーカー（プロンプトと解析の両方で使用）。
  static const String sectionSynopsis = '【あらすじ】';
  static const String sectionIntro = '【紹介】';
  static const String sectionTags = '【タグ】';

  /// 本文を [maxChars] 文字に截断する（前後の空白は除去）。
  ///
  /// 後方互換のため残す。プロンプト経路は
  /// [normalizeNovelBody] + [extractBalancedBody] を使う。
  static String clampBody(String body, {int maxChars = maxBodyChars}) {
    final normalized = body.trim();
    if (normalized.length <= maxChars) return normalized;
    return normalized.substring(0, maxChars);
  }

  /// 小説本文の生テキストから挿絵・ルビ・制御タグを除去し、
  /// 表示可能なプレーンテキスト（プロンプト入力用）にする。
  ///
  /// [NovelParser.parsePage] を使う:
  /// - `[uploadedimage:N]` / `[pixivimage:N(-p)]` / `[newpage]` → 除去
  /// - `[[rb:base > ruby]]` → base（ルビは畳む）
  /// パーサがプレーンテキストとして残した変形タグは正規表現で安全除去する。
  static String normalizeNovelBody(String raw) {
    final blocks = NovelParser.parsePage(raw);
    final sb = StringBuffer();
    for (final block in blocks) {
      if (block is! ParagraphBlock) continue;
      final collapsed = NovelParser.collapseRunsForDisplay(
        block.runs,
        RubyDisplayMode.hide,
      );
      final plain = collapsed.map((r) => (r as PlainText).text).join();
      final trimmed = plain.trim();
      if (trimmed.isEmpty) continue;
      if (sb.isNotEmpty) sb.writeln();
      sb.write(trimmed);
    }
    var out = sb.toString().trim();
    out = out
        .replaceAll(RegExp(r'\[\[rb:[^\]]*\]\]'), '')
        .replaceAll(RegExp(r'\[uploadedimage:\d+\]'), '')
        .replaceAll(RegExp(r'\[pixivimage:\d+(?:-\d+)?\]'), '')
        .replaceAll(RegExp(r'\[newpage\]'), '');
    return out.trim();
  }

  /// 本文から均衡抜粋（冒頭 / 中盤 / 終盤）を抽出する。
  ///
  /// [normalized] が [maxChars] 以下ならそのまま返す。超える場合は
  /// 合計 [maxChars] を3等分して冒頭・中盤・終盤を取り、
  /// 省略マーカーで結合する。
  static String extractBalancedBody(
    String normalized, {
    int maxChars = maxBodyChars,
  }) {
    final text = normalized.trim();
    if (text.length <= maxChars) return text;
    final per = maxChars ~/ 3;
    final head = text.substring(0, per);
    final midStart = (text.length - per) ~/ 2;
    final mid = text.substring(midStart, midStart + per);
    final tail = text.substring(text.length - per);
    return '$head\n…（中略）…\n$mid\n…（中略）…\n$tail';
  }

  /// システムプロンプト（日本語・厳格な出力形式を指定）。
  ///
  /// M1: 作者説明に言及しない。本文に基づく要約・ネタバレ禁止を明示する。
  static const String _systemPrompt =
      'あなたは小説を要約するアシスタントです。\n'
      'ユーザーは小説のタイトル・タグ・本文の抜粋（冒頭/中盤/終盤）を渡します。\n'
      '本文の内容に基づいて、自分の言葉でオリジナルの要約を書きなさい。'
      '入力には作者の説明文は含まれません。本文の文面をそのまま写さないこと。\n'
      '具体的な結末や重要な真相のネタバレは含めないこと。\n'
      '以下の形式だけを、余計な説明なしで出力してください。\n'
      '【あらすじ】\n'
      '3行（1行1文・作品の全体像を絞った要約）\n'
      '【紹介】\n'
      'ネタバレの少ない導入文（2〜3文・読者に作品の魅力を伝える。'
      '具体的な結末や重要な真相を書かないこと）\n'
      '【タグ】\n'
      '5つの候補タグ（半角コンマで区切った1行）';

  /// 要約生成用メッセージ列（system + user）を構築する。
  ///
  /// M1: 作者説明（description）は**含まない**。タイトル + タグは補助のみ。
  /// 本文は [normalizeNovelBody] で正規化し [extractBalancedBody] で
  /// 均衡抽出する。
  ///
  /// [emphasizeRephrase] はコピー検出後のリトライ時に言い換えを強調する。
  static List<LlamaChatMessage> buildPrompt({
    required String title,
    List<String> tags = const [],
    required String body,
    bool emphasizeRephrase = false,
  }) {
    final tagLine = tags
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .join(', ');
    final excerpt = extractBalancedBody(normalizeNovelBody(body));
    final buffer = StringBuffer()
      ..writeln('タイトル: ${title.trim()}')
      ..writeln('タグ: ${tagLine.isEmpty ? '（なし）' : tagLine}')
      ..writeln('本文（抜粋・冒頭/中盤/終盤）:')
      ..writeln(excerpt);
    if (emphasizeRephrase) {
      buffer.writeln(
        '注意: 前の回答は既存の文章と酷似していました。'
        '必ず文構造・語彙を変えて、自分の言葉で要約し直してください。',
      );
    }
    return [
      LlamaChatMessage.fromText(
        role: LlamaChatRole.system,
        text: _systemPrompt,
      ),
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: buffer.toString(),
      ),
    ];
  }

  /// モデル出力から [LlmSummaryResult] を解析する。
  ///
  /// 3セクション（【あらすじ】【紹介】【タグ】）が揃い、タグが1件以上
  /// 見つからなければ null を返す（呼び出し側が例外に変換する）。
  static LlmSummaryResult? parseOutput(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final synopsis = _extractSection(text, sectionSynopsis, [
      sectionIntro,
      sectionTags,
    ]);
    final intro = _extractSection(text, sectionIntro, [sectionTags]);
    final tagsRaw = _extractSection(text, sectionTags, const []);
    if (synopsis == null || intro == null || tagsRaw == null) return null;
    final tags = _splitTags(tagsRaw);
    if (tags.isEmpty) return null;
    return LlmSummaryResult(
      synopsis: synopsis,
      intro: intro,
      tagSuggestions: tags.length > 5 ? tags.sublist(0, 5) : tags,
    );
  }

  /// [start] マーカー以降、[ends] のいずれかのマーカー以前を抽出。
  static String? _extractSection(String text, String start, List<String> ends) {
    final i = text.indexOf(start);
    if (i < 0) return null;
    var content = text.substring(i + start.length);
    var end = content.length;
    for (final e in ends) {
      final j = content.indexOf(e);
      if (j >= 0 && j < end) end = j;
    }
    return content.substring(0, end).trim();
  }

  /// タグ行を分解する（コンマ・読点・空白・改行で区切り）。
  /// 先頭の箇条書きマーカー（「1. 」や「・」）だけを取り除く。
  static List<String> _splitTags(String raw) {
    return raw
        .split(RegExp(r'[、,，\s]+'))
        .map(
          (t) =>
              t.trim().replaceAll(RegExp(r'^(?:\d+[.、)）]\s*|[・\-*]\s*)'), ''),
        )
        .where((t) => t.isNotEmpty)
        .toList();
  }

  /// 出力がモデルの拒否応答に該当するか（解析失敗時のみ判定する）。
  static bool looksRefused(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return false;
    if (parseOutput(t) != null) return false;
    const patterns = <String>[
      '申し訳ありません',
      'ごめんなさい',
      'お答えできません',
      'お助けできません',
      '提供できません',
      '生成できません',
      '生成を控える',
      'ポリシー',
      'ガイドライン',
      '倫理的',
      'Sorry',
      "I'm sorry",
      'I cannot',
      "I can't",
      'I apologize',
    ];
    return patterns.any((p) => t.contains(p));
  }

  // ------------------------------------------------------------------
  // コピー検出（M1: 純粋関数・閾値は調整可能）
  // ------------------------------------------------------------------

  /// コピー検出用にテキストを正規化する（小文字化・空白・句読点除去）。
  static String normalizeForCopyDetection(String text) {
    var out = text.toLowerCase();
    out = out.replaceAll(RegExp(r'\s+'), '');
    out = out.replaceAll(RegExp(r'[、。．,.!！?？;；:：（）()「」『』【】\[\]{}]'), '');
    return out;
  }

  /// n-gram 部分文字列の集合。
  static Set<String> _ngrams(String text, int n) {
    final out = <String>{};
    if (text.length < n) return out;
    for (var i = 0; i + n <= text.length; i++) {
      out.add(text.substring(i, i + n));
    }
    return out;
  }

  /// [output] の n-gram が [source] の n-gram に出現する重複率（0..1）を返す。
  ///
  /// 出力が短すぎ（[minLen] 未満）または source が [n] 未満なら 0.0
  /// （短い出力は検出から除外する）。
  static double calculateNgramOverlap({
    required String output,
    required String source,
    int n = copyNgram,
    int minLen = copyMinLen,
  }) {
    final o = normalizeForCopyDetection(output);
    final s = normalizeForCopyDetection(source);
    if (o.length < minLen || s.length < n) return 0.0;
    final outGrams = _ngrams(o, n);
    if (outGrams.isEmpty) return 0.0;
    final srcGrams = _ngrams(s, n);
    var hits = 0;
    for (final g in outGrams) {
      if (srcGrams.contains(g)) hits++;
    }
    return hits / outGrams.length;
  }

  /// [output] が作者説明または入力本文と過度に重複するかを判定する。
  ///
  /// 純粋関数。[descThreshold] / [bodyThreshold] は調整可能。
  static bool isExcessiveCopy({
    required String output,
    required String body,
    String? description,
    int n = copyNgram,
    int minLen = copyMinLen,
    double descThreshold = copyThresholdDescription,
    double bodyThreshold = copyThresholdBody,
  }) {
    if (description != null) {
      final d = calculateNgramOverlap(
        output: output,
        source: description,
        n: n,
        minLen: minLen,
      );
      if (d >= descThreshold) return true;
    }
    final b = calculateNgramOverlap(
      output: output,
      source: body,
      n: n,
      minLen: minLen,
    );
    return b >= bodyThreshold;
  }

  /// 小説本文を解決する（M1）: キャッシュ → ネットワーク取得 + キャッシュ保存 → null。
  ///
  /// 依存関数は注入（本物のDB/ネットワークなしでテスト可能）。
  /// 取得失敗・空本文は null を返す。呼び出し側は
  /// [kLlmBodyUnavailableMessage] を表示し、
  /// **作者説明へフォールバックしない**こと。
  static Future<String?> resolveNovelBody({
    required int workId,
    required Future<Map<String, dynamic>?> Function(int workId) getCached,
    required Future<NovelTextData> Function(int workId) fetchText,
    Future<void> Function(NovelTextData data)? saveToCache,
  }) async {
    try {
      final row = await getCached(workId);
      final cached = (row?['text'] as String?) ?? '';
      if (cached.trim().isNotEmpty) return cached;
    } catch (_) {
      // キャッシュ読込失敗時はネットワーク取得へ続行。
    }
    try {
      final data = await fetchText(workId);
      final text = data.novelText;
      if (text.trim().isEmpty) return null;
      if (saveToCache != null) {
        try {
          await saveToCache(data);
        } catch (_) {
          // キャッシュ保存失敗は要約生成を妨げない。
        }
      }
      return text;
    } catch (_) {
      return null;
    }
  }

  /// キャッシュ照会用の入力フィンガープリント（M6）。
  ///
  /// プロンプト入力（タイトル + タグ + 正規化本文の均衡抜粋）の SHA-256。
  /// 本文・タイトル・タグのいずれかが変わればキャッシュミスになる。
  static String computeSourceFingerprint({
    required String title,
    List<String> tags = const [],
    required String body,
  }) {
    final excerpt = extractBalancedBody(normalizeNovelBody(body));
    final tagLine = tags
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .join(',');
    return sha256
        .convert(utf8.encode('v2|$title|$tagLine|$excerpt'))
        .toString();
  }

  /// 要約生成を一通り実行する（本文正規化 → プロンプト構築 → 生成 → 解析 → コピー検出）。
  ///
  /// [service] は呼び出し側が loadModel 済みであることを想定。
  /// 失敗時は [LlmSummaryException]（自然な日本語メッセージ）を投げる。
  /// キャンセル時は [LlmCancelledException] をそのまま送出する。
  ///
  /// M1 ルール:
  /// - 本文が空なら [kLlmBodyUnavailableMessage] を投げる
  ///   （作者説明へのフォールバックはしない）。
  /// - [isExcessiveCopy] で閾値超過なら言い換え強化プロンプトで
  ///   **最大1回だけ**再生成。2回目でなお超過なら copyWarning: true
  ///   を付けて返す（無限再生成しない）。
  static Future<LlmSummaryResult> generate({
    required LocalLlmService service,
    required String title,
    required String body,
    List<String> tags = const [],
    String? description,
    void Function(String piece)? onToken,
    String? modelLabel,
    void Function()? onRegeneration,
  }) async {
    final normalized = normalizeNovelBody(body);
    if (normalized.isEmpty) {
      throw const LlmSummaryException(kLlmBodyUnavailableMessage);
    }
    final excerpt = extractBalancedBody(normalized);
    final sourceNote = normalized.length <= maxBodyChars
        ? '生成元: 小説本文（全文 ${_fmtNum(normalized.length)} 文字）'
        : '生成元: 小説本文（全文 ${_fmtNum(normalized.length)} 文字から 冒頭・中盤・終盤 を抽出（計 ${_fmtNum(excerpt.length)} 文字））';

    LlmSummaryResult? result;
    var copyWarning = false;
    // B: 最終 attempt のプロンプトを保持し、生成後にトークン数を実測する。
    var lastMessages = const <LlamaChatMessage>[];
    for (var attempt = 0; attempt < 2; attempt++) {
      final messages = buildPrompt(
        title: title,
        tags: tags,
        body: body,
        emphasizeRephrase: attempt == 1,
      );
      lastMessages = messages;
      final raw = await service.generate(
        messages,
        onToken: onToken,
        options: service.generationOptions,
      );
      final parsed = parseOutput(raw);
      if (parsed == null) {
        if (looksRefused(raw)) {
          throw const LlmSummaryException(
            'モデルが今回の要約生成を拒否しました。もう一度試すか、別のモデルをお試しください。',
          );
        }
        throw const LlmSummaryException('モデルの出力を解析できませんでした。もう一度お試しください。');
      }
      result = parsed;
      final output = '${parsed.synopsis}\n${parsed.intro}';
      final excessive = isExcessiveCopy(
        output: output,
        body: excerpt,
        description: description,
      );
      if (attempt == 0 && excessive) {
        onRegeneration?.call();
        continue; // 言い換え強化プロンプトで1回だけ再生成（上限1回）。
      }
      copyWarning = excessive;
      break;
    }
    final r = result!;
    final stats = service.lastGenerationStats;
    // B: 入力トークン数。モデルのトークナイザで実測できる場合のみ設定する
    // （実測不可なら null のまま = 「個別取得不可」として扱う。推定値は報告しない）。
    final inputTokens = await service.promptTokenCount(lastMessages);
    return LlmSummaryResult(
      synopsis: r.synopsis,
      intro: r.intro,
      tagSuggestions: r.tagSuggestions,
      copyWarning: copyWarning,
      bodySourceNote: sourceNote,
      modelLabel: modelLabel,
      generationMs: stats?.elapsed.inMilliseconds,
      tokensPerSecond: stats?.tokensPerSecond,
      generatedAt: DateTime.now(),
      timeToFirstTokenMs: stats?.timeToFirstTokenMs,
      inputTokens: inputTokens,
    );
  }

  /// 数値をカンマ区切り整形（lookbehind 不使用）。
  static String _fmtNum(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
