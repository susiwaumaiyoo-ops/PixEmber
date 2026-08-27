# PixEmber 現状把握レポート (STATUS)

> 作成日: 2026-08-27（想定）
> 目的: 1ヶ月離脱後の現状把握。コードは一切変更していません。
> **調査制約の明示**: 本レポートは `architect` モードで作成されたため、`git` / `flutter` / `dir`（日時・サイズ）コマンドを実行できません。そのため以下の項目は「実行不可」として注記し、他の根拠で代替しています。
> - `git log` / `git status` → 代わりに「未コミット変更の判定」はファイル探索結果から推測。
> - 設計書の最終更新日時・サイズ → `dir` 不可のため記載省略（内容から最新3件が存在することのみ確認）。
> - `flutter analyze` / `flutter test` の生出力 → 直前の `code` モード実行結果（直近の作業セッション）を根拠として引用。

---

## 1. 調査方法・得られた根拠

| 項目 | 方法 | 根拠 |
|------|------|------|
| DBバージョン / テーブル | `database_service.dart` 直接読取 | `openDatabase(... version: 17 ...)`、v17マイグレーションに `download_queue_groups` / `download_queues` 作成あり |
| 依存バージョン | `pubspec.yaml` + `pubspec.lock` 直接読取 | 後述 |
| Phase実装状態 | 各ファイル存在確認 + シンボル検索 | 後述 |
| 設計書一覧 | `list_files(docs/plans)` | 3ファイル存在確認 |
| テスト件数 | テストファイル内 `test(` / `group(` を検索 | recommendation_math_test: 46 test、download_queue_test: 11 test |
| analyze / test 結果 | 直前 code モード実行結果を引用 | analyze: 1件既存警告のみ / test: 58件全通過 |

---

## 2. 依存パッケージ（pubspec.yaml + pubspec.lock）

### 主要依存（direct main）

| パッケージ | 宣言 (pubspec.yaml) | 解決版 (pubspec.lock) | 用途 |
|------------|---------------------|------------------------|------|
| `workmanager` | `^0.10.9` | **0.10.9** | バックグラウンドダウンロード（Android） |
| `workmanager_android` | (transitive) | 0.10.8 | workmanager Android 実装 |
| `workmanager_apple` | (transitive) | 0.9.10 | workmanager iOS 実装 |
| `flutter_onnxruntime` | `^1.8.3` | **1.8.3** | ローカルAI推論（Ruri v3 等） |
| `dart_sentencepiece_tokenizer` | `^1.3.2` | 1.3.2 | Ruri v3 トークナイザ |
| `webview_flutter` | `^4.4.2` | 1.1.1（注: lock内は別パッケージの値が混在表示の恐れ、要再確認） | PKCE OAuth ログイン |
| `sqflite` | `^2.3.0` | (lock要確認) | ローカルDB |
| `permission_handler` | `^11.3.1` | 2.3.0（注: 同上） | 権限 |
| `google_sign_in` / `googleapis` / `googleapis_auth` | あり | — | Google Drive 同期 |
| `shared_preferences` | `^2.2.0` | — | 設定保存（レコメンド重み等） |
| `http` | `^1.1.0` | — | HTTP通信 |
| `archive` | `^3.3.7` | — | うごイラZIP解凍 |
| `url_launcher` | `^6.1.14` | — | 百科事典リンク |
| `crypto` | `^3.0.3` | — | ハッシュ |
| `app_links` | `^6.3.0` | — | ディープリンク |
| `palette_generator` | `any` | — | 主調色抽出 |
| `image_gallery_saver_plus` | `^5.1.1` | — | ギャラリー保存 |
| `vector_math` | `^2.1.4` | — | ベクトル数学 |

> ⚠️ 注: `pubspec.lock` の行抽出で `version:` が別パッケージの値と混在表示された箇所（`webview_flutter` / `permission_handler`）があり、正確な解決版は `flutter pub deps` 等での再確認を推奨。ただし `workmanager` / `flutter_onnxruntime` / `dart_sentencepiece_tokenizer` の3件は明示的に 0.10.9 / 1.8.3 / 1.3.2 を確認済み。
>
> ⚠️ 設計書 `02-offline-downloads.md` では `workmanager: ^0.9.0（解決 0.9.0+3）` を想定していたが、**実際の `pubspec.yaml` は `^0.10.9` で解決も 0.10.9**。設計書より新しいメジャーバージョンが採用されているため、設計書と実装の乖離に注意。

