// モデル未導入状態でのクラッシュ耐性テスト。
//
// 発生していた不具合:
//   小説詳細画面を開くと EmbeddingService.initialize() が
//   「Ruri モデルが未準備です（未ダウンロードまたは検証失敗）。」の
//   StateError を completer.completeError で待ち手に伝播させ、
//   SimilarWorksService → 画面の Future まで未ハンドルのまま
//   アプリがクラッシュ（ネイティブ tombstoned）していた。
//
// 対策の検証対象:
// - EmbeddingService.initialize() はモデル未導入でも例外を投げず
//   isInitialized == false のまま正常終了すること
// - SimilarWorksService は未初期化でもクラッシュせず
//   modelReady == false の結果（UI ではセクション非表示）を返すこと
// - EmotionCurveService はモデル未導入でもクラッシュせず
//   感情辞書の簡易モードへフォールバックすること
// - 小説詳細画面をモデル未導入状態で開いても例外が UI に届かないこと
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/illust_model.dart';
import 'package:pixiv_viewer/novel_model.dart';
import 'package:pixiv_viewer/screens/novel_detail_screen.dart';
import 'package:pixiv_viewer/services/database_service.dart';
import 'package:pixiv_viewer/services/embedding_service.dart';
import 'package:pixiv_viewer/services/emotion_curve_service.dart';
import 'package:pixiv_viewer/services/similar_works_service.dart';

