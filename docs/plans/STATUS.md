# PixEmber — 開発ステータス

最終更新: 2026-09-04（非AI機能パック Phase N1 実装中）

## 現在の状態
- DB バージョン: 23（N1 は変更なし。プリセットは SharedPreferences `search_presets_v1` に保存）
- テスト: 383 件パス（N1 実装前時点）、flutter analyze クリーン
- 検索UX: ボトム3タブ（イラスト / 小説 / フィーリング発掘）を維持。検索バーフォーカス→アシストビュー領域置換（オーバーレイ不使用）

## 完成済み機能パック

### 感動機能パック（A〜F 完了）
- A 読書速度推定: `reading_speed_service` + 読了目安表示（コミット b2da6aa）
- B 読書傾向: `reading_trends_service` + 統計画面の傾向セクション（7f90367）
- C 感情曲線: `emotion_curve_service`（端末内 ONNX トークナイザ推論）+ 小説詳細カード（f7e12dd）
- D 類似作品: `similar_works_service` + 関連作品カード（2f4d2f6）
- E 感情ピークTOC / 休眠タグ / うご代表フレーム（8214ec1・テスト383件）
- F 視覚モデル選定ドキュメント（承認ゲート、実装なし）（2224c00）

### 非AI機能パック（進行中）
- [x] N1 検索プリセット: 詳細検索条件の保存 / 1タップ復元（フィルタシート保存ボタン + アシストビュー「保存した検索」セクション、上限30件、long-press で改名/削除）
- [ ] N2 AIレコメンド理由説明（理由生成 + ⓘ→BottomSheet）
- [ ] N3 小説シリーズ追跡（series_progress_service + 詳細画面進捗バー）
- [ ] N4 今日の再発見カード（discovery_card_service + Assist View）
- [ ] N5 あとで読むAI整理 + 簡易フォルダ分け
- [ ] N6 読書メモ・引用メモ（reading_notes・DB v24 に予定、追加のみ）
- [ ] N7 設定画面の最小統合（settings_screen + Drawer 導線）
- [ ] N8 監査・docs・仕上げ

## 制約（本ラウンド）
- 検索UX を壊さない: 4タブ禁止・独立検索タブ禁止・`Positioned(top:110)` オーバーレイ復活禁止
- R-18 / x_restrict 分離、スペース区切り検索、小説全文検索を維持
- CLIP / 視覚モデル追加・AIモデル拡充・トークナイザ変更は禁止
- Gradle / AGP / Kotlin / Flutter SDK 変更禁止
- 破壊的 DB 変更禁止（N6 は v24 への非破壊的増設のみ）
- 全て端末内処理・外部送信しない
