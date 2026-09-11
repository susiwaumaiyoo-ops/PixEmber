# ローカルLLM アーキテクチャ（作業5）

最終更新: 2026-09-11（留守中バッチ／作業5）

本アプリのローカルAI小説要約（手動シート ＋ Phase 9-B 自動要約）の推論経路と制約を記録する。
**全て端末内処理。推論のためのネットワーク送信は行わない。**

---

## 1. 推論経路（native FFI）

```
UI isolate（FlutterEngine）
   └─ LlmSummarySheet / AutoSummaryService
        └─ LlmRunArbiter（推論の単一オーナー・直列化）
             └─ LocalLlmService（セッション/モデル切替・状態機械）
                  └─ NativeLlmEngine（Dart FFI + ワーカー Isolate）
                       └─ libnative_llm.so（llama.cpp C API ラッパ）
                            ├─ libllama.so / libggml*.so（jniLibs/arm64-v8a）
                            └─ NPU: libggml-htp-v*.so / libggml-hexagon.so
```

- `libnative_llm.so` は `android/app/src/main/cpp/native_llm.c`（llama.cpp の C API を薄くラップ）。
- Dart 側は [`native_llm_bindings.dart`](../lib/services/native_llm_bindings.dart)（`dart:ffi` 構造体/シンボル）と
  [`native_llm_engine.dart`](../lib/services/native_llm_engine.dart)。
- **重い推論は専用ワーカー Isolate 上で回す**（`_workerMain` / `SendPort`）。UI スレッドをブロックしない。
- 旧 `llamadart` / `llm_llamacpp` は**不使用**（移行の経緯は [`docs/plans/12-local-llm-runtime-gate.md`](plans/12-local-llm-runtime-gate.md) に歴史として残存）。

### 二つの FlutterEngine（UI と FGS）
- 自動要約はフォアグラウンドサービス（`flutter_foreground_task`）で走る。
- UI 側 `FlutterEngine` と FGS の `TaskHandler` 用 `FlutterEngine` は**同一プロセス・別エンジン**
  （`AndroidManifest.xml` に `android:process` 指定なし＝同一 PID に同居）。
- 両者の疎通は Map のみ通る `sendDataToTask` / `sendDataToMain` / `addTaskDataCallback` を使用。
- FGS 側のエンジンでも `GeneratedPluginRegistrant` と `NativeLlmChannel` を `onEngineCreate` で手動登録する
  （[`SMOKE_PREP.md`](auto_summary/SMOKE_PREP.md) 参照）。
- **仲裁**: `LlmRunArbiter` が `LocalLlmService` の単一オーナーとして手動要約と自動要約を直列化し、
requestId 重複を排除、手動優先でキューをドレインする（`scheduleMicrotask` で再帰回避）。

## 2. KV キャッシュ・リセット

- プロンプト構築は `LlmSummaryService.buildPrompt` / `buildPromptFromText`。
- 会話をまたいだ KV の混入を避けるため、作品単位・パス単位でリセットを伴って生成する
  （`_ResetTrackingEngine` 相当の挙動をテストで担保）。
- モデル切り替え時は `_disposeOwnEngine` でセッションを破棄し、別キー（modelPath×runtime settings）で再ロード。

## 3. 長文チャンク（map-reduce）

- 本文が長い場合は [`llm_chunking.dart`](../lib/services/llm_chunking.dart) の `LlmChunker.split` で文・段落単位に分割。
- **Map**: 各チャンクを [`llm_summary_service.dart`](../lib/services/llm_summary_service.dart) の `_mapChunk` で要点化。
- **Reduce**: `_runFinalPass` で要点群を統合し最終要約を生成（`LlmProcessingMode` で chunk / map-reduce を切り替え）。
- 進捗は `chunkCurrent / chunkTotal` を snapshot に載せ、進捗画面・通知で同一スナップショットを表示。
- 過剰コピー検出: `calculateNgramOverlap` / `isExcessiveCopy` で原文複写を警戒。

## 4. モデル形式・量子化の要件

- GGUF 形式必須。マジック検証は `LlmModelImportService.hasGgufMagic`。
- **NPU（Hexagon HTP）を利用する場合、Q4_0 を要求する**。それ以外の量子化は NPU 非対応のため
  `npuCompatibleForQuant` で判定し CPU へフォールバック／警告（`_showNpuWarning`）。
- モデルはカタログ DL（`assets/llm_models.json`）またはピッカー取り込みで導入。
- 完全ハッシュ検証（SHA-256）は `RuriModelManager` 側が担い、結果を prefs にキャッシュして再検証を省略。

## 5. NPU 実行環境（ADSP_LIBRARY_PATH）

- HTP（Hexagon）実行時、DSP 側ライブラリ探索に `ADSP_LIBRARY_PATH` が必要。
- `.so` は `nativeLibraryDir` 直下に展開済み（`libggml-hexagon.so` / `libggml-htp-v*.so`）。
- Dart 側は `NativeLlmEngine._libDir()` でネイティブライブラリディレクトリを解決し子プロセス／DL に渡す。
- 実機未検証の項目（HTP 起動可否等）は [`SMOKE_PREP.md`](auto_summary/SMOKE_PREP.md) のチェックリストに遺した。

## 6. 画面スリープ・電力

- FGS は `dataSync` 系 foreground service type を使用。
  **Android 14 以降、`dataSync` は約6時間上限**（超過でシステムがサービス停止）。自動要約は
  この上限を前提に、中断・再開・永続化（`AutoSummaryRepository`）で耐える設計。
- 自動要約は **充電中 + Wi-Fi + 発熱なし** を条件に待機・実行する
  （`AutoSummaryWaitReason.power / wifi / temperature`）。条件を失えば生成せず待機。
- screen-off 時も FGS で継続するが、推論は電力・発熱ゲートで抑制される。

## 7. 手動と自動の同一有効性判定（F2）

- 要約キャッシュ `llm_summaries` の有効性は `work_id × model_id × prompt_version × source_fingerprint
  × model_file_hash` で判定する。
- `model_file_hash` は `LlmSummaryCacheService.computeModelFileHash`
  （`SHA256(basename:size:mtime)`、失敗時 `SHA256(path)`）。ファイル差し替えで旧キャッシュを誤 HIT させない。
- 手動シート（`_startLocal` / `_startViaFgs`）と自動（`auto_summary_real_ports.dart` の `isCachedValid`）で
  **同一の検証経路**を通す（作業2で統一）。

---

関連: 状態機械は [`docs/auto_summary/STATE.md`](auto_summary/STATE.md)、実機スモーク手順は
[`docs/auto_summary/SMOKE_PREP.md`](auto_summary/SMOKE_PREP.md)。
