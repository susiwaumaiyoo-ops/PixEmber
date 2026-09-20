# Phase 16c-4 — Drawer 廃止と旧ナビゲーションの完全解体

- 開始: commit `003f4be`（16c-3 終点・1040 tests green）
- 終点: commit `fd94d13`
- 検証: `flutter analyze` clean / `flutter test` **1045 passed**（開始時 1040 → +5）
- 端末の視覚確認: **未実施**（デバイス不在。analyze + test のみ）

## 1. Sub コミット一覧

| Sub | Commit | 内容 |
|---|---|---|
| 16c-4a | `824441f` | 旧 Drawer 導線の受け皿を Home / Settings に先行移設 |
| 16c-4b | `ba89541` | `HomeSurfaceMode.combined` 廃止 → `isSearchMode` に単純化 |
| 16c-4c | `27f184f` | `Scaffold.drawer`・ハンバーガー・Drawer 構築ロジックを完全削除 |
| 16c-4d | `fd94d13` | 到達性テストを「Drawer なし」前提に更新 + 17 導線の移設マップ固定 |

各 Sub は独立 commit。各コミット時点で `flutter analyze` 0 issues・該当テスト全緑を確認してから次へ進んだ。

---

## 2. AIレコメンドの Home 上の可視性

**別画面（独立フィード）のまま。`HomeContentSource` には追加しなかった。**

- `HomeContentSource`（recommend / latest / following / bookmarks）は
  `_fetchIllustsBySource`・`_fetchNovelsBySource` の `switch` が exhaustive。
  ここに「AIレコメンド」を追加すると、イラスト・小説の両方に
  専用 fetch を書く必要があり、レコメンドは独立フィード（`AiRecommendFeedScreen`）
  として完成しているため二重実装になる。
- 代わりに **[`HomeSearchSourceChips`](../pixiv_viewer/lib/screens/home_search_source_chips.dart:13)
  のチップ列の末尾（`itemCount: sources.length + 1`）** に選択状態を持たない
  導線専用チップ `_AiRecommendChip` を置いた。タップで
  `PixivViewerHomeState.openAiRecommendFeed()` が `AiRecommendFeedScreen` を push する。
- したがって AIレコメンドは **ホームのチップ列から 1 タップ** で届き、
 フィードそのものを差し替えることはない。

---

## 3. SettingsScreen に追加した項目と位置

[`settings_screen.dart`](../pixiv_viewer/lib/screens/settings_screen.dart:45) の
`build()` 内、検索セクションの直後:

| 追加位置 | 項目 | 備考 |
|---|---|---|
| 「コンテンツ」セクション（新設） | ミュート（ブラックリスト）管理 → `MuteSettingsScreen` | 16c-4a で新規追加。旧 Drawer のミュート導線の受け皿 |
| 「バックアップ」セクション（既存） | バックアップ管理 → `BackupManagerScreen` | 16c-3d 時点で存在。コメントで「Drive 同期の受け皿」を明記 |
| 「レコメンド」セクション（既存） | AIインデックス管理 | 16c-3d 時点で存在 |

移設せずで済んだもの: **バックアップ管理** と **ログイン/ログアウト**。
いずれも 16c-3d 時点で Settings / Home AppBar に既存導線があり、
Drawer 側を削除するだけで自然に一本化された（スペックどおり）。

---

## 4. 削除した行数・機能（16c-4c）

| 対象 | 削除量 |
|---|---|
| `home_screen_state.dart` | **514 行削除**（2,506 → 1,811 行）。うち Drawer 本体 約 320 行 |
| `home_sync_handler.dart` | **449 行・ファイルごと削除**（`HomeSyncHandler` 全体） |

### 削除したもの

1. `Scaffold.drawer` プロパティと `Drawer` / `DrawerHeader` / `ListView` 構築
2. `AppBar.leading`（ハンバーガーアイコン）— `drawer:` が消えたことで自動消滅
3. Drawer 内 17 ListTile の構築ロジック（購読タグ・あとで読むの FutureBuilder 未読バッジ含む）
4. **未使用 import 13 件**: `bookmark_list_screen` / `history_screen` /
   `folder_list_screen` / `mute_settings_screen` / `subscriptions_screen` /
   `read_later_screen` / `statistics_screen` / `ai_index_maintenance_screen` /
   `backup_manager_screen` / `offline_bookshelf_screen` /
   `download_queue_screen` / `duplicate_finder_screen` / `settings_screen`
