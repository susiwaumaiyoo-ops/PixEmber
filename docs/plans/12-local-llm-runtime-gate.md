# PixEmber Phase L「ローカルLLMランタイム（llamadart）運用ゲート」

> 目的: 小説AI要約PoCのローカルLLMランタイムを `llamadart` に固定した運用手順
> （ビルド・モデル配置・制約・トラブルシュート）を定める。
> ランタイム差し替え: `llm_llamacpp 0.4.0` → `llamadart 0.8.22`（2026-09）。
> 移行理由: llm_llamacpp は Windows ビルド時に `unzip` バイナリ依存があり、
> llamadart は native assets（code_assets）方式でランタイムを自動取得・展開するため
> 外部依存なし。全プラットフォーム（Android / iOS / macOS / Windows / Linux / Web）対応。

---

## 1. ランタイム構成（llamadart 0.8.22）

- パッケージ: `llamadart: ^0.8.22`（MIT）。純Dartパッケージ + build hook。
  Flutter プラグインではない（`flutter: plugin` マニフェストなし）。
- 形式ルーティング:
  - `*.gguf` → llama.cpp（`NativeLlamaBackend`、worker isolate 内で FFI）
  - `*.litertlm` → LiteRT-LM（本PoCは非使用）
- native assets:
  - build hook（`hook/build.dart`）が初回ビルド時に
    GitHub（`leehack/llamadart-native` v0.3.0）からプラットフォーム別
    `.tar.gz` バンドルをダウンロードし、**Dart 側 `package:archive` で展開**。
    `unzip` バイナリ・Gradle/CMake 手動設定は一切不要。
  - バンドル対象: android-arm64 / android-x64 / ios-arm64 / ios-arm64-sim /
    linux-arm64 / linux-x64 / macos-arm64 / macos-x86_64 / windows-x64 /
    windows-arm64（llama.cpp v0.3.0 相当）。
  - バンドルキャッシュ（ダウンロード tar.gz + 展開先）は **pub cache の
     llamadart パッケージ配下**（hook の package_root）:
     `%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev\llamadart-0.8.22\.dart_tool\llamadart\native_bundles\v0.3.0\<platform>\`
     （LiteRT-LM は同配下 `litert_lm/<tag>/<os>/<arch>`）。プロジェクトの
     `.dart_tool` ではない点に注意。再ビルドはキャッシュを再利用。
- 推論モデル:
  - `LlamaEngine(LlamaBackend())` → `loadModel(path, modelParams:)` →
    `create(messages, params:)`（`Stream<LlamaCompletionChunk>`）→ `dispose()`。
  - チャットテンプレート（Jinja）は GGUF metadata から自動検出・適用。
  - キャンセル: ストリーム購読破棄が共有メモリ cancel token に伝播し、
    worker isolate が次のトークン境界でデコード停止（実キャンセル）。
  - 同時生成は 1 件のみ（2 件目以降は StateError）。

## 2. アプリ側ラッパー

- `lib/services/local_llm_service.dart`
  - `LlmInferenceEngine` 抽象（loadModel / generate / dispose）。
    テストは fake 差し替え（`test/local_llm_summary_test.dart`）。
  - `LlamaDartEngine`: 本番実装。`ModelParams(contextSize: 8192, gpuLayers: 0)`
    （CPU のみ・旧ランタイムの nGpuLayers=0 と同等の保守挙動。
    GPU オフロードは `gpuLayers` を上げるだけで有効化可能）。
  - `LocalLlmService`: 状態機械 idle/loading/generating/done/error。
    `loadModel` はファイル検証後に**実際のモデルロード**まで await
    （worker isolate 実行のため UI はブロックしない）。
  - サンプリング: `GenerationParams(temp: 0.2, topP: 0.9, maxTokens: 1024)`。
- `lib/services/llm_summary_service.dart`: プロンプト構築・2000字截断・
  3セクション解析・拒否検知（ランタイム非依存）。

## 3. ビルド手順

```bash
flutter pub get
# 初回のみ: build hook が llama.cpp ランタイムを自動取得（要ネット）
flutter build apk --debug        # Android（arm64-v8a / x86_64）
flutter build windows --debug    # Windows（x64 / arm64）
```

- Android: `minSdk = flutter.minSdkVersion`（Flutter 3.47 で 24）でよい。
  llamadart はプラグインではないため minSdk 制約を付与しない。
  （llm_llamacpp 時代の minSdk 28 は不要化・元に戻済み。）
- Windows: llamadart 自体は `unzip` 依存なし（旧 shim `C:\Users\you10\bin\unzip.exe` は
  本 PoC では不要）。
  **ただし** 既存依存 `flutter_tts` の Windows CMake が PATH 上の `nuget.exe` を
  要求するため、`nuget.exe`（`https://dist.nuget.org/win-x86-commandline/latest/nuget.exe`）
  を `C:\Users\you10\.local\bin\` に配置済み。llamadart とは無関係の既存要件。
  また、過去の失敗 configure が `CMAKE_INSTALL_PREFIX` を CMake キャッシュに残すと
  install 段階が `C:\Program Files` を書き先にしてアクセス拒否になるため、
  その場合は `build\windows\x64` を削除して再ビルド（2026-09-06 に実際発生・解消）。
- 既知の注意:
  - ランタイム取得にネット接続が必要（初回）。windows-x64 バンドルは約 698.5MB
    （llama.cpp + CUDA/Vulkan DLL）で初回ビルド/テストは長時間になる。
    先に上記キャッシュ配下へ入手しておくと再ビルドが高速化。
  - `flutter test` でも host（windows-x64）バンドルの hook が走るため
    初回はダウンロードが発生する。

## 4. GGUF モデル配置手順（手動・自動DLなし）

1. モデルファイル（例: Qwen3-0.6B / Gemma-2-2b の Q4_K_M 等、数百MB以下推奨）を
   入手（Hugging Face の `*-GGUF` レポなど）。
2. 端末内の app documents に `models/llm/` を作成し GGUF を配置:
   - `adb push model.gguf /sdcard/Android/data/com.example.pixiv_viewer/files/models/llm/`
   - `adb shell mkdir -p /sdcard/Android/data/com.example.pixiv_viewer/files/models/llm`
3. 設定画面「AI要約（実験）モデル」:
   - 既定ディレクトリに GGUF が 1 個なら自動採用、複数なら手動選択。
   - 選択は SharedPreferences（キー `llm_summary_model_path`）に絶対パス保存。
   - **「モデルをインポート」ボタン（2026-09 追加）**: SAF ピッカー
     （file_picker 8.1.2, `allowedExtensions: ['gguf']`）で端末内の
     `.gguf` を選択 → アプリ内部ディレクトリへ実コピー → 自動選択・保存。
     - 背景: Scoped Storage 環境では `/sdcard/Download` 等の外部パスを
       llama.cpp の `fopen` が直接読めず「Model file does not appear
       to be GGUF」エラーになるため、Dart 側で内部ストレージへコピーする
       ことが必須（SAF なのでストレージ権限は不要）。
     - 実装: `lib/services/llm_model_import_service.dart`
       （GGUF マジック検証 / 4MB チャンクコピー + 進捗・キャンセル /
       `.part` + rename で原子性 / 同名同サイズは再利用）。
     - ビルド注記: file_picker の依存 `flutter_plugin_android_lifecycle
       2.0.35` が compileSdk 36 を要求するため、アプリ側 compileSdk=36 と
       全プラグインの compileSdk 揚げを `android/build.gradle.kts` で実施。
4. 小説詳細画面で「AI要約（実験）」ボタンが出現すれば準備完了。

## 5. 制約・注意点

- 同時生成は 1 件（要約シートを開いている間は別生成不可）。
- `engine.create` の `enableThinking` はデフォルト true。非思考モデルでは
  無害。思考系テンプレートのモデルでは thinking が
  `delta.thinking` に分離されるため content には混入しない。
- Android の GPU オフロード（Vulkan 等）は `ModelParams.gpuLayers` を
  999 相当に上げると有効だが、PoC 段階では CPU（0）を維持。
- 本PoCのプラットフォームゲートは Android のみ
  （`LlmModelPaths.isSupportedPlatform`）。llamadart 自体は
  Windows/iOS 等も動くため、将来的にゲート開放は 1 行変更で可能。
- モデル自動ダウンロードは実装しない（手動配置前提・既存方針）。
- GGUF は Git 管理しない（既存方針）。
- 生成ログにモデル出力全文・本文全文を記録しない（PoC は debugPrint しない設計）。

## 6. llm_llamacpp からの差分（移行記録）

| 項目 | llm_llamacpp 0.4.0 | llamadart 0.8.22 |
|---|---|---|
| 形態 | Flutter プラグイン + hook | 純Dart + hook（code_assets） |
| minSdk | 28 必須 | 制約なし（flutter.minSdkVersion=24 で可） |
| Windows | unzip バイナリ必須（shim 設置） | 不要 |
| モデルロード | 初回 generate 時に推論 isolate 内で遅延 | `loadModel` で即ロード（worker isolate） |
| キャンセル | UI 停止のみ（ネイティブは完走） | 実キャンセル（token 境界で停止） |
| テンプレート | llama_chat_apply_template | Jinja（metadata 自動検出） |
| ストリーム型 | `LLMChunk.message.content` | `LlamaCompletionChunk.choices[0].delta.content` |
| 依存制約 | — | `archive ^4.0.7` 必須（3.3.7→4.2.0 に更新） |

`archive` 4.x 対応: `ArchiveFile.content` が `Uint8List` に型付き化したため
`ugoira_frame_service.dart` / `ugoira_player.dart` の不要キャストを削除。

## 7. ゲート（承認条件）

- [x] `flutter analyze` クリーン（2026-09-06 再確認: No issues found）
- [x] `flutter test` 全件パス（556 件・0 失敗、2026-09-06 実測）
- [x] `flutter build apk --debug` 成功（llamadart バンドル同梱・app-debug.apk 454MB、2026-09-06 実測）
- [x] `flutter build windows --debug` 成功（unzip 不要確認・212.6s、2026-09-06 実測）
- [ ] 実機確認: GGUF 配置 → 設定 → 詳細画面の要約生成（ストリーミング/キャンセル/再試行）