/// ダウンロード済み画像が少ない場合の案内メッセージを決定する純粋関数。
///
/// 視覚類似検索・重複検出は画像が 2 件以上ないと意味をなさないため、
/// 画像数に応じて以下の 3 パターンを返す。
/// - 0 件: 「ダウンロード済み画像がありません」
/// - 1 件: 「画像は1件あります。<機能名>には2件以上必要です」
/// - 2 件以上: null（通常処理へ）
String? buildEmptyImageMessage(int imageCount, String featureName) {
  if (imageCount <= 0) {
    return 'ダウンロード済み画像がありません';
  }
  if (imageCount == 1) {
    return '画像は1件あります。$featureNameには2件以上必要です。';
  }
  return null;
}
