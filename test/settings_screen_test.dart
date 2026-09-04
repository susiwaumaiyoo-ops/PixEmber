// 設定画面（非AI機能パック Phase N7）のユニットテスト。
// リーダー prefs キー（novel_pref_*）との互換性・導線・プリセット管理を検証。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/screens/backup_manager_screen.dart';
import 'package:pixiv_viewer/screens/folder_list_screen.dart';
import 'package:pixiv_viewer/screens/settings_screen.dart';
import 'package:pixiv_viewer/services/search_preset_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpSettings(
  WidgetTester tester, {
  Map<String, Object> initial = const {},
}) async {
  SharedPreferences.setMockInitialValues(initial);
  // 全セクションが可視範囲に入るようビューポートを拡大
  // （ListView の遅延ビルドとオフスクリーンのタップを回避）。
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
  await tester.pumpAndSettle();
}

void main() {
  group('セクション表示', () {
    testWidgets('6セクションの見出しが表示される', (tester) async {
      await _pumpSettings(tester);
      for (final title in [
        '検索',
        'レコメンド',
        '小説リーダー',
        'ライブラリ',
        'バックアップ',
        'ライセンス',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
    });

    testWidgets('各導線タイルが表示される', (tester) async {
      await _pumpSettings(tester);
      for (final title in [
        '保存した検索',
        'AIレコメンド',
        'AIインデックス管理',
        'お気に入りフォルダ',
        'あとで読む',
        'オフライン本棚',
        'しおり一覧',
        'バックアップ管理',
        'ダウンロード管理',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
    });
  });

  group('リーダー設定キーの互換性', () {
    testWidgets('既存の novel_pref_* キーを読み込む', (tester) async {
      await _pumpSettings(
        tester,
        initial: {
          'novel_pref_font_size': 20.0,
          'novel_pref_line_height': 2.2,
          'novel_pref_scroll_speed': 7.5,
          'novel_pref_tts_rate': 1.5,
          'novel_pref_theme_mode': 0,
          'novel_pref_ruby_mode': 'hide',
          'novel_pref_show_reading_time': false,
          'novel_pref_show_emotion_color': true,
        },
      );
      // スライダーの値表示
      expect(find.text('20'), findsOneWidget);
      expect(find.text('2.2'), findsOneWidget);
      expect(find.text('7.5'), findsOneWidget);
      expect(find.text('1.5'), findsOneWidget);
      // ドロップダウンの選択表示
      expect(find.text('白'), findsOneWidget);
      expect(find.text('非表示'), findsOneWidget);
    });

    testWidgets('スイッチ操作で同じキーに書き戻す', (tester) async {
      await _pumpSettings(tester);
      // 読書時間を表示: 既定 true → tap で false
      await tester.tap(find.text('読書時間を表示'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('novel_pref_show_reading_time'), isFalse);

      // TTS ルビ読み上げ: 既定 false → tap で true
      await tester.tap(find.text('TTS でルビも読み上げる'));
      await tester.pumpAndSettle();
      expect(prefs.getBool('novel_pref_tts_read_ruby'), isTrue);
    });

    testWidgets('ドロップダウンでテーマ・ルビを同じキーに書き戻す', (tester) async {
      await _pumpSettings(tester);
      await tester.tap(find.text('セピア'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('漆黒'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('novel_pref_theme_mode'), 2);

      await tester.tap(find.text('表示'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('括弧'));
      await tester.pumpAndSettle();
      expect(prefs.getString('novel_pref_ruby_mode'), 'brackets');
    });
  });

  group('導線（ナビゲーション）', () {
    testWidgets('バックアップ管理へ遷移できる', (tester) async {
      await _pumpSettings(tester);
      await tester.tap(find.text('バックアップ管理'));
      // 遷移アニメーションのみ進める（先画面に無限スピナーがあれば settle しない）
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BackupManagerScreen), findsOneWidget);
    });

    testWidgets('お気に入りフォルダへ遷移できる', (tester) async {
      await _pumpSettings(tester);
      await tester.tap(find.text('お気に入りフォルダ'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(FolderListScreen), findsOneWidget);
    });
  });

  group('保存した検索', () {
    testWidgets('空のときは空状態が表示される', (tester) async {
      await _pumpSettings(tester);
      await tester.tap(find.text('保存した検索'));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存した検索はありません'), findsOneWidget);
    });

    testWidgets('保存済みプリセットをリスト表示し削除できる', (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final service = SearchPresetService();
      await service.save(
        name: '猫 イラスト',
        category: 'illust',
        keyword: '猫',
        filterJson: const {},
        now: DateTime(2026, 1, 1),
      );
      await service.save(
        name: '猫 小説',
        category: 'novel',
        keyword: '猫',
        filterJson: const {},
        now: DateTime(2026, 1, 2),
      );

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();
      expect(find.text('2件・最大30件'), findsOneWidget);

      await tester.tap(find.text('保存した検索'));
      await tester.pumpAndSettle();
      expect(find.text('猫 イラスト'), findsOneWidget);
      expect(find.text('猫 小説'), findsOneWidget);

      // 新し方（猫 小説）が先頭表示 → 先頭の削除ボタンをタップ
      await tester.tap(find.byTooltip('削除').first);
      await tester.pumpAndSettle();
      expect(find.text('猫 小説'), findsNothing);
      expect(find.text('猫 イラスト'), findsOneWidget);

      expect((await service.load()).length, 1);
    });

    testWidgets('プリセットの名前を変更できる', (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final service = SearchPresetService();
      await service.save(
        name: '旧名',
        category: 'illust',
        keyword: '犬',
        filterJson: const {},
      );

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存した検索'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('名前を変更'));
      await tester.pumpAndSettle();
      // 行名 + ダイアログの TextField に入力値が 2 箇所表示される
      expect(find.text('旧名'), findsWidgets);
      await tester.enterText(find.byType(TextField), '新名');
      await tester.tap(find.text('変更する'));
      await tester.pumpAndSettle();

      expect(find.text('新名'), findsOneWidget);
      final list = await service.load();
      expect(list.length, 1);
      expect(list.first.name, '新名');
    });
  });
}