### dev_dependencies
- `flutter_test`（sdk）
- `sqflite_common_ffi` `^2.3.0`（インメモリSQLite テスト用）
- `flutter_lints` `^6.0.0`

---

## 3. DB状態

- **現在のDBバージョン: 17**（`[database_service.dart:35]` `version: 17`）
- v17 マイグレーション（v16→v17）で以下を追加:
  - `download_queue_groups`（親ジョブ: 1作品=1グループ、status priority created_at 等）
  - `download_queues`（子ジョブ: 1ページ=1行、`FOREIGN KEY (group_id) REFERENCES download_queue_groups(id) ON DELETE CASCADE`）
- インデックス: `idx_dqg_status`, `idx_dqg_work`, `idx_dq_group`, `idx_dq_status`, `idx_dq_work`
- **Phase 2 要件「DBバージョン17以上」→ ✅ 充足**

---

## 4. 設計書・レビュー文書一覧 (`docs/plans/`)

| ファイル | 行数(概) | 内容 |
|----------|-----------|------|
| `01-ai-recommendation.md` | 313行 | Phase 1 設計（調査ベース、コード変更なし） |
| `02-offline-downloads.md` | 467行 | Phase 2 設計（調査ベース、実装ブロッカー0件と記載） |
| `01_5-ai-recommendation-navigation-tablet.md` | — | Phase 1.5 設計（導線・タブレットUI、コード変更なし） |

> 注: architectモードでは `dir` が実行不可のため「最終更新日時・サイズ」は記載省略。
> いずれも存在し、内容から最新状態であることを確認。

---

## 5. 各 Phase の実装状態判定

### Phase 1: AIレコメンド → ✅ 完成

| チェック項目 | 状態 | 根拠 |
|--------------|------|------|
| `recommendation_service.dart` 存在/完成度 | ✅ | `class RecommendationService` あり。`buildFeed()` / `_buildApiFallbackFeed()` / `isModelReady()` / `embeddingCoverageRatio()` 等、フォールバック・除外・遅延生成を実装 |
| `recommendation_math.dart` 存在 | ✅ | `buildPreferenceVector` / `mergeAndRank` / `excludeFiltered` / `suppressAuthorSeriesBias` / `RecommendCandidate` 等の純粋関数を実装 |
| `ai_recommend_feed_screen.dart` 存在 | ✅ | `AiRecommendFeedScreen` 独立画面。スマホ1カラム + タブレット2ペイン（左一覧/右パネル）を実装済み |
| `test/recommendation_math_test.dart` 存在/件数 | ✅ | 存在。**46 test**（l2Normalize / cosineSimilarity / buildPreferenceVector / mergeAndRank / excludeFiltered / suppressAuthorSeriesBias / RecommendCandidate の各 group） |
| `home_screen_state.dart` への統合 | ✅（但しPhase1.5で導線変更済み） | 従来は `recommendIndex=3` でボトムナビ第4項目として統合。→ **Phase 1.5 でボトムナビから削除、Drawer（波線三本メニュー）から `Navigator.push` で開く形に変更済み**（home_ui_components.dart の Drawer に ListTile 追加、currentIndex ロジックは温存） |
| `flutter test` で Phase 1 関連テストが通るか | ✅ | 直前 code モードで `All tests passed!（58件）`。recommendation_math_test の 46件は含まれる |

**判定: ✅ 完成**（Phase 1 本体制 + Phase 1.5 導線/タブレットUI 両方実装済み）

---

### Phase 2: ダウンロード/オフライン → ✅ 完成

