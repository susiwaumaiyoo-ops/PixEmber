// Phase 16c-3a: PixivViewerHome のホーム/検索表示モード契約テスト。
//
// 本番の [PixivViewerHome] は initState で DB にアクセスするため
// widget test で pump すると `databaseFactory not initialized` になる。
// そのためここでは [PixivViewerHomeState] を直接インスタンス化し、
// `@visibleForTesting` な [_attachSurfaceMode] と [normalizeContentIndex]
// 経由で「モード契約・リスナー寿命・正規化」だけを検証する。
// build() を通らないため setState は発火せず、DB なしで動く。
//
// feed/search の表示差分そのものは 16c-3c で実装する。
// 検索モードで Feeling セグメントが出ないことは
// `home_content_mode_selector_test.dart` が `showFeelingDiscovery` で検証する。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/screens/home_screen_state.dart';

void main() {
  group('HomeSurfaceMode enum', () {
    test('combined / feed / search の 3 状態を持つ', () {
      expect(HomeSurfaceMode.values, hasLength(3));
      expect(HomeSurfaceMode.values, contains(HomeSurfaceMode.combined));
      expect(HomeSurfaceMode.values, contains(HomeSurfaceMode.feed));
      expect(HomeSurfaceMode.values, contains(HomeSurfaceMode.search));
    });
  });

  group('PixivViewerHomeState のモードバインド', () {
    late PixivViewerHomeState state;

    setUp(() {
      state = PixivViewerHomeState();
    });

    test('listenable が null なら combined になる', () {
      state.attachSurfaceMode(null);
      expect(state.surfaceMode, HomeSurfaceMode.combined);
    });

    test('feed / search の切替を通知する', () {
      final notifier = ValueNotifier<HomeSurfaceMode>(HomeSurfaceMode.feed);
      addTearDown(notifier.dispose);
      state.attachSurfaceMode(notifier);

      expect(state.surfaceMode, HomeSurfaceMode.feed);

      notifier.value = HomeSurfaceMode.search;
      expect(state.surfaceMode, HomeSurfaceMode.search);

      notifier.value = HomeSurfaceMode.feed;
      expect(state.surfaceMode, HomeSurfaceMode.feed);
    });

    test('Feeling 選択中に search へ切り替えると検索可能モードへ正規化される', () {
      final notifier = ValueNotifier<HomeSurfaceMode>(HomeSurfaceMode.feed);
      addTearDown(notifier.dispose);
      state.attachSurfaceMode(notifier);

      // feed ではフィーリング発掘を選べる。
      // changeTab は setState を呼ぶため、未マウントの State では
      // 直接フィールドを操作する（build しないテストの代償）。
      state.currentIndex = PixivViewerHomeState.feelingDiscoveryIndex;
      expect(state.currentIndex, PixivViewerHomeState.feelingDiscoveryIndex);

      // search へ切り替える: 正規化で illustIndex へ戻る
      notifier.value = HomeSurfaceMode.search;
      expect(state.surfaceMode, HomeSurfaceMode.search);
      expect(state.currentIndex, PixivViewerHomeState.illustIndex);
    });

    test('search の直前に選んでいた検索可能モードへ戻る', () {
      final notifier = ValueNotifier<HomeSurfaceMode>(HomeSurfaceMode.feed);
      addTearDown(notifier.dispose);
      state.attachSurfaceMode(notifier);

      // changeTab が記録する「直前の検索可能モード」をエミュレートする。
      // 本番では changeTab(novelIndex) がこの値を更新する。
      state.currentIndex = PixivViewerHomeState.novelIndex;
      state.lastSearchableContentIndexForTest = PixivViewerHomeState.novelIndex;
      state.currentIndex = PixivViewerHomeState.feelingDiscoveryIndex;
      expect(state.currentIndex, PixivViewerHomeState.feelingDiscoveryIndex);

      notifier.value = HomeSurfaceMode.search;
      expect(state.currentIndex, PixivViewerHomeState.novelIndex);
    });

    test('search では changeTab(feelingDiscoveryIndex) を拒否する', () {
      final notifier = ValueNotifier<HomeSurfaceMode>(HomeSurfaceMode.search);
      addTearDown(notifier.dispose);
      state.attachSurfaceMode(notifier);

      // 未マウントでも changeTab の setState は呼ばれない:
      // 同じ index なら早期 return するため。
      state.changeTab(PixivViewerHomeState.feelingDiscoveryIndex);
      expect(state.currentIndex, PixivViewerHomeState.illustIndex);
    });

    test('listenable を差し替えると旧リスナーが解除される', () {
      final first = ValueNotifier<HomeSurfaceMode>(HomeSurfaceMode.feed);
      final second = ValueNotifier<HomeSurfaceMode>(HomeSurfaceMode.search);
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      state.attachSurfaceMode(first);
      state.attachSurfaceMode(second);
      expect(state.surfaceMode, HomeSurfaceMode.search);

      // 旧 notifier を動かしても surfaceMode は変わらない
      first.value = HomeSurfaceMode.feed;
      expect(state.surfaceMode, HomeSurfaceMode.search);
    });

    test('同一インスタンスの再指定でリスナーが二重登録されない', () {
      final notifier = ValueNotifier<HomeSurfaceMode>(HomeSurfaceMode.feed);
      addTearDown(notifier.dispose);

      state.attachSurfaceMode(notifier);
      state.attachSurfaceMode(notifier);
      state.attachSurfaceMode(notifier);

      // 二重登録だと偶数回目の通知で「元の値」に見えてしまう。
      // 正規の実装なら毎回追従する。
      notifier.value = HomeSurfaceMode.search;
      expect(state.surfaceMode, HomeSurfaceMode.search);
      notifier.value = HomeSurfaceMode.feed;
      expect(state.surfaceMode, HomeSurfaceMode.feed);
      notifier.value = HomeSurfaceMode.search;
      expect(state.surfaceMode, HomeSurfaceMode.search);
    });

    test('リスナー解除後に通知しても例外が出ない', () {
      final notifier = ValueNotifier<HomeSurfaceMode>(HomeSurfaceMode.feed);
      state.attachSurfaceMode(notifier);

      // State.dispose() は未初期化の late final を多数参照するため
      // ここでは呼ばない。代わりに dispose の先頭が実行するのと同じ
      // removeListener 経路（_attachSurfaceMode(null)）で検証する。
      state.attachSurfaceMode(null);

      expect(() {
        notifier.value = HomeSurfaceMode.search;
        notifier.dispose();
      }, returnsNormally);
      expect(state.surfaceMode, HomeSurfaceMode.combined);
    });
  });

  group('normalizeContentIndex（純粋関数）', () {
    test('フィーリング発掘なら最後の検索可能モードへ戻す', () {
      expect(
        PixivViewerHomeState.normalizeContentIndex(
          PixivViewerHomeState.feelingDiscoveryIndex,
          PixivViewerHomeState.novelIndex,
        ),
        PixivViewerHomeState.novelIndex,
      );
      expect(
        PixivViewerHomeState.normalizeContentIndex(
          PixivViewerHomeState.feelingDiscoveryIndex,
          PixivViewerHomeState.illustIndex,
        ),
        PixivViewerHomeState.illustIndex,
      );
    });

    test('イラスト/小説はそのまま返す', () {
      expect(
        PixivViewerHomeState.normalizeContentIndex(
          PixivViewerHomeState.illustIndex,
          PixivViewerHomeState.novelIndex,
        ),
        PixivViewerHomeState.illustIndex,
      );
      expect(
        PixivViewerHomeState.normalizeContentIndex(
          PixivViewerHomeState.novelIndex,
          PixivViewerHomeState.illustIndex,
        ),
        PixivViewerHomeState.novelIndex,
      );
    });

    test('lastSearchable が許容外なら illustIndex に戻す', () {
      expect(
        PixivViewerHomeState.normalizeContentIndex(
          PixivViewerHomeState.feelingDiscoveryIndex,
          PixivViewerHomeState.feelingDiscoveryIndex,
        ),
        PixivViewerHomeState.illustIndex,
      );
    });
  });
}
