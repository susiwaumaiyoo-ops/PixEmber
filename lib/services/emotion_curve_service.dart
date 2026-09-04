// 小説の感情曲線サービス（感動機能パック Phase C）。
//
// 設計:
// - 小説本文を約800字のチャンクに分割（上限200、超えたら均等間引き）
// - Ruri v3（encodeDocument / L2正規化済みベクトル）でチャンクごとに埋め込み、
//   感情アンカー文（喜・悲・怖・怒・穏・切なさ 各3〜5文）の encodeQuery 平均
//   ベクトルとのコサイン類似度を算出する。
// - 感情ごとの z スコア正規化で「感情曲線」を作る。
// - 結果は emotion_curves テーブル（DB v23）にキャッシュ。
//   本文から再生成可能なため Google Drive バックアップ対象外。
// - モデル未導入なら感情辞書によるフォールバック（簡易モード）。
// - 集計系は全て純粋関数（単体テスト対象）。サービスの生成処理は
//   進捗コールバック＋キャンセル対応でバックグラウンド実行を想定する。

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'database_service.dart';
import 'embedding_service.dart';
import 'ruri_model_manager.dart';

/// 感情軸ラベル（6軸固定: 喜・悲・怖・怒・穏・切なさ）。
const List<String> kEmotionLabels = ['喜', '悲', '怖', '怒', '穏', '切'];

/// 感情の表示名。
const Map<String, String> kEmotionNames = {
  '喜': '喜び',
  '悲': '悲しみ',
  '怖': '恐怖',
  '怒': '怒り',
  '穏': '穏やか',
  '切': '切なさ',
};

/// 感情ごとの表示色（ARGB 値。UI 側で Color 化する）。
const Map<String, int> kEmotionColorValues = {
  '喜': 0xFFFFD54F,
  '悲': 0xFF64B5F6,
  '怖': 0xFF7E57C2,
  '怒': 0xFFEF5350,
  '穏': 0xFF81C784,
  '切': 0xFFF48FB1,
};

/// 辞書フォールバック使用時の modelId。
const String kDictionaryModelId = 'dictionary-simple';

/// 感情アンカー文（感情ごとに 3〜5 文の日本語文）。
/// encodeQuery → 平均化 → 正規化してアンカーベクトルとする。
const Map<String, List<String>> kEmotionAnchors = {
  '喜': ['うれしくて、思わず笑顔になる。', '喜びに胸が躍り、心が弾む。', '幸せな気持ちでいっぱいになる。', '楽しい出来事に心が温まる。'],
  '悲': ['悲しくて、涙が止まらない。', '大切なものを失い、胸が締めつけられる。', '寂しさが心に広がっていく。', '哀しい別れに心が沈む。'],
  '怖': ['恐ろしくて身がすくむ。', '暗闇の中で恐怖に震える。', '不気味な気配に背筋が凍る。', '不安と恐怖で息が詰まる。'],
  '怒': ['怒りで頭が真っ白になる。', '理不尽な仕打ちに腹が立つ。', '許せない気持ちで拳を握る。', '強い憤りが胸を焼く。'],
  '穏': [
    '穏やかな午後に心が落ち着く。',
    '静かな時間がゆっくり流れる。',
    '優しい風が頬を撫でていく。',
    'ゆったりとした安心感に包まれる。',
  ],
  '切': ['切ない思いが胸に残る。', 'もう戻れない日々に思いを馳せる。', '大切な人への想いが募る。', '甘い痛みが心を締めつける。'],
};

