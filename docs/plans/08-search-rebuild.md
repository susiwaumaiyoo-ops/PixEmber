# PixEmber 検索機能 全面リビルド計画書

## 1. 背景と目的

現在の検索機能は複数の API サービスファイル (`pixiv_api_service.dart`, `pixiv_api_individual.dart`, `pixiv_api_search.dart`, `pixiv_api_filter.dart`) に分散しており、以下の課題がある。

- 同一ロジックの重複実装と保守性の低下
- プレミアム機能の一部がローカル再現できていない
- 検索 UI が複数ファイルに分散し、フィルター状態管理が複雑
- ダウンロード完了済み 1 件表示の問題

本計画では、検索機能を単一の API サービスに統一し、UI/UX を刷新する。

---

## 2. 現状調査結果

### 2.1 API サービス調査 (`pixiv_api_service.dart`)

#### 実装済みエンドポイント

| メソッド | エンドポイント | 備考 |
|---------|--------------|------|
| `getAccessToken` | `/v1/identity/token` | 認証 |
| `getRefreshToken` | `/v1/identity/token` | 認証 |
| `getRecommend` | `/v1/illust/recommended` | イラストおすすめ |
| `searchIllust` | `/v1/search/illust` | イラスト検索 |
| `getIllustRelated` | `/v2/illust/related` | 関連イラスト |
| `getRanking` | `/v1/illust/ranking` | イラストランキング |
| `getNovelRecommend` | `/v1/novel/recommended` | 小説おすすめ |
| `searchNovel` | `/v1/search/novel` | 小説検索 |
| `searchNovelAllText` | `/v1/novel/text` + `/v1/search/illust` | 小説全文検索（並行） |
| `getNovelText` | `/v1/webview/v2/novel` | 小説本文 |
| `getNovelSeries` | `/v1/novel/series` | シリーズ詳細 |
| `getNovelSeriesAll` | `/v1/novel/series/all` | シリーズ全話 |
| `getIllustById` | `/v1/illust/detail` | イラスト詳細 |
| `getNovelById` | `/v2/novel/detail` | 小説詳細 |
| `getUserDetail` | `/v1/user/detail` | ユーザー詳細 |
| `getUserIllusts` | `/v1/user/illusts` | ユーザーイラスト一覧 |
| `getUserNovels` | `/v1/user/novels` | ユーザー小説一覧 |
| `getUgoiraMetadata` | `/v1/ugoira/metadata` | うごイラメタデータ |
| `toggleBookmark` | `/v2/illust/bookmark/add` 他 | ブックマーク切替 |
| `filterIllusts` | ローカル | ミュートフィルタ |
| `filterNovels` | ローカル | ミュートフィルタ |

#### 未実装だが利用可能なエンドポイント

| エンドポイント | 用途 | 優先度 |
|---------------|------|--------|
| `/v1/illust/new` | 新着イラスト | 高 |
| `/v2/illust/follow` | フォロー新着 | 高 |
| `/v1/novel/new` | 新着小説 | 高 |
| `/v1/novel/follow` | フォロー新着小説 | 高 |
| `/v1/trending-tags/illust` | トレンドタグ（イラスト） | 中 |
| `/v1/trending-tags/novel` | トレンドタグ（小説） | 中 |
| `/v1/user/bookmarks/illust` | ブックマーク一覧（イラスト） | 高 |
| `/v1/user/bookmarks/novel` | ブックマーク一覧（小説） | 高 |
| `/v1/user/following` | フォロー中ユーザー | 中 |
| `/v1/user/follower` | フォロワー | 中 |
| `/v1/user/mypixiv` | マイピク | 中 |
| `/v1/search/user` | ユーザー検索 | 低 |
| `/v1/manga/recommended` | 漫画おすすめ | 低 |
| `/v1/spotlight/articles` | 記事 | 低 |

#### 検索パラメータ カバレッジ

| パラメータ | イラスト検索 | 小説検索 | 備考 |
|-----------|------------|---------|------|
| `search_target` | partial/exact/title_and_caption | +text, keyword | `normalizeSearchTarget` で正規化済み |
| `sort` | date_desc/asc, popular_desc | 同上 | |
| `offset` | ○ | ○ | |
| `filter` | for_android | for_android | |
| `bookmarkFilter` | ○ (word suffix) | ○ (word suffix) | 例: `100users入り` |
| `xRestrict` | ○ (word suffix) | ○ (word suffix) | `r18` の場合 `R-18` を付与 |
| `workType` | ○ | - | |
| `start_text_length` | - | ○ | |
| `end_text_length` | - | ○ | |
| `duration` | ✗ | ✗ | 未実装 |
| `start_date` | ✗ | ✗ | 未実装 |
| `end_date` | ✗ | ✗ | 未実装 |
| `bookmark_num_min` | ✗ | ✗ | 未実装 |
| `bookmark_num_max` | ✗ | ✗ | 未実装 |

