// 画像重複・近似重複検出サービス（Phase 6）。
//
// 設計:
// - SHA-256: ファイルバイト列の完全一致検出（同一ファイル・再ダウンロード重複）。
// - dHash: 9x8 グレースケールの差分ハッシュ（64bit）で近似重複検出。
//   ハミング距離 0..[maxHammingDistance] を「近似」と判定する。
// - image_fingerprints（DB v21）: 各画像の指紋を端末ローカル保存。
//   元画像から再生成可能なため Google Drive バックアップ対象外。
// - 削除は一切自動化しない: UI 側でユーザー確認を必須とする。
//   本サービスは「検出・列挙」のみ提供し、ファイル操作は行わない。
// - 画像デコードは Isolate 実行想定の純粋関数として分離（UI非ブロック）。

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;

/// 画像1枚分の指紋。
class ImageFingerprint {
  final int illustId;
  final String localPath;
  final String sha256Hex;
  final int dhash;

  const ImageFingerprint({
    required this.illustId,
    required this.localPath,
    required this.sha256Hex,
    required this.dhash,
  });
}

/// ファイルバイト列から SHA-256 を計算する（16進小文字）。
String computeSha256Hex(Uint8List bytes) =>
    crypto.sha256.convert(bytes).toString();

/// デコード済み画像から dHash（64bit）を計算する純粋関数。
///
/// 9x8=72 ピクセルにダウンサンプルし、各行の隣接ピクセル差
/// （左 > 右 なら 1）を 64bit に詰める。輝度は Rec.601 重み付け。
/// デコード済み画像の解像度は問わない（任意サイズで計算可能）。
int computeDHash(img.Image image) {
  const cols = 9;
  const rows = 8;
  final w = image.width;
  final h = image.height;
  if (w < 2 || h < 2) return 0;

  // 各行の隣接差分ビットを集める。
  var hash = 0;
  var bit = 0;
  for (var row = 0; row < rows; row++) {
    final y = (row * h) ~/ rows;
    for (var col = 0; col < cols - 1; col++) {
      final xLeft = (col * w) ~/ cols;
      final xRight = ((col + 1) * w) ~/ cols;
      final l = image.getPixel(xLeft, y);
      final r = image.getPixel(xRight, y);
      final lLum = 0.299 * l.r + 0.587 * l.g + 0.114 * l.b;
      final rLum = 0.299 * r.r + 0.587 * r.g + 0.114 * r.b;
      if (lLum > rLum) {
        hash |= 1 << bit;
      }
      bit++;
    }
  }
  return hash;
}

/// 画像バイト列から指納を一括計算する（Isolate 実行想定）。
/// デコード失敗時は null を返す。
ImageFingerprint? computeFingerprint({
  required int illustId,
  required String localPath,
  required Uint8List bytes,
}) {
  final sha = computeSha256Hex(bytes);
  img.Image? image;
  try {
    image = img.decodeImage(bytes);
  } catch (_) {
    image = null;
  }
  if (image == null) return null;
  return ImageFingerprint(
    illustId: illustId,
    localPath: localPath,
    sha256Hex: sha,
    dhash: computeDHash(image),
  );
}

/// 2つの dHash 間のハミング距離（異なるビット数）。
///
/// dHash は bit63 を使うため 64bit int としては負値になり得る。
/// 算術シフト（>>）では -1 >> 1 = -1 のまま減らず無限ループするため、
/// 必ず符号なし右シフト（>>>）を使う。
int hammingDistance(int a, int b) {
  var diff = a ^ b;
  var count = 0;
  while (diff != 0) {
    count += diff & 1;
    diff >>>= 1;
  }
  return count;
}

/// 重複グループ（完全一致 or 近似）の1つ。
class DuplicateGroup {
  /// グループ内の候補画像（同一 SHA-256 の場合 exact=true）。
  final List<ImageFingerprint> members;
  final bool exact;

  const DuplicateGroup({required this.members, required this.exact});
}

/// 指納リストから重複グループを検出する純粋関数。
///
/// - [exact] = true: SHA-256 完全一致でグループ化。
/// - [exact] = false: dHash のハミング距離が [maxHammingDistance] 以下の
///   画像同士を近似としてグループ化（greedy 連結・順序依存なし）。
/// 2枚未満のグループは結果に含めない。
List<DuplicateGroup> findDuplicateGroups(
  List<ImageFingerprint> fingerprints, {
  bool exact = true,
  int maxHammingDistance = 6,
}) {
  if (exact) {
    final bySha = <String, List<ImageFingerprint>>{};
    for (final f in fingerprints) {
      bySha.putIfAbsent(f.sha256Hex, () => []).add(f);
    }
    return [
      for (final group in bySha.values)
        if (group.length >= 2) DuplicateGroup(members: group, exact: true),
    ];
  }

  // 近似: Union-Find でハミング距離閾値以下のペアを連結。
  final n = fingerprints.length;
  final parent = List<int>.generate(n, (i) => i);

  int find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]]; // 経路短縮
      x = parent[x];
    }
    return x;
  }

  void union(int a, int b) {
    final ra = find(a);
    final rb = find(b);
    if (ra != rb) parent[ra] = rb;
  }

  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      if (hammingDistance(fingerprints[i].dhash, fingerprints[j].dhash) <=
          maxHammingDistance) {
        union(i, j);
      }
    }
  }

  final groups = <int, List<ImageFingerprint>>{};
  for (var i = 0; i < n; i++) {
    groups.putIfAbsent(find(i), () => []).add(fingerprints[i]);
  }
  final result = <DuplicateGroup>[];
  for (final members in groups.values) {
    if (members.length < 2) continue;
    // 安定した出力のためメンバーを illustId 昇順に並べる。
    members.sort((a, b) => a.illustId.compareTo(b.illustId));
    result.add(DuplicateGroup(members: members, exact: false));
  }
  // グループ自体は先頭メンバーの illustId 昇順で並べる。
  result.sort(
    (a, b) => a.members.first.illustId.compareTo(b.members.first.illustId),
  );
  return result;
}

/// ハミング距離を「近似度%」表示用に変換する（64bit 中の一致ビット割合）。
int similarityPercent(int hamming) {
  const totalBits = 64;
  final v = ((totalBits - hamming) / totalBits * 100).round();
  return math.max(0, math.min(100, v));
}
