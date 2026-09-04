/// Phase 3 検索UI刷新: ホームタブ内検索の表示モード。
///
/// 新タブは作らず、既存のイラスト/小説タブ上で
/// 「通常閲覧 / 検索補助 / 検索結果」の3状態を切り替える。
enum HomeSearchUiMode {
  /// 通常閲覧（おすすめ・新着・フォロー・ブックマーク・ランキング等）
  browsing,

  /// 検索バーフォーカス中の補助画面（履歴・よく使う・トレンド）
  assisting,

  /// キーワード検索結果表示中
  results,
}

/// ホームタブのコンテンツソース。
/// ランキングはソースチップに表示せずサブモード(2)として別導線で維持する。
enum HomeContentSource {
  /// おすすめ（既存 recommend API）
  recommend,

  /// 新着（getNewIllusts / getNewNovels）
  latest,

  /// フォロー中（getFollowedIllusts / getFollowedNovels）
  following,

  /// ブックマーク（getUserBookmarks / getUserBookmarkNovels）
  bookmarks,
}

/// HomeSearchUiMode の遷移ルールを純粋関数として定義する。
///
/// 遷移図:
/// ```
///   browsing  -> assisting : 検索バー focus
///   assisting -> results   : submit / 履歴タップ / トレンドタップ
///   results   -> assisting : 検索バー再フォーカス
///   assisting -> browsing  : 文字空 + unfocus + 未検索
///   results   -> browsing  : ソースチップ選択 / clear で検索解除
/// ```
class HomeSearchUiModeTransitions {
  const HomeSearchUiModeTransitions._();

  /// 検索バーにフォーカスしたとき。
  /// どの状態からでも assisting になる（結果表示中の再編集含む）。
  static HomeSearchUiMode onFocus(HomeSearchUiMode current) {
    return HomeSearchUiMode.assisting;
  }

  /// 検索を送信したとき（空文字は呼び出し側で抑止する）。
  /// どの状態からでも results になる。
  static HomeSearchUiMode onSubmit(HomeSearchUiMode current) {
    return HomeSearchUiMode.results;
  }

  /// フォーカスを外したとき。
  /// assisting かつ未検索（テキストが空）なら browsing へ、
  /// assisting かつテキストありなら検索未実行でも assisting を維持する
  /// （=結果がまだ無い場合は元コンテンツに戻る）。
  ///
  /// [hasPendingText] : フォーカス解除時点でテキストが空でないか
  /// [hasSearchResult] : まだ検索結果が有効か
  static HomeSearchUiMode onUnfocus(
    HomeSearchUiMode current, {
    required bool hasPendingText,
    required bool hasSearchResult,
  }) {
    if (current != HomeSearchUiMode.assisting) return current;
    // 空欄 + 未検索 → 通常コンテンツに戻る
    if (!hasPendingText && !hasSearchResult) return HomeSearchUiMode.browsing;
    // テキストあり + 検索済み → 結果表示に戻る
    if (hasSearchResult) return HomeSearchUiMode.results;
    // テキストあり + 未検索 → 元コンテンツに戻る（結果が無いので維持不可）
    return HomeSearchUiMode.browsing;
  }

  /// テキストをクリアしたとき。
  /// 結果表示中なら現在ソースの閲覧へ戻り、
  /// フォーカス中（assisting）なら assisting のまま。
  static HomeSearchUiMode onClear(HomeSearchUiMode current) {
    if (current == HomeSearchUiMode.results) return HomeSearchUiMode.browsing;
    return current;
  }

  /// ソースチップ（おすすめ/新着/フォロー/ブックマーク）を選択したとき。
  /// キーワード結果は破棄して閲覧モードへ。
  static HomeSearchUiMode onSourceSelected(HomeSearchUiMode current) {
    return HomeSearchUiMode.browsing;
  }
}

/// [HomeContentSource] のラベル。
extension HomeContentSourceLabel on HomeContentSource {
  String get label {
    switch (this) {
      case HomeContentSource.recommend:
        return 'おすすめ';
      case HomeContentSource.latest:
        return '新着';
      case HomeContentSource.following:
        return 'フォロー';
      case HomeContentSource.bookmarks:
        return 'ブックマーク';
    }
  }
}