### 2.2 検索 UI/画面調査

#### `home_screen_state.dart` (1883 lines)
- メインの検索 State。`PixivViewerHomeState` がすべての検索ロジックを管理
- イラスト: `illustSubMode` (0=おすすめ, 1=検索, 2=ランキング)
- 小説: `novelSubMode` (0=おすすめ, 1=検索, 2=ランキング)
- 検索フィルター State: `selectedSearchTarget`, `selectedSort`, `selectedAgeLimit`, `selectedBookmarkFilter`, `selectedWorkType`, `selectedDuration`, `selectedIllustAiFilter`, `selectedNovelSearchTarget`, `selectedNovelAgeLimit`, `selectedNovelBookmarkFilter`, `selectedNovelTextLengthLimit`, `novelSeriesOnly`, `novelExcludeTags`, `novelDensityMode`
- `AllTextSearchState` でタグ+本文の並行検索を管理
- 検索履歴: SharedPreferences + DB の二重保存

#### `home_filter_handler.dart` (1043 lines)
- フィルター UI の分離。`HomeFilterHandler` がボトムシートを提供
- SharedPreferences への永続化
- イラスト/小説それぞれのフィルターを別々に保存

#### `home_ui_components.dart` (867 lines)
- グリッド/リスト表示、検索履歴オーバーレイ、フィルターセクションタイトル、ChoiceChip
- 空状態 (`_buildEmptyState`) とエラー表示

#### `feeling_discovery_screen.dart` (1694 lines)
- フィーリング発掘（AI 意味検索）の独立画面
- `HybridSearchService` によるハイブリッド検索
- `FeelingSearchQuery` 構造化クエリ
- モデル DL/初期化 UI、段階的レンダリング
- タブレット対応（700px ブレイクポイント）
- 検索候補オーバーレイ（DB 履歴 + 購読タグ）

#### `visual_search_screen.dart` (331 lines)
- ダウンロード済みイラストの視覚類似検索
- `ColorGridEncoder` + Isolate で特徴ベクトル生成
- `image_embeddings` DB テーブルへの保存

#### `duplicate_finder_screen.dart` (375 lines)
- 重複/近似画像検出
- 完全一致と近似のタブ切り替え

### 2.3 プレミアム機能 ローカル再現調査

| 機能 | 現状 | ローカル再現可能性 |
|-----|------|-----------------|
| Popular ソート | `popular_desc` で実装済み | ○ |
| 男性/女性人気 (`day_male`/`day_female`) | ランキング mode で一部対応 | △（ランキングのみ、検索では未対応） |
| ブックマーク検索 | `bookmarkFilter` で word suffix 方式 | △（数値範囲指定不可） |
| 日付範囲 (`start_date`/`end_date`) | 未実装 | ✗ |
| ブックマーク数範囲 (`bookmark_num_min`/`max`) | 未実装 | ✗ |
| 執筆文字数範囲 | `start_text_length`/`end_text_length` で小説のみ | △（イラストにはなし） |

### 2.4 ダウンロード 1 件表示バグ調査

#### 調査対象ファイル
- `download_queue_screen.dart`
- `offline_bookshelf_screen.dart`
- `visual_search_screen.dart`
- `duplicate_finder_screen.dart`

#### 事実
- `download_queue_screen.dart` の空状態メッセージは `"ダウンロードキューは空です"`（`_buildEmpty`、line 342）
- `offline_bookshelf_screen.dart` の空状態メッセージは `"キャッシュされた小説はありません"`（line 177）
- `"ダウンロード済みの画像がありません"` は `visual_search_screen.dart` (line 209) と `duplicate_finder_screen.dart` (line 241) に存在

#### 結論
- 現在のコードでは、`download_queue_screen.dart` は `_groups.isEmpty` の場合のみ空状態を表示
- `getDownloadQueueGroups()` は completed グループも含むため、1 件完了時でも `_groups` は空ではない
- **ユーザー報告の「完了 1 件で空表示」事象は、現在のコードでは再現しない**
- もし過去に再現していた場合、原因は `completedCount` と `_groups` の取得タイミングの競合の可能性がある

---

## 3. リビルド方針

### 3.1 アーキテクチャ