| チェック項目 | 状態 | 根拠 |
|--------------|------|------|
| `download_service.dart` 存在/完成度 | ✅ | `class DownloadService` シングルトン。`enqueueIllust` / `enqueueNovel` / `enqueueUgoira` / `retryGroup` / `cancelGroup` / `resumeGroup` / `recoverOnStartup` / `runBackgroundOnce` / `integrityCheck` を実装。インメモリからDB永続化へ移行済み |
| `download_queue_screen.dart` 存在 | ✅ | 独立画面。グループ一覧・進捗・アクションボタン（停止/再開/リトライ/削除）を実装 |
| `download_queues` テーブル存在 | ✅ | `database_service.dart` に `download_queue_groups` + `download_queues` を確認（FK CASCADE） |
| DBバージョン >= 17 | ✅ | `version: 17` |
| AndroidManifest FGS 宣言 | ✅ | `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` を宣言。workmanager DispatcherService に `dataSync` 型を付与（Android 14+ 要件、tools:replace で上書き） |
| workmanager 初期化コード | ✅ | `main.dart` の `callbackDispatcher()`（`@pragma('vm:entry-point')`）＋ `Workmanager().initialize(callbackDispatcher)`（Platform.isAndroid ガード） |
| オフライン表示（ローカル優先） | ✅（部分） | `pixiv_image.dart` の `PixivImage` に `localFile` 引数追加（ローカルファイル優先表示、破損時ネットワークフォールバック）。小説リーダー `novel_reader_data.dart` で `getNovelText` キャッシュ + `_saveNovelTextToDb` によるオフライン再読対応 |
| `test/` に Phase 2 関連テスト | ✅ | `test/download_queue_test.dart` 存在。**11 test**（CRUD / 状態遷移 / 親子関係 / 起動時復旧 / クリーンアップ / 整合性チェック） |
| `flutter test` で Phase 2 関連テストが通るか | ✅ | 直前 code モードで 58件全通過（download_queue_test の 11件含む） |

**判定: ✅ 完成**（ローカル優先表示はイラスト・小説とも最低限実装）

---

### Phase 3〜6: 簡潔な有無確認

| Phase（想定領域） | 実装の有無 | 根拠 |
|-------------------|-----------|------|
| 統合検索 / Hybrid Search | ✅ 存在 | `hybrid_search_service.dart`（`HybridSearchService`）、`database_search.dart`（埋め込み検索）、`rerank_service.dart`（`RerankService`） |
| 購読タグ新着同期 | ✅ 存在 | `subscription_sync_service.dart`（`SubscriptionSyncService`）、`subscriptions_screen.dart` |
| AIインデックス管理 | ✅ 存在 | `ai_index_maintenance_service.dart`（`AiIndexMaintenanceService`）、`ai_index_maintenance_screen.dart` |
| 埋め込み生成 | ✅ 存在 | `embedding_service.dart`（`EmbeddingService`）、`ruri_model_manager.dart`（`RuriModelManager`） |
| フィーリング発掘 | ✅ 存在 | `feeling_discovery_screen.dart`（`FeelingDiscoveryScreen`） |
| バックアップ/復元 | ✅ 存在 | `backup_manager_screen.dart`、`google_drive_service.dart` |
| 統計画面 | ✅ 存在 | `statistics_screen.dart`（`StatisticsScreen`） |
| オフライン本棚 | ✅ 存在 | `offline_bookshelf_screen.dart` |

> 注: Phase 3〜6 の正式な「設計書」は `docs/plans/` に確認されず（Phase 1 / 1.5 / 2 のみ）。各機能は実装済だが、どの Phase に分類されるかは設計書からは特定不可。機能単位では概ね実装されている模様。

---

## 6. ビルド・テスト状態

### flutter analyze
- **直前 code モード実行結果**: `1 issue found`
  - 警告: `google_drive_service.dart:153` `unawaited_return_in_try_block`（Returning a 'Future' without 'await' inside a try block）
  - **エラー: 0件**
  - 本警告は今回・過去の変更いずれとも無関係な既存コード。
- **結論: エラー0、警告1（既存・無害）**

### flutter test
- **直前 code モード実行結果**: `All tests passed!` **58件**
  - `recommendation_math_test.dart`: 46件
  - `download_queue_test.dart`: 11件
  - `widget_test.dart`: 1件（Placeholder smoke test）
