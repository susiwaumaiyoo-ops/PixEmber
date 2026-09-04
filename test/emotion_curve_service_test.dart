// 小説の感情曲線サービス（感動機能パック Phase C）のユニットテスト。
//
// 対象:
// - 純粋関数: splitToChunks / cosine / zNormalizeScores /
//   computeDictionaryScores / summarizeStoryColor /
//   dominantEmotionAtProgress / parseEmotionCurveCache
// - EmotionCurveService: フェイクエンコーダによる曲線生成・キャンセル・
//   辞書フォールバック（実モデル・実DB・ネットワークに依存しない）

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_viewer/services/emotion_curve_service.dart';

/// dim 次元の one-hot ベクトル。
List<double> _oneHot(int j, [int dim = 6]) => [
  for (var i = 0; i < dim; i++)
    if (i == j) 1.0 else 0.0,
];

/// フェイクの query エンコーダ: アンカー文を感情の one-hot へ写像する。
Future<List<double>> _fakeQueryEncoder(String text) async {
  for (var j = 0; j < kEmotionLabels.length; j++) {
    final anchors = kEmotionAnchors[kEmotionLabels[j]] ?? const <String>[];
    if (anchors.contains(text)) return _oneHot(j);
  }
  return List.filled(6, 0.0);
}

/// フェイクの document エンコーダ: チャンク本文に含まれる感情辞書から
/// 最もヒット数の多い感情の one-hot を返す（該当なしは微小な均一ベクトル）。
Future<List<double>> _fakeDocumentEncoder(String text) async {
  var bestJ = -1;
  var bestHits = 0;
  for (var j = 0; j < kEmotionLabels.length; j++) {
    final words = kEmotionDictionary[kEmotionLabels[j]] ?? const <String>[];
    var hits = 0;
    for (final w in words) {
      if (text.contains(w)) hits++;
    }
    if (hits > bestHits) {
      bestHits = hits;
      bestJ = j;
    }
  }
  if (bestJ < 0) return List.filled(6, 0.1);
  return _oneHot(bestJ);
}

