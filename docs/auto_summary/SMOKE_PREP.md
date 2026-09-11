# SMOKE_PREP — 実機スモークの下準備（作業1）

作成: 2026-09-11（留守中バッチ）
目的: Zoo 単独（adb のみ・ユーザー物理操作なし）で自動要約 B2-4+5 を
実機検証できる範囲を確認し、実行できない理由と残項目を明確化する。

## 結論（先に）
- **実機検証は今回 実施できず。** 理由: `adb devices` が空（デバイス未接続）。
  物理デバイスが接続されていない環境では install/launch/logcat/dumpsys すべて不可。
- **自動要約の「今すぐ実行」を adb 単独で起動する手段は存在しない。**
  下記の経路調査のとおり、UI 操作や開発者トリガーなしに FGS 自動要約を開始する
  exported コンポーネント / deeplink / intent-extra 経路は実装されていない。
  → 座標 tap は禁止指示のため使用しない。よって **実推論は 0 件**（20分/5件上限のうち 0 を使用）。

## デバイス状況
```
$ adb devices
List of devices attached
(空)
```
- 接続機器なし。`adb -s <serial>` 指定対象もなし。

## Manifest から確定した事実（実機不要でコード検証できたこと）
出典: [`AndroidManifest.xml`](../../android/app/src/main/AndroidManifest.xml)

1. **Application = `.PixEmberApplication`**（android:name=.PixEmberApplication）— 全 engine 共有の起動点。
2. FGS 宣言:
   - `com.pravera.flutter_foreground_task.service.ForegroundService`（android:foregroundServiceType=dataSync, exported=false）
   - `androidx.work.impl.foreground.SystemForegroundService`（dataSync, tools:node=merge）
3. **`android:process` はどの service/activity にも未指定** → すべてアプリ既定プロセス
   （= applicationId `com.example.pixiv_viewer`）で動作する。
   → **UI FlutterEngine と FGS TaskHandler FlutterEngine は同一プロセス内の別エンジン**。
   （別プロセス分離はしていない。PID 照合でこの予測を実機確認するのが本来の狙いだった。）
4. exported な起動経路:
   - `.MainActivity` のみ exported=true。intent-filter は LAUNCHER と
     `https://www.pixiv.net` / `https://pixiv.net` の VIEW（deeplink＝作品閲覧用）だけ。
   - **自動要約を開始するための exported intent-filter / extra / action は無い。**
     FGS は Dart 側 `FlutterForegroundTask.startService()` からのみ起動される設計。

## 「今すぐ実行」adb 単独起動の手段調査
| 候補経路 | 有無 | 根拠 |
|---|---|---|
| deeplink で自動要約トリガー | ✗ | Manifest の deeplink は pixiv.net 作品表示のみ（`_showLlmSummarySheet` 等の UI 経由） |
| `am start` + intent extra で FGS 起動 | ✗ | MainActivity は extra から自動要約を開始しない。Dart 側 `ensureServiceReady()` 経由のみ |
| exported service を `am start-foreground-service` | ✗ | ForegroundService は exported=false。外部から直接起動不可（Android の FGS 開始制約でもある） |
| 開発者用トリガー（feature flag / debug only 画面） | ✗ | 該当コードなし（grep: 自動開始を adb 経由で受ける分岐なし） |
| 通知ボタン | 要実機＋要物理操作 | `adb input tap` は禁止指示のため使用しない |

→ **「手段なし」と記録。自動要約の実推論は行わない。**

## コード検証できたスタック初期化の期待挙動（実機 logcat で確認すべき項目）
出典: [`PixEmberApplication.kt`](../../android/app/src/main/kotlin/com/example/pixiv_viewer/PixEmberApplication.kt),
[`NativeLlmChannel.kt`](../../android/app/src/main/kotlin/com/example/pixiv_viewer/NativeLlmChannel.kt),
[`auto_summary_task_handler.dart`](../../lib/services/auto_summary_task_handler.dart)

FGS TaskHandler 側 FlutterEngine は `GeneratedPluginRegistrant` が自動適用されないため、
`PixEmberApplication.onEngineCreate` で手動登録している：
1. `GeneratedPluginRegistrant.registerWith(engine)` → sqflite/shared_preferences/battery_plus/connectivity_plus を背面 engine へ
2. `NativeLlmChannel.register(engine, applicationContext)` → `getNativeLibraryDir` MethodChannel を背面 engine へ

実機 logcat で次が出ることを確認する必要がある（現状ログ採取不可）：
- `[AutoSummaryTask] onStart(starter: ...)`（task_handler.dart:59）
- `onEngineCreate` が FGS 起動時に呼ばれ、上記登録が走る（クラッシュしない）
- pixiv_viewer プロセス単一（UI/FGS 同一 PID）
- NativeLlmEngine が nativeLibraryDir を解決できる（=FFI 初期化成功）

## ユーザー操作が必要な残項目（実機検証チェックリスト）
デバイス接続後、以下は物理操作が前提。B2-6（5作品・20分以内・推論合計20分以内）を遵守すること。

- [ ] `adb devices` で対象シリアル確認 → `flutter devices` でも認識されること
- [ ] `cd pixiv_viewer && flutter install`（または `adb install -r build/app/outputs/flutter-apk/app-debug.apk`）
- [ ] `adb logcat -c` 後、アプリ起動（ランチャー）→ `adb logcat` を採取へ
- [ ] 起動時クラッシュが無いこと／`onEngineCreate` 由来の例外が無いことを確認
- [ ] 設定画面で自動要約を有効化（通知権限 POST_NOTIFICATIONS を許可）
- [ ] タグを1つ登録、モデルが導入済み（または導入）であること
- [ ] 「今すぐ実行」をタップ → 以下を adb で観測（実推論は1作品で十分）：
  - [ ] FGS 起動（`dumpsys activity services com.example.pixiv_viewer` に ForegroundService / dataSync）
  - [ ] 通知表示（`dumpsys notification --noredact | findstr PixEmber`）
  - [ ] `adb shell pidof com.example.pixiv_viewer` の PID が UI/FGS で同一（Manifest android:process 未指定と整合）
  - [ ] logcat で HTP0/backend 選択、memory/KV reset、NativeLlmEngine 初期化、モデルロード回数
  - [ ] 保存完了（`llm_summaries` に該当 work_id×model_id×prompt_version×fingerprint の行）
  - [ ] 進捗ダッシュボード／状況を見る 画面で件数整合（対象=保存+処理中+待ち+失敗+スキップ）
- [ ] 一時停止／再開／終了ボタンと通知アクションが同一スナップショットを出すること
- [ ] 実行中に画面を閉じても自動バッチが停止しないこと／復帰時に同じ run へ再接続すること
- [ ] `svc power stayon true` を変更した場合、最後に必ず `svc power stayon false` で戻す

## svc power / 温度への注意
- 画面保持はアプリ側 wakelock_plus（PARTIAL）に委ね、`svc power stayon` の変更は原則不要。
  変更した場合は必ず元に戻すこと（不在バッチで触れていない＝変更不要だった）。
- 高温を実機で作ってテストしない（BRIEF 禁止事項）。1作品だけ・短時間で打ち切る。

## このファイルで「確認できたこと」／「できなかったこと」
- 確認できた（コード静的）: 同一プロセス前提／FGS dataSync 宣言／背面 engine への
  plugin+MethodChannel 手動登録設計／自動要約の adb 単独起動経路の不在。
- できなかった（要デバイス＋要物理操作）: 実推論・通知・モデルロード回数・保存・再接続の実機確認。
