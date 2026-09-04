// ハイブリッド「似た作品」サービス（感動機能パック Phase D）のユニットテスト。
//
// サービス本体は DB / API / モデルに依存するため、ここでは純粋関数
// （タグ Jaccard / 正規化 / 理由生成 / 重複排除 / API スコア）を検証する。
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/similar_works_service.dart';

void main() {
  const w = SimilarWeights(); // 意味0.5 / タグ0.3 / 視覚0.2

  group('tagJaccard', () {
    test('完全一致は 1.0', () {
      expect(tagJaccard(['a', 'b'], ['a', 'b']), closeTo(1.0, 1e-9));
    });
    test('一部一致', () {
      // {a,b} ∩ {b,c} = {b} (1), {a,b,c} (3) → 1/3
      expect(tagJaccard(['a', 'b'], ['b', 'c']), closeTo(1 / 3, 1e-9));
    });
    test('交差なしは 0', () {
      expect(tagJaccard(['a'], ['b']), 0.0);
    });
    test('両方空は 0（0除算しない）', () {
      expect(tagJaccard([], []), 0.0);
    });
    test('空文字タグは無視', () {
      expect(tagJaccard(['a', ''], ['a']), closeTo(1.0, 1e-9));
    });
  });

  group('normalizeSemantic / normalize01', () {
    test('cosine -1 → 0、0 → 0.5、1 → 1', () {
      expect(normalizeSemantic(-1.0), closeTo(0.0, 1e-9));
      expect(normalizeSemantic(0.0), closeTo(0.5, 1e-9));
      expect(normalizeSemantic(1.0), closeTo(1.0, 1e-9));
    });
    test('範囲外はクランプ', () {
      expect(normalizeSemantic(1.5), 1.0);
      expect(normalize01(1.5), 1.0);
      expect(normalize01(-0.2), 0.0);
    });
    test('NaN は 0', () {
      expect(normalizeSemantic(double.nan), 0.0);
      expect(normalize01(double.nan), 0.0);
    });
  });

  group('buildReason', () {
    test('意味が支配的なら「内容が似ています」', () {
      final r = buildReason(
        semanticScore: 0.9,
        tagScore: 0.1,
        visualScore: 0.0,
        weights: w,
        type: 'novel',
      );
      expect(r, '内容が似ています');
    });
    test('タグが支配的なら「タグが似ています」', () {
      // 意味 0.1*0.5=0.05, タグ 0.9*0.3=0.27
      final r = buildReason(
        semanticScore: 0.1,
        tagScore: 0.9,
        visualScore: 0.0,
        weights: w,
        type: 'novel',
      );
      expect(r, 'タグが似ています');
    });
    test('視覚が支配的ならイラストは「絵柄が似ています」', () {
      // 視覚 0.9*0.2=0.18 > 意味 0.05, タグ 0.03
      final r = buildReason(
        semanticScore: 0.1,
        tagScore: 0.1,
        visualScore: 0.9,
        weights: w,
        type: 'illust',
      );
      expect(r, '絵柄が似ています');
    });
    test('視覚支配でも小説なら「内容が似ています」にフォールバック', () {
      final r = buildReason(
        semanticScore: 0.0,
        tagScore: 0.0,
        visualScore: 0.9,
        weights: w,
        type: 'novel',
      );
      expect(r, '内容が似ています');
    });
    test('全て 0 なら「関連作品」', () {
      final r = buildReason(
        semanticScore: 0.0,
        tagScore: 0.0,
        visualScore: 0.0,
        weights: w,
        type: 'novel',
      );
      expect(r, '関連作品');
    });
    test('意味の重みを 0 にすると意味は理由に選ばれない', () {
      const zeroSemantic = SimilarWeights(semantic: 0.0, tag: 0.5, visual: 0.5);
      final r = buildReason(
        semanticScore: 1.0,
        tagScore: 0.5,
        visualScore: 0.0,
        weights: zeroSemantic,
        type: 'novel',
      );
      expect(r, 'タグが似ています');
    });
  });

  group('dedupeByWork', () {
    SimilarWork mk(String type, int id, {double score = 0.5}) => SimilarWork(
      workId: id,
      type: type,
      score: score,
      semanticScore: 0,
      tagScore: 0,
      visualScore: 0,
      source: 'local',
      reason: 'x',
      row: const {},
    );

    test('(type, workId) で重複排除（先勝ち）', () {
      final out = dedupeByWork([
        mk('novel', 1, score: 0.9),
        mk('novel', 1, score: 0.1), // 重複 → 除外
        mk('novel', 2),
      ]);
      expect(out.length, 2);
      expect(out.first.score, 0.9); // 先勝ち
    });
    test('type が違えば同一 id でも残る', () {
      final out = dedupeByWork([mk('novel', 1), mk('illust', 1)]);
      expect(out.length, 2);
    });
    test('空リストは空', () {
      expect(dedupeByWork([]), isEmpty);
    });
  });

  group('SimilarWeights.activeSum', () {
    test('既定は 1.0', () {
      expect(w.activeSum, closeTo(1.0, 1e-9));
    });
    test('負の重みは無視して正規化', () {
      const x = SimilarWeights(semantic: -1.0, tag: 0.5, visual: 0.5);
      expect(x.activeSum, closeTo(1.0, 1e-9));
    });
    test('全て 0 以下なら 1.0（0除算回避）', () {
      const x = SimilarWeights(semantic: 0, tag: 0, visual: 0);
      expect(x.activeSum, 1.0);
    });
  });

  group('SimilarWorksService.apiScoreForIndex', () {
    test('先頭は 0.7、以降逓減し 0.4 で頭打ち', () {
      final svc = SimilarWorksService();
      expect(svc.apiScoreForIndex(0), closeTo(0.7, 1e-9));
      expect(svc.apiScoreForIndex(10), closeTo(0.5, 1e-9));
      expect(svc.apiScoreForIndex(100), closeTo(0.4, 1e-9));
      expect(svc.apiScoreForIndex(0) >= svc.apiScoreForIndex(50), isTrue);
    });
  });
}
