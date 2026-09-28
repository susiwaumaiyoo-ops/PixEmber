// Phase 18c: ReadLaterScreen の初 widget テスト（コレクション内検索）。
//
// statistics_screen_test.dart と同様に sqflite には依存せず、
// read_later に対する query() のみ実装した Fake DB を
// DatabaseService.setTestDatabase で注入する（シングルトン共有）。
// 本番の getReadLaterList が生成し得る where / whereArgs の
// 4 形態（status のみ / query のみ / 両方 / なし）のみを解釈する。
//
// 検証内容:
// - 初期表示（全件・件数バッジ）
// - 検索アイコンで title が TextField に差し替わること
// - タイトル部分一致で絞り込まれること
// - 検索語がタブ切替を跨いで維持されること
// - 該当 0 件で「該当する作品が見つかりません」が表示されること
// - 検索モード解除で全件に戻る・検索語がクリアされること
// - 大きい textScaleFactor でも AppBar が overflow しないこと
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Database;

import 'package:pixiv_viewer/screens/read_later_screen.dart';
import 'package:pixiv_viewer/services/database_service.dart';

/// read_later の query() のみ実装した最小 Fake DB。
/// getReadLaterList が生成し得る where 形態のみ解釈する。
class _FakeReadLaterDatabase implements Database {
  _FakeReadLaterDatabase(this._rows);