```
lib/
├── services/
│   ├── pixiv_api_service.dart        # 単一の API サービス（全エンドポイント統一）
│   ├── pixiv_api_http.dart           # HTTP クライアント共通化
│   ├── database_search.dart          # ローカル検索（embedding/lexical）
│   └── hybrid_search_service.dart    # フィーリング発掘 v2
├── screens/
│   ├── search/
│   │   ├── search_screen.dart        # 統合検索画面
│   │   ├── search_filter_sheet.dart  # フィルターボトムシート
│   │   └── search_history_overlay.dart # 検索履歴オーバーレイ
│   ├── feeling_discovery_screen.dart # フィーリング発掘（刷新）
│   ├── visual_search_screen.dart     # 視覚類似検索
│   └── duplicate_finder_screen.dart  # 重複検出
└── models/
    ├── search_filter.dart            # 検索フィルター共通モデル
    └── feeling_query.dart            # FeelingSearchQuery 分離
```

### 3.2 単一 API サービス化

`pixiv_api_individual.dart`, `pixiv_api_search.dart`, `pixiv_api_filter.dart` を `pixiv_api_service.dart` に統合。

**統合ルール:**
- 重複する `_MuteFilter` は単一実装に統一
- `filterIllustsIsolated` / `filterNovelsIsolated` の `Isolate.run` パターンを共通化
- `AllTextSearchState<T>` の重複を解消
- `_wrap<T>` のシグネチャを統一（`pixiv_api_individual.dart` の `fromJson` 引数方式を採用）

### 3.3 検索フィルター モデル統一

```dart
class SearchFilter {
  final String searchTarget;      // partial_match_for_tags 等
  final String sort;              // date_desc, popular_desc 等
  final String ageLimit;          // all, r18, r18g
  final int bookmarkFilter;       // 0 またはusers入り数
  final String? workType;         // illust, manga
  final int? startDate;           // Unix timestamp (新規)
  final int? endDate;             // Unix timestamp (新規)
  final int? bookmarkNumMin;      // 新規
  final int? bookmarkNumMax;      // 新規
  final String? duration;         // 新規
  // 小説専用
  final int? minTextLength;
  final int? maxTextLength;
  final bool seriesOnly;
  final List<String> excludeTags;
  // イラスト専用
  final String aiFilter;          // all, exclude, only
}
```

### 3.4 新規エンドポイント追加方針

優先度の高いものから実装:
1. `/v1/user/bookmarks/illust` + `/v1/user/bookmarks/novel` — ブックマーク一覧
2. `/v2/illust/follow` + `/v1/novel/follow` — フォロー新着
3. `/v1/illust/new` + `/v1/novel/new` — 新着
4. `/v1/trending-tags/illust` + `/v1/trending-tags/novel` — トレンドタグ

### 3.5 検索 UI 刷新

#### 画面構成
- 既存の `home_screen_state.dart` の検索ロジックを `search_screen.dart` に分離
- フィルターは `search_filter_sheet.dart` に集約
- 検索履歴は `search_history_overlay.dart` に分離

#### レスポンシブ対応

| ブレイクポイント | レイアウト |
|-----------------|-----------|
| < 600px | 単一カラム、全幅フィルター |
| 600–840px | 2カラムグリッド、サイドフィルター |
| > 840px | 3カラムグリッド、常時サイドパネル |

### 3.6 データベース変更

#### 必要な変更
- `search_history` テーブル: 既存の `use_count` を活用（変更不要）
- 新規: `bookmark_filters` テーブル（将来の保存用、今回は任意）

#### 変更不要
- `novels`, `illusts`, `novel_embeddings`, `illust_embeddings` は変更不要
- `download_queue_groups`, `download_queues` は変更不要

---

## 4. 実装タスク

### Phase 1: API サービス統合
1. `pixiv_api_service.dart` に未実装エンドポイントを追加
2. `pixiv_api_individual.dart` の重複メソッドを削除し、`pixiv_api_service.dart` に委譲
3. `pixiv_api_search.dart` の `AllTextSearchState` を `pixiv_api_service.dart` に統合
4. `pixiv_api_filter.dart` の `_MuteFilter` を `pixiv_api_service.dart` に統合
5. `normalizeSearchTarget` の適用範囲を拡大

### Phase 2: 検索フィルター拡充
1. `SearchFilter` モデルを新規作成
2. `start_date`/`end_date` の API 送信対応
3. `bookmark_num_min`/`bookmark_num_max` の API 送信対応
4. `duration` の API 送信対応
5. フィルター UI に新しい条件を追加

### Phase 3: 検索 UI 刷新
1. `search_screen.dart` を作成（`home_screen_state.dart` から分離）
2. `search_filter_sheet.dart` を作成（`home_filter_handler.dart` から分離）
3. `search_history_overlay.dart` を作成
4. レスポンシブ対応（phone/tablet）
5. フィーリング発掘との統合ナビゲーション

### Phase 4: 新規エンドポイント
1. ブックマーク一覧 API 実装
2. フォロー新着 API 実装
3. 新着 API 実装
4. トレンドタグ API 実装