void main() {
  setUp(() {
    final svc = EmotionCurveService();
    svc.testEncodeDocument = null;
    svc.testEncodeQuery = null;
    svc.testSkipCache = true; // テストでは実DBに触れない
    svc.testForceDictionary = false;
  });

  // ==========================================================================
  // splitToChunks
  // ==========================================================================
  group('splitToChunks', () {
    test('空本文 → 空リスト', () {
      expect(splitToChunks('', ['']), isEmpty);
    });

    test('短い本文 → 1チャンク（ページ 0-0）', () {
      final r = splitToChunks('abc', ['abc']);
      expect(r.length, 1);
      expect(r[0].text, 'abc');
      expect(r[0].pageStart, 0);
      expect(r[0].pageEnd, 0);
    });

    test('複数ページの文字位置→ページ対応が正しい', () {
      final pages = ['a' * 500, 'b' * 500, 'c' * 500];
      final text = pages.join();
      final r = splitToChunks(text, pages, chunkSize: 800);
      expect(r.length, 2);
      expect(r[0].pageStart, 0);
      expect(r[0].pageEnd, 1);
      expect(r[1].pageStart, 1);
      expect(r[1].pageEnd, 2);
    });

    test('maxChunks 超過 → 均等間引き（元の index は単調増加）', () {
      final text = 'x' * 8000;
      final r = splitToChunks(text, [text], chunkSize: 800, maxChunks: 4);
      expect(r.length, 4);
      expect(r[0].index, 0);
      for (var i = 1; i < r.length; i++) {
        expect(r[i].index > r[i - 1].index, isTrue);
      }
    });
  });

  // ==========================================================================
  // cosine
  // ==========================================================================
  group('cosine', () {
    test('平行=1 / 直交=0 / ゼロベクトル=0 / 長さ違い=0', () {
      expect(cosine([1, 0], [1, 0]), closeTo(1.0, 1e-9));
      expect(cosine([1, 0], [0, 1]), closeTo(0.0, 1e-9));
      expect(cosine([0, 0], [1, 1]), 0.0);
      expect(cosine([1, 2, 3], [4, 5]), 0.0);
    });
  });

  // ==========================================================================
  // zNormalizeScores
  // ==========================================================================
  group('zNormalizeScores', () {
    test('空 → 空', () {
      expect(zNormalizeScores([]), isEmpty);
    });

    test('定数列 → 全て0', () {
      final z = zNormalizeScores([
        [0.5, 0.2],
        [0.5, 0.9],
      ]);
      expect(z[0], [0.0, 0.0]);
      expect(z[1][0], closeTo(-1.0, 1e-9));
      expect(z[1][1], closeTo(1.0, 1e-9));
    });

    test('正規化後は平均0・分散1', () {
      final z = zNormalizeScores([
        [1.0],
        [2.0],
        [3.0],
      ]);
      final col = [z[0][0], z[0][1], z[0][2]];
      final mean = (col[0] + col[1] + col[2]) / 3;
      expect(mean, closeTo(0.0, 1e-9));
      var variance = 0.0;
      for (final x in col) {
        variance += (x - mean) * (x - mean);
      }
      expect(variance / 3, closeTo(1.0, 1e-9));
    });
  });

  // ==========================================================================
  // computeDictionaryScores（簡易モード）
  // ==========================================================================
  group('computeDictionaryScores', () {
    test('喜語彙を含むチャンク → 喜軸が最も高い', () {
      final chunks = [
        const EmotionChunk(
          index: 0,
          text: '嬉しい笑顔が輝く。笑い声が響く。',
          pageStart: 0,
          pageEnd: 0,
        ),
      ];
      final scores = computeDictionaryScores(chunks);
      final joy = scores[0][kEmotionLabels.indexOf('喜')];
      final fear = scores[0][kEmotionLabels.indexOf('怖')];
      expect(joy > 0, isTrue);
      expect(joy > fear, isTrue);
    });
  });

  // ==========================================================================
  // summarizeStoryColor（物語の色）
  // ==========================================================================
  group('summarizeStoryColor', () {
    test('空 → プレースホルダ', () {
      expect(summarizeStoryColor([]), '色はこれから');
      expect(summarizeStoryColor([[]]), '色はこれから');
    });

    test('揺れが小さい → 「漂う」表現', () {
      final z = [
        [0.1, 0.1, 0.1],
        [0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0],
      ];
      expect(summarizeStoryColor(z), contains('喜び'));
      expect(summarizeStoryColor(z), contains('漂う'));
    });

    test('前半と後半で支配的感情が反転 → 「移ろう」表現', () {
      final z = [
        [2.0, 2.0, -2.0, -2.0], // 喜
        [-2.0, -2.0, 2.0, 2.0], // 悲
        [0.0, 0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0, 0.0],
      ];
      final s = summarizeStoryColor(z);
      expect(s, contains('喜び'));
      expect(s, contains('悲しみ'));
      expect(s, contains('移ろう'));
    });
  });

  // ==========================================================================
  // dominantEmotionAtProgress
  // ==========================================================================
  group('dominantEmotionAtProgress', () {
    test('空曲線 → null', () {
      const r = EmotionCurveResult(
        chunks: [],
        zScores: [],
        storyColor: '',
        isSimpleMode: true,
        modelId: 'x',
      );
      expect(dominantEmotionAtProgress(r, 0.5), isNull);
    });

    test('全感情が非正 → null', () {
      const r = EmotionCurveResult(
        chunks: [],
        zScores: [
          [-1.0],
          [0.0],
          [0.0],
          [0.0],
          [0.0],
          [0.0],
        ],
        storyColor: '',
        isSimpleMode: true,
        modelId: 'x',
      );
      expect(dominantEmotionAtProgress(r, 0.5), isNull);
    });
  });

  // ==========================================================================
  // parseEmotionCurveCache
  // ==========================================================================
  group('parseEmotionCurveCache', () {
    test('正常な行 → 復元できる', () {
      final row = <String, dynamic>{
        'work_id': 1,
        'model_id': 'test-model',
        'chunks_json': jsonEncode({
          'v': 1,
          'modelId': 'test-model',
          'color': '全体に「喜び」が漂う物語',
          'chunks': [
            [0, 1],
            [2, 3],
          ],
          'z': [
            [0.5, -0.5],
            [-0.5, 0.5],
            [0.0, 0.0],
            [0.0, 0.0],
            [0.0, 0.0],
            [0.0, 0.0],
          ],
        }),
        'updated_at': '2026-01-01',
      };
      final r = parseEmotionCurveCache(row);
      expect(r, isNotNull);
      expect(r!.chunks.length, 2);
      expect(r.chunks[1].pageStart, 2);
      expect(r.chunks[1].pageEnd, 3);
      expect(r.zScores.length, 6);
      expect(r.storyColor, contains('喜び'));
      expect(r.isSimpleMode, isFalse);
    });

    test('壊れた JSON → null', () {
      expect(
        parseEmotionCurveCache({'chunks_json': '{broken', 'model_id': 'x'}),
        isNull,
      );
    });
  });

  // ==========================================================================
  // EmotionCurveService（フェイクエンコーダ）
  // ==========================================================================
  group('EmotionCurveService', () {
    test('フェイクエンコーダで曲線生成（6軸×チャンク数）', () async {
      final svc = EmotionCurveService();
      svc.testEncodeQuery = _fakeQueryEncoder;
      svc.testEncodeDocument = _fakeDocumentEncoder;

// チャンク数が 1 だと z スコアの分散が 0 になり全ゼロになるため、
      // 各ページをパディングして 2 チャンクぴったり（合計 < 1600 文字）に収める。
      final p1 = '嬉しい。笑顔で満ちた一日だった。笑い声が響く。' + 'あ' * 772;
      final p2 = '悲しい別れ。涙が止まらなかった。寂しさが胸を締めつける。' + 'あ' * 762;
      final pages = [p1, p2];
      final result = await svc.compute(
        workId: 42,
        text: pages.join(),
        pages: pages,
      );
      expect(result, isNotNull);
      expect(result!.zScores.length, 6);
      expect(result.zScores.first.length, result.chunks.length);
      expect(result.isSimpleMode, isFalse);
      expect(result.storyColor, isNotEmpty);

      // 第1チャンク（喜の文）は喜軸 > 悲軸。
      final joy = result.zScores[kEmotionLabels.indexOf('喜')];
      final sad = result.zScores[kEmotionLabels.indexOf('悲')];
      expect(joy.first > sad.first, isTrue);

      // 現在位置の支配的感情: 先頭=喜、末尾=悲。
      expect(dominantEmotionAtProgress(result, 0.0)?.label, '喜');
      expect(dominantEmotionAtProgress(result, 1.0)?.label, '悲');
    });

    test('キャンセル → StateError', () async {
      final svc = EmotionCurveService();
      svc.testEncodeQuery = _fakeQueryEncoder;
      var calls = 0;
      svc.testEncodeDocument = (t) async {
        calls++;
        if (calls == 2) svc.cancel();
        return _oneHot(0);
      };

      final text = 'a' * 2400; // 3チャンク（800字×3）
      await expectLater(
        svc.compute(workId: 99, text: text, pages: [text]),
        throwsStateError,
      );
    });

    test('辞書フォールバック → 簡易モード', () async {
      final svc = EmotionCurveService();
      svc.testForceDictionary = true;

      final pages = ['嬉しい笑顔。喜びに満ちている。'];
      final r = await svc.compute(workId: 7, text: pages.join(), pages: pages);
      expect(r, isNotNull);
      expect(r!.isSimpleMode, isTrue);
      expect(r.modelId, kDictionaryModelId);
      expect(r.zScores.length, 6);
      expect(r.storyColor, isNotEmpty);
    });

    test('空本文 → null', () async {
      final svc = EmotionCurveService();
      svc.testForceDictionary = true;
      expect(await svc.compute(workId: 1, text: '', pages: const []), isNull);
    });
  });
}
