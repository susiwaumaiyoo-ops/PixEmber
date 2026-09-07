import 'package:llamadart/llamadart.dart' show LlamaChatMessage, LlamaChatRole;

import 'local_llm_service.dart';

/// 小説のAI要約結果（3セクション）。
class LlmSummaryResult {
  /// 3行あらすじ。
  final String synopsis;

  /// スーパー軽めの導入文（2〜3文）。
  final String intro;

  /// タグ候補（最大5件）。
  final List<String> tagSuggestions;

  const LlmSummaryResult({
    required this.synopsis,
    required this.intro,
    required this.tagSuggestions,
  });
}

/// 要約生成でユーザーに表示する例外（自然な日本語メッセージを持つ）。
class LlmSummaryException implements Exception {
  final String message;
  const LlmSummaryException(this.message);
  @override
  String toString() => message;
}

/// 小説要約サービス（プロンプト構築・出力解析・拒否検知）。
///
/// 入力: タイトル / 説明（キャプション）/ タグ / 冒頭本文（[maxBodyChars] 文字で截断）。
/// 出力: [LlmSummaryResult]（あらすじ3行 / 紹介 / タグ候補5件）。
class LlmSummaryService {
  LlmSummaryService._();

  /// 本文の入力上限（文字数）。これを超える分は切り捨てる。
  static const int maxBodyChars = 2000;

  /// 出力形式のセクションマーカー（プロンプトと解析の両方で使用）。
  static const String sectionSynopsis = '【あらすじ】';
  static const String sectionIntro = '【紹介】';
  static const String sectionTags = '【タグ】';

  /// 本文を [maxBodyChars] 文字に截断する（前後の空白は除去）。
  static String clampBody(String body, {int maxChars = maxBodyChars}) {
    final normalized = body.trim();
    if (normalized.length <= maxChars) return normalized;
    return normalized.substring(0, maxChars);
  }

  /// システムプロンプト（日本語・厳格な出力形式を指定）。
  static const String _systemPrompt =
      'あなたは小説を要約するアシスタントです。\n'
      'ユーザーは小説のタイトル・あらすじ（作者書き）・タグ・本文の冒頭を渡します。\n'
      '以下の形式だけを、余計な説明なしで出力してください。\n'
      '【あらすじ】\n'
      '3行（1行1文・作品の全体像を絞った要約）\n'
      '【紹介】\n'
      'ネタバレの少ない導入文（2〜3文・読者に作品の魅力を伝える）\n'
      '【タグ】\n'
      '5つの候補タグ（半角コンマで区切った1行）';

  /// 要約生成用メッセージ列（system + user）を構築する。
  ///
  /// チャットテンプレート（ChatML / Gemma instruct 等の Jinja テンプレート）は
  /// llamadart が GGUF の metadata から自動検出し [LlamaEngine.create] 内で
  /// 適用するため、ここでは素の役割付きメッセージを渡すだけでよい。
  /// 本文は [clampBody] で [maxBodyChars] 文字に截断される。
  static List<LlamaChatMessage> buildPrompt({
    required String title,
    required String description,
    List<String> tags = const [],
    required String body,
  }) {
    final tagLine = tags
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .join(', ');
    final buffer = StringBuffer()
      ..writeln('タイトル: ${title.trim()}')
      ..writeln('あらすじ（作者書き）: ${description.trim()}')
      ..writeln('タグ: ${tagLine.isEmpty ? '（なし）' : tagLine}')
      ..writeln('本文（冒頭）:')
      ..writeln(clampBody(body));
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

  /// 要約生成を一通り実行する（プロンプト構築 → 生成 → 解析）。
  ///
  /// [service] は呼び出し側が loadModel 済みであることを想定。
  /// 失敗時は [LlmSummaryException]（自然な日本語メッセージ）を投げる。
  /// キャンセル時は [LlmCancelledException] をそのまま送出する。
  static Future<LlmSummaryResult> generate({
    required LocalLlmService service,
    required String title,
    required String description,
    List<String> tags = const [],
    required String body,
    void Function(String piece)? onToken,
  }) async {
    final messages = buildPrompt(
      title: title,
      description: description,
      tags: tags,
      body: body,
    );
    final raw = await service.generate(messages, onToken: onToken);
    final result = parseOutput(raw);
    if (result != null) return result;
    if (looksRefused(raw)) {
      throw const LlmSummaryException(
        'モデルが今回の要約生成を拒否しました。もう一度試すか、別のモデルをお試しください。',
      );
    }
    throw const LlmSummaryException('モデルの出力を解析できませんでした。もう一度お試しください。');
  }
}
