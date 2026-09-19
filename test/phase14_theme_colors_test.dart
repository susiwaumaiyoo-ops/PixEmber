// Phase 14 (14d-2 / 14e): シリーズアイコンと固定オーバーレイ上の配色の
// ライト/ダーク回帰テスト。
//
// - 14d-2: NovelListCard のシリーズアイコンが secondary（旧 blueAccent）。
// - 14e-1: 同期 HUD は固定の黒(0.8)オーバーレイ背景のため、副題は
//   onSurfaceVariant（ライトで濃いグレー）ではなく白系統であること。
//   （buildSyncProgressHUD は PixivViewerHomeState 全体を必要とするため
//   ウィジェットポンプは不可。ここでは固定色ペアの静的検証に留める。）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/illust_model.dart';
import 'package:pixiv_viewer/novel_model.dart';
import 'package:pixiv_viewer/theme/app_theme.dart';
import 'package:pixiv_viewer/widgets/novel_list_card.dart';

Novel _seriesNovel() {
  return Novel(
    id: 1,
    title: 'テスト小説',
    caption: '',
    author: Author(id: 0, name: '作者', account: '@test'),
    tags: [],
    coverUrl: '', // 空でローカルプレースホルダ経路（ネットワーク不使用）
    textCount: 0,
    wordCount: 0,
    textLength: 0,
    pageCount: 1,
    createDate: '',
    totalView: 0,
    totalBookmarks: 0,
    isBookmarked: false,
    series: NovelSeriesInfo(id: 10, title: 'テストシリーズ'),
    seriesOrder: 1,
  );
}

Future<void> _pumpCard(WidgetTester tester, ThemeData theme) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: ListView(children: [NovelListCard(novel: _seriesNovel())]),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('NovelListCard シリーズアイコン（14d-2）', () {
    for (final (name, theme) in [
      ('light', AppTheme.lightTheme),
      ('dark', AppTheme.darkTheme),
    ]) {
      testWidgets('$name: シリーズアイコンは secondary（旧 blueAccent ではない）', (
        tester,
      ) async {
        await _pumpCard(tester, theme);
        final icon = tester.widget<Icon>(
          find.byIcon(Icons.collections_bookmark),
        );
        expect(icon.color, theme.colorScheme.secondary);
        expect(icon.color, isNot(Colors.blueAccent));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('同期 HUD の固定オーバーレイ配色（14e-1・静的検証）', () {
    // buildSyncProgressHUD の背景は Themes 共通の Colors.black(0.8) であり、
    // その上の副題が固定白系（white70）で書かれていることを、
    // ウィジェットポンプ不可（PixivViewerHomeState 全体が必要）のため
    // ソースレベルで検証する。
    test('HUD 副題は onSurfaceVariant でない（固定黒背景上の可読性）', () async {
      final src = await _readFileSync('lib/screens/home_ui_components.dart');
      final hudStart = src.indexOf('Widget buildSyncProgressHUD()');
      expect(hudStart, isNonNegative, reason: 'HUD メソッドが存在する');
      final hud = src.substring(hudStart, hudStart + 1200);
      expect(
        hud.contains("color: Colors.white70"),
        isTrue,
        reason: '固定黒背景上の副題は白系であること',
      );
      expect(
        hud.contains('colorScheme.onSurfaceVariant'),
        isFalse,
        reason: '固定黒背景上に onSurfaceVariant を使ってはならない',
      );
    });
  });

  group('ダウンロードキュー completed 色（14e-2・静的検証）', () {
    test(
      '_statusColor の completed は前景用 primary（primaryContainer ではない）',
      () async {
        final src = await _readFileSync(
          'lib/screens/download_queue_screen.dart',
        );
        final start = src.indexOf('Color _statusColor(');
        expect(start, isNonNegative, reason: '_statusColor が存在する');
        final fn = src.substring(start, start + 800);
        final completedCase = fn.substring(fn.indexOf("case 'completed':"));
        expect(
          completedCase.contains('colorScheme.primaryContainer'),
          isFalse,
          reason: '前景（Icon/Chip文字）に容器系トークンは使わない',
        );
        expect(completedCase.contains('return colorScheme.primary;'), isTrue);
      },
    );
  });
}

// 相対パス（flutter test はプロジェクトルートを cwd にするため）。
Future<String> _readFileSync(String relPath) async {
  final f = File(relPath);
  expect(await f.exists(), isTrue, reason: relPath);
  return f.readAsStringSync();
}