/// インメモリ SQLite に最小限のテーブルを作る。
/// （存在しないテーブルへのクエリは各呼び出し側で握りつぶされるため、
///  クラッシュ耐性の検証に必要な分のみ定義する）
Future<Database> _openTestDb() async {
  return openDatabase(
    inMemoryDatabasePath,
    version: 1,
    onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE history (
          work_id INTEGER PRIMARY KEY,
          title TEXT,
          author_name TEXT,
          url TEXT,
          metadata TEXT,
          type TEXT,
          created_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE read_later (
          work_id INTEGER PRIMARY KEY,
          created_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE mutes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          mute_type TEXT,
          value TEXT,
          label TEXT,
          created_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE novels (
          id INTEGER PRIMARY KEY,
          title TEXT,
          author_id INTEGER,
          series_id INTEGER,
          tags_json TEXT,
          text_length INTEGER,
          total_bookmarks INTEGER
        )
      ''');
      await db.execute('''
        CREATE TABLE emotion_curves (
          work_id INTEGER PRIMARY KEY,
          model_id TEXT,
          chunks_json TEXT,
          updated_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE novel_embeddings (
          work_id INTEGER PRIMARY KEY,
          model_id TEXT,
          embedding TEXT
        )
      ''');
    },
  );
}

Novel _novel({int id = 1, List<String> tags = const ['TSO', 'F/GO']}) => Novel(
  id: id,
  title: 'テスト小説',
  caption: 'キャプション',
  author: Author(id: 1000, name: '作者', account: 'author'),
  tags: tags,
  coverUrl: '',
  textCount: 100,
  wordCount: 100,
  textLength: 100,
  pageCount: 1,
  createDate: '2024-01-01 00:00:00',
  totalView: 1,
  totalBookmarks: 1,
  isBookmarked: false,
);

void main() {
  group('EmbeddingService（モデル未導入）', () {
    test('initialize() は例外を投げず、未初期化のまま正常に返る', () async {
      final svc = EmbeddingService();
      await svc.dispose();

      // モデル未導入（テスト環境では path_provider プラグインも無いため
      // 必ず初期化に失敗する）でも、ここで例外が飛ばないこと。
      await svc.initialize();

      expect(svc.isInitialized, isFalse);
      expect(svc.initError, isNotNull);
      await svc.dispose();
    });

    test('複数箇所からの並行 initialize() でも未ハンドル例外が発生しない', () async {
      final svc = EmbeddingService();
      await svc.dispose();
      await Future.wait([svc.initialize(), svc.initialize(), svc.initialize()]);
      expect(svc.isInitialized, isFalse);
      await svc.dispose();
    });

    test('未初期化での encode* は契約どおり StateError（画面で catch 済み）', () async {
      final svc = EmbeddingService();
      await svc.dispose();
      await svc.initialize();
      await expectLater(svc.encodeQuery('x'), throwsStateError);
      await expectLater(svc.encodeDocument('x'), throwsStateError);
      await svc.dispose();
    });
  });

  group('SimilarWorksService（モデル未導入）', () {
    setUp(() {
      // sqflite のプラグインが無いテスト環境で sqlite3 を使えるようにする。
      // （ウィジェットテストは fake_async 内で Timer が残留するため ffi を使わない）
      databaseFactory = databaseFactoryFfi;
    });

    test('未初期化状態でもクラッシュせず空結果（modelReady=false）を返す', () async {
      final db = await _openTestDb();
      DatabaseService().setTestDatabase(db);
      SimilarWorksService.testInstance = SimilarWorksService();
      try {
        final result = await SimilarWorksService.resolve().buildForNovel(
          _novel(),
          limit: 12,
        );
        expect(result.modelReady, isFalse);
        expect(result.semanticAvailable, isFalse);
        expect(result.works, isEmpty);
        expect(result.sameAuthor, isEmpty);
        expect(result.sameSeries, isEmpty);
      } finally {
        SimilarWorksService.testInstance = null;
      }
    });

    test('意味軸が使えなくてもタグベースの候補は返る（フォールバック）', () async {
      final db = await _openTestDb();
      await db.insert('novels', {
        'id': 2,
        'title': '類似候補',
        'author_id': 2000,
        'series_id': 0,
        'tags_json': jsonEncode(['TSO', 'オリジナル']),
        'text_length': 200,
        'total_bookmarks': 5,
      });
      DatabaseService().setTestDatabase(db);
      SimilarWorksService.testInstance = SimilarWorksService();
      try {
        final result = await SimilarWorksService.resolve().buildForNovel(
          _novel(),
          limit: 12,
        );
        expect(result.modelReady, isFalse);
        // タグ Jaccard で類似した候補がタグ軸のみで取得できる。
        expect(result.works.map((w) => w.workId), contains(2));
        expect(result.works.every((w) => w.semanticScore == 0), isTrue);
      } finally {
        SimilarWorksService.testInstance = null;
      }
    });

    test('DB が全く準備できていない場合も例外を投げず空結果を返す', () async {
      // テーブルが 1 つも無い空の DB を注入し、全クエリが失敗する状態にする。
      // （inMemoryDatabasePath は同一インスタンスが再利用されるため、
      //  前テストの行は明示的に削除しておく）
      final emptyDb = await openDatabase(inMemoryDatabasePath);
      for (final t in ['novels', 'novel_embeddings', 'emotion_curves']) {
        try {
          await emptyDb.execute('DROP TABLE IF EXISTS $t');
        } catch (_) {
          // 想定しないエラーのみ。テスト継続
        }
      }
      DatabaseService().setTestDatabase(emptyDb);
      SimilarWorksService.testInstance = SimilarWorksService();
      try {
        final result = await SimilarWorksService.resolve().buildForNovel(
          _novel(),
          limit: 12,
        );
        expect(result.modelReady, isFalse);
        expect(result.works, isEmpty);
      } finally {
        SimilarWorksService.testInstance = null;
      }
    });
  });

  group('EmotionCurveService（モデル未導入）', () {
    setUp(() {
      final svc = EmotionCurveService();
      svc.testEncodeDocument = null;
      svc.testEncodeQuery = null;
      svc.testSkipCache = true;
      svc.testForceDictionary = false;
    });

    test('compute() はクラッシュせず簡易モードへフォールバックする', () async {
      final svc = EmotionCurveService();
      final pages = ['嬉しくて、思わず笑顔になる。'];
      final r = await svc.compute(workId: 1, text: pages.join(), pages: pages);
      expect(r, isNotNull);
      expect(r!.isSimpleMode, isTrue);
      expect(r.modelId, kDictionaryModelId);
      expect(r.zScores.length, kEmotionLabels.length);
    });

    test('モデル経路のエンコーダが例外を投げても簡易モードへフォールバックする', () async {
      final svc = EmotionCurveService();
      // フェイクエンコーダを渡すと isModelAvailable() はモデル有り扱いになる。
      // その状態でエンコードが必ず失敗しても例外を UI に漏らさないこと。
      svc.testEncodeQuery = (t) async => throw StateError('モデル破損');
      svc.testEncodeDocument = (t) async => throw StateError('モデル破損');

      final pages = ['切ない思いが胸に残る。'];
      final r = await svc.compute(workId: 2, text: pages.join(), pages: pages);
      expect(r, isNotNull);
      expect(r!.isSimpleMode, isTrue);
      expect(r.modelId, kDictionaryModelId);
    });

    test('キャンセルは従来どおり StateError として伝播する', () async {
      final svc = EmotionCurveService();
      svc.testEncodeQuery = (t) async => [1.0, 0.0];
      svc.testEncodeDocument = (t) async {
        svc.cancel();
        return [1.0, 0.0];
      };
      final text = 'a' * 2400; // 3 チャンク
      await expectLater(
        svc.compute(workId: 3, text: text, pages: [text]),
        throwsStateError,
      );
    });
  });

  group('NovelDetailScreen（モデル未導入）', () {
    testWidgets('詳細画面を開いても例外が UI に届かず、AI セクションは静かに非表示になる', (tester) async {
      // DB 注入を解除（プラグイン無し → database getter が失敗し、
      // 各呼び出し元の try-catch で握りつぶされる状態）。
      // sqflite ffi を fake_async 内で使うとトランザクション用 Timer が
      // 残留して invariant 違反になるため、ここでは ffi に戻さない。
      databaseFactory = databaseFactoryFfi; // load 時の getter 例外回避のため設定
      DatabaseService().clearTestDatabase();

      // 前テストで残ったテストフック（フェイクエンコーダ等）を必ず戻す。
      final ec = EmotionCurveService();
      ec.testEncodeDocument = null;
      ec.testEncodeQuery = null;
      ec.testSkipCache = true;
      ec.testForceDictionary = false;

      await tester.pumpWidget(
        MaterialApp(home: NovelDetailScreen(novel: _novel())),
      );
      await tester.pumpAndSettle();

      // 未ハンドル例外が一切起きていないこと。
      expect(tester.takeException(), isNull);

      // モデル未導入なので AI 系セクションは非表示（エラー表示も出ない）。
      expect(find.text('📚 似た作品'), findsNothing);
      expect(find.text('似た作品の読み込みに失敗しました'), findsNothing);
      expect(find.textContaining('感情曲線'), findsNothing);
      expect(find.textContaining('AIモデル'), findsNothing);
    });
  });
}
