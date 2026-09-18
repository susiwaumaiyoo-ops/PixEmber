// Phase 9a Section A: DatabaseService 分割後の public static 互換性テスト。
//
// 分割前は `DatabaseService.isGenuineNovelMissing` と
// `DatabaseService.subscriptionNewItemsLimitPerTag` が `class DatabaseService`
// に直属していた。Phase 6/7 の part 分割でそれぞれ
// `DatabaseServiceIntegrity` / `DatabaseServiceSubscriptions` に移動したが、
// Dart は static を継承しないため親クラス表面から入口が消えた。
// Phase 9a で親に転送用 static を追加したので、旧 import パスを含む
// 3 経路すべてから同一結果・同一値・同一シングルトンになることを確認する。
//
// ※ 実 DB は開かない（シングルトンのファクトリ参照と定数評価のみ）。
// ※ part-of ファイルは直接 import できないが、part で宣言された public クラスは
//   その親ライブラリを import すれば同じ名前空間から参照できる。

import 'package:flutter_test/flutter_test.dart';

// 旧 import パス（分割前から存在し、外部はすべてこちらを使っていた想定）。
import 'package:pixiv_viewer/services/database_service.dart' as legacy;

// 新 import パス（part 分割後の実体）。同一ライブラリを別 prefix で参照。
import 'package:pixiv_viewer/services/database/database_service.dart'
    as current;

// 定数コンテキストで使えることの証明: この行がコンパイルを通れば
// `subscriptionNewItemsLimitPerTag` は定数式として振る舞う（getter 化されていない）。
const int _legacyLimitConst =
    legacy.DatabaseService.subscriptionNewItemsLimitPerTag;
const int _currentLimitConst =
    current.DatabaseService.subscriptionNewItemsLimitPerTag;
const List<int> _limitsConst = [
  legacy.DatabaseService.subscriptionNewItemsLimitPerTag,
  current.DatabaseService.subscriptionNewItemsLimitPerTag,
];

void main() {
  group('DB public static compatibility (Phase 9a A-2)', () {
    test('subscriptionNewItemsLimitPerTag: 旧パス・新パス・part 実体が同値', () {
      expect(legacy.DatabaseService.subscriptionNewItemsLimitPerTag, 100);
      expect(current.DatabaseService.subscriptionNewItemsLimitPerTag, 100);
      expect(
        current.DatabaseServiceSubscriptions.subscriptionNewItemsLimitPerTag,
        100,
      );
      expect(
        legacy.DatabaseService.subscriptionNewItemsLimitPerTag,
        same(current.DatabaseService.subscriptionNewItemsLimitPerTag),
      );
      expect(_legacyLimitConst, 100);
      expect(_currentLimitConst, 100);
      expect(_limitsConst, [100, 100]);
    });

    test('isGenuineNovelMissing: 旧パス・新パス・part 実体が同結果', () {
      const genuineMissingCases = ['作品が見つかりませんでした', 'Item Not Found 404'];
      const notMissingCases = [
        // エンドポイント不存在系（API仕様変更の誤判定を防ぐ）
        '指定されたエンドポイントが存在しません',
        'endpoint not found',
        // 認証・権限・レート制限
        '401 Unauthorized',
        '403 Forbidden',
        '429 rate limit exceeded',
        // それ以外
        'network error',
        '',
      ];

      for (final msg in genuineMissingCases) {
        final legacyResult = legacy.DatabaseService.isGenuineNovelMissing(msg);
        expect(legacyResult, isTrue, reason: 'genuine-missing: "$msg"');
        expect(
          legacyResult,
          current.DatabaseService.isGenuineNovelMissing(msg),
          reason: 'legacy vs current: "$msg"',
        );
        expect(
          legacyResult,
          current.DatabaseServiceIntegrity.isGenuineNovelMissing(msg),
          reason: 'legacy vs part: "$msg"',
        );
      }

      for (final msg in notMissingCases) {
        final legacyResult = legacy.DatabaseService.isGenuineNovelMissing(msg);
        expect(legacyResult, isFalse, reason: 'not-missing: "$msg"');
        expect(
          legacyResult,
          current.DatabaseService.isGenuineNovelMissing(msg),
          reason: 'legacy vs current: "$msg"',
        );
        expect(
          legacyResult,
          current.DatabaseServiceIntegrity.isGenuineNovelMissing(msg),
          reason: 'legacy vs part: "$msg"',
        );
      }
    });

    test('旧パスと新パスは同一型・同一シングルトン（DBを開かない）', () {
      expect(
        legacy.DatabaseService().runtimeType.toString(),
        current.DatabaseService().runtimeType.toString(),
      );
      expect(
        identical(legacy.DatabaseService(), current.DatabaseService()),
        isTrue,
      );
      // part 実体クラスのインスタンスでもあることを型レベルで確認。
      expect(legacy.DatabaseService(), isA<current.DatabaseServiceIntegrity>());
      expect(
        legacy.DatabaseService(),
        isA<current.DatabaseServiceSubscriptions>(),
      );
    });
  });
}
