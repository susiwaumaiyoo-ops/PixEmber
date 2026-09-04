# B6 ブロック記録: AIモデルDLのバックグラウンド継続＋通知

## 結論
**スキップ（方針5: 新規パッケージ必須のため追加せず報告）**

## 調査事実
- モデルDL: `RuriModelManager.download()` → `downloadModel()`
  （`lib/services/ruri_model_manager.dart:334`）。
- 進捗は `onProgress(ValueNotifier<int>)` コールバックで画面Stateの `setState` に直結
  （`lib/screens/feeling_discovery_screen.dart:186`）。
- `pubspec.yaml` に導入されている依存:
  - `workmanager: ^0.10.9`（画像DL用バックグラウンドタスク）のみ。
  - **OS通知パッケージ（`flutter_local_notifications` 等）は存在しない。**

## 方針5への適合
- 「通知」を実現するには `flutter_local_notifications`（または同等）の新規追加が必須。
- ガイドライン「新規パッケージが必須なら追加せず理由を報告してスキップ」に従い、今回は実装しない。

## 現状で満たされている部分
- `download()` は非同期HTTPダウンロードのため、詳細/他画面へ push しても
  ダウンロード自体はバックグラウンドで継続する（画面 dispose 後は進捗表示のみ停止）。
- つまり「画面を離れてもDLが継続する」は事実上既に達成済み。

## 今後の実装候補（承認された場合）
1. `flutter_local_notifications` を `pubspec.yaml` に追加。
2. `RuriModelManager` に通知チャンネル初期化と進捗/完了/失敗通知を組み込む。
3. `workmanager` 経由の真正バックグラウンド化（アプリ終了後も継続）を
   `DownloadService` の既存パターンを参考に実装。