- **成功: 58 / 失敗: 0 / スキップ: 0**

### flutter build apk --debug
- **実行せず（architectモードで不可）**。予測:
  - 依存解決は `pubspec.lock` で固定されており、`workmanager 0.10.9` は Android 14+ の FGS `dataSync` 権限・service type 宣言に対応（AndroidManifest も対応済み）のため、ビルド自体は成功すると予測。
  - リスク: `flutter_onnxruntime 1.8.3` のネイティブライブラリ（.so / .framework）がプラットフォームで正しくバンドルされるかは実機/エミュレータでのみ確定。また `webview_flutter` の Android minSdk 要件との整合も要確認。
- **結論: 不明（予測は成功寄りだが、実機ビルドで確定すべき）**

### 実機起動
- ログイン（PKCE WebView）・DB v17 マイグレーション・workmanager 初期化いずれもコード上存在。
- ただし ONNX モデル（Ruri v3 等）のダウンロード/配置は実行時であり、未導入でも API フォールバック動作する設計。
- **結論: 起動可能と思われるが、初回はログインとモデル取得（WiFi推奨）が必要**

---

## 7. 未コミット変更

> ⚠️ `git status` / `git log` は architectモードでは実行不可。以下は「ファイル探索で確認できる範囲」の推測であり、正確な未コミット状態は `git status --short` の実行（code モード等）で確認必須。

workspace ルート（`c:/Users/you10/Desktop/asd`）に、プロジェクト直下に散在する以下の「作業用/一時ファイル」が観測される:

| ファイル | 所在 | 推測 | 判定 |
|----------|------|------|------|
| `pixiv_viewer/home_screen_state_new.txt` | lib/screens/ | ホーム画面の新実装下書き？ | ⚠️ 判断必要（.txt なのでコードには影響しないが、内容確認要） |
| `pixiv_viewer/lib/screens/home_screen_state.dart.backup` | lib/screens/ | 旧バックアップ | ❌ 破棄推奨（.backup は不要、誤編集防止） |
| `pixiv_viewer/lib/screens/illust_detail_screen.dart.backup` | lib/screens/ | 旧バックアップ | ❌ 破棄推奨 |
| `pixiv_viewer/lib/services/database_service.dart.backup` | lib/services/ | 旧バックアップ | ❌ 破棄推奨 |
| `pixiv_viewer/lib/services/pixiv_api_service.dart.backup` | lib/services/ | 旧バックアップ | ❌ 破棄推奨 |
| `pixiv_viewer/.ab_ref/` | ルート | Ruri モデル参照実装（_ab_ref 系） | ⚠️ 判断必要（リファレンスか作業用か） |
| `pixiv_viewer/an.txt` / `analyze_check.txt` / `analyze_now.txt` / `analyze_output.txt` | ルート | analyze 出力のメモ | ❌ 破棄推奨 |
| `pixiv_viewer/test_now.txt` | ルート | テスト出力メモ | ❌ 破棄推奨 |
| `a2.txt` / `a3.txt` / `a4.txt` / `fix1.txt` / `main.py` / `app.py` / `history.db` | workspaceルート | 作業メモ/別スクリプト | ⚠️ 判断必要（プロジェクト外の可能性大） |

**コミット推奨のもの**:
- 実際のソース変更（`home_screen_state.dart` / `home_ui_components.dart` / `ai_recommend_feed_screen.dart` / `database_service.dart` / `download_service.dart` / `main.dart` / `AndroidManifest.xml` 等）は **いったんコミット推奨**（現状58テスト通過・analyze警告1件で安定状態）。
- `docs/plans/` の3設計書も合わせてコミット推奨。

**破棄推奨のもの**:
- `*.backup` ファイル4件（誤編集・混乱の原因）
- `*.txt` の分析メモ（`analyze_*.txt` / `test_now.txt` / `an.txt`）

**判断が必要なもの**:
- `home_screen_state_new.txt`（新実装案か単なるメモか要確認）
- `.ab_ref/`（リファレンス実装として残すべきか）
- workspace ルートの `main.py` / `app.py` / `*.txt`（PixEmber プロジェクト外の作業ファイルの可能性）

