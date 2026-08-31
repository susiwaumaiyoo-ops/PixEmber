# PixEmber

> **A beautiful, standalone, and high-performance Pixiv client for Android, Desktop, and Web.**
> 美しく、自立型で、高性能なPixivクライアント。Android・デスクトップ・Webに対応。

PixEmber（ピクス・エンバー）は、pixivをもっと快適に楽しむための非公式・スタンドアローンなクライアントです。
アプリ内蔵WebViewによる全自動ログイン、Isolateを活用した軽快なスクロール、
本物の電子書籍のような文庫本風小説リーダー、そして滑らかな全画面ズームビューアを備えています。

PixEmber is a standalone, unofficial client that lets you enjoy pixiv more comfortably.
It features in-app WebView automated login, jank-free scrolling powered by isolates,
a book-style novel reader with real furigana (ruby) rendering, and a silky-smooth
fullscreen image viewer.

---

## ✨ Features / 主な機能

- **Fully Automated Login (全自動ログイン)**
  - Log in instantly with just a tap — no copy-pasting tokens required. The in-app WebView handles browser-based authentication seamlessly.
  - アプリ内WebViewにより、トークンのコピペ不要でブラウザ連携をタップするだけ。一瞬で認証完了します。

- **Ultra-Smooth Scrolling (極めて軽快なUI)**
  - Background parsing via `Isolate.run()` (Dart 2.19+) completely eliminates scroll jank.
  - Dart 2.19+ の `Isolate.run()` によるバックグラウンドパース処理により、スクロールの引っかかり（Jank）を100%排除。

- **Book-Style Novel Reader (文庫本風小説リーダー)**
  - Real e-book style ruby (furigana) rendering, adjustable left/right margins, free bookmark deletion, automatic series navigation, and an on-screen HUD (progress) display.
  - 本物の電子書籍のようなルビ（ふりがな）表示、左右の余白を個別に調整できるマージン設定、しおりの自由削除、シリーズ自動ナビゲーション、HUD（進捗）表示。

- **Fullscreen Image Viewer (イラスト全画面ズーム)**
  - Smooth pinch-in / pinch-out / zoom powered by `InteractiveViewer`.
  - `InteractiveViewer` による滑らかなピンチイン・アウト・ズーム。

- **Safe Local Management (安全なローカル管理)**
  - History, mutes (tags / users / AI-detection), and favorite folders stored in a local SQLite database.
  - 履歴、ミュート（タグ・ユーザー・AI判定）、お気に入りフォルダをローカルSQLite DBで安全に管理。

- **Novel Text-to-Speech (小説読み上げ)**
  - OS-standard TTS via `flutter_tts`, with ruby/furigana normalization, sentence chunking, and a resumable reading position saved per novel.
  - OS標準のTTSエンジンによる小説読み上げ。ルビ正規化・文チャンク分割・読了位置の保存と再開に対応。

- **Reading Time Dashboard (読書・閲覧時間ダッシュボード)**
  - On-device only tracking of how long you read novels / browse illustrations, with daily charts, per-type totals, and a one-tap privacy delete. Never leaves your device and is excluded from Google Drive backups.
  - 小説の読書時間とイラストの閲覧時間を端末内のみで記録し、日別グラフ・種別集計を表示。プライバシー削除ボタン付きで、データは端末外へ送信されず Drive バックアップ対象外です。

- **Visual Similar Search (視覚類似検索)**
  - Find visually similar works among your downloaded images using on-device feature vectors (pluggable encoder design — a classical color-grid encoder is used until a real model is integrated).
  - ダウンロード済み画像から視覚的に似た作品を探すオンデバイス検索。エンコーダは差し替え可能設計（実モデル導入までは古典的色グリッド特徴量）。

- **Duplicate Detection (重複画像の検出)**
  - SHA-256 exact-duplicate and dHash near-duplicate detection with interruptible scanning. Deletion always requires per-image confirmation — nothing is ever removed automatically.
  - SHA-256 による完全一致と dHash による近似重複の検出。スキャンは中断可能で、削除は画像ごとの確認必須（自動削除は一切行いません）。

- **Cloud Sync (クラウド同期)**
  - Automatic backup of your data to Google Drive.
  - データをGoogle Driveへ自動バックアップ。

---

## 📥 Download / ダウンロード

Grab the latest release APK from the **[Releases](../../releases)** page.
最新のリリースAPKは **[Releases](../../releases)** ページからダウンロードしてください。

1. Open the [Releases](../../releases) page.
2. Download the latest `app-release.apk`.
3. Install it on your Android device (you may need to allow "Install from unknown sources").

1. [Releases](../../releases) ページを開きます。
2. 最新の `app-release.apk` をダウンロードします。
3. Android端末にインストールします（「提供元不明のアプリ」を許可する必要がある場合があります）。

---

## 🛠 Build from Source / 開発者向けビルド手順

### Prerequisites / 前提条件

- [Flutter SDK](https://flutter.dev/docs/get-started/install) (stable channel, 3.x)
- Dart SDK (bundled with Flutter)
- Android SDK (for Android builds)
- A Pixiv account

### Steps / 手順

```bash
# 1. Clone the repository / リポジトリをクローン
git clone https://github.com/your-username/pixember.git
cd pixember

# 2. Install dependencies / 依存関係をインストール
flutter pub get

# 3. Run on an emulator or device / エミュレータまたは実機で実行
flutter run

# 4. Build a release APK / リリースAPKをビルド
flutter build apk --release
# The output APK is located at: /build/app/outputs/flutter-apk/app-release.apk
```

For Desktop (Windows / Linux / macOS):
デスクトップ（Windows / Linux / macOS）向けには以下を実行します。

```bash
flutter build windows   # or: linux / macos
```

For Web:
Web向けには以下を実行します。

```bash
flutter build web
```

---

## ⚠️ Disclaimer / 免責事項

> **ENGLISH**
>
> This software is an **unofficial client** developed for **personal use, educational, and research purposes**. It has **no affiliation** with pixiv Inc. or the official pixiv service. The developer **assumes no responsibility whatsoever** for any account restrictions (including BANs) or other consequences arising from the use of this tool. Use it **at your own risk**.
>
> **日本語**
>
> 本ソフトウェアは個人利用および教育・研究目的で開発された**非公式クライアント**です。Pixiv公式とは**一切関係ありません**。本ツールを使用したことによるアカウント制限（BAN）等について、開発者は**一切の責任を負いません**。**自己責任でご利用ください。**

---

## 📄 License / ライセンス

This project is provided for personal, educational, and research use. Please respect pixiv's Terms of Service.
本プロジェクトは個人・教育・研究利用のために提供されています。pixivの利用規約を遵守してください。

---

<p align="center">
  Made with ❤️ for the pixiv community · PixEmber
</p>
