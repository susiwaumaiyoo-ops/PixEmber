# PixEmber 現状把握レポート (STATUS)

> 最終更新: 2026-08-29（Phase 3-6 実装完了）
> 本レポートは **実コマンド実行結果** に基づく（前回 architect 版の調査制約を解消・全面差し替え）。

---

## 1. 実コマンド結果（必須現状確認・2026-08-27〜28 実施）

| コマンド | 結果 |
|---------|------|
| `git status --short` | **空（クリーン）** — Phase 2 チェックポイント直後の状態で開始 |
| `git log --oneline -10` | 6 コミット。最新 `4f57c38` "checkpoint: phase 1 and 2 completed before phase 3-6"（2026-08-28 00:47 JST / suiswaumaiyoo-ops） |
| `flutter pub get` | 成功。workmanager **0.10.9**（workmanager_android 0.10.8 / workmanager_apple 0.9.10）、flutter_onnxruntime 1.8.3、dart_sentencepiece_tokenizer 1.3.2 解決。※ palette_generator は discontinued 表示（動作問題なし） |
| `flutter analyze` | 初回: 警告 1 件（`google_drive_service.dart:153`）→ **D 修正後: `No issues found!`（0 件）** |
| `flutter test` | **`All tests passed!` 58 件**（recommendation_math 46 + download_queue 11 + widget_test 1） |

---

## 2. 安定化作業（本セッション実施）

| 項目 | 状態 | 内容 |
|------|------|------|
| A. STATUS.md 更新 | ✅ | 実コマンド結果へ差し替え（本ファイル） |
| B. 設計書バージョン乖離修正 | ✅ | `02-offline-downloads.md` の workmanager `0.9.x` 系記述を実装実態 **0.10.9** へ全修正。API 例（`initialize` / `registerOneOffTask` / タスク名 `pixiv_download_queue` / `ExistingWorkPolicy.keep`）も実装コード一致へ更新 |
| C. 不要ファイル整理 | ✅ | `git rm` 10 件: `.backup` ×4（home_screen / illust_detail_screen / database_service / pixiv_api_service）、`an.txt` / `analyze_check.txt` / `analyze_now.txt` / `analyze_output.txt` / `test_now.txt` / `$null`（誤生成ゴミファイル） |
| C. 判断保留（報告のみ） | ⚠️ | `lib/screens/home_screen_state_new.txt`（旧実装の全文下書き 4513 行・ビルドに無影響）、`ruri_report.json`（Ruri トークナイザ検証レポート・参考資料）。削除可否はユーザー判断 |
| D. analyze 警告修正 | ✅ | `google_drive_service.dart:153` `return _restoreFromId(...)` → `return await _restoreFromId(...)`（try 内 await 追加のみの最小安全修正）。**analyze 0 件を確認** |

> 現在の作業ツリー: 上記安定化作業分の未コミット変更あり（削除 10 件 staged / google_drive_service.dart 修正 / ドキュメント更新）。**コミット実行はユーザー判断待ち。**

---

## 3. Phase 1 / 1.5 / 2 軽量監査（回帰なし確認）

| 監査対象 | 結果 |
|---------|------|
| Phase 1 / 1.5: AIレコメンド | ✅ `ai_recommend_feed_screen.dart` 独立画面（実 Drawer 導線）、`recommendation_service.dart` / `recommendation_math.dart` 完備、46 テスト通過。ボトムナビ 3 タブ構成（旧4タブ名残 `recommendIndex=3` とデッド分岐は削除済み） |
| Phase 2: DL/オフライン | ✅ `download_service.dart`（DB 永続キュー / `recoverOnStartup` / `runBackgroundOnce` / `registerBackgroundTaskIfAndroid`）、`main.dart` の callbackDispatcher + Android ガード初期化、AndroidManifest の FGS + `dataSync` 型宣言、`pixiv_image.dart` の localFile 優先表示、11 テスト通過 |
| 総合 | **回帰なし**（58 テスト全通過・analyze 0 件） |

---

## 4. 依存・DB 現状（要約）