### Phase 5: ダウンロード 1 件表示バグ（調査完了）
- 現在のコードでは再現しない
- 予防的に対策を実装:
  - `download_queue_screen.dart` の `_buildEmpty` を completed 専用ビューに分離
  - pending/running が 0 で completed がある場合の表示を追加

---

## 5. テスト計画

### ユニットテスト
- `pixiv_api_service_test.dart` — 全エンドポイントのモックテスト
- `search_filter_test.dart` — SearchFilter の変換・永続化テスト
- `hybrid_search_service_test.dart` — ローカル検索パイプライン
- `database_search_test.dart` — embedding/lexical 検索

### ウィジェットテスト
- `search_screen_test.dart` — 検索入力、結果表示、フィルター適用
- `search_filter_sheet_test.dart` — フィルターボトムシート
- `feeling_discovery_screen_test.dart` — フィーリング発掘 UI

### 統合テスト
- 検索→詳細→ダウンロード フロー
- フィルター永続化→アプリ再起動→復元

### 受け入れ条件
1. 既存の 162 テストがすべてパスすること
2. 新規追加テストが 50 件以上であること
3. 検索結果が API レスポンスと一致すること
4. フィルター設定がアプリ再起動後も保持されること
5. オフライン時にローカル検索が動作すること

---

## 6. 実装ブロッカー

| ブロッカー | 影響 | 対策 |
|-----------|------|------|
. | Pixiv App-API の一部エンドポイントが非公開 | 公式ドキュメント/既存実装から推測 |
| `duration` パラメータの仕様不明 | 日付範囲フィルターに影響 | API レスポンスを確認しながら実装 |
| 複数ファイルの依存関係が複雑 | 統合時のリグレッションリスク | 段階的リファクタリング + テスト追加 |

---

## 7. ダウンロード 1 件表示バグ 調査結果と修正方針

### 調査結果
- `download_queue_screen.dart`: `_groups.isEmpty` 時のみ `_buildEmpty` が表示される
- `getDownloadQueueGroups()` は全ステータス（pending/running/completed/failed/canceled）を返す
- 完了 1 件でも `_groups.length == 1` となり、リストが表示される
- **現在のコードではユーザー報告の事象は再現しない**

### 修正方針（予防的）
1. `download_queue_screen.dart` に `completedOnly` 表示モードを追加
2. pending/running が 0 件かつ completed が 1 件以上の場合、サマリーに「完了のみ」表示を追加
3. `_buildEmpty` を pending 用と completed 用に分離

---

## 8. 変更ファイル一覧（予定）

| ファイル | 操作 | 内容 |
|---------|------|------|
| `lib/services/pixiv_api_service.dart` | 変更 | 未実装エンドポイント追加、重複コード統合 |
| `lib/services/pixiv_api_individual.dart` | 削除 | `pixiv_api_service.dart` に統合 |
| `lib/services/pixiv_api_search.dart` | 削除 | `pixiv_api_service.dart` に統合 |
| `lib/services/pixiv_api_filter.dart` | 変更 | `_MuteFilter` を `pixiv_api_service.dart` に移管 |
| `lib/screens/search/search_screen.dart` | 新規 | 統合検索画面 |
| `lib/screens/search/search_filter_sheet.dart` | 新規 | フィルターボトムシート |
| `lib/screens/search/search_history_overlay.dart` | 新規 | 検索履歴オーバーレイ |
| `lib/screens/home_screen_state.dart` | 変更 | 検索ロジックを分離、State を縮小 |
| `lib/screens/home_filter_handler.dart` | 変更 | フィルター UI を分離 |
| `lib/screens/home_ui_components.dart` | 変更 | 検索関連 UI を分離 |
| `lib/screens/feeling_discovery_screen.dart` | 変更 | 新アーキテクチャに適合 |
| `lib/models/search_filter.dart` | 新規 | 検索フィルター共通モデル |
| `test/pixiv_api_service_test.dart` | 新規 | API サービス単体テスト |
| `test/search_filter_test.dart` | 新規 | フィルターモデルテスト |
| `test/search_screen_test.dart` | 新規 | 検索画面ウィジェットテスト |
| `test/feeling_discovery_screen_test.dart` | 新規 | フィーリング発掘テスト |

---

## 9. 着手順

1. **Phase 1 着手前**: `pixiv_api_service.dart` の全メソッドをモック化したテストを追加
2. **Phase 1**: API サービス統合 + 重複ファイル削除
3. **Phase 2**: フィルター拡充 + UI 更新
4. **Phase 3**: 検索画面刷新
5. **Phase 4**: 新規エンドポイント追加
6. **Phase 5**: ダウンロード画面の preventive fix

各 Phase 終了時に `flutter test` を実行し、回帰がないことを確認する。
