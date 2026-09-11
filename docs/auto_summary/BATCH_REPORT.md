# 留守中バッチ報告（実機検証の下準備 + 品質整備）

作成: 2026-09-11（留守中バッチ最終レポート）
実行モード: 自律（質問・承認待ちなし、不確実項目は「未実施・理由」を記録して続行）

---

## 総括

| 作業 | 状態 | コミット | analyze/test |
|---|---|---|---|
| 作業1 adb-only スモーク調査 | ✅ 完了（実機不在のため調査+手順書） | `951d3a0` | 該当なし（docsのみ） |
| 作業2 F2 model_file_hash | ✅ 完了 | `f9f806c` | 0件 / 726→726 |
| 作業3 統合テスト拡充 | ✅ 完了 | `59a5a9b` | 0件 / 734 pass |
| 作業4 リリース衛生監査 | ✅ 完了（ログ修正+監査記録） | `8ba8c14` | 0件 / 734 pass |
| 作業5 ドキュメント | ✅ 完了 | `c1360ec` | 0件（docsのみ） |

最終状態: **flutter analyze 0 issues / flutter test 734 件パス**。

---

## 作業1: adb-only 実機スモーク調査 → SMOKE_PREP.md

- `adb devices` は**空**＝実機/エミュレータ未接続。よって実機スモーク（install/launch/logcat/PID 確認）は
  **この場では実施不能**。絶対ルール（勝手に推論実行しない／実機 ≤20分）とも整合し、実機操作は行わない。
- コードから確定できる事実を [`SMOKE_PREP.md`](SMOKE_PREP.md) に記録:
  - 「今すぐ実行」を adb 単独で発火する導線は**存在しない**（deeplink は pixiv.net の view のみ、
    MainActivity に自動要約の intent-extra なし、ForegroundService は `exported=false`）。
  - UI 用 FlutterEngine と FGS TaskHandler 用エンジンは `android:process` 未指定＝**同一 PID に同居**する想定。
  - `onEngineCreate` で `GeneratedPluginRegistrant` + `NativeLlmChannel` を手動登録している旨を明記。
  - logcat で確認すべき項目と、ユーザーが実機で行うべき操作チェックリスト（B2-6 用）を遺した。
- **未実施（実機依存）**: 実インストール／起動／logcat 実測／PID 実確認／自動要約発火。**理由**: デバイス未接続。

## 作業2: F2 — キャッシュ検索に model_file_hash を追加

技術負債: `llm_summaries` に `model_file_hash`（NOT NULL）列はあるのに `get()` が検索条件に含めておらず、
モデルファイル差し替え後も旧キャッシュが誤 HIT し得た。

- `LlmSummaryCacheService.get()` に **任意引数 `String? modelFileHash`** を追加。指定時のみ
  `AND model_file_hash = ?` を付与（後方互換: 未指定は従来動作）。
- 手動／自動の全検索経路を統一:
  - `llm_summary_sheet.dart` `_startLocal` / `_startViaFgs`
  - `auto_summary_real_ports.dart` `isCachedValid`
- 既存行の扱い（設計判断をコメント化）: 列は NOT NULL かつ全経路が同一 `computeModelFileHash`
  （`SHA256(basename:size:mtime)`、失敗時 `SHA256(path)`）で算出するため、既存行も同一関数由来＝
  マイグレーション不要・**データ削除なし**。誤 HIT を避けるため検索側のみ厳密化。
- テスト追加（`llm_summary_cache_test.dart`）: hash 不一致=ミス／未指定=従来 HIT（後方互換）。
- **バグ発見→修正**: `_startLocal` で `computeModelFileHash` の await を `if (workId != null)` ガード**外**へ
  移動したところ、await が1つ増え `llm_model_preset_test` の固定 `pump(300ms)` seq が崩れ3件失敗。
  ガード内で遅延計算＋保存時に `??` フォールバックする形へ修正し green 復帰（B2ロジック変更ではなく
  自分が入れた回帰の是正）。
- **コミット副作用（要認識・未修正）**: `f9f806c` に44ファイル（+9047/-473）が入った。これは従来から
  **未追跡だった B2 一式（llm_run_arbiter / auto_summary_* / native_llm_* / docs 他）を `git add -A lib test` が
  巻き込んだ**ため。ルール上 `reset --hard`／履歴破棄は禁止なので**ロールバックしない**。以後（task3〜5）は
  対象ファイルを明示 `git add` し混入を防止した。中身は正しく動作するコードで、緑も保たれている。

## 作業3: 自動要約の統合テスト拡充（fake / インメモリDB）

既存で網羅済（tag/work 重複排除・件数整合・全キャッシュ・失敗不加算・maxPerSession・通電待機・
runNow 多重・チャンク伝播・mute 等）。**ギャップ**を中心に追加:

- `auto_summary_service_test.dart`: **Wi-Fi 条件喪失**（充電と区別、`waitReason=wifi` で生成しない）を1件追加。
- `llm_run_arbiter_test.dart`: **自動生成中に waiting した手動を `cancelManual` → 自動完了後も消化されない**
  （drain 時に cancelled 生成なし）を1件追加。
- `auto_summary_repository_test.dart`: **新規**（インメモリ sqflite_ffi + v26 スキーマ）6件:
  saveSnapshot→loadLatest で saved/waiting/target 復元／loadRun 未知は null／loadLatest は最大 updated_at／
  reconcileStaleRunning が非終端 run→error・processing→waiting・saved 維持／終端 run はスキップ／
  saveSnapshot は items を丸ごと置換。
