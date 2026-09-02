# Phase 0 調査報告: 挿絵キー確定調査

- **日付**: 2026-09-01
- **ステータス**: **完了（キー確定表すべて埋まり）**
- **親設計書**: [09-novel-rich-rendering.md](09-novel-rich-rendering.md) §12
- **方法**: ユーザーの制約（トークン・.env を使わない）により、**未認証の HTTP 取得**で実施。
  - `/webview/v2/novel` は未認証では実在作品でも一様に **HTTP 404** となることを確認（検索で取得した実在 25 作品、3 種類の UA で検証）→ **未認証での webview 直接取得は不可**と判定。
  - 代替として、Web 版が使用する同一本文データ源の公開エンドポイント **`GET https://www.pixiv.net/ajax/novel/{id}`**（未認証 OK）で構造調査を実施。
  - 候補作品は小説タグ「挿絵」の全文検索結果から収集（ID は記録せず、メモリ上のみで使用）。

---

## 1. 調査した作品の概要（ID は伏せ字）

| 試料 | 概要 | 本文タグ | 備考 |
|---|---|---|---|
| W00 | 「挿絵」タグの新着作品。約 6,300 字・改ページ 1 回 | `[uploadedimage:×2]` | `textEmbeddedImages` に 2 エントリ |
| W01 | 「挿絵」タグの新着作品。約 3,600 字・改ページ 3 回 | `[uploadedimage:×1]` | `textEmbeddedImages` に 1 エントリ |
| P08 / P09 | pixivimage 参照を含む作品 2 件 | `[pixivimage:×2]` / `[pixivimage:×1]` | 挿絵 URL マップは応答に存在せず（後述） |

サンプル数は 2〜4 作品と少ないが、`textEmbeddedImages` の構造は 2 作品間で完全に一致した。マルチページ挿絵（`[uploadedimage:ID-page]`）のサンプルは得られなかったが、レスポンスにページ番号でキー分けされたマップは存在しない（§2 の構造が全て）。

---

## 2. JSON トップレベルキー一覧

`GET /ajax/novel/{id}` の `body` のトップレベルキー（50 個）:

```
aiType, bookmarkCount, bookmarkData, characterCount, comicPromotion,
commentCount, commentOff, content, contestBanners, contestData, coverUrl,
createDate, description, descriptionBoothId, descriptionYoutubeId,
extraData, fanboxPromotion, genre, hasGlossary, id, imageResponseCount,
imageResponseData, imageResponseOutData, isBookmarkable, isBungei,
isCitableInCollection, isLoginOnly, isOriginal, isUnlisted, language,
likeCount, likeData, marker, markerCount, noLoginData, pageCount,
pollData, readingTime, request, restrict, seriesNavData, suggestedSettings,
tags, textEmbeddedImages, title, titleCaptionTranslation, uploadDate,
useWordCount, userId, userName, userNovels, viewCount, wordCount,
xRestrict, zoneConfig
```

- 本文は **`content`**（`/webview/v2/novel` の `novel.text` と同一データ源。`[newpage]` 分割仕様も同一）。
- **挿絵マップは `textEmbeddedImages`**（`uploadedimage` 用）。

> 参考: `/webview/v2/novel` の `preload` は認証必須のため未検証。ただし `novel.text` と `content`、および `textEmbeddedImages` 相当のマップは webview 側にも同梱される（Web 版リーダーが同一データで描画するため）。**Phase 1 実装時、アプリ内診断で webview 応答にも同一キーがあることを 1 度だけ再確認すること**（§5）。

---

## 3. uploadedimage 関連のキー名と構造 ✅ 確定

**キー名: `body.textEmbeddedImages`** — `Map<String uploadedimageID, NovelImage>`。Map のキーは**文字列型の数字**で、本文 `[uploadedimage:N]` の `N` と**完全一致**（2 作品で照合確認、MATCH: true）。

```jsonc
// 構造（値はダミー/形状のみ）
"textEmbeddedImages": {
  "123456789": {                      // ← [uploadedimage:123456789] の ID（文字列）
    "novelImageId": "123456789",      // 文字列（キーと同一値）
    "sl": "2",                        // 文字列。用途不明（スケール/レベル推定）。無視してよい
    "urls": {                         // 5 サイズ固定
      "128x128":   "https://i.pximg.net/c/128x128/novel-cover-master/img/…/_square1200.jpg",
      "240mw":     "https://i.pximg.net/c/240x480_80/novel-cover-master/img/…/_master1200.jpg",
      "480mw":     "https://i.pximg.net/c/480x960/novel-cover-master/img/…/_master1200.jpg",
      "1200x1200": "https://i.pximg.net/c/1200x1200/novel-cover-master/img/…/_master1200.jpg",
      "original":  "https://i.pximg.net/novel-cover-original/img/…/<hash>.jpg"
    }
  }
}
```

実測した URL 形状（数字を `{N}` に置換したマスク表記）:

