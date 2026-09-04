# B6: AIモデルDLのバックグラウンド継続＋通知

## ステータス
**再オープン・解決済み（Reopened / Resolved）**

## 誤った結論の訂正
前回の調査では「OS通知には `flutter_local_notifications` が必須」としてスキップしたが、
これは**誤り**。workmanager `0.10.9` は `ForegroundServiceConfig` ＋ `reportProgress` /
`setProgressListener` のみで FGS 通知・進捗表示を実現可能。新規パッケージは不要。

## 実装内容（workmanager のみ・新規依存ゼロ）
- `lib/services/model_download_coordinator.dart`: アプリ全体単一インスタンス、
  modelId ごと single-flight、状態機械（idle/queued/downloading/verifying/completed/
  failed/cancelled）、SharedPreferences への進捗永続（2% 単位）。
- Android: `Workmanager().registerOneOffTask` ＋ `ForegroundServiceConfig(
  foregroundServiceType: dataSync)` で真正バックグラウンド継続。
- 非 Android: フォアグラウンドDL継続（workmanager Android API は呼ばない）。
- `main.dart` の `callbackDispatcher` にモデルDLタスク分岐を追加、
  `setProgressListener` でアプリ側へ進捗反映、Android 13+ は `POST_NOTIFICATIONS`
  を `permission_handler` で要求。
- `android/gradle.properties`: `workmanager.enableDataSyncForegroundService=true` を追加。
- 通知本文にモデルURLや個人情報は含めない。

## 検証
- `dart format` / `flutter analyze`: 通過（No issues）。
- `test/model_download_coordinator_test.dart`: フェイク単体テスト追加
  （single-flight、状態遷移、進捗永続/復元、SHA失敗、キャンセル、taskName分岐、
  inputData欠損安全失敗、非Androidはバックグラウンド登録しない）。

## 備考
- 過去の「スキップ」は調査不足による誤判定。再オープンして正しく実装完了。