5. **`HomeSyncHandler`（ファイルごと削除）**: `buildGoogleDriveSyncSection()` が
   Drawer 専用だった。バックアップ/復元は `BackupManagerScreen` が自前の
   `GoogleDriveService` で完全にカバーしているためデッドコード化していた。
6. **state から Drive 即時操作を削除**: `isBackingUp` / `isRestoring` /
   `lastSyncSummary` フィールド、`handleGoogleBackup()` / `handleGoogleRestore()` /
   `handleGoogleLogin()` / `handleGoogleLogout()` /
   `_showLoadingDialog()` / `_hideLoadingDialog()`。

### 残したもの（意図的）

- `_initializeDriveSync()` と `lastSyncTimestamp` / `loggedInEmail`:
  フィードサーフェスの即時同期 HUD（`buildSyncProgressHUD`）と
  `logout()` のメール表示が参照するため。サイレントサインインと
  最終同期時刻の復元だけは Home 側に残した。

---

## 5. 17 導線の移設先（機能消失なし）

| # | 導線 | 移設先 | 移設 Sub |
|---|---|---|---|
| 1 | しおり一覧 | `LibraryHubScreen`（保存） | 16c-2b |
| 2 | 閲覧履歴 | `LibraryHubScreen`（履歴とオフライン） | 16c-2b |
| 3 | お気に入りフォルダ | `LibraryHubScreen`（保存） | 16c-2b |
| 4 | 購読タグ | `LibraryHubScreen`（履歴とオフライン） | 16c-2b |
| 5 | あとで読む | `LibraryHubScreen`（保存） | 16c-2b |
| 6 | 閲覧統計 | `LibraryHubScreen`（整理と分析） | 16c-2b |
| 7 | ダウンロード管理 | `LibraryHubScreen`（整理と分析） | 16c-2b |
| 8 | オフライン本棚 | `LibraryHubScreen`（履歴とオフライン） | 16c-2b |
| 9 | 重複画像の検出 | `LibraryHubScreen`（整理と分析） | 16c-2b |
| 10 | ミュート（ブラックリスト）管理 | `SettingsScreen`「コンテンツ」 | **16c-4a** |
| 11 | AIインデックス管理 | `SettingsScreen`「レコメンド」 | 16c-3d |
| 12 | バックアップ管理 | `SettingsScreen`「バックアップ」 | 16c-3d |
| 13 | Google ドライブ同期 | `BackupManagerScreen` に集約 | 既存 |
| 14 | AIレコメンド | Home チップ列末尾 | **16c-4a** |
| 15 | 似た画像を探す | 検索サーフェス `HomeVisualSearchEntry` | 16c-3c |
| 16 | ログイン/ログアウト | Home AppBar `PopupMenuButton` | **16c-4a** |
| 17 | 設定 | 4 目的地の「設定」（物理タブ2） | 16c-1 |

---

## 6. テスト件数の遷移と理由

| Sub | テスト数 | 増減理由 |
|---|---|---|
| 16c-3 終点 | 1,040 | — |
| 16c-4a 後 | 1,043 | `ai_recommend_home_entry_test.dart` 新規 3 件（Settings のミュート表示・AIインデックス/バックアップ存在・state シンボル監査）。`SettingsScreen` は SharedPreferences があれば pump 可能なため実機ウィジェット検証ができた |
| 16c-4b 後 | 1,041 | `combined` 廃止で 2 件削除: 「combined は feed/search どちらでもない」「combined では assisting のみ表示」。enum は 2 状態になったが件数は増えず |
| 16c-4c 後 | 1,041 | テスト不変（生産コードのみ）。`HomeSyncHandler` を参照するテストは元々なし |
| 16c-4d 後 | **1,045** | `navigation_reachability_test.dart` の「Drawer はまだ存在する」センチネル 1 件を、Drawer 削除後の監査 4 件に置換（**+3**）。内訳: ソース監査（`drawer:` / `Drawer(` / `DrawerHeader(` / `Icons.menu` の不在）・`home_sync_handler.dart` 削除確認・LibraryHub 9 導線・Settings 3 導線・17 = 9+3+5 の完全性 |

