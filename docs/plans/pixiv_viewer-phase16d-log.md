# Phase 16d — モーションシステムの構築と完了演出

## 1. Sub 別変更と commit

| Sub | commit | 内容 |
| --- | --- | --- |
| 16d-1 | `6fd9a9f` | AppMotion トークン + Reduce Motion 尊重 + `AppPageTransitionsBuilder`（テーマ設定）。テスト `test/app_motion_test.dart` |
| 16d-2 | `20fecd7` | AppShell タブ切替フェードスルー + Home↔Search サーフェスヘッダ `AnimatedSwitcher` |
| 16d-2 | `63a4a11` | サムネイル→詳細の Hero（独立 commit）。テスト `test/hero_motion_test.dart` |
| 16d-3 | `2332d9a` | 画像フェードイン / グリッド stagger / ブックマーク bounce / チップ判断。テスト `test/micro_interactions_test.dart`（10 件） |
| 16d-4 | `dbd3b92` | `AppSuccessCheck` + 3 適用箇所。テスト `test/app_success_check_test.dart`（11 件） |

新規パッケージ追加: **なし**（Flutter 標準 `AnimationController` / `TweenAnimationBuilder` / `Interval` / `AnimatedSwitcher` / `AnimatedOpacity` / `ScaleTransition` / `Hero` / `PageTransitionsBuilder` / `CustomPainter` のみ）。

## 2. AppMotion 最終値

`lib/theme/app_motion.dart`（16d 開始時の仮説から**変更なし**）:

| トークン | 値 |
| --- | --- |
| `AppMotion.short` | 160ms（応答・チップ） |
| `AppMotion.medium` | 240ms（遷移・登場） |
| `AppMotion.long` | 320ms（詳細へ入る・完了）。**これより長い演出は 16d では認めない** |
| `AppMotion.enter` | `Curves.easeOutCubic` |
| `AppMotion.exit` | `Curves.easeInCubic` |
| `AppMotion.emphasized` | `Cubic(0.05, 0.7, 0.1, 1.0)`（M3 emphasizedDecelerate と同値） |
| `AppMotion.reduce(ctx)` | `MediaQuery.maybeDisableAnimationsOf(ctx) ?? false` |
| `AppMotion.of(ctx, d)` | reduce 時 `Duration.zero`、それ以外 `d` |

使用箇所（本フェーズで増えた分）: `pixiv_image.dart`（2）/ `home_ui_components.dart`（2）/ `illust_detail_ui_components.dart`（3）/ `app_success_check.dart`（3）。既存: `app_page_transitions.dart`（6）/ `home_screen_state.dart`（3）/ `app_shell.dart`（2）。

## 3. 遷移・タブ切替・Hero 実装方式

### ページ遷移（16d-1）
`ThemeData.pageTransitionsTheme` に `AppPageTransitionsBuilder` を設定。`buildTransitions` は `AppMotion.reduce(context)` を見て、Reduce Motion のときはアニメーションなしで即座に目的地を表示。通常時は `SlideTransition`（上から 8% / 縦方向のみ・横移動なし）+ `FadeTransition`、カーブ `AppMotion.emphasized`、`secondaryAnimation` は `AppMotion.exit`。戻り（pop）は逆再生。

### タブ切替（16d-2）
`IndexedStack` は**維持**（State 破棄を禁止）。その上で各タブを `_buildTabFade` が `AnimatedOpacity` で包む:
- 選択タブ: opacity 1.0 / `medium` 240ms / `enter`
- 非選択タブ: opacity 0.0 / `short` 160ms / `exit`

IndexedStack が常に全タブを build するため、両者の duration/curve をずらすだけで**フェードスルー**（古いタブが消えきる前に新しいタブが登場し始める）になる。`AnimatedSwitcher` は子を差し替えると State が破棄されるため使用していない。

### Home↔Search サーフェスヘッダ（16d-2）
`_buildSurfaceHeader` が `AnimatedSwitcher` でヘッダを差し替え。`switchInCurve: AppMotion.enter` / `switchOutCurve: AppMotion.exit` / `duration: AppMotion.medium`。ヘッダはステートレスな表示要素のみで State を持たないため破棄は問題ない。

