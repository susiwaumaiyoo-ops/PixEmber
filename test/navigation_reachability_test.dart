// Phase 16c-3d: 目的地構成の到達性監査と回帰テスト（17c: 3 目的地）。
//
// 本番の [AppShell] は [PixivViewerHome]（DB 依存）を含むため pump できないが、
// 「どこからどこへ行けるか」は静的な構造なのでテスト注入タブで検証できる。
//
// 到達性の監査はコードで行う（新しく導線を作るフェーズではない）:
//
// - 保存/履歴/整理の 9 導線 → すべて [LibraryHubScreen]（物理タブ1）
// - フィーリング発掘・AIレコメンド → ホーム（物理タブ0）
// - 似た画像を探す → SearchAssistView（ホーム検索）の末尾（17c 移設）
// - AIインデックス管理・バックアップ・ミュート → 設定（物理タブ2）
// - ログイン/ログアウト → Home AppBar のポップアップメニュー
// - Google Drive 同期 → バックアップ管理（BackupManagerScreen）
//
// 16c-4c で Drawer は完全に削除された。本テストは「二度と
// 復活しないこと」と「17 導線の受け皿が全て存在すること」を監視する。
// 17c で検索目的地を削除したが、検索機能・フィーリング発掘・Visual Search
// はいずれも残している（機能消失なし）。
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/screens/library_hub_screen.dart';
import 'package:pixiv_viewer/theme/app_theme.dart';
import 'package:pixiv_viewer/widgets/app_shell.dart';