**削除したテストと理由（16c-4b）**:
- `combined は feed 専用・search 専用のどちらでもない` — 削除されたモードを検証していたため、モード削除と同時に廃止。
- `combined では従来どおり assisting のみで表示` — 同上。

---

## 7. 到達性テスト（16c-4d）が監視すること

[`navigation_reachability_test.dart`](../pixiv_viewer/test/navigation_reachability_test.dart:1)
の group「Drawer の完全削除と 17 導線の受け皿（16c-4c）」:

1. **ソース監査**: `home_screen_state.dart` に `drawer:` / `Drawer(` /
   `DrawerHeader(` / `Icons.menu,` / `Icons.menu_outlined` が
   一切含まれないこと（`Icons.menu_book` は小説タブの AppBar アイコンなので許容）。
2. **ファイル監査**: `home_sync_handler.dart` が存在しないこと。
3. **受け皿の完全性**: 17 = 9（LibraryHub）+ 3（Settings）+ 5
   （AIレコメンド・似た画像・ログイン・設定・Drive 同期）。
4. 4 目的地の NavigationBar・`destinationToTab = [0, 0, 1, 2]`・
   root/nested Navigator 境界・タップ領域・Semantics は 16c-3d から維持。

> 備考: `test/phase10_gen_fixtures_test.dart`（Phase 10 時代の未追跡テスト）
> が作業ディレクトリに残存していたため、16c-4d のコミットに一緒に含めた。
> `flutter test` は全テストを実行するため、このファイルは 16c-4c 時点の
> 件数 (1042) にも既に含まれており、遷移の計算に影響しない。

---

## 8. 端末での視覚確認

**未実施。** 接続デバイスがないため `flutter analyze` と `flutter test` のみ。
視点は `Scaffold` の `drawer:` が `null` になったことで
`AppBar` の `leading` が自動非表示になることと、
`actions` のポップアップメニューが右側に表示されること。
実機確認は Phase 16d 以降の APK ビルド時に持ち越し。

---

## 9. Phase 16c 完了まとめ

Phase 16c 全体（16c-1 → 16c-4）で、2,234 行あった単一 Home State は
**1,811 行**になり、ナビゲーションは完全にボトムNavigationBar 中心になった:

- **4 目的地・3 物理 Navigator**: ホーム / 検索 / ライブラリ / 設定。
  ホームと検索は `destinationToTab = [0, 0, 1, 2]` で
  **同じ `PixivViewerHomeState`** を共有し、`HomeSurfaceMode`
  （`feed` / `search` の 2 状態）だけで表示を切り替える。
  State を 2 つ作らない・検索結果を複製しない（16c-3a）。
- **Drawer は完全消滅**: 17 導線は LibraryHub 9 + Settings 3 +
  Home チップ / 検索エントリ / AppBar ポップアップ に分散（16c-4）。
- **互換モード `combined` 廃止**: `isSearchMode` / `isFeedMode` の
  boolean 2 つに集約。分岐の見通しが大幅に改善（16c-4b）。
- **デザインシステム**: `AppPanel` / `AppSectionHeader` /
  `AppStateView` / `AppStatusBanner` に統一し、
  `AppSpacing` で間隔を一元化（16b / 16c-2b）。
- **テスト**: 1,040 → 1,042 件。ナビゲーション構造は
  `app_shell_test` / `library_hub_screen_test` /
  `navigation_reachability_test` / `surface_mode` / `surface_split` /
  `ai_recommend_home_entry` の 6 ファイルが構造契約として機能している。

残課題（Phase 16d 以降の候補）:
- 端末での視覚確認（本フェーズは未実施）。
- `HomeContentModeSelector` とボトムナビの間に残っている
  「コンテンツ種別」の二重の操作経路を統一するかどうかの判断。