/// 感情辞書（簡易モード用。各感情 約50語）。
const Map<String, List<String>> kEmotionDictionary = {
  '喜': [
    '嬉しい',
    'うれしい',
    '喜び',
    '喜ぶ',
    '笑う',
    '笑顔',
    '笑い',
    '微笑む',
    '微笑み',
    '笑み',
    'にっこり',
    'にこにこ',
    '幸せ',
    '幸福',
    '楽しい',
    '楽しみ',
    '歓声',
    '歓喜',
    '感激',
    '興奮',
    'わくわく',
    'どきどき',
    '晴れやか',
    '輝く',
    '祝福',
    '拍手',
    '勝利',
    '抱きしめる',
    '抱き合う',
    '飛び跳ねる',
    '跳び上がる',
    '弾む',
    '陽気',
    '明るい',
    'はしゃぐ',
    '上機嫌',
    '大成功',
    '叶う',
    '叶った',
    '良かった',
    'よかった',
    '最高',
    '素晴らしい',
    '素敵',
    '万歳',
    'めでたい',
    '祝う',
    '祝い',
    '笑い声',
    '笑い合う',
  ],
  '悲': [
    '悲しい',
    '悲しみ',
    '泣く',
    '涙',
    '号泣',
    'すすり泣き',
    '泣きじゃくる',
    '涙ぐむ',
    '嗚咽',
    '慟哭',
    '寂しい',
    '寂しさ',
    '孤独',
    'ひとりぼっち',
    '別れ',
    '別離',
    '死',
    '亡くなる',
    '失う',
    '喪失',
    '哀しい',
    '哀しみ',
    '辛い',
    'つらい',
    '苦しい',
    '痛み',
    '傷つく',
    '絶望',
    '落胆',
    '失望',
    '失意',
    '落ち込む',
    '沈む',
    '暗い',
    '濡れる頬',
    '頬を伝う',
    '最期',
    '棺',
    '葬儀',
    '墓',
    '後悔',
    '悔やむ',
    '未練',
    '空虚',
    '空白',
    '消える',
    '冷たい',
    'さよなら',
    'お別れ',
    '見送る',
  ],
  '怖': [
    '怖い',
    '恐怖',
    '恐ろしい',
    '震える',
    '震え',
    '怯える',
    '怯え',
    '不安',
    '戦慄',
    '悪寒',
    '背筋が凍る',
    'ぞくり',
    'ぞっと',
    '不気味',
    '気配',
    '闇',
    '暗闇',
    '影',
    '怪物',
    '化け物',
    '幽霊',
    '呪い',
    '悲鳴',
    '叫び',
    '逃げろ',
    '逃げる',
    '追われる',
    '迫る',
    '息を呑む',
    '冷汗',
    '青ざめる',
    '顔面蒼白',
    'すくむ',
    '硬直',
    '震える声',
    '脅威',
    '危険',
    '死の気配',
    '血',
    '惨劇',
    '殺意',
    '狂気',
    '絶叫',
    '忍び寄る',
    '潜む',
    '得体の知れない',
    '何かがいる',
    '闇の中',
    '黒い影',
    '迫り来る',
  ],
  '怒': [
    '怒り',
    '怒る',
    '怒鳴る',
    '激怒',
    '憤り',
    '腹が立つ',
    'むかつく',
    'イライラ',
    '苛立ち',
    '許せない',
    '理不尽',
    '裏切り',
    '裏切られた',
    '憎い',
    '憎しみ',
    '憎悪',
    '恨み',
    '復讐',
    '叫ぶ',
    '怒号',
    '拳',
    '殴る',
    '叩きつける',
    '睨む',
    '睨みつける',
    '歯ぎしり',
    '逆上',
    '立腹',
    '侮辱',
    '屈辱',
    '蔑む',
    '嘲笑',
    '怒りに震える',
    '激昂',
    '爆発',
    '怒声',
    '詰め寄る',
    '食ってかかる',
    '罵る',
    '吐き捨てる',
    '憤慨',
    '苛烈',
    '激高',
    '燃える怒り',
    '血が沸く',
    'ぶちまける',
    '怒目',
    '鬼の形相',
    '拳を握る',
    '怒り心頭',
  ],
  '穏': [
    '穏やか',
    '静か',
    '静けさ',
    'のどか',
    'のんびり',
    'ゆったり',
    'まったり',
    'くつろぐ',
    '安らぎ',
    '安らぐ',
    '安心',
    '安心感',
    '落ち着く',
    '落ち着き',
    '平穏',
    '平和',
    '和やか',
    '温かい',
    '暖かい',
    'ぬくもり',
    '木漏れ日',
    '夕焼け',
    '朝焼け',
    'そよ風',
    '微風',
    'さざ波',
    '静寂',
    '眠り',
    'まどろみ',
    '微笑ましい',
    '和む',
    '癒し',
    '癒される',
    '柔らか',
    '優しい',
    '陽だまり',
    '波音',
    '虫の声',
    '静かな夜',
    '緩やか',
    '安堵',
    'ほっと',
    '息をつく',
    '満ち足りた',
    '充足',
    '湯気',
    '温もり',
    '安らか',
    '長閑',
    '平穏な日々',
  ],
  '切': [
    '切ない',
    '切なさ',
    'せつない',
    '胸が締めつけられる',
    '苦しいほど',
    '愛しい',
    'いとおしい',
    '恋しい',
    '恋しさ',
    '想い',
    '想う',
    '懐かしい',
    '懐かしさ',
    '思い出',
    '追憶',
    'もう一度',
    'もう会えない',
    '届かない',
    'すれ違い',
    '別れ際',
    '背中',
    '面影',
    '残像',
    '余韻',
    'ため息',
    '遠い目',
    '目を伏せる',
    '俯く',
    '胸の奥',
    '奥底',
    '疼く',
    'ざわつく',
    '揺れる',
    '揺らぐ',
    '迷い',
    '名残り',
    '名残',
    '儚い',
    'はかない',
    '散る',
    '零れる',
    'こぼれる',
    '滲む',
    'ぼやける',
    '甘く苦い',
    '戻れない',
    'あの頃',
    '昔の日々',
    '記憶',
    '面影を探す',
  ],
};

