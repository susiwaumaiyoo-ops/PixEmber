// 読書傾向集計（Phase B）のテスト。
//
// 対象（純粋関数）:
// - 曜日×時間帯ヒートマップ（日付境界 / UTC→ローカル / 期間境界 / 空データ）
// - 月別トップタグ推移（月境界 / データなし月省略 / 空データ）
// - スティーク（連続 / 途切れ警告 / 最長 / 空データ）
// - 年次サマリ（年度境界 / distinct 集計 / 空データ）
// - 発掘率（初見作者 / 空データ）
// - 作者集中度 / フォーマット関数
// - 統計画面へのレンダリング（Fake DB 注入）
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Database;

import 'package:pixiv_viewer/screens/statistics_screen.dart';
import 'package:pixiv_viewer/services/database_service.dart';
import 'package:pixiv_viewer/services/reading_trends_service.dart';

/// 傾向データ（histoy・usage_sessions・tags_json・text_length）を返す Fake DB。
class _FakeTrendsDatabase implements Database {
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
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day).toIso8601String();
    final yesterday = n.subtract(const Duration(days: 1)).toIso8601String();
    if (table == 'history') {
      return [
        {
          'type': 'novel',
          'work_id': 1,
          'author_name': 'AuthorA',
          'created_at': today,
        },
        {
          'type': 'novel',
          'work_id': 2,
          'author_name': 'AuthorB',
          'created_at': yesterday,
        },
      ];
    }
    if (table == 'usage_sessions') {
      return [
        {
          'work_type': 'novel',
          'work_id': 1,
          'duration_seconds': 600,
          'started_at': today,
        },
      ];
    }
    return [];
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? args,
  ]) async {
    if (sql.contains('tags_json')) {
      return [
        {
          'id': 1,
          'tags_json': jsonEncode(['恋愛', 'ドラマ']),
        },
        {'id': 2, 'tags_json': '恋愛'},
      ];
    }
    if (sql.contains('text_length')) {
      return [
        {'id': 1, 'text_length': 12000},
        {'id': 2, 'text_length': 8000},
      ];
    }
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  // 2026-09-04 は金曜日。
  final now = DateTime(2026, 9, 4, 12, 0, 0);

  Map<String, dynamic> usageRow({
    int workId = 1,
    int seconds = 60,
    String? startedAt,
    String workType = 'novel',
  }) => <String, dynamic>{
    'work_type': workType,
    'work_id': workId,
    'duration_seconds': seconds,
    'started_at': startedAt ?? now.toIso8601String(),
  };

  group('computeWeekdayHourHeatmap', () {
    test('曜日（月曜始まり）× 時間 のバケット', () {
      // 2026-09-07 は月曜日。
      final h = computeWeekdayHourHeatmap(
        [usageRow(startedAt: '2026-09-07T08:30:00')],
        period: TrendPeriod.all,
        now: DateTime(2026, 9, 10),
      );
      expect(h.length, 168);
      expect(h[0 * 24 + 8], 1); // 月曜 8時
    });

    test('UTC タイムスタンプはローカル時間に変換される（JST 前提）', () {
      // UTC 2026-09-07T23:30Z → JST 2026-09-08（火曜）08:30。
      final h = computeWeekdayHourHeatmap(
        [usageRow(startedAt: '2026-09-07T23:30:00.000Z')],
        period: TrendPeriod.all,
        now: DateTime(2026, 9, 10),
      );
      expect(h[1 * 24 + 8], 1); // 火曜 8時
    });

    test('期間境界（開始は含む）', () {
      // start = 2026-08-05T12:00（now - 30日）。
      final rows = [
        usageRow(startedAt: '2026-08-05T11:59:00'), // 開始1分前 → 除外
        usageRow(startedAt: '2026-08-05T12:00:00'), // 開始ちょうど → 採用
        usageRow(startedAt: '2026-09-04T12:00:00'), // 本日 → 採用
      ];
      final h = computeWeekdayHourHeatmap(
        rows,
        period: TrendPeriod.d30,
        now: now,
      );
      expect(h.reduce((a, b) => a + b), 2);
    });

    test('空データは全0', () {
      final h = computeWeekdayHourHeatmap(
        const [],
        period: TrendPeriod.d30,
        now: now,
      );
      expect(h.length, 168);
      expect(h.every((v) => v == 0), isTrue);
    });
  });

  group('computeMonthlyTagEvolution', () {
    Map<String, dynamic> histRow(String createdAt, int workId) =>
        <String, dynamic>{'created_at': createdAt, 'work_id': workId};

    test('月別バケット・TOP N・データなし月は省略', () {
      final history = [
        histRow('2026-08-01T10:00:00', 1),
        histRow('2026-08-10T10:00:00', 2),
        histRow('2026-09-01T10:00:00', 1),
      ];
      final tags = {
        1: ['恋愛', 'ドラマ'],
        2: ['恋愛'],
      };
      final months = computeMonthlyTagEvolution(
        history,
        tags,
        period: TrendPeriod.all,
        now: now,
      );
      expect(months.length, 2);
      expect(months[0]['year'], 2026);
      expect(months[0]['month'], 8);
      final augTags = (months[0]['tags'] as List).cast<Map<String, dynamic>>();
      expect(augTags.first['name'], '恋愛');
      expect(augTags.first['count'], 2);
      expect(months[1]['month'], 9);
    });

    test('月境界（23:59 は前月、00:01 は翌月）', () {
      final history = [
        histRow('2026-08-31T23:59:00', 1),
        histRow('2026-09-01T00:01:00', 2),
      ];
      final months = computeMonthlyTagEvolution(
        history,
        {
          1: ['a'],
          2: ['b'],
        },
        period: TrendPeriod.all,
        now: now,
      );
      expect(months.length, 2);
      expect(months[0]['month'], 8);
      expect(months[1]['month'], 9);
    });

    test('タグが無い作品だけなら空', () {
      final months = computeMonthlyTagEvolution(
        [histRow('2026-09-01T10:00:00', 9)],
        const {},
        period: TrendPeriod.all,
        now: now,
      );
      expect(months, isEmpty);
    });
  });

  group('computeReadingStreak', () {
    test('本日まで連続', () {
      final days = [
        now,
        now.subtract(const Duration(days: 1)),
        now.subtract(const Duration(days: 2)),
      ];
      final s = computeReadingStreak(days, now: now);
      expect(s['current'], 3);
      expect(s['longest'], 3);
      expect(s['atRisk'], isFalse);
    });

    test('本日無しでも昨日から継続中なら atRisk', () {
      final days = [
        now.subtract(const Duration(days: 1)),
        now.subtract(const Duration(days: 2)),
        // 過去の3日連続（途切れている）
        now.subtract(const Duration(days: 10)),
        now.subtract(const Duration(days: 11)),
        now.subtract(const Duration(days: 12)),
      ];
      final s = computeReadingStreak(days, now: now);
      expect(s['current'], 2);
      expect(s['longest'], 3);
      expect(s['atRisk'], isTrue);
    });

    test('昨日も無い場合は途切れ（current=0・atRisk=false）', () {
      final s = computeReadingStreak([
        now.subtract(const Duration(days: 3)),
      ], now: now);
      expect(s['current'], 0);
      expect(s['atRisk'], isFalse);
    });

    test('空データは 0 / 0', () {
      final s = computeReadingStreak(const [], now: now);
      expect(s['current'], 0);
      expect(s['longest'], 0);
      expect(s['atRisk'], isFalse);
    });
  });

  group('computeAnnualSummary', () {
    test('今年のみ・作品は distinct', () {
      final rows = [
        usageRow(workId: 1, seconds: 120, startedAt: '2026-01-01T10:00:00'),
        usageRow(workId: 1, seconds: 60, startedAt: '2026-03-01T10:00:00'),
        usageRow(workId: 2, seconds: 60, startedAt: '2026-08-01T10:00:00'),
        usageRow(
          workId: 3,
          seconds: 60,
          startedAt: '2025-12-31T10:00:00',
        ), // 去年
        usageRow(
          workId: 4,
          seconds: 60,
          startedAt: '2026-05-01T10:00:00',
          workType: 'illust',
        ),
      ];
      final s = computeAnnualSummary(rows, {
        1: 10000,
        2: 20000,
        3: 99999,
      }, now: now);
      expect(s['workCount'], 2);
      expect(s['totalChars'], 30000);
      expect(s['totalSeconds'], 240);
    });

    test('空データは全0', () {
      final s = computeAnnualSummary(const [], const {}, now: now);
      expect(s['workCount'], 0);
      expect(s['totalChars'], 0);
      expect(s['totalSeconds'], 0);
    });
  });

  group('computeDiscoveryRate', () {
    Map<String, dynamic> h(String at, String author) => <String, dynamic>{
      'created_at': at,
      'author_name': author,
    };

    test('初見作者の比率', () {
      // 期間開始 = 2026-08-05T12:00。
      final rows = [
        h('2026-08-01T10:00:00', 'A'), // 期間前（既見）
        h('2026-09-01T10:00:00', 'A'), // 期間内（既見）
        h('2026-09-02T10:00:00', 'B'), // 初見
        h('2026-09-03T10:00:00', 'C'), // 初見
      ];
      final d = computeDiscoveryRate(rows, period: TrendPeriod.d30, now: now);
      expect(d['totalAuthors'], 3);
      expect(d['newAuthors'], 2);
      expect(d['rate'], closeTo(2 / 3, 1e-9));
    });

    test('空データは rate=0', () {
      final d = computeDiscoveryRate(
        const [],
        period: TrendPeriod.d30,
        now: now,
      );
      expect(d['totalAuthors'], 0);
      expect(d['rate'], 0.0);
    });
  });

  group('computeAuthorConcentration', () {
    test('TOP 占比と作者数', () {
      final rows = [
        {'author_name': 'A'},
        {'author_name': 'A'},
        {'author_name': 'A'},
        {'author_name': 'B'},
        {'author_name': 'C'},
        {'author_name': 'D'},
        {'author_name': ''}, // 空は除外
      ];
      final c = computeAuthorConcentration(rows, topN: 2);
      expect(c['totalAuthors'], 4);
      expect(c['totalRows'], 6);
      expect((c['top'] as List).first['name'], 'A');
      expect(c['topShare'], closeTo(4 / 6, 1e-9));
    });
  });

  group('formatCharCount / formatHoursMinutes', () {
    test('文字数フォーマット', () {
      expect(formatCharCount(0), '0文字');
      expect(formatCharCount(9999), '9999文字');
      expect(formatCharCount(12000), '1.2万字');
      expect(formatCharCount(12300), '1.2万字');
      expect(formatCharCount(356000), '35.6万字');
    });

    test('時間フォーマット', () {
      expect(formatHoursMinutes(0), '1分未満');
      expect(formatHoursMinutes(600), '10分');
      expect(formatHoursMinutes(3600), '1時間');
      expect(formatHoursMinutes(3600 + 30 * 60), '1時間30分');
    });
  });

  group('StatisticsScreen 読書傾向セクション', () {
    testWidgets('ヒートマップ・スティーク・年次サマリがレンダリングされる', (tester) async {
      tester.view.physicalSize = const Size(1080, 6000);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final db = DatabaseService();
      db.setTestDatabase(_FakeTrendsDatabase());

      await tester.pumpWidget(const MaterialApp(home: StatisticsScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull);
      expect(find.text('読書傾向'), findsOneWidget);
      // 本日 + 昨日 のセッション → 2日連続。
      expect(find.textContaining('日連続'), findsOneWidget);
      // 今年 1作品読了。
      expect(find.textContaining('今年の読書'), findsOneWidget);
    });
  });
}