  final List<Map<String, Object?>> _rows;

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    List<String>? columns,
    bool? distinct,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    if (table != 'read_later') return [];
    var result = List<Map<String, Object?>>.from(_rows);
    if (where != null) {
      int argIndex = 0;
      if (where.contains('status = ?')) {
        final status = whereArgs![0] as int;
        result = result
            .where((r) => r['status'] == status)
            .toList(growable: true);
        argIndex = 1;
      }
      if (where.contains('title LIKE ?')) {
        final q = (whereArgs![argIndex] as String)
            .replaceAll('%', '')
            .toLowerCase();
        result = result
            .where((r) {
              final title = (r['title'] as String? ?? '').toLowerCase();
              final author = (r['author_name'] as String? ?? '').toLowerCase();
              final tags = (r['tags_json'] as String? ?? '').toLowerCase();
              return title.contains(q) ||
                  author.contains(q) ||
                  tags.contains(q);
            })
            .toList(growable: true);
      }
    }
    // added_at DESC, id DESC（本番の orderBy と同一）。
    result.sort((a, b) {
      final cmp = (b['added_at'] as String).compareTo(a['added_at'] as String);
      return cmp != 0 ? cmp : (b['id'] as int).compareTo(a['id'] as int);
    });
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Map<String, Object?> _row({
  required int id,
  required int workId,
  required String title,
  required String author,
  required String tags,
  required int status,
  required String addedAt,
}) => {
  'id': id,
  'work_id': workId,
  'title': title,
  'author_name': author,
  'tags_json': tags,
  'status': status,
  'x_restrict': 0,
  'added_at': addedAt,
  'cover_url': '',
  'text_length': 1000,
};

List<Map<String, Object?>> _sampleRows() => [
  _row(
    id: 1,
    workId: 101,
    title: '紅茶の探偵譚',
    author: '田中ヨコ',
    tags: '["romance","mystery"]',
    status: 0,
    addedAt: '2026-01-01T00:00:00Z',
  ),
  _row(
    id: 2,
    workId: 102,
    title: '剣の章',
    author: '佐藤ハルキ',
    tags: '["fantasy","action"]',
    status: 1,
    addedAt: '2026-01-02T00:00:00Z',
  ),
  _row(
    id: 3,
    workId: 103,
    title: '赤い空の観測所',
    author: '佐藤ハルキ',
    tags: '["romance","daily life"]',
    status: 2,
    addedAt: '2026-01-03T00:00:00Z',
  ),
];

Future<void> pumpReadLater(
  WidgetTester tester, {
  required Database fakeDb,
  TextScaler textScaler = const TextScaler.linear(1.0),
}) async {
  final db = DatabaseService();
  db.setTestDatabase(fakeDb);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: textScaler),
        child: const ReadLaterScreen(),
      ),
    ),
  );
  // initState の _loadAll（非同期・全 4 タブ分）を消化。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('ReadLaterScreen 初期表示', () {
    testWidgets('全 3 件と件数バッジが表示される', (tester) async {
      await pumpReadLater(
        tester,
        fakeDb: _FakeReadLaterDatabase(_sampleRows()),
      );

      expect(find.text('あとで読む'), findsOneWidget);
      expect(find.text('すべて (3)'), findsOneWidget);
      expect(find.text('未読 (1)'), findsOneWidget);
      expect(find.text('読書中 (1)'), findsOneWidget);
      expect(find.text('読了 (1)'), findsOneWidget);
      // 既定の「すべて」タブに 3 件すべて表示。
      expect(find.text('紅茶の探偵譚'), findsOneWidget);
      expect(find.text('剣の章'), findsOneWidget);
      expect(find.text('赤い空の観測所'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('ReadLaterScreen コレクション内検索（18b）', () {
    testWidgets('検索アイコンで title が検索フィールドに差し替わる', (tester) async {
      await pumpReadLater(
        tester,
        fakeDb: _FakeReadLaterDatabase(_sampleRows()),
      );
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.byTooltip('検索'));
      await tester.pump();

      // title の「あとで読む」が消え、TextField が現れる。
      expect(find.text('あとで読む'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byTooltip('検索を終了'), findsOneWidget);
      // 従来の actions は検索中は出さない（close のみ）。
      expect(find.byTooltip('あとで読む整理提案'), findsNothing);
    });

    testWidgets('タイトル部分一致で表示が絞り込まれる', (tester) async {
      await pumpReadLater(
        tester,
        fakeDb: _FakeReadLaterDatabase(_sampleRows()),
      );
      await tester.tap(find.byTooltip('検索'));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '探偵譚');
      await tester.pump();

      // '紅茶の探偵譚' のみ残り、バッジも更新される。
      expect(find.text('紅茶の探偵譚'), findsOneWidget);
      expect(find.text('剣の章'), findsNothing);
      expect(find.text('赤い空の観測所'), findsNothing);
      expect(find.text('すべて (1)'), findsOneWidget);
      expect(find.text('未読 (1)'), findsOneWidget);
      expect(find.text('読書中 (0)'), findsOneWidget);
      expect(find.text('読了 (0)'), findsOneWidget);
    });

    testWidgets('検索語はタブ切替を跨いで維持される', (tester) async {
      await pumpReadLater(
        tester,
        fakeDb: _FakeReadLaterDatabase(_sampleRows()),
      );
      await tester.tap(find.byTooltip('検索'));
      await tester.pump();

      // '赤い空' は 103（読了）のみにマッチ。検索語が維持されていれば
      // 未読・読書中のバッジは 0 のまま、解除（リセット）されていれば 1 になる。
      await tester.enterText(find.byType(TextField), '赤い空');
      await tester.pump();
      expect(find.text('すべて (1)'), findsOneWidget);
      expect(find.text('未読 (0)'), findsOneWidget);
      expect(find.text('読書中 (0)'), findsOneWidget);
      expect(find.text('読了 (1)'), findsOneWidget);

      // 「読了」タブへ切替 → バッジは維持され 103 が表示される。
      // TabBarView（PageView）のページ遷移は 300ms のアニメーションのため、
      // 単一 pump だと到達ページがまだレイアウトされない。
      await tester.tap(find.text('読了 (1)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('赤い空の観測所'), findsOneWidget);
      // 検索語がリセットされていたら「未読 (1)」「読書中 (1)」になるはず。
      expect(find.text('未読 (0)'), findsOneWidget);
      expect(find.text('読書中 (0)'), findsOneWidget);

      // 「読書中」タブへ切替 → 空のまま（検索語が維持される証拠）。
      await tester.tap(find.text('読書中 (0)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('剣の章'), findsNothing);
      expect(find.text('紅茶の探偵譚'), findsNothing);
      expect(find.text('該当する作品が見つかりません'), findsOneWidget);
      // 検索フィールドの文字列も消えていない。
      expect(find.text('赤い空'), findsOneWidget);
    });

    testWidgets('該当 0 件で「該当する作品が見つかりません」が表示される', (tester) async {
      await pumpReadLater(
        tester,
        fakeDb: _FakeReadLaterDatabase(_sampleRows()),
      );
      await tester.tap(find.byTooltip('検索'));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '存在しない作品名');
      await tester.pump();

      expect(find.text('該当する作品が見つかりません'), findsOneWidget);
      expect(find.text('すべて (0)'), findsOneWidget);
    });

    testWidgets('検索モード解除で検索語がクリアされ全件に戻る', (tester) async {
      await pumpReadLater(
        tester,
        fakeDb: _FakeReadLaterDatabase(_sampleRows()),
      );
      await tester.tap(find.byTooltip('検索'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '佐藤');
      await tester.pump();
      expect(find.text('すべて (2)'), findsOneWidget);

      await tester.tap(find.byTooltip('検索を終了'));
      await tester.pump();

      // title が復帰し、全 3 件・バッジも元に戻る。
      expect(find.text('あとで読む'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('すべて (3)'), findsOneWidget);
      expect(find.text('紅茶の探偵譚'), findsOneWidget);
      expect(find.text('剣の章'), findsOneWidget);
      expect(find.text('赤い空の観測所'), findsOneWidget);
    });

    testWidgets('大きい textScaleFactor でも AppBar は overflow しない', (tester) async {
      await pumpReadLater(
        tester,
        fakeDb: _FakeReadLaterDatabase(_sampleRows()),
        textScaler: TextScaler.linear(2.0),
      );
      await tester.tap(find.byTooltip('検索'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '佐藤ハルキ');
      await tester.pump();

      expect(tester.takeException(), isNull);
      // 検索中もタイトル部分・タブ・検索結果が描画されている。
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('剣の章'), findsOneWidget);
      expect(find.text('赤い空の観測所'), findsOneWidget);
    });
  });
}