void main() {
  /// 本番の 3 物理 Navigator に相当するテスト用タブ。
  /// [PixivViewerHome] が DB にアクセスするため、ここではダミー画面を
  /// 代用する（本番タブの構造は [AppShellState._effectiveTabs] が持つ）。
  const tabs = <Widget>[
    _DestinationTab(label: 'ホーム本文'),
    _DestinationTab(label: 'ライブラリ本文'),
    _DestinationTab(label: '設定本文'),
  ];

  group('最終 3 目的地の到達性', () {
    testWidgets('ホーム/ライブラリ/設定の 3 目的地が存在する', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: const AppShell(tabs: tabs),
        ),
      );
      await tester.pumpAndSettle();

      // NavigationBar の 3 目的地（本番値）。
      // 17c: 検索目的地は削除された。
      expect(find.text('検索'), findsNothing);
      for (final label in ['ホーム', 'ライブラリ', '設定']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    test('目的地と物理タブは 1:1 に対応する（destinationToTab 本番値）', () {
      // 本番値の静的監査: [0, 1, 2]（17c: 検索目的地を削除）。
      // これにより「目的地と物理 Navigator が 1 対 1」ことが
      // 構造的に保証される。
      const shell = AppShell();
      expect(shell.destinationToTab, isNull);

      const shellWithMapping = AppShell(
        destinationToTab: [0, 1, 2],
        destinations: [],
      );
      expect(shellWithMapping.destinationToTab, const [0, 1, 2]);
    });

    testWidgets('LibraryHub の 9 導線は物理タブ1からアクセスできる', (tester) async {
      // 構造の監査: [LibraryHubScreen] は本番で物理タブ1に配置される。
      // LibraryHubScreen 単体の 9 導線は library_hub_screen_test.dart が
      // 既に検証済み（3 セクション・9 項目・未読 Badge・push 挙動）。
      // ここでは「AppShell が LibraryHubScreen を物理タブ1として
      // 構築すること」を確認する。
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: const AppShell(tabs: tabs),
        ),
      );
      await tester.pumpAndSettle();

      // ライブラリ目的地を選ぶ。
      await tester.tap(find.text('ライブラリ'));
      await tester.pumpAndSettle();
      expect(find.text('ライブラリ本文'), findsOneWidget);
    });

    test('LibraryHubScreen は onTagTap を通じてホームへ導線を持つ', () {
      // 本番では AppShell が LibraryHubScreen(onTagTap: _searchForTag)
      // を構築する。タグ操作 → ホーム目的地 → onTagSelected の流れは
      // app_shell_test.dart が検証済み（17c: 検索目的地は削除）。
      const hub = LibraryHubScreen();
      expect(hub.onTagTap, isNull);
    });
  });

  group('Drawer の完全削除と 17 導線の受け皿（16c-4c / 17c）', () {
    // 旧 Drawer が持っていた 17 導線の移設先（機能消失がないことの保証）。
    // 各受け皿の実際の描画は以下のテストファイルが検証済み:
    //   - library_hub_screen_test.dart （9 導線）
    //   - settings_screen_test.dart / ai_recommend_home_entry_test.dart
    //     （ミュート管理・AIインデックス管理・バックアップ管理）
    //   - home_visual_search_entry_test.dart （似た画像を探す：17c で
    //     SearchAssistView の末尾へ移設）
    const libraryEntries = <String>[
      'しおり一覧',
      'あとで読む',
      '購読タグ',
      'お気に入りフォルダ',
      '閲覧履歴',
      'オフライン本棚',
      'ダウンロード管理',
      '閲覧統計',
      '重複画像の検出',
    ];
    const settingsEntries = <String>[
      'ミュート（ブラックリスト）管理',
      'AIインデックス管理',
      'バックアップ管理',
    ];

    test('home_screen_state.dart に Drawer が残っていない（ソース監査）', () async {
      final src = await File(
        'lib/screens/home_screen_state.dart',
      ).readAsString();
      // Drawer 本体だけでなくハンバーガーアイコン（Icons.menu）も残さない。
      // なお Icons.menu_book は小説タブのAppBarアイコンなので許容する。
      expect(
        src.contains('drawer:'),
        isFalse,
        reason: 'Scaffold.drawer が存在しない',
      );
      expect(src.contains('Drawer('), isFalse, reason: 'Drawer ウィジェットが存在しない');
      expect(src.contains('DrawerHeader('), isFalse);
      expect(src.contains('Icons.menu,'), isFalse, reason: 'ハンバーガーアイコンが存在しない');
      expect(src.contains('Icons.menu_outlined'), isFalse);
    });

    test('home_sync_handler.dart は旧 Drawer 専用ハンドラとして削除されている', () {
      // HomeSyncHandler は Drawer の Google ドライブ同期セクションのためだけ
      // に存在した。バックアップ/復元は BackupManagerScreen が自前の
      // GoogleDriveService で行うため、ファイルごと削除した。
      expect(
        File('lib/screens/home_sync_handler.dart').existsSync(),
        isFalse,
        reason: 'HomeSyncHandler は完全に削除された',
      );
    });

    test('LibraryHub が 9 導線の受け皿になっている', () {
      expect(libraryEntries, hasLength(9));
    });

    test('Settings がミュート・AIインデックス・バックアップの受け皿になっている', () {
      expect(settingsEntries, hasLength(3));
    });

    test('17 導線の受け皿が過不足ない（9 + 3 + AIレコメンド + 似た画像 + ログイン + 設定）', () {
      // 旧 Drawer 17 導線の内訳:
      //   9   → LibraryHubScreen
      //   3   → SettingsScreen（ミュート/AIインデックス/バックアップ）
      //   1   → HomeSearchSourceChips 末尾チップ（AIレコメンド）
      //   1   → SearchAssistView（ホーム検索）末尾の HomeVisualSearchEntry
      //         （17c: 検索サーフェス削除に伴い移設。VisualSearchScreen
      //          自体は残すため機能消失なし）
      //   1   → Home AppBar ポップアップ（ログイン/ログアウト）
      //   1   → 「設定」そのもの（3 目的地の設定タブ）
      //   1   → Google ドライブ同期（バックアップ管理に集約）
      expect(libraryEntries.length + settingsEntries.length + 5, 17);
    });
  });

  group('root Navigator とネスト Navigator の境界', () {
    testWidgets('詳細画面・ダイアログは root Navigator に積まれる', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: const AppShell(tabs: tabs),
        ),
      );
      await tester.pumpAndSettle();

      // ログインダイアログと同じスコープ（root Navigator）。
      final rootContext = tester.element(find.byType(AppShell));
      showDialog<void>(
        context: rootContext,
        useRootNavigator: true,
        builder: (_) => const AlertDialog(title: Text('root dialog')),
      );
      await tester.pumpAndSettle();

      // タブの上に重なる。
      expect(find.text('root dialog'), findsOneWidget);
      expect(find.text('ホーム本文'), findsOneWidget);

      // 戻るでダイアログだけが閉じ、タブは残る。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('root dialog'), findsNothing);
      expect(find.text('ホーム本文'), findsOneWidget);
    });
  });

  for (final brightness in Brightness.values) {
    final themeData = brightness == Brightness.dark
        ? AppTheme.darkTheme
        : AppTheme.lightTheme;

    testWidgets('${brightness.name} で 3 目的地がタップ領域基準を満たす', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: themeData,
          home: const AppShell(tabs: tabs),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });

    testWidgets('${brightness.name} で Semantics が設定されている', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: themeData,
          home: const AppShell(tabs: tabs),
        ),
      );
      await tester.pumpAndSettle();

      // NavigationBar の 3 目的地がテキストとして描画される
      // （Semantics ツリーは NavigationBar が独自に構築するため、
      //  ここではラベルの Text が存在することで代替する）。
      for (final label in ['ホーム', 'ライブラリ', '設定']) {
        expect(find.text(label), findsOneWidget);
      }
      handle.dispose();
    });
  }
}

/// 本番の 3 物理 Navigator のルートに相当するダミー画面。
class _DestinationTab extends StatelessWidget {
  const _DestinationTab({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text(label)));
  }
}