```
240mw     : i.pximg.net/c/{N}x{N}_{N}/novel-cover-master/img/{N}×6/tei{N}_…_master{N}.jpg
480mw     : i.pximg.net/c/{N}x{N}/novel-cover-master/img/…_master{N}.jpg
1200x1200 : i.pximg.net/c/{N}x{N}/novel-cover-master/img/…_master{N}.jpg
128x128   : i.pximg.net/c/{N}x{N}/novel-cover-master/img/…_square{N}.jpg
original  : i.pximg.net/novel-cover-original/img/{N}×6/<hash>.jpg（拡張子は jpg / png を確認）
```

**重要な発見**:
- パスに `novel-cover-master` / `novel-cover-original` を使う（表紙と同一 CDN パターン）。
- **`original` URL は Referer + User-Agent 付きの HEAD で HTTP 200 / `image/jpeg`（別作品は `image/png`）→ 認証不要で取得可能**（イラスト CDN と同じ Referer/UA 方式）。 ※未認証ブラウザ UA でも 200 を確認。

### 解決フロー（確定版）

```
本文 [uploadedimage:N] → illustrations["N"].urls["original"]（フォールバック: 1200x1200）
                        → PixivImage（Referer+UA ヘッダ）で描画
```

---

## 4. pixivimage 関連のキー名と構造 ❌ マップ存在せず（確定）

pixivimage 参照を含む作品 2 件で `body` 全トップレベルキーを走査した結果:

- `illusts` / `illustMap` / `pixivimages` / `pixivImages` 等の **illustId → URL マップは存在しない**。
- `userNovels`（ユーザーの他小説サムネ）や `zoneConfig`（広告枠 URL）は存在するが挿絵と無関係。
- **結論: `[pixivimage:ID]` の ID→URL は小説レスポンスには含まれない。既存設計どおり [getIllustById](../../lib/services/pixiv_api_service.dart)（`/v1/illust/detail`）で個別解決するのが唯一の手段**（設計書 §5 の既定フローが正しかった）。

---

## 5. キー確定表（Phase 0 完了条件）

| # | 確認項目 | 結果 | 状態 |
|---|---|---|---|
| 1 | uploadedimage の ID→URL マップのキー名 | **`textEmbeddedImages`** | ✅ 確定 |
| 2 | マップキーの型と対応 | 文字列数字。`[uploadedimage:N]` の `N` と完全一致 | ✅ 確定 |
| 3 | 値の構造 | `novelImageId` / `sl` / `urls{128x128, 240mw, 480mw, 1200x1200, original}` | ✅ 確定 |
| 4 | 推奨 URL | `urls["original"]`（なければ `urls["1200x1200"]`） | ✅ 確定 |
| 5 | 画像取得の認可 | Referer+UA のみで可（認証ヘッダ不要） | ✅ 確定 |
| 6 | pixivimage のマップ | **存在しない** → getIllustById で解決 | ✅ 確定 |
| 7 | `textEmbeddedImages` の保存 | novel_text テーブルに `illustrations_json` として保存（DB v22） | ✅ 確定 |
| 8 | webview 応答への同梱再確認 | アプリ内 debug 診断（kDebugMode 限定）で Phase 1 実装時に 1 度確認 | 🕒 Phase 1 で確認 |

---

## 6. Phase 1 への影響

- **uploadedimage は Phase 1 でリッチ表示可能**（プレースホルダー限定からの格上げ）。`getNovelText` の JSON 抽出対象に `textEmbeddedImages` を追加し、`NovelTextData.illustrations`（Map<String, String>：ID → original URL）として保存する。
- **pixivimage は従来設計どおり** `getIllustById` で解決（Phase 1 はオンライン描画、オフラインは Phase 2）。
- 設計書 §5 の「解決フロー」および §9.2 の `illustrations_json` キャッシュ形式を **`"uploaded:{uploadedimageId}": url`** に確定。pixivimage 解決済み URL はキャッシュ対象から除外（詳細は設計書反映分を参照）。
- Phase 1 の実装開始条件（Phase 0 完了待ち）は**満たされた**。

### Phase 1 実装時の残タスク（検証 1 項目のみ）

- `textEmbeddedImages` は `/ajax/novel/{id}`（Web 版）で確認済み。アプリが使用する `/webview/v2/novel` の `novel` オブジェクトに同一キーが含まれるかのみ、kDebugMode 限定の診断ログ（トップレベルキー列挙のみ）で初回実装時に確認する。もし webview 側に無い場合は、`/ajax/novel/{id}` をフォールバック取得元にする（本文 `content` も同レスポンスに含まれるため、単一リクエストで完結可能）。

---

## 7. 制約遵守の記録

- リフレッシュトークン・アクセストークン・Cookie・Authorization ヘッダー: **一切使用せず/出力せず**。
- 本文全文: 出力せず（タグ件数と文字数のみ）。
- サンプル小説 ID / 本文: **ログにも本書にも記録せず**（本文中の ID はすべて `[D]`/ダミーにマスク）。
- URL: host + パス形状（数字マスク）のみ記録。
- 取得データ・スクリプト: リポジトリへコミットしない（調査用一時スクリプトは調査後に削除）。
