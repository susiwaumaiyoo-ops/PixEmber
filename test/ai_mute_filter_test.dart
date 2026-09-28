// Phase 19A-1: AIミュート（aiMuteValue）のフィルタ挙動の契約テスト。
//
// 修正前: aiMuteValue == '2'（UI: 「AI作品のみにする (逆フィルタ)」）が
// 全作品を `continue` して全件を非表示にするバグだった。
// 修正後: '2' は AI作品のみを残す（非AIを除外）。
//
// - shouldKeepAiWork（純粋関数）: 値 × AI/非AI の全組み合わせ
// - filterIllusts（ffi インメモリ DB + mutes テーブル）:
//   '0' / '1' / '2' 各々の混在リストの絞り込み、
//   既存のタグ/ユーザーミュートの回帰
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/illust_model.dart';
import 'package:pixiv_viewer/services/database_service.dart';
import 'package:pixiv_viewer/services/pixiv_api/pixiv_api_service.dart';

/// mutes テーブル（database_schema の mutes と同一構造）。
const String _createMutes = '''
  CREATE TABLE IF NOT EXISTS mutes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    mute_type TEXT,
    value TEXT,
    label TEXT,
    created_at TEXT
  )
''';

/// イラスト 1 件の最小 JSON（filterIllusts が読むフィールドのみ）。
Map<String, dynamic> _illust({
  required int id,
  required int aiType,
  List<String> tags = const [],
}) =>
    {
      'id': id,
      'type': 'illust',
      'x_restrict': 0,
      'illust_ai_type': aiType,
      'user': {'id': 1000 + id},
      'tags': [
        for (final t in tags) {'name': t, 'translated_name': ''}
      ],
    };

void main() {
  group('shouldKeepAiWork（純粋関数）', () {
    test('aiMuteValue が null（ミュート未登録）なら全て残す', () {
      expect(PixivApiService.shouldKeepAiWork(null, true), isTrue);
      expect(PixivApiService.shouldKeepAiWork(null, false), isTrue);
    });

    test("'0'（除外しない）なら全て残す", () {
      expect(PixivApiService.shouldKeepAiWork('0', true), isTrue);
      expect(PixivApiService.shouldKeepAiWork('0', false), isTrue);
    });

    test("'1'（AI作品を非表示）なら非AIのみ残す", () {
      expect(PixivApiService.shouldKeepAiWork('1', true), isFalse);
      expect(PixivApiService.shouldKeepAiWork('1', false), isTrue);
    });

    test("'2'（AIのみにする・逆フィルタ）ならAIのみ残す（19A-1 修正箇所）", () {
      // 旧実装はここで両方 false（全件非表示）になっていた。
      expect(PixivApiService.shouldKeepAiWork('2', true), isTrue);
      expect(PixivApiService.shouldKeepAiWork('2', false), isFalse);
    });

    test('不明な値は除外しない（保守的に残す）', () {
      expect(PixivApiService.shouldKeepAiWork('9', true), isTrue);
      expect(PixivApiService.shouldKeepAiWork('9', false), isTrue);
    });
  });

  group('filterIllusts（mutes DB 経由）', () {
    late DatabaseService db;
    late Database testDb;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      db = DatabaseService();
      testDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 1, onCreate: (d, _) async {
          await d.execute(_createMutes);
        }),
      );
      db.setTestDatabase(testDb);
    });

    tearDown(() async {
      await testDb.close();
      await db.restartDatabase();
    });

    /// AI 1 件（id=1）+ 非AI 1 件（id=2）の混在リスト。
    List<dynamic> mixed() => [
      _illust(id: 1, aiType: 2, tags: ['AI']),
      _illust(id: 2, aiType: 0, tags: ['猫']),
    ];

    List<int> ids(List<dynamic> list) =>
        list.map((e) => (e as Illust).id).toList();

    Future<void> setAiMute(String value) async {
      await testDb.insert(
        'mutes',
        {'mute_type': 'ai', 'value': value, 'label': null},
      );
    }

    test('ai ミュートなしなら全件残す', () async {
      final result = await PixivApiService().filterIllusts(mixed());
      expect(ids(result), [1, 2]);
    });

    test("'0'（除外しない）なら全件残す", () async {
      await setAiMute('0');
      final result = await PixivApiService().filterIllusts(mixed());
      expect(ids(result), [1, 2]);
    });

    test("'1'（AI非表示）なら非AIのみ残す", () async {
      await setAiMute('1');
      final result = await PixivApiService().filterIllusts(mixed());
      expect(ids(result), [2]);
    });

    test("'2'（AIのみ・逆フィルタ）ならAIのみ残す（19A-1 修正箇所）", () async {
      await setAiMute('2');
      final result = await PixivApiService().filterIllusts(mixed());
      // 修正前はここで空リスト（全件非表示）になっていた。
      expect(ids(result), [1]);
    });

    test('タグミュートは ai ミュートと併存して効く（回帰）', () async {
      await setAiMute('1');
      await testDb.insert(
        'mutes',
        {'mute_type': 'tag', 'value': '猫', 'label': null},
      );
      // AI(id=1) は '1' で除外、非AI(id=2) はタグミュートで除外 → 空。
      final result = await PixivApiService().filterIllusts(mixed());
      expect(result, isEmpty);
    });

    test('ユーザーミュートは回帰していない', () async {
      await testDb.insert(
        'mutes',
        {'mute_type': 'user', 'value': '1001', 'label': null},
      );
      final result = await PixivApiService().filterIllusts(mixed());
      // id=1（user 1001）のみミュート。
      expect(ids(result), [2]);
    });
  });
}