/// チャンク分割結果。pageStart/pageEnd でリーダーのページ位置に対応する。
class EmotionChunk {
  final int index;
  final String text;
  final int pageStart;
  final int pageEnd;

  const EmotionChunk({
    required this.index,
    required this.text,
    required this.pageStart,
    required this.pageEnd,
  });
}

/// 感情曲線の結果。
class EmotionCurveResult {
  /// チャンク一覧（ページ対応情報付き）。
  final List<EmotionChunk> chunks;

  /// 感情ごとの z スコア曲線（[kEmotionLabels] 順、各リスト長さ = チャンク数）。
  final List<List<double>> zScores;

  /// 「物語の色」サマリ文。
  final String storyColor;

  /// true = 感情辞書による簡易モード。
  final bool isSimpleMode;

  /// 生成に使用したモデルID（簡易モードは [kDictionaryModelId]）。
  final String modelId;

  const EmotionCurveResult({
    required this.chunks,
    required this.zScores,
    required this.storyColor,
    required this.isSimpleMode,
    required this.modelId,
  });
}

/// 本文を約 [chunkSize] 文字のチャンクに分割する（純粋関数）。
///
/// [novelPages] はページごとの本文。各チャンクは含む文字位置から
/// ページ範囲（pageStart〜pageEnd）を決定する。
/// チャンク数が [maxChunks] を超える場合は均等間引きして残す。
List<EmotionChunk> splitToChunks(
  String text,
  List<String> novelPages, {
  int chunkSize = 800,
  int maxChunks = 200,
}) {
  final total = text.length;
  if (total <= 0 || chunkSize <= 0) return const [];

  // 各ページの累計終了オフセット。
  final ends = <int>[];
  var acc = 0;
  for (final p in novelPages) {
    acc += p.length;
    ends.add(acc);
  }

  int pageOf(int pos) {
    for (var i = 0; i < ends.length; i++) {
      if (pos < ends[i]) return i;
    }
    return ends.isEmpty ? 0 : ends.length - 1;
  }

  final raw = <EmotionChunk>[];
  var idx = 0;
  for (var start = 0; start < total; start += chunkSize) {
    final end = start + chunkSize > total ? total : start + chunkSize;
    raw.add(
      EmotionChunk(
        index: idx++,
        text: text.substring(start, end),
        pageStart: pageOf(start),
        pageEnd: pageOf(end - 1),
      ),
    );
  }

  if (raw.length <= maxChunks) return raw;

  // 上限超過: 均等間引き（元の index は維持する）。
  final result = <EmotionChunk>[];
  for (var i = 0; i < maxChunks; i++) {
    final src = (i * raw.length) ~/ maxChunks;
    result.add(raw[src]);
  }
  return result;
}

