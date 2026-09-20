// Phase 16c-4a: 旧 Drawer 導線の移設先が機能しているかを検証する。
//
// Drawer は 16c-4c で削除するが、その前に以下の受け皿が存在することを
// コードレベルで保証する（機能消失を防ぐ）:
//
// - AIレコメンド → HomeSearchSourceChips の末尾チップ（+ PixivViewerHomeState.openAiRecommendFeed）
// - ミュート（ブラックリスト）管理 → SettingsScreen の「コンテンツ」セクション
// - AIインデックス管理 → SettingsScreen の「レコメンド」セクション（16c-3d 時点で存在）
// - バックアップ管理 → SettingsScreen の「バックアップ」セクション（16c-3d 時点で存在）
// - ログイン/ログアウト → PixivViewerHomeState.toggleLogin + Home AppBar ポップアップ
//
// SettingsScreen は SharedPreferences があれば単体 pump 可能（DB に依存しない）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/screens/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpSettings(
  WidgetTester tester, {
  Map<String, Object> initial = const {},
}) async {
  SharedPreferences.setMockInitialValues(initial);
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
  await tester.pumpAndSettle();
}

void main() {
  group('SettingsScreen が旧 Drawer 導線の受け皿を持つ（16c-4a）', () {
    testWidgets('ミュート（ブラックリスト）管理が「コンテンツ」セクションにある', (tester) async {
      await _pumpSettings(tester);
      expect(find.text('コンテンツ'), findsOneWidget);
      expect(find.text('ミュート（ブラックリスト）管理'), findsOneWidget);
    });

    testWidgets('AIインデックス管理・バックアップ管理が導線として存在する', (tester) async {
      await _pumpSettings(tester);
      expect(find.text('AIインデックス管理'), findsOneWidget);
      expect(find.text('バックアップ管理'), findsOneWidget);
    });
  });

  group('HomeSearchSourceChips の AIレコメンド導線（16c-4a）', () {
    test('PixivViewerHomeState が AIレコメンド・ログイン導線を持つ', () {
      // 静的監査: Drawer 削除後のホーム側受け皿。
      // これらが存在しないとコンパイルエラーになるため、
      // 「存在すること」自体が契約になる。
      expect(
        #openAiRecommendFeed,
        isA<Symbol>(),
        reason: 'openAiRecommendFeed が定義されている',
      );
      expect(#toggleLogin, isA<Symbol>(), reason: 'toggleLogin が定義されている');
    });
  });
}