- **削除**: 「自動→自動で生成は直列」は既存「model-load-once」が自動→自動の直列完了を担保済みで冗長、
  かつ自分のテストコード側でゲート解放漏れによりタイムアウトしたため**削除**（プロダクション変更なし）。
- 結果: 対象3ファイル green、フル `flutter test` **734 pass**、analyze 0。
- **依然ギャップ（未実施・要実機 or 追加設計）**: 通知＋画面の同一スナップショット同期（UI/通知は fake 実行系で
  一部担保だが実 FGS 経由の同一性は未検証）、画面再接続で同一 run 復旧（リポジトリ復元は repo テストで担保、
  画面接続は未検証）、READY 未達／サービス消失時の recovery（`FgsLifecycle` の timeout は単体、結合は未検証）。
  **理由**: これらは FGS／実エンジン境界に依存し fake 単体では再現が不確か。実機検証（B2-6）に委ねる。

## 作業4: リリース衛生監査

- **ログリーク（修正済・log のみ／kDebugMode ゲート化）**:
  - `pixiv_api_service.dart`: OAuth refresh 失敗時 `response.body`、429/401/その他 API エラー時 `ERROR Body`。
  - `home_screen_state.dart`: PKCE token exchange 失敗時 `response.body`（直上コメント「出力しない」と矛盾していた）。
  - novel 本文は元々 `text.length` のみで内容露出なし（良好）。
- **未変更（ログ以外＝挙動変更に該当）**: `throw Exception(...)` 句内に `response.body` を埋める箇所は
  エラーメッセージが UI に出うるが「ログのみ修正」方針外。→ RELEASE_CHECKLIST §5 残課題に記録。
- `kDebugMode` を home_screen_state.dart が未 import（この環境では material 経由の re-export が効かず）→
  `package:flutter/foundation.dart` を明示 import し analyze 0 復旧。
- **docs/RELEASE_CHECKLIST.md 新規**: applicationId=`com.example.pixiv_viewer`、release 署名＝debug 鍵の疑い、を
  **絶対ルール（値の変更禁止）により未対応**として明記。keystore / OAuth 登録は個別タスク推奨。
- **散在ファイル（削除せず列挙）**: ルート直下の一時 txt / Python / `_ab_ref/`、`pixiv_viewer` 直下の
  `tatus --short`（`git status --short` の誤入力）、各種 *_out.txt / *.log / gguf_head.bin / ruri_report.json /
  hf_check*.py 等を RELEASE_CHECKLIST §4 に列挙。**未削除**（ルール準守）。
- 未使用ファイル/imports: analyze が unused 警告 0（デッドコードなし）。

## 作業5: ドキュメント

- `docs/plans/STATUS.md`: DB v24→**v26**、テスト 493→**734**、ローカルLLMは native FFI へ移行済み、を反映。
- `docs/ARCHITECTURE_LLM.md` **新規**: 推論経路（FFI＋ワーカー Isolate／二 FlutterEngine 同一PID／arbiter 直列化）、
  KV リセット、chunk map-reduce、Q4_0（NPU 要求）、ADSP_LIBRARY_PATH、画面スリープ・dataSync 6h 上限・
  充電/Wi-Fi/発熱ゲート、F2 の手動/自動同一検証。
- `README.md`: 実態に即した「端末内AI小説要約」セクションを追記（llamadart 記述は元々 README に無く、
  実装は native FFI に移行済みのため正しい記述に）。
- `docs/plans/12-local-llm-runtime-gate.md`（llamadart 計画書）冒頭に**陳腐化注記**を追記（実装は native FFI）。

---

## 発見したが未修正のバグ／懸念（B2 ロジック変更禁止に抵触するため記録のみ）

1. **task2 のコミット混入（上記）**: 履歴は正当なコードで緑だが、コミット粒度が任務単位になっていない。
   ロールバック禁止のため現状維持。次回以降は対象ファイルを明示 add（task3〜5 は実施済み）。
2. **例外メッセージ内の `response.body`**: API 生 JSON が UI スナックバーに出うる（ログは修正済だが throw は未変更）。
   要約化は設計判断を要するため RELEASE_CHECKLIST §5 に遺した。
3. **実機検証未完了（B2-6）**: 自動要約の E2E（FGS 発火→READY→推論→永続化→再開）はデバイス不在で未確認。
   SMOKE_PREP.md のチェックリストをユーザーが実機で実施すること。

## ユーザーaction（実機でしかできない残作業）

- 端末を USB/無線接続 → `adb devices` で認識確認 → SMOKE_PREP.md の手順で install/launch。
- 「今すぐ実行」はadb単独発火不可のため、**設定画面のトグル＋「今すぐ実行」を手でタップ**して発火。
- logcat で `[AutoSummaryTask]`/`[FgsLifecycle]`/`[LlmRunArbiter]` を確認（PID 同居・READY・直列化の目視）。
- 実機推論は ≤20分・5作品以内のゲートを守る（ルール）。

## 所要時間

本セッション（08:05 UTC 着手〜08:28 UTC レポート）= 約23分。
（前セッションからの B2-4+5 完了分を含む全体でも 6h 上限内。）
