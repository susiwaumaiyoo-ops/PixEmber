# PixEmber — 開発ステータス

最終更新: 2026-09-11（Phase 9-B 自動要約 / Phase L ローカルLLM 整備・留守中バッチ作業5）

## 現在の状態
- DB バージョン: 26（v25 で llm_summaries / v26 で auto_summary_runs・auto_summary_items を追加。いずれもテーブル追加のみ・既存データ不変）
- テスト: 734 件パス、flutter analyze クリーン
- ローカルLLM 推論: llamadart ではなく `libnative_llm.so`（llama.cpp C API ラッパ）を Dart FFI 経由で呼ぶ設計に移行済み。詳細は [`docs/ARCHITECTURE_LLM.md`](../ARCHITECTURE_LLM.md)。
- 自動要約（Phase 9-B）: 進行状態は STATE.md 参照（B2-4+5 完了・B2-6 実機検証は未実施）
- 検索UX: ボトム3タブ（イラスト / 小説 / フィーリング発掘）を維持。検索バーフォーカス→アシストビュー領域置換（オーバーレイ不使用）

## 完成済み機能パック

### 感動機能パック（A〜F 完了）
- A 読書速度推定: `reading_speed_service` + 読了目安表示（コミット b2da6aa）
- B 読書傾向: `reading_trends_service` + 統計画面の傾向セクション（7f90367）
- C 感情曲線: `emotion_curve_service`（端末内 ONNX トークナイザ推論）+ 小説詳細カード（f7e12dd）
- D 類似作品: `similar_works_service` + 関連作品カード（2f4d2f6）
- E 感情ピークTOC / 休眠タグ / うご代表フレーム（8214ec1・テスト383件）
- F 視覚モデル選定ドキュメント（承認ゲート、実装なし）（2224c00）

### 非AI機能パック（N1〜N8 完了）
- [x] N1 検索プリセット: 詳細検索条件の保存 / 1タップ復元（フィルタシート保存ボタン + アシストビュー「保存した検索」セクション、上限30件、long-press で改名/削除）
- [x] N2 AIレコメンド理由説明: 推薦候補に理由タグ（タグN件一致／最近読んだ作品に近い／お気に入り傾向／未読の作者／類似度区分）+ カード右上のⓘで BottomSheet 表示（理由空の場合は「総合的な類似度で推薦」）
- [x] N3 小説シリーズ追跡: series_progress_service（次の未読話/読了X/N/残り目安）+ 詳細画面進捗カード「シリーズ 3/12 ・ 次は第4話」+「次から読む」、リーダー目次Drawer進捗行、あとで読む long-press「シリーズの続きへ」
- [x] N4 今日の再発見カード: discovery_card_service（休眠タグ/シリーズ続き/長期未見作者/オフライン保存未読 → 優先度ソート・重複排除・最大3件）+ 検索アシストビュー上部「今日の再発見」カード（非ブロッキング・0件は非表示、タップで検索/小説詳細/作者ページへ）
- [x] N5 あとで読むAI整理 + 簡易フォルダ分け: read_later_organize_service（埋め込みカバレッジ60%以上なら意味クラスタリング・そうでなければタグ頻度「簡易モード」→ グループ提案・名前候補）+ あとで読む AppBar の「整理を提案」→ BottomSheet で提案一覧（フォルダ名編集/採用/スキップ）。「採用」押下時のみフォルダ作成＋追加（自動移動なし・dry-run と実行を分離）（856fa63・テスト472件）
- [x] N6 読書メモ・引用メモ: reading_notes テーブル（DB v24・追加のみ・work_id/page_index/anchor_text/note_text）+ 小説リーダー上部バーのメモボタン → BottomSheet（現在ページへの引用アンカー表示・保存/編集（行長押し）/削除・この作品の全メモ一覧、別ページのメモをタップで該当ページへジャンプ）+ exportAllData/importAllData に reading_notes を追加し Google Drive バックアップ対象に（7af6f50・テスト483件）
- [x] N7 設定画面の最小統合: settings_screen（検索 / レコメンド / 小説リーダー / ライブラリ / バックアップ / ライセンス の6セクション）+ ホーム Drawer の「設定」タイル導線。小説リーダー設定は HUD と同一 novel_pref_* キーの直接読み書き（値共有・互換維持）・「保存した検索」は SearchPresetService で管理（一覧 / 改名 / 削除）・新規 DB / 設定キーなし・検索UX 不変（a220189・テスト493件）
- [x] N8 監査・docs・仕上げ: flutter analyze クリーン / flutter test 493件パス / flutter build apk --debug 成功 / README に N1〜N7 機能リストとプライバシー注記（端末内処理・外部送信しない）を追加 / analyze クリーンのため追加デッドコードなし

## 制約（本ラウンド）
- 検索UX を壊さない: 4タブ禁止・独立検索タブ禁止・`Positioned(top:110)` オーバーレイ復活禁止
- R-18 / x_restrict 分離、スペース区切り検索、小説全文検索を維持
- CLIP / 視覚モデル追加・AIモデル拡充・トークナイザ変更は禁止
- Gradle / AGP / Kotlin / Flutter SDK 変更禁止
- 破壊的 DB 変更禁止（N6 の v24 増設はテーブル追加のみ・既存データ不変）
- 全て端末内処理・外部送信しない