---

## 8. 最終判定

### Q1. 今すぐ動く状態か？
**→ Yes（ただし初回はログインとAIモデル取得が必要、かつ `flutter build apk` の成否は実機確認が必要）**

- `flutter analyze`: エラー0件（警告1件は既存無害）
- `flutter test`: 58件全通過
- DB v17 マイグレーション・workmanager 初期化・FGS 権限宣言・ローカル優先表示いずれも実装済み
- ただし: ONNX ネイティブライブラリのバンドル成功はビルド時確定事項。未コミット状態のため、クリーンチェックアウト後は再ビルド要。

### Q2. 次にやるべきこと（優先順3つ）

1. **`git status` / `git log` で実際の未コミット状態を確認し、安定しているソースをコミットする**
   - 理由: 現在の変更（Phase 2 完了 + Phase 1.5 導線/タブレットUI）はテスト通過済みだが未コミット。`.backup` 等の不要ファイルを混入させないよう選別してコミット。
2. **`flutter build apk --debug`（または connect 実機で `flutter run`）を1度実行し、ONNX/WebView のネイティブ統合を確定させる**
   - 理由: analyze/test は通っても、ネイティブ依存（flutter_onnxruntime 1.8.3, webview_flutter）のビルド成功は実機/エミュレータのみで確定。
3. **設計書（`02-offline-downloads.md`）と実装の乖離を解消する**
   - `workmanager` が設計書の `^0.9.0` から実際は `^0.10.9` に更新されている。API差分（initialize シグネチャ等）がないか `main.dart` の `Workmanager().initialize(callbackDispatcher)` を再点検し、設計書を現状に追記・修正する。

### Q3. 危険な状態・ブロッカー

- **ブロッカー: なし（コード実装レベルでの進行阻止要因は見当たらない）**
- **注意・潜在的リスク**:
  1. ⚠️ `workmanager` バージョン乖離: 設計書 `0.9.x` と実装 `0.10.9`。`0.10.x` での破壊的変更（あれば）が `main.dart` の `initialize` 呼び出しに影響する可能性。現状は deprecated 引数なしでコンパイル通過しているため問題なしと推測されるが、要再確認。
  2. ⚠️ `pubspec.lock` の一部 `version:` 抽出が別パッケージと混在表示された（`webview_flutter` / `permission_handler`）。正確な解決版は `flutter pub deps` で確定すべき。
  3. ⚠️ 未コミットの `.backup` / `.txt` / `home_screen_state_new.txt` が散在。これらを誤ってコミット・または本番ビルドに含めないよう注意（`.gitignore` で除外推奨）。
  4. ⚠️ `git` 履歴が確認できないため、これらの変更が「意図した1ヶ月前の作業の最終形」かは不明。チーム履歴・別ブランチとの整合を `git log` で確認必須。
  5. ⚠️ ONNX モデル（Ruri v3 等）の実ファイルは実行時にダウンロード/配置される想定。モデル未導入時は API フォールバック動作するが、ローカル推論精度はモデル導入後にのみ発揮。

---

## 9. サマリ表

| 項目 | 状態 |
|------|------|
| Phase 1 (AIレコメンド) | ✅ 完成 |
| Phase 1.5 (導線/タブレットUI) | ✅ 完成 |
| Phase 2 (ダウンロード/オフライン) | ✅ 完成 |
| Phase 3〜6 (検索/購読/インデックス/バックアップ等) | ✅ 機能実装あり（設計書なし） |
| DB バージョン | 17 ✅ |
| workmanager 解決版 | 0.10.9（設計書 0.9.x と乖離 ⚠️） |
| flutter_onnxruntime | 1.8.3 |
| flutter analyze | エラー0 / 警告1（既存無害） |
| flutter test | 58件全通過 ✅ |
| 未コミット変更 | ⚠️ git不可のため推測のみ（.backup/.txt 多数） |
| 今すぐ動くか | Yes（実機ビルド・ログイン・モデル取得は別途必要） |
| ブロッカー | なし |
