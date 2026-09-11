# リリースチェックリスト（作業4：リリース衛生監査）

最終更新: 2026-09-11（留守中バッチ／作業4）

本ドキュメントは本番リリース前に必ず棚卸しする項目を記録する。
**留守中バッチでは絶対ルール（依存追加・コア変更・値の書き換え禁止）により、
以下「未対応」項目は値の変更を行わず、現状と要対応事項の記録に留めた。**

---

## 1. 認証・個人情報のログ流出（部分対応済み）

novel 本文・OAuth トークン等の機微情報を `debugPrint` で素出ししていた箇所を、
`kDebugMode` ゲートで release ビルドでは出力しないよう修正した（作業4・このコミット）。

修正したログ箇所:
- `lib/services/pixiv_api_service.dart`
  - OAuth refresh 失敗時の `response.body`（`kDebugMode` ゲート化）
  - 429 / 401 / その他 API エラー時の `ERROR Body: ${response.body}`（`kDebugMode` ゲート化）
- `lib/screens/home_screen_state.dart`
  - PKCE token exchange 失敗時の `response.body`（`kDebugMode` ゲート化）

備考:
- 小説本文の内容自体は元よりログへ出しておらず、長さ（`text.length`）のみを
  出力していた。本文内容の露出は確認されなかった。
- `throw Exception(...)` 句内に `response.body` を埋め込む箇所は、例外メッセージが
  UI に表示されうるが「ログのみ修正」の範囲外（挙動変更）のため**未変更**。
  対応する場合はエラーメッセージの要約化を別途設計する（→ §5 残課題）。

## 2. applicationId（未対応・要判断）

- 現状: `android/app/build.gradle.kts` の `applicationId = "com.example.pixiv_viewer"`。
- **未対応理由**: 絶対ルールにより値の書き換えを禁止。`com.example.*` は
  一般配布向けではないが、書き換えると既存インストールデータ／認証設定／
  Google OAuth のクライアント登録と不整合が起きうる。判断を要する。
- 推奨: リリース前に正式パッケージ名へ変更し、OAuth クライアント／ Firebase 等
  の登録情報も併せて更新すること。変更は個別タスクで。

## 3. リリース署名（未対応・要判断）

- 現状: release ビルドが debug キーで署名されている可能性が高い
  （`build.gradle.kts` の signingConfigs を確認）。
- **未対応理由**: keystore 新規作成／`key.properties` 追加は依存・認証情報の追加に
  当たり絶対ルールで禁止。値の変更を伴うため。
- 推奨: 本番用 keystore を安全に管理し、`signingConfig.release` を debug 以外の
  鍵へ差し替えること。パスフレーズはコミットしない。

## 4. リポジトリ内の散在ファイル（削除せず列挙のみ）

作業ルールにより**削除しない**。リリース前に整理対象として列挙する。

ワークスペース直下（`asd/`, pixiv_viewer 外）:
- `a2.txt`, `a3.txt`, `a4.txt` — 一時ログと思われる
- `analyze_check.txt`, `analyze_now.txt` — analyze 出力の一時保存
- `fix1.txt` — 一時ファイル
- `b2_test.log` — テストログ
- `app.py`, `main.py`, `history.db`, `gguf_meta.py` — Flutter とは無関係な
  Python／DB 実験ファイル（ワークスペース直下に残存）
- `_ab_ref/` — ONNX モデル比較用の参照データ一式（大ファイル含む）

`pixiv_viewer/` 直下（git 管理外の一時成果物・要 `.gitignore` 確認）:
- `tatus --short` — コマンド打ち間違いで生成された空ファイル（`git status --short` の誤入力）
- `analyze_llm.txt`, `build_release.txt`, `device_ls.txt`, `full_tests_out.txt`,
  `llm_tests_out.txt`, `test_llm.txt`, `hf_check_*.txt`, `hf_i1_out.txt`,
  `hf_tree_out.txt`, `tmpl_out.txt`, `tmpl_evidence.txt`, `tmpl_evidence2.txt`,
  `llm_dump.txt` — 一時ログ／ダンプ
- `gguf_head.bin` — GGUF ヘッダ抜粋（バイナリ）
- `ruri_report.json` — 生成レポート
- `hf_check*.py` — 検証用 Python

→ これらはリリースビルド成果物には含まれないが、リポジトリに混入している場合、
  `.gitignore` 追加か削除で整理すべき（今回は削除しない）。

## 5. 残課題（要判断・今回は非実施）

- `throw Exception` メッセージ内への API `response.body` 埋め込み（§1 備考）。
  UI スナックバーに生 JSON が出る可能性。要約化する設計判断が必要。
- applicationId / release 署名 の正式化（§2, §3）。
- 一時ファイルの `.gitignore` 登録または削除（§4）。
- `flutter analyze` は本作業の修正後も unused / import 警告 0 を確認済み。