- **DB バージョン: 21**（v18 `tts_reading_positions` / v19 `usage_sessions` / v20 `image_embeddings` / v21 `image_fingerprints` — すべて非破壊マイグレーション）
- workmanager 0.10.9（設計書との乖離は解消済み） / flutter_tts 4.2.5 / image 4.3.0（純Dart・ネイティブビルド影響なし） / flutter_onnxruntime 1.8.3 / dart_sentencepiece_tokenizer 1.3.2
- モデル・バイナリは git 管理外（実行時ダウンロード方式）
- **バックアップ対象外テーブル**（再生成可能な端末ローカルデータ）: `tts_reading_positions` / `usage_sessions` / `image_embeddings` / `image_fingerprints`

---

## 5. Phase 3〜6 実装ステータス

| Phase | スコープ | 状態 |
|-------|---------|------|
| 3 | 小説TTS読み上げ（flutter_tts・ルビ/タグ正規化・チャンク分割と位置マッピング・DB v18） | ✅ 完了（テスト 28 件） |
| 4 | 閲覧・読書ダッシュボード（usage_sessions DB v19・ローカル集計のみ・削除機能） | ✅ 完了（テスト 16 件） |
| 5 | 視覚類似検索（VisualEncoder プラグ可能抽象 + ColorGridEncoder 暫定実装・image_embeddings DB v20・実モデル不導入） | ✅ 完了（テスト 13 件） |
| 6 | 重複・近似重複検出（SHA-256 + dHash・image_fingerprints DB v21・自動削除なし・削除は確認ダイアログ必須） | ✅ 完了（テスト 17 件） |

### 実装詳細メモ

- **Phase 3 (TTS)**: flutter_tts 4.2.5 には `resume()` API が存在しないため、全プラットフォームで「停止→現チャンク先頭から再開」方式に統一（iOS 専用 pause 分岐は撤回）。読了位置は `tts_reading_positions`（v18）に UPSERT、リーダー HUD の「TTS 再開位置」から継続可。
- **Phase 4 (利用時間)**: 小説リーダーとイラスト詳細の 2 画面でセッション計測（小説詳細はリーダーとの二重計上を避け対象外）。バックグラウンド移行時は `checkpointAll()` で経過分を確定保存→復帰時 `discardBackgroundTime()` でバックグラウンド時間を計測から除外。3 秒未満の断片はノイズとして破棄。統計画面に「読書・閲覧時間」カード（総利用/今日/7日/30日・小説/イラスト別・日別棒グラフ）+ 削除ボタン（プライバシー）。
- **Phase 5 (視覚類似検索)**: `VisualEncoder` 抽象 + `ColorGridEncoder`（8x8 色グリッド 192 次元・L2正規化）暫定実装。実モデル（CLIP 等）導入時はエンコーダ差し替えのみで DB スキーマ・検索ロジック不要変更。`image` 4.3.0 パッケージ追加（純Dart・Gradle/ネイティブ設定変更なし）。画像解析は `Isolate.run` で UI 非ブロック。Float32 を BLOB 保存。
- **Phase 6 (重複検出)**: SHA-256（完全一致）+ dHash 64bit（近似・ハミング距離閾値 4）の Union-Find グループ化。スキャンは中断可能・再開時は未解析分のみ処理。削除は画像ごとに確認ダイアログ必須（自動削除なし）、削除後 `integrityCheck()` でキュー/本棚の整合性を修復。**実装中に発見・修正した重要バグ: dHash は bit63 を使うため負値を取り得るが、`hammingDistance` の算術シフト `>>` では -1 が減らず無限ループする。符号なしシフト `>>>` で修正。**

---

## 6. ナビゲーション統合

- ホームドロワー（実体は `home_screen_state.dart` の build 内 Drawer）に全主要機能をグループ化して配置：
  - AI 機能: AIレコメンド / 似た画像を探す（視覚類似検索）/ AIインデックス管理
  - データ・保存: 閲覧統計 / ダウンロード管理 / オフライン本棚 / 重複画像の検出 / バックアップ管理
  - 既存: しおり一覧 / 閲覧履歴 / お気に入りフォルダ / ミュート管理 / 購読タグ / あとで読む / ログイン / Google ドライブ同期
- かつて `home_ui_components.dart` に存在した「第二の Drawer」は `HomeUIComponents.build()` が未呼び出しのデッドコードだったため削除（視覚類似検索・重複検出等の導線が実際には非表示になっていた原因）。131 テスト全通過・analyze 0 件のまま導線を実 Drawer に統合

---

## 7. ブロッカー

- **なし。**（Phase 3-6 すべて完了・全テスト通過・analyze 0 件）