/// コサイン類似度（純粋関数）。ノルム 0 や長さ不一致は 0 を返す。
double cosine(List<double> a, List<double> b) {
  if (a.isEmpty || a.length != b.length) return 0;
  var dot = 0.0;
  var na = 0.0;
  var nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na <= 0 || nb <= 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// 感情ごとの z スコア正規化（純粋関数）。
///
/// 入力はチャンク行の行列（各要素が 6 感情スコア）。
/// 出力は感情軸ごとの曲線リスト（[kEmotionLabels] 順、長さ = チャンク数）。
/// 標準偏差がほぼ 0 の感情軸は全て 0 にする。
List<List<double>> zNormalizeScores(List<List<double>> scores) {
  if (scores.isEmpty) return const [];
  final n = scores.length;
  final e = scores.first.length;
  final result = <List<double>>[];
  for (var j = 0; j < e; j++) {
    final col = [for (var i = 0; i < n; i++) scores[i][j]];
    final mean = col.fold<double>(0, (a, b) => a + b) / n;
    var variance = 0.0;
    for (final v in col) {
      variance += (v - mean) * (v - mean);
    }
    variance /= n;
    final sd = math.sqrt(variance);
    if (sd < 1e-9) {
      result.add(List.filled(n, 0.0));
    } else {
      result.add([for (final v in col) (v - mean) / sd]);
    }
  }
  return result;
}

/// 感情辞書によるスコアリング（純粋関数・簡易モード用）。
///
/// チャンクごとに各感情辞書のヒット数を数える（チャンク行の行列を返す）。
List<List<double>> computeDictionaryScores(List<EmotionChunk> chunks) {
  final result = <List<double>>[];
  for (final chunk in chunks) {
    final row = <double>[];
    for (final label in kEmotionLabels) {
      final words = kEmotionDictionary[label] ?? const <String>[];
      var hits = 0;
      for (final w in words) {
        if (chunk.text.contains(w)) hits++;
      }
      row.add(hits.toDouble());
    }
    result.add(row);
  }
  return result;
}

/// 「物語の色」サマリを生成する（純粋関数）。
///
/// [zScores] は感情軸ごとの z スコア曲線（[kEmotionLabels] 順）。
/// 曲線の形状から一言サマリを返す。
String summarizeStoryColor(List<List<double>> zScores) {
  if (zScores.isEmpty || zScores.first.isEmpty) return '色はこれから';
  final n = zScores.first.length;

  double peakOf(int j) {
    var m = zScores[j][0];
    for (final v in zScores[j]) {
      if (v > m) m = v;
    }
    return m;
  }

  var best = 0;
  for (var j = 1; j < zScores.length; j++) {
    if (peakOf(j) > peakOf(best)) best = j;
  }

  var varSum = 0.0;
  var cnt = 0;
  for (final row in zScores) {
    for (final v in row) {
      varSum += v.abs();
      cnt++;
    }
  }
  final variability = cnt > 0 ? varSum / cnt : 0.0;
  final word = kEmotionNames[kEmotionLabels[best]] ?? kEmotionLabels[best];

  // チャンクが少ない・揺れが小さい場合は「漂う」表現。
  if (n < 3 || variability < 0.35) {
    return '全体に「$word」が漂う物語';
  }

  // 前半と後半の支配的な感情を比較する。
  final half = n ~/ 2;
  int strongestIn(int from, int to) {
    var bj = 0;
    var bv = double.negativeInfinity;
    for (var j = 0; j < zScores.length; j++) {
      var s = 0.0;
      var c = 0;
      for (var i = from; i < to; i++) {
        s += zScores[j][i];
        c++;
      }
      final avg = c > 0 ? s / c : 0.0;
      if (avg > bv) {
        bv = avg;
        bj = j;
      }
    }
    return bj;
  }

  final first = strongestIn(0, half);
  final last = strongestIn(half, n);
  if (first != last) {
    final w1 = kEmotionNames[kEmotionLabels[first]] ?? kEmotionLabels[first];
    final w2 = kEmotionNames[kEmotionLabels[last]] ?? kEmotionLabels[last];
    return '「$w1」から「$w2」へ移ろう物語';
  }
  return '全体に「$word」が満ちる物語';
}

/// 進捗 [progress]（0.0〜1.0）位置の支配的感情（z が最大の感情軸）を返す。
///
/// 全感情の z が 0 以下（感情が弱い位置）なら null。
({String label, int colorValue})? dominantEmotionAtProgress(
  EmotionCurveResult curve,
  double progress,
) {
  if (curve.zScores.isEmpty || curve.zScores.first.isEmpty) return null;
  final n = curve.zScores.first.length;
  final idx = (progress * n).floor().clamp(0, n - 1);
  var best = 0;
  for (var j = 1; j < curve.zScores.length; j++) {
    if (curve.zScores[j][idx] > curve.zScores[best][idx]) best = j;
  }
  if (best >= kEmotionLabels.length) return null;
  if (curve.zScores[best][idx] <= 0) return null;
  final label = kEmotionLabels[best];
  return (label: label, colorValue: kEmotionColorValues[label] ?? 0xFF9E9E9E);
}

/// DB キャッシュ行から感情曲線を復元する（純粋関数）。壊れたデータは null。
EmotionCurveResult? parseEmotionCurveCache(Map<String, dynamic> row) {
  try {
    final json =
        jsonDecode(row['chunks_json'] as String) as Map<String, dynamic>;
    final modelId =
        (row['model_id'] as String?) ?? (json['modelId'] as String? ?? '');
    final zRaw = (json['z'] as List)
        .map((e) => (e as List).map((v) => (v as num).toDouble()).toList())
        .toList();
    final pairs = (json['chunks'] as List)
        .map((e) => (e as List).map((v) => (v as num).toInt()).toList())
        .toList();
    final chunks = [
      for (var i = 0; i < pairs.length; i++)
        EmotionChunk(
          index: i,
          text: '',
          pageStart: pairs[i].isEmpty ? 0 : pairs[i][0],
          pageEnd: pairs[i].length < 2
              ? (pairs[i].isEmpty ? 0 : pairs[i][0])
              : pairs[i][1],
        ),
    ];
    return EmotionCurveResult(
      chunks: chunks,
      zScores: zRaw,
      storyColor: (json['color'] as String?) ?? '',
      isSimpleMode: modelId == kDictionaryModelId,
      modelId: modelId,
    );
  } catch (_) {
    return null;
  }
}

/// エンコーダのシグネチャ（テスト注入用）。
typedef EmotionEncoder = Future<List<double>> Function(String text);

/// 感情曲線サービス（シングルトン）。
///
/// 優先順: DB キャッシュ → モデル生成（背景・進捗・キャンセル対応）
/// → 感情辞書フォールバック（簡易モード）。
class EmotionCurveService {
  EmotionCurveService._internal();
  static final EmotionCurveService _instance = EmotionCurveService._internal();
  factory EmotionCurveService() => _instance;

  /// テスト注入用: 設定すると実モデル/実DBを使わない。
  @visibleForTesting
  EmotionEncoder? testEncodeDocument;
  @visibleForTesting
  EmotionEncoder? testEncodeQuery;
  @visibleForTesting
  bool testSkipCache = false;
  @visibleForTesting
  bool testForceDictionary = false;

  bool _cancelled = false;

  /// 進行中の曲線計算のキャンセルを要求する。
  void cancel() => _cancelled = true;

  /// 生成用の埋め込みモデルが利用可能か。
  Future<bool> isModelAvailable() async {
    if (testEncodeDocument != null) return !testForceDictionary;
    if (testForceDictionary) return false;
    try {
      return await RuriModelManager().isModelPresent();
    } catch (_) {
      return false;
    }
  }

  /// キャッシュのみ読む（リーダーHUD・詳細画面の初期表示用）。
  Future<EmotionCurveResult?> loadFromCache(int workId) async {
    if (testSkipCache) return null;
    try {
      final row = await DatabaseService().getEmotionCurve(workId);
      if (row == null) return null;
      return parseEmotionCurveCache(row);
    } catch (_) {
      return null;
    }
  }

  /// 感情曲線を計算する（モデル経路はキャッシュ保存も行う）。
  ///
  /// 本文が空などチャンクが取れない場合は null。
  /// キャンセル時は [StateError] を投げる。
  Future<EmotionCurveResult?> compute({
    required int workId,
    required String text,
    required List<String> pages,
    void Function(int done, int total)? onProgress,
  }) async {
    _cancelled = false;
    final chunks = splitToChunks(text, pages);
    if (chunks.isEmpty) return null;

    if (!await isModelAvailable()) {
      // 簡易モード: 感情辞書（モデル未導入のフォールバック）。
      final raw = computeDictionaryScores(chunks);
      final z = zNormalizeScores(raw);
      return EmotionCurveResult(
        chunks: chunks,
        zScores: z,
        storyColor: summarizeStoryColor(z),
        isSimpleMode: true,
        modelId: kDictionaryModelId,
      );
    }

    final encodeDoc = testEncodeDocument ?? _encodeDocumentReal;
    final encodeQuery = testEncodeQuery ?? _encodeQueryReal;

    // アンカーベクトル（感情ごとに文ベクトルを平均化 → 正規化）。
    final anchors = <List<double>>[];
    for (final label in kEmotionLabels) {
      final sentences = kEmotionAnchors[label] ?? const <String>[];
      final acc = <double>[];
      for (final s in sentences) {
        final v = await encodeQuery(s);
        if (acc.isEmpty) {
          acc.addAll(v);
        } else {
          for (var i = 0; i < acc.length && i < v.length; i++) {
            acc[i] += v[i];
          }
        }
      }
      if (acc.isEmpty) {
        throw StateError('感情アンカーが存在しません: $label');
      }
      anchors.add(_normalize([for (final x in acc) x / sentences.length]));
    }

    // チャンクごとにエンコード → アンカーとのコサイン類似度。
    final scores = <List<double>>[];
    for (var i = 0; i < chunks.length; i++) {
      if (_cancelled) {
        throw StateError('感情曲線の計算をキャンセルしました');
      }
      final vec = await encodeDoc(chunks[i].text);
      scores.add([for (final a in anchors) cosine(vec, a)]);
      onProgress?.call(i + 1, chunks.length);
    }
    if (_cancelled) {
      throw StateError('感情曲線の計算をキャンセルしました');
    }

    final z = zNormalizeScores(scores);
    final result = EmotionCurveResult(
      chunks: chunks,
      zScores: z,
      storyColor: summarizeStoryColor(z),
      isSimpleMode: false,
      modelId: testEncodeDocument != null
          ? 'test-model'
          : EmbeddingService.modelId,
    );

    if (!testSkipCache) {
      try {
        await DatabaseService().saveEmotionCurve(
          workId: workId,
          modelId: result.modelId,
          chunksJson: jsonEncode(_toCacheJson(result)),
        );
      } catch (e) {
        debugPrint('感情曲線キャッシュの保存に失敗（無視）: $e');
      }
    }
    return result;
  }

  Future<List<double>> _encodeDocumentReal(String text) =>
      EmbeddingService().encodeDocument(text);

  Future<List<double>> _encodeQueryReal(String text) =>
      EmbeddingService().encodeQuery(text);

  Map<String, dynamic> _toCacheJson(EmotionCurveResult r) => {
    'v': 1,
    'modelId': r.modelId,
    'color': r.storyColor,
    'chunks': [
      for (final c in r.chunks) [c.pageStart, c.pageEnd],
    ],
    'z': r.zScores,
  };

  List<double> _normalize(List<double> v) {
    var n = 0.0;
    for (final x in v) {
      n += x * x;
    }
    n = math.sqrt(n);
    if (n <= 0) return v;
    return [for (final x in v) x / n];
  }
}
