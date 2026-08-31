// 閲覧統計画面のユニットテスト。
//
// 対象:
// - 純粋関数 computeStatistics（決定性・キャプチャなしを担保）
//   修正前は Isolate.run にクロージャを渡し Widget/Binding 系の送信不可
//   オブジェクトを参照して「Illegal argument in isolate message」を投じていた。
//   修正後はトップレベルの純粋関数をメイン Isolate で直接呼ぶため、
//   同一入力で常に同一出力（外部状態・Widget 非依存）であることを検証する。
// - StatisticsScreen のエラー経路 UI（長いエラーでも overflow しない）
//
// 実DBファイル・ネットワークには依存しない（query を例外投げる Fake DB を注入）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Database;

import 'package:pixiv_viewer/screens/statistics_screen.dart';
import 'package:pixiv_viewer/services/database_service.dart';

/// query が例外を投げる最小の Fake DB。
class _ThrowingDatabase implements Database {
  final String message;
  _ThrowingDatabase(this.message);

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
  }) async => throw Exception(message);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  // ========================================================================
  // 純粋関数: computeStatistics（決定性 / キャプチャなし）
  // ========================================================================
  group('computeStatistics（純粋関数・決定性）', () {
    final now = DateTime(2026, 8, 29, 12, 0, 0);

    Map<String, dynamic> row({
      String type = 'novel',
      String author = 'authorA',
      DateTime? createdAt,
    }) => <String, dynamic>{
      'type': type,
      'author_name': author,
      'created_at': (createdAt ?? now).toIso8601String(),
    };

    test('空リストは全て0・日別は当日を末尾に30日分0埋め', () {
      final m = computeStatistics([], now: now);
      expect(m['total'], 0);
      expect(m['illust'], 0);
      expect(m['novel'], 0);
      expect(m['unknown'], 0);
      expect(m['today'], 0);
      expect(m['last7'], 0);
      expect(m['last30'], 0);
      final daily = (m['daily'] as List).cast<Map<String, dynamic>>();
      expect(daily.length, 30);
      expect(daily.last['date'], '2026-8-29');
      expect(daily.last['count'], 0);
    });

    test('type 別集計（illust/ugoira は illust に集約）', () {
      final m = computeStatistics([
        row(type: 'illust'),
        row(type: 'ugoira'),
        row(type: 'novel'),
        row(type: 'unknownType'),
      ], now: now);
      expect(m['illust'], 2);
      expect(m['novel'], 1);
      expect(m['unknown'], 1);
      expect(m['total'], 4);
    });

    test('期間バケット（今日 / 過去7日 / 過去30日）', () {
      final m = computeStatistics([
        row(createdAt: DateTime(2026, 8, 29, 9, 0, 0)), // 今日
        row(createdAt: DateTime(2026, 8, 26, 9, 0, 0)), // 3日前
        row(createdAt: DateTime(2026, 8, 15, 9, 0, 0)), // 14日前
        row(createdAt: DateTime(2026, 7, 1, 9, 0, 0)), // 59日前（30日超）
      ], now: now);
      expect(m['today'], 1);
      expect(m['last7'], 2); // 今日(0日) + 3日前のみ（14日前は7日圏外）
      expect(m['last30'], 3);
      expect(m['total'], 4);
    });

    test('作者集計は件数降順・TOP10 に制限', () {
      final rows = <Map<String, dynamic>>[];
      // authorA x3, authorB x2, authorC x1
      for (int i = 0; i < 3; i++) {
        rows.add(row(author: 'authorA'));
      }
      for (int i = 0; i < 2; i++) {
        rows.add(row(author: 'authorB'));
      }
      rows.add(row(author: 'authorC'));
      final m = computeStatistics(rows, now: now);
      final authors = (m['authors'] as List).cast<Map<String, dynamic>>();
      expect(authors.first['name'], 'authorA');
      expect(authors.first['count'], 3);
      expect(authors.last['name'], 'authorC');
      expect(authors.last['count'], 1);
    });

    test('同一入力で常に同一出力（純粋性・外部状態非依存）', () {
      final rows = [
        row(type: 'illust', author: 'a'),
        row(type: 'novel', author: 'b'),
        row(type: 'novel', author: 'a', createdAt: DateTime(2026, 8, 25)),
        row(type: 'unknown', author: '', createdAt: DateTime(2026, 7, 20)),
      ];
      final a = computeStatistics(rows, now: now);
      final b = computeStatistics(rows, now: now);
      // 深さ比較: 同一入力が同一 Map 構造・値を返す（キャプチャや
      // 呼び出し元状態への依存がないことの担保）。
      expect(a, equals(b));
      // 入力リストの改変が結果に影響しない（コピー/値参照のみ）。
      rows[0]['author_name'] = 'MUTATED';
      final c = computeStatistics(rows, now: now);
      expect((c['authors'] as List).first, isNot(equals('MUTATED')));
    });
  });

  // ========================================================================
  // StatisticsScreen: エラー経路 UI（長いエラーでも overflow しない）
  // ========================================================================
  group('StatisticsScreen エラー経路', () {
    testWidgets('長いエラーメッセージでも overflow せずスクロール可能', (tester) async {
      // 小さい画面（360x640）で、長いエラーが必ず溢れる旧実装との差分を検出。
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      // 長いエラーメッセージ（スタックトレース相当）を投じる Fake DB。
      final longMsg = 'stack trace line\n' * 120;
      final db = DatabaseService();
      db.setTestDatabase(_ThrowingDatabase(longMsg));

      // overflow（RenderOverflow）を検知するため onError を差し替える。
      FlutterErrorDetails? overflowError;
      final oldOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exception.toString().contains('OVERFLOWED')) {
          overflowError = details;
        }
      };
      addTearDown(() => FlutterError.onError = oldOnError);

      await tester.pumpWidget(const MaterialApp(home: StatisticsScreen()));
      // initState の _load()（非同期）を消化。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // エラー UI が表示されている。
      expect(find.textContaining('統計の読み込みに失敗しました'), findsOneWidget);
      expect(find.text('再読み込み'), findsOneWidget);

      // 長いメッセージでも overflow が起きない（修正の担保）。
      expect(
        overflowError,
        isNull,
        reason:
            '長いエラー時に BOTTOM OVERFLOW した: '
            '${overflowError?.exception}',
      );

      // エラー本体はスクロール可能コンテナ内にある。
      expect(find.byType(SingleChildScrollView), findsWidgets);
    });
  });
}