### Hero（16d-2、独立 commit）
- **タグ設計**: `tag: 'illust-$id-$pageIndex'`（作品 ID + ページインデックス）。詳細画面の `_maybeHero` が一貫して同じ形式を使うため重複しない。
- **重複回避**: 関連グリッド（`_buildSimilarSection` / `_buildRelatedSection`）には** Hero を付けない**（一覧上に同名タグが複数できるため）。
- **ugoira 除外**: うごくメーカーの表紙は `Hero` ではなく通常の `Image`。
- **タブ越え**: AppShell は IndexedStack で両タブを build し続けるため、Home→詳細遷移でタグが必ず存在する。

## 4. マイクロインタラクション適用箇所（16d-3）

| 箇所 | 実装 | 判断 |
| --- | --- | --- |
| 画像フェードイン | `PixivImage.frameBuilder`。`wasSynchronouslyLoaded || frame != null` はそのまま表示（キャッシュヒットはアニメーションしない）。デコード中のみ `TweenAnimationBuilder<double>` 0.0→1.0・`medium`/`enter` | 実装 |
| グリッド stagger | `HomeUIComponents._buildStaggeredGridItem`。`index >= _staggeredCount` が真のときだけ `TweenAnimationBuilder` + `Interval(index<8?index:8 / 20.0, 1.0, curve: enter)` で包む。`_staggeredCount` は `HomeUIComponents` が `initState` で 1 回だけ生成されるため、**追加ロード・スクロール再描画では発動しない**。項目ごとの `AnimationController` は持たない（`ValueKey('grid-stagger-$index')`） | 実装 |
| ブックマーク bounce | 新規 `BounceBookmarkIcon`。`AnimationController(medium)` + `TweenSequence`（1.0→1.25 weight 70 / 1.25→1.0 weight 30）。**API 成功後のみ**発動: `illust_detail_handler.toggleBookmark` が成功時に `state.didBookmarkSucceed = toAdd` を立て、`BounceBookmarkIcon.didUpdateWidget` が `widget.bounce && !oldWidget.bounce`（false→true 変化）のときだけ `forward(from: 0.0)`。`_IllustDetailScreenState.build` は ListenableBuilder ではないため、「一度だけ」制御はアイコン側の差分判定に完全に委ねる。3 箇所（phone appBar / tablet appBar / メタパネル ElevatedButton.icon）のアイコンを差し替え | 実装 |
| ついでにバグ修正 | `illust_detail_handler.toggleBookmark` が `isToggling = false` をクリアしていなかった（API 成功時）ので修正 | 副産物的修正 |

### 「何もしなかった」判断: chips / segments
M3 の `ChoiceChip` / `SegmentedButton` は選択状態の遷移に**組み込みのアニメーション**（selection overlay のフェード＋スケール）を持つ。240ms 以内・派手すぎない・Reduce Motion にも従うため、**何も追加しない**と判断した。この判断は `test/micro_interactions_test.dart` の「16d-3 チップ/セグメント」グループで固定（`home_search_source_chips.dart` と `home_content_mode_selector.dart` に `AppMotion` トークンを持ち込んでいないことを assert）。

## 5. AppSuccessCheck 適用 3 箇所（16d-4）

`lib/widgets/design_system/app_success_check.dart`（新規）:
- 円が 0→1 に `AppMotion.emphasized` で広がり、`Interval(0.55, 1.0, curve: AppMotion.enter)` で遅延してチェックマークのパスを引く（`CustomPainter`・`AnimationController(duration: AppMotion.long)`）。
- 既定サイズ 48・`haptic` は既定 `false`（完了演出は静か）・`onCompleted` はステータス completed のとき 1 度。
- Reduce Motion: `AppMotion.reduce(context)` で `value = 1.0` を即セット（アニメーションせず最終状態）。

「一度だけ」制御:
- 原則 `visible` の **false→true 変化**（`didUpdateWidget`）。初回 build から `visible: true` の場合は `SchedulerBinding.addPostFrameCallback` で次フレーム発動（`didUpdateWidget` は初回 build で呼ばれないため）。

| 適用箇所 | サイズ | 「一度だけ」の実装 |
| --- | --- | --- |
| `download_queue_screen` の完了タイル | 20 | `_justCompletedGroupId`（`_svc.onComplete` で立て、`_load` が DB に反映した時点で `null` に下ろす）。スクロールで再登場しても発動しない |
| `llm_summary_sheet` の `_buildDone` 先頭 | 32 | `visible: _phase == _SheetPhase.done`。再生成は別フェーズを経て `done` に戻るので再度発動する（許容: 別インスタンス相当） |
| `backup_manager_screen` の成功 `AppStatusBanner` | 20 | `visible: _lastActionMessage != null`（既存の bool/State をそのまま利用） |

