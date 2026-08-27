import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/recommendation_math.dart';

void main() {
  group('l2Normalize', () {
    test('単位ベクトルを正規化しても変わらない', () {
      // 既にL2ノルム=1のベクトルはそのまま
      final v = Float32List.fromList([1.0, 0.0, 0.0]);
      final result = l2Normalize(v);
      expect(result.length, 3);
      expect(result[0], closeTo(1.0, 1e-6));
      expect(result[1], closeTo(0.0, 1e-6));
      expect(result[2], closeTo(0.0, 1e-6));
    });

    test('非単位ベクトルをL2正規化する', () {
      final v = Float32List.fromList([3.0, 4.0]);
      // ノルム = sqrt(9 + 16) = 5
      final result = l2Normalize(v);
      expect(result[0], closeTo(0.6, 1e-6)); // 3/5
      expect(result[1], closeTo(0.8, 1e-6)); // 4/5
      // 正規化後のノルムは1
      expect(vectorNorm(result), closeTo(1.0, 1e-6));
    });

    test('ゼロベクトルはそのまま返す（NaN発生しない）', () {
      final v = Float32List.fromList([0.0, 0.0, 0.0]);
      final result = l2Normalize(v);
      expect(result[0], closeTo(0.0, 1e-12));
      expect(result[1], closeTo(0.0, 1e-12));
      expect(result[2], closeTo(0.0, 1e-12));
      // NaNが混入していないことを確認
      expect(result[0].isNaN, isFalse);
    });

    test('戻り値は新しいインスタンス（元配列を破壊しない）', () {
      final original = Float32List.fromList([3.0, 4.0]);
      final result = l2Normalize(original);
      expect(identical(original, result), isFalse);
      // 元配列は不変
      expect(original[0], 3.0);
      expect(original[1], 4.0);
    });
  });

  group('vectorNorm', () {
    test('通常のベクトルのノルムを計算', () {
      expect(vectorNorm(Float32List.fromList([3.0, 4.0])), closeTo(5.0, 1e-6));
    });

    test('ゼロベクトルのノルムは0', () {
      expect(
        vectorNorm(Float32List.fromList([0.0, 0.0, 0.0])),
        closeTo(0.0, 1e-12),
      );
    });

    test('単位ベクトルのノルムは1', () {
      expect(vectorNorm(Float32List.fromList([1.0, 0.0])), closeTo(1.0, 1e-6));
    });
  });

  group('sqrt (自前実装)', () {
    test('既知の平方根を計算', () {
      expect(sqrt(4.0), closeTo(2.0, 1e-10));
      expect(sqrt(9.0), closeTo(3.0, 1e-10));
      expect(sqrt(16.0), closeTo(4.0, 1e-10));
      expect(sqrt(100.0), closeTo(10.0, 1e-10));
    });

    test('0以下は0を返す', () {
      expect(sqrt(0.0), 0.0);
      expect(sqrt(-1.0), 0.0);
    });
  });

  group('cosineSimilarity', () {
    test('同一ベクトルの類似度は1', () {
      final v = Float32List.fromList([1.0, 2.0, 3.0]);
      expect(cosineSimilarity(v, v), closeTo(1.0, 1e-6));
    });

    test('直交ベクトルの類似度は0', () {
      final a = Float32List.fromList([1.0, 0.0]);
      final b = Float32List.fromList([0.0, 1.0]);
      expect(cosineSimilarity(a, b), closeTo(0.0, 1e-6));
    });

    test('反対方向ベクトルの類似度は-1', () {
      final a = Float32List.fromList([1.0, 0.0]);
      final b = Float32List.fromList([-1.0, 0.0]);
      expect(cosineSimilarity(a, b), closeTo(-1.0, 1e-6));
    });

    test('次元が異なる場合は0を返す', () {
      final a = Float32List.fromList([1.0, 2.0]);
      final b = Float32List.fromList([1.0, 2.0, 3.0]);
      expect(cosineSimilarity(a, b), 0.0);
    });

    test('ゼロベクトルとの類似度は0（NaN発生しない）', () {
      final a = Float32List.fromList([0.0, 0.0]);
      final b = Float32List.fromList([1.0, 2.0]);
      expect(cosineSimilarity(a, b), 0.0);
      expect(cosineSimilarity(a, b).isNaN, isFalse);
    });

    test('事前計算済みノルムを渡せる', () {
      final a = Float32List.fromList([3.0, 4.0]);
      final b = Float32List.fromList([3.0, 4.0]);
      final aNorm = 5.0;
      // aNormを渡さない場合と同じ結果
      final withoutPreset = cosineSimilarity(a, b);
      final withPreset = cosineSimilarity(a, b, aNorm);
      expect(withPreset, closeTo(withoutPreset, 1e-6));
      expect(withPreset, closeTo(1.0, 1e-6));
    });
  });

  group('buildPreferenceVector (加重平均 + L2正規化)', () {
    test('全ベクトルが空の場合は空ベクトルを返す', () {
      final result = buildPreferenceVector(
        historyVectors: [],
        favoriteVectors: [],
      );
      expect(result, isEmpty);
    });

    test('全てゼロベクトルの場合はゼロベクトルを返す（NaNなし）', () {
      final result = buildPreferenceVector(
        historyVectors: [
          Float32List.fromList([0.0, 0.0]),
        ],
        favoriteVectors: [],
      );
      expect(result.length, 2);
      expect(result[0], closeTo(0.0, 1e-12));
      expect(result[1], closeTo(0.0, 1e-12));
      expect(result[0].isNaN, isFalse);
      expect(result[1].isNaN, isFalse);
    });

    test('履歴1件の加重平均が正しい', () {
      final h = [
        Float32List.fromList([2.0, 0.0]),
      ];
      final result = buildPreferenceVector(
        historyVectors: h,
        favoriteVectors: [],
        historyWeight: 1.0,
        favoriteWeight: 2.0,
      );
      // 履歴1件、減衰1.0 → 加重平均 = [2.0, 0.0] / 1.0 = [2.0, 0.0]
      // L2正規化 → [1.0, 0.0]
      expect(result.length, 2);
      expect(result[0], closeTo(1.0, 1e-6));
      expect(result[1], closeTo(0.0, 1e-6));
    });

    test('お気に入りの重み付けが反映される', () {
      // 履歴 [1, 0], お気に入り [0, 1]
      // historyWeight=1.0, favoriteWeight=2.0
      // acc = [1*1.0, 0] + [0, 1*2.0] = [1, 2]
      // totalWeight = 1.0 + 2.0 = 3.0
      // 加重平均 = [1/3, 2/3]
      // L2正規化後も方向は [1, 2] と同じ
      final result = buildPreferenceVector(
        historyVectors: [
          Float32List.fromList([1.0, 0.0]),
        ],
        favoriteVectors: [
          Float32List.fromList([0.0, 1.0]),
        ],
        historyWeight: 1.0,
        favoriteWeight: 2.0,
      );
      expect(result.length, 2);
      // 方向ベクトル [1, 2] を正規化 = [1/sqrt(5), 2/sqrt(5)]
      final expected = 1.0 / sqrt(5.0);
      expect(result[0], closeTo(expected, 1e-6));
      expect(result[1], closeTo(2.0 * expected, 1e-6));
    });

    test('履歴の線形減衰（最新=1.0, 最古=0.5）が適用される', () {
      // 履歴3件: v0=[1,0], v1=[0,0], v2=[0,1]
      // 減衰: i=0 → 1.0, i=1 → 0.75, i=2 → 0.5
      // acc = [1*1.0, 0] + [0, 0] + [0, 1*0.5] = [1.0, 0.5]
      // totalWeight = 1.0 + 0.75 + 0.5 = 2.25
      // 加重平均 = [1/2.25, 0.5/2.25]
      final result = buildPreferenceVector(
        historyVectors: [
          Float32List.fromList([1.0, 0.0]),
          Float32List.fromList([0.0, 0.0]),
          Float32List.fromList([0.0, 1.0]),
        ],
        favoriteVectors: [],
        historyWeight: 1.0,
        favoriteWeight: 0.0, // お気に入り無効化して履歴のみ評価
      );
      expect(result.length, 2);
      final expectedX = 1.0 / 2.25;
      final expectedY = 0.5 / 2.25;
      // 方向が一致することを確認（正規化後の比率）
      // result[0]/result[1] == expectedX/expectedY
      final ratio = result[0] / result[1];
      final expectedRatio = expectedX / expectedY;
      expect(ratio, closeTo(expectedRatio, 1e-4));
    });

    test('次元が混在する場合は最初の非空ベクトルの次元に合わせる', () {
      final result = buildPreferenceVector(
        historyVectors: [
          Float32List.fromList([1.0, 0.0, 0.0]), // dim=3
          Float32List.fromList([0.0, 1.0]), // dim=2 → 無視される
        ],
        favoriteVectors: [],
      );
      expect(result.length, 3);
    });

    test('戻り値は常にL2正規化されている（ノルム=1）', () {
      final result = buildPreferenceVector(
        historyVectors: [
          Float32List.fromList([5.0, 10.0, 15.0]),
          Float32List.fromList([2.0, 4.0, 6.0]),
        ],
        favoriteVectors: [
          Float32List.fromList([1.0, 2.0, 3.0]),
        ],
      );
      expect(result.length, 3);
      expect(vectorNorm(result), closeTo(1.0, 1e-5));
    });
  });

  group('mergeAndRank (統合とランク付け)', () {
    test('ローカル候補とAPI候補を統合しスコア降順で返す', () {
      final localNovels = [
        {'id': 101, 'similarity': 0.9, 'author_id': 1},
        {'id': 102, 'similarity': 0.7, 'author_id': 2},
      ];
      final apiNovels = [
        {
          'id': 201,
          'author': {'id': 5},
        },
        {
          'id': 202,
          'author': {'id': 6},
        },
      ];
      final result = mergeAndRank(
        localNovels: localNovels,
        localIllusts: [],
        apiNovels: apiNovels,
        apiIllusts: [],
        apiFallbackWeight: 0.4,
      );
      // ローカル0.9 > ローカル0.7 > API0.4 = API0.4
      expect(result.length, 4);
      expect(result[0].workId, 101);
      expect(result[0].score, closeTo(0.9, 1e-6));
      expect(result[0].source, 'local');
      expect(result[1].workId, 102);
      expect(result[2].source, 'api');
      expect(result[2].score, closeTo(0.4, 1e-6));
    });

    test('スコア0以下のローカル候補は除外される', () {
      final localNovels = [
        {'id': 101, 'similarity': 0.0, 'author_id': 1},
        {'id': 102, 'similarity': -0.5, 'author_id': 2},
        {'id': 103, 'similarity': 0.8, 'author_id': 3},
      ];
      final result = mergeAndRank(
        localNovels: localNovels,
        localIllusts: [],
        apiNovels: [],
        apiIllusts: [],
      );
      expect(result.length, 1);
      expect(result[0].workId, 103);
    });

    test('workId=0の候補は除外される', () {
      final apiNovels = [
        {
          'id': 0,
          'author': {'id': 1},
        },
        {
          'id': 201,
          'author': {'id': 2},
        },
      ];
      final result = mergeAndRank(
        localNovels: [],
        localIllusts: [],
        apiNovels: apiNovels,
        apiIllusts: [],
      );
      expect(result.length, 1);
      expect(result[0].workId, 201);
    });

    test('maxPerSourceで各ソースの件数を制限できる', () {
      final localNovels = [
        {'id': 101, 'similarity': 0.9, 'author_id': 1},
        {'id': 102, 'similarity': 0.8, 'author_id': 2},
        {'id': 103, 'similarity': 0.7, 'author_id': 3},
      ];
      final apiNovels = [
        {
          'id': 201,
          'author': {'id': 4},
        },
        {
          'id': 202,
          'author': {'id': 5},
        },
        {
          'id': 203,
          'author': {'id': 6},
        },
      ];
      final result = mergeAndRank(
        localNovels: localNovels,
        localIllusts: [],
        apiNovels: apiNovels,
        apiIllusts: [],
        maxPerSource: 2,
      );
      // ローカル2件 + API2件 = 4件
      expect(result.length, 4);
      final localCount = result.where((c) => c.source == 'local').length;
      final apiCount = result.where((c) => c.source == 'api').length;
      expect(localCount, 2);
      expect(apiCount, 2);
    });

    test('イラスト候補も統合される', () {
      final localIllusts = [
        {'id': 301, 'similarity': 0.85, 'author_id': 10},
      ];
      final apiIllusts = [
        {
          'id': 401,
          'author': {'id': 11},
        },
      ];
      final result = mergeAndRank(
        localNovels: [],
        localIllusts: localIllusts,
        apiNovels: [],
        apiIllusts: apiIllusts,
      );
      expect(result.length, 2);
      expect(result[0].workId, 301);
      expect(result[0].type, 'illust');
      expect(result[1].workId, 401);
      expect(result[1].type, 'illust');
    });
  });

  group('excludeFiltered (除外処理)', () {
    test('既読作品を除外する', () {
      final candidates = [
        RecommendCandidate(
          workId: 1,
          type: 'novel',
          score: 0.9,
          source: 'local',
          row: {},
        ),
        RecommendCandidate(
          workId: 2,
          type: 'novel',
          score: 0.8,
          source: 'local',
          row: {},
        ),
        RecommendCandidate(
          workId: 3,
          type: 'novel',
          score: 0.7,
          source: 'local',
          row: {},
        ),
      ];
      final result = excludeFiltered(
        candidates: candidates,
        readWorkIds: {2},
        mutedAuthorIds: {},
        mutedWorkIds: {},
        deletedWorkIds: {},
      );
      expect(result.length, 2);
      expect(result.any((c) => c.workId == 2), isFalse);
    });

    test('ミュート中の作者を除外する', () {
      final candidates = [
        RecommendCandidate(
          workId: 1,
          type: 'novel',
          score: 0.9,
          source: 'local',
          row: {'author_id': 100},
        ),
        RecommendCandidate(
          workId: 2,
          type: 'novel',
          score: 0.8,
          source: 'local',
          row: {'author_id': 200},
        ),
        RecommendCandidate(
          workId: 3,
          type: 'novel',
          score: 0.7,
          source: 'local',
          row: {'author_id': 300},
        ),
      ];
      final result = excludeFiltered(
        candidates: candidates,
        readWorkIds: {},
        mutedAuthorIds: {200},
        mutedWorkIds: {},
        deletedWorkIds: {},
      );
      expect(result.length, 2);
      expect(result.any((c) => c.authorId == 200), isFalse);
    });

    test('ミュート中の作品を除外する', () {
      final candidates = [
        RecommendCandidate(
          workId: 1,
          type: 'novel',
          score: 0.9,
          source: 'local',
          row: {},
        ),
        RecommendCandidate(
          workId: 2,
          type: 'novel',
          score: 0.8,
          source: 'local',
          row: {},
        ),
      ];
      final result = excludeFiltered(
        candidates: candidates,
        readWorkIds: {},
        mutedAuthorIds: {},
        mutedWorkIds: {1},
        deletedWorkIds: {},
      );
      expect(result.length, 1);
      expect(result[0].workId, 2);
    });

    test('削除済み作品を除外する', () {
      final candidates = [
        RecommendCandidate(
          workId: 1,
          type: 'novel',
          score: 0.9,
          source: 'local',
          row: {},
        ),
        RecommendCandidate(
          workId: 2,
          type: 'novel',
          score: 0.8,
          source: 'local',
          row: {},
        ),
        RecommendCandidate(
          workId: 3,
          type: 'novel',
          score: 0.7,
          source: 'local',
          row: {},
        ),
      ];
      final result = excludeFiltered(
        candidates: candidates,
        readWorkIds: {},
        mutedAuthorIds: {},
        mutedWorkIds: {},
        deletedWorkIds: {3},
      );
      expect(result.length, 2);
      expect(result.any((c) => c.workId == 3), isFalse);
    });

    test('複数の除外条件が同時に適用される', () {
      final candidates = [
        RecommendCandidate(
          workId: 1,
          type: 'novel',
          score: 0.9,
          source: 'local',
          row: {'author_id': 100},
        ),
        RecommendCandidate(
          workId: 2,
          type: 'novel',
          score: 0.8,
          source: 'local',
          row: {'author_id': 200},
        ),
        RecommendCandidate(
          workId: 3,
          type: 'novel',
          score: 0.7,
          source: 'local',
          row: {'author_id': 300},
        ),
        RecommendCandidate(
          workId: 4,
          type: 'novel',
          score: 0.6,
          source: 'local',
          row: {'author_id': 400},
        ),
      ];
      final result = excludeFiltered(
        candidates: candidates,
        readWorkIds: {1},
        mutedAuthorIds: {200},
        mutedWorkIds: {4},
        deletedWorkIds: {},
      );
      expect(result.length, 1);
      expect(result[0].workId, 3);
    });

    test('authorId=0（作者不明）の候補は作者ミュート対象外', () {
      final candidates = [
        RecommendCandidate(
          workId: 1,
          type: 'novel',
          score: 0.9,
          source: 'local',
          row: {},
        ),
        RecommendCandidate(
          workId: 2,
          type: 'novel',
          score: 0.8,
          source: 'local',
          row: {'author_id': 200},
        ),
      ];
      final result = excludeFiltered(
        candidates: candidates,
        readWorkIds: {},
        mutedAuthorIds: {0}, // 0は無視されるべき
        mutedWorkIds: {},
        deletedWorkIds: {},
      );
      expect(result.length, 2);
    });
  });

  group('suppressAuthorSeriesBias (多様性制御)', () {
    test('空リストはそのまま返す', () {
      final result = suppressAuthorSeriesBias(candidates: []);
      expect(result, isEmpty);
    });

    test('同一作者の連続が2件まではペナルティなし', () {
      final candidates = [
        RecommendCandidate(
          workId: 1,
          type: 'novel',
          score: 1.0,
          source: 'local',
          row: {'author_id': 100},
        ),
        RecommendCandidate(
          workId: 2,
          type: 'novel',
          score: 0.9,
          source: 'local',
          row: {'author_id': 100},
        ),
        RecommendCandidate(
          workId: 3,
          type: 'novel',
          score: 0.8,
          source: 'local',
          row: {'author_id': 200},
        ),
      ];
      final result = suppressAuthorSeriesBias(
        candidates: candidates,
        maxConsecutivePerAuthor: 2,
        penalty: 0.3,
      );
      // 作者100は2件連続なのでペナルティなし
      // 結果はスコア降順で維持される
      expect(result.length, 3);
      expect(result[0].workId, 1);
      expect(result[0].score, closeTo(1.0, 1e-6));
      expect(result[1].workId, 2);
      expect(result[1].score, closeTo(0.9, 1e-6));
    });

    test('同一作者が3件連続すると3件目にペナルティがかかる', () {
      final candidates = [
        RecommendCandidate(
          workId: 1,
          type: 'novel',
          score: 1.0,
          source: 'local',
          row: {'author_id': 100},
        ),
        RecommendCandidate(
          workId: 2,
          type: 'novel',
          score: 0.9,
          source: 'local',
          row: {'author_id': 100},
        ),
        RecommendCandidate(
          workId: 3,
          type: 'novel',
          score: 0.8,
          source: 'local',
          row: {'author_id': 100},
        ),
      ];
      final result = suppressAuthorSeriesBias(
        candidates: candidates,
        maxConsecutivePerAuthor: 2,
        penalty: 0.3,
      );
      // 3件目の作者100は streak=3 > max=2 → ペナルティ
      // score = 0.8 * (1 - 0.3) = 0.56
      final penalized = result.where((c) => c.workId == 3).first;
      expect(penalized.score, closeTo(0.8 * 0.7, 1e-6));
    });

    test('同一シリーズが連続すると3件目以降にペナルティがかかる', () {
      final candidates = [
        RecommendCandidate(
          workId: 1,
          type: 'novel',
          score: 1.0,
          source: 'local',
          row: {'series_id': 500},
        ),
        RecommendCandidate(
          workId: 2,
          type: 'novel',
          score: 0.9,
          source: 'local',
          row: {'series_id': 500},
        ),
        RecommendCandidate(
          workId: 3,
          type: 'novel',
          score: 0.8,
          source: 'local',
          row: {'series_id': 500},
        ),
      ];
      final result = suppressAuthorSeriesBias(
        candidates: candidates,
        maxConsecutivePerSeries: 2,
        penalty: 0.5,
      );
      final penalized = result.where((c) => c.workId == 3).first;
      expect(penalized.score, closeTo(0.8 * 0.5, 1e-6));
    });

    test('ペナルティ後は再度ソートされる', () {
      final candidates = [
        RecommendCandidate(
          workId: 1,
          type: 'novel',
          score: 1.0,
          source: 'local',
          row: {'author_id': 100},
        ),
        RecommendCandidate(
          workId: 2,
          type: 'novel',
          score: 0.9,
          source: 'local',
          row: {'author_id': 100},
        ),
        RecommendCandidate(
          workId: 3,
          type: 'novel',
          score: 0.85,
          source: 'local',
          row: {'author_id': 100},
        ),
        RecommendCandidate(
          workId: 4,
          type: 'novel',
          score: 0.8,
          source: 'local',
          row: {'author_id': 200},
        ),
      ];
      final result = suppressAuthorSeriesBias(
        candidates: candidates,
        maxConsecutivePerAuthor: 2,
        penalty: 0.5,
      );
      // workId=3: 0.85 * 0.5 = 0.425
      // workId=4: 0.8 (ペナルティなし)
      // ソート後: 1(1.0) > 2(0.9) > 4(0.8) > 3(0.425)
      expect(result[0].workId, 1);
      expect(result[1].workId, 2);
      expect(result[2].workId, 4);
      expect(result[3].workId, 3);
    });

    test('異なる作者に切り替わるとストリークリセットされる', () {
      final candidates = [
        RecommendCandidate(
          workId: 1,
          type: 'novel',
          score: 1.0,
          source: 'local',
          row: {'author_id': 100},
        ),
        RecommendCandidate(
          workId: 2,
          type: 'novel',
          score: 0.9,
          source: 'local',
          row: {'author_id': 200},
        ),
        RecommendCandidate(
          workId: 3,
          type: 'novel',
          score: 0.8,
          source: 'local',
          row: {'author_id': 100},
        ),
      ];
      final result = suppressAuthorSeriesBias(
        candidates: candidates,
        maxConsecutivePerAuthor: 2,
        penalty: 0.3,
      );
      // 100 → 200 → 100 と切り替わるので各作者2件未満、ペナルティなし
      for (final c in result) {
        expect(c.score, c.workId == 1 ? closeTo(1.0, 1e-6) : c.score);
      }
      // 全員ペナルティなし（元のスコア維持）
      final w1 = result.where((c) => c.workId == 1).first;
      final w2 = result.where((c) => c.workId == 2).first;
      final w3 = result.where((c) => c.workId == 3).first;
      expect(w1.score, closeTo(1.0, 1e-6));
      expect(w2.score, closeTo(0.9, 1e-6));
      expect(w3.score, closeTo(0.8, 1e-6));
    });

    test('authorId=0（作者不明）はストリークカウント対象外', () {
      final candidates = [
        RecommendCandidate(
          workId: 1,
          type: 'novel',
          score: 1.0,
          source: 'local',
          row: {},
        ),
        RecommendCandidate(
          workId: 2,
          type: 'novel',
          score: 0.9,
          source: 'local',
          row: {},
        ),
        RecommendCandidate(
          workId: 3,
          type: 'novel',
          score: 0.8,
          source: 'local',
          row: {},
        ),
      ];
      final result = suppressAuthorSeriesBias(
        candidates: candidates,
        maxConsecutivePerAuthor: 2,
        penalty: 0.3,
      );
      // 全員 authorId=0 なのでストリーク対象外、ペナルティなし
      expect(result.length, 3);
      expect(result[0].score, closeTo(1.0, 1e-6));
      expect(result[1].score, closeTo(0.9, 1e-6));
      expect(result[2].score, closeTo(0.8, 1e-6));
    });
  });

  group('RecommendCandidate', () {
    test('authorId getter: DB行形式（author_id）から取得', () {
      final c = RecommendCandidate(
        workId: 1,
        type: 'novel',
        score: 0.5,
        source: 'local',
        row: {'author_id': 123},
      );
      expect(c.authorId, 123);
    });

    test('authorId getter: API モデル形式（author.id）からフォールバック', () {
      final c = RecommendCandidate(
        workId: 1,
        type: 'novel',
        score: 0.5,
        source: 'api',
        row: {
          'author': {'id': 456},
        },
      );
      expect(c.authorId, 456);
    });

    test('authorId getter: 不明時は0を返す', () {
      final c = RecommendCandidate(
        workId: 1,
        type: 'novel',
        score: 0.5,
        source: 'local',
        row: {},
      );
      expect(c.authorId, 0);
    });

    test('seriesId getter: DB行形式（series_id）から取得', () {
      final c = RecommendCandidate(
        workId: 1,
        type: 'novel',
        score: 0.5,
        source: 'local',
        row: {'series_id': 789},
      );
      expect(c.seriesId, 789);
    });

    test('seriesId getter: Novel モデル形式（series.id）からフォールバック', () {
      final c = RecommendCandidate(
        workId: 1,
        type: 'novel',
        score: 0.5,
        source: 'api',
        row: {
          'series': {'id': 999},
        },
      );
      expect(c.seriesId, 999);
    });

    test('copyWith で score のみ更新できる', () {
      final c = RecommendCandidate(
        workId: 1,
        type: 'novel',
        score: 0.9,
        source: 'local',
        row: {'author_id': 1},
      );
      final updated = c.copyWith(score: 0.5);
      expect(updated.score, 0.5);
      expect(updated.workId, c.workId);
      expect(updated.type, c.type);
      expect(updated.source, c.source);
    });
  });
}