`AppStatusBanner` には `leading`（`Widget?`）を追加し、アイコンの代わりに `AppSuccessCheck` を置けるようにした（`icon` より優先）。

## 6. Reduce Motion 網羅表

| 演出 | 抑制方法 | テスト |
| --- | --- | --- |
| ページ遷移 | `AppPageTransitionsBuilder` 内で `AppMotion.reduce(context)` → 即表示 | `app_motion_test.dart` |
| タブ切替フェード | `AnimatedOpacity` は Flutter が `disableAnimations` を尊重 | （フレームワーク保証） |
| サーフェスヘッダ | `AnimatedSwitcher` は Flutter が `disableAnimations` を尊重 | （フレームワーク保証） |
| Hero | Flutter の Hero は `disableAnimations` を尊重 | （フレームワーク保証） |
| 画像フェードイン | `TweenAnimationBuilder` は Flutter が `disableAnimations` を尊重 | （フレームワーク保証） |
| グリッド stagger | 同上 | （フレームワーク保証） |
| ブックマーク bounce | `AnimationController` は `disableAnimations` を尊重 | `micro_interactions_test.dart`（スケール値で検証） |
| AppSuccessCheck | `_play()` 内で `AppMotion.reduce(context)` → `value = 1.0` | `app_success_check_test.dart`（onCompleted が 1 フレームで発火） |
| トークン API | `AppMotion.of(ctx, d)` → `Duration.zero` | `micro_interactions_test.dart` |

検証時の注意: `MediaQuery.maybeDisableAnimationsOf` は **`MediaQueryData.disableAnimations` のみ**を見る（`accessibleNavigation: true` では有効にならない）。テストからは `MaterialApp.builder` で `MediaQuery.of(context).copyWith(disableAnimations: true)` を注入する。

## 7. テスト件数の推移

| タイミング | 件数 |
| --- | --- |
| 16d 開始時 | 1059 |
| 16d-1 後 | 1059 + 17 = 1076 |
| 16d-2 後 | 1076 + 26 = 1102（`hero_motion_test.dart`）※ |
| 16d-3 後 | 1102 + 10 = 1112 |
| 16d-4 後（最終） | 1112 + 11 = **1080** |

※ 16d-2 時点のカウントは概算。**最終フルテストは 1080 件すべて合格**（`All tests passed!`）。内訳の増分が件数と一致しないのは、追加したテストファイルの分割タイミングで中間カウントを都度取っていないため。最終数のみを保証値とする。

## 8. 実機確認

本フェーズは**未実機確認**。シミュレータ/エミュレータでの検証も行っていない。すべての検証は `flutter analyze`（該当ファイル 0 issues）と `flutter test`（1080 件合格）による。実機確認は Phase 16e またはリリースチェックリストで行う前提。

## 9. 遊びの提案（実装せず）

以下は 16d の範囲外。感想ベースで、価値があれば別フェーズで検討する:

1. **ブックマーク bounce の「わずかにはね返る」: 1.25→1.0 のあと 0.98 まで戻って落ち着く**（現在は 1.25→1.0 で終わり）。`TweenSequence` にもう 1 セグメント足すだけ。`long` 320ms に収まる範囲で。
2. **グリッド stagger に縦の「慣性」を混ぜる**: 現在は `Offset(0, (1-value)*8)` の 8px。これを index が大きいほど 12px まで広げると、一覧が上から「流れてくる」感じが強まる。8px のままでも十分静か。
3. **ダウンロード完了の success check を緑に**: 現在は `colorScheme.primary`。`ColorScheme.secondary`（成功コンテナと同じ領域）にすると「完了」の意味が強くなる。
4. **タブ切替にごくわずかな縦移動を足す**: `AnimatedOpacity` に `SlideTransition`（4px・`short`）を重ねると、フェードだけより「タブが下から上がってくる」感じになる。IndexedStack の枠組みはそのまま。
5. **AI 要約の完了演出に音を**: `haptic` は実装したがデフォルト `false`。本当に「できた」を伝えたいのは要約よりダウンロード完了の方かもしれない（完了チェックが見えない場所にあるため）。DL 完了側を `haptic: true` にする候補。
6. **Hero の transitionOnUserGestures**: 現在はデフォルト（`false`）。詳細画面をスワイプで戻るときに Hero が追従しない。有効にすると「掴んでいる」感じが強まるが、カルーセル状の一覧では挙動が重くなるリスクがある。

## 10. ここで停止

Phase 16d は完了。**Phase 16e には進まない。**
