// 視覚類似画像検索サービス（Phase 5）。
//
// 設計:
// - VisualEncoder 抽象: 将来の ONNX 実モデル（CLIP 等）への差し替えを想定。
//   エンコーダは DI されており、DB スキーマ・検索ロジックは変更不要。
// - ColorGridEncoder: 画像を 8x8 セルに分割し各セル平均 RGB を並べた
//   192 次元特徴量の暫定エンコーダ（色構成ベースの大まかな類似検索）。
// - 画像のデコード・エンコードは Isolate.run で実行し UI をブロックしない。
// - image_embeddings（DB v20）: Float32 ベクトルを BLOB で端末ローカル保存。
//   元画像から再生成可能なため Google Drive バックアップ対象外。
// - 類似度はコサイン類似度で計算し、昇順ソートではなく必要な上位のみ返す。
// - リポジトリにモデル・画像バイナリは含めない（ダウンロード済み実画像のみ処理）。

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 視覚特徴量エンコーダの抽象インターフェース。
abstract class VisualEncoder {
  /// 出力ベクトルの次元数。
  int get dimension;

  /// デコード済み画像から特徴ベクトルを抽出する（純粋関数・同期）。
  /// 戻り値は L2 正規化済みとする。
  Float32List encode(img.Image image);
}

/// 暫定エンコーダ: 画像を grid x grid セルに分割し、各セルの平均 RGB を
/// 並べた特徴量（grid=8 で 192 次元）。
///
/// 色の空間配置を捉える古典的手法。実モデル導入までのプレースホルダで、
/// 色合い・構図が近い画像を大まかに検索できる。ピクセルの座標は
/// `x * grid ~/ width` でセル番号へ写像する（リサイズ不要で高速）。
class ColorGridEncoder implements VisualEncoder {
  final int grid;

  const ColorGridEncoder({this.grid = 8});

  @override
  int get dimension => grid * grid * 3;

  @override
  Float32List encode(img.Image image) {
    final w = image.width;
    final h = image.height;
    final out = Float32List(dimension);
    if (w == 0 || h == 0) return out;

    final sums = Float64List(dimension);
    final counts = Int32List(grid * grid);
    for (final p in image) {
      final cx = (p.x * grid) ~/ w;
      final cy = (p.y * grid) ~/ h;
      final cell = cy * grid + cx;
      if (cell >= grid * grid) continue; // 端数ガード
      final base = cell * 3;
      sums[base] += p.r.toDouble();
      sums[base + 1] += p.g.toDouble();
      sums[base + 2] += p.b.toDouble();
      counts[cell]++;
    }

    // セル平均を 0..255 → -1..1 へ写像。
    for (var cell = 0; cell < grid * grid; cell++) {
      final n = counts[cell];
      if (n == 0) continue;
      final base = cell * 3;
      out[base] = (sums[base] / n / 255.0) * 2.0 - 1.0;
      out[base + 1] = (sums[base + 1] / n / 255.0) * 2.0 - 1.0;
      out[base + 2] = (sums[base + 2] / n / 255.0) * 2.0 - 1.0;
    }

    // L2 正規化（ゼロベクトル時はそのまま返す）。
    var sq = 0.0;
    for (final v in out) {
      sq += v * v;
    }
    final norm = math.sqrt(sq);
    if (norm > 0) {
      for (var i = 0; i < out.length; i++) {
        out[i] /= norm;
      }
    }
    return out;
  }
}

/// 画像バイト列をデコードして特徴ベクトルを算出する（Isolate 実行想定）。
/// デコード失敗時は null を返す。
///
/// image 4.x の一部デコーダは不正データに対して null ではなく
/// RangeError 等を投げるため、例外も失敗として握りつぶす。
Float32List? decodeAndEncode(Uint8List bytes, VisualEncoder encoder) {
  img.Image? image;
  try {
    image = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  if (image == null) return null;
  return encoder.encode(image);
}

/// Float32List → BLOB（sqflite は Uint8List を BLOB として保存）。
/// lengthInBytes は既にバイト単位なのでそのまま長さに使う。
Uint8List float32ToBytes(Float32List v) =>
    Uint8List.view(v.buffer, v.offsetInBytes, v.lengthInBytes);

/// BLOB → Float32List（リトルエンディアン固定で明示的に復元）。
/// sqflite から返される Uint8List はオフセット付きの場合があるため
/// offsetInBytes を尊重する。
Float32List bytesToFloat32(Uint8List bytes) {
  final data = bytes.buffer.asByteData(
    bytes.offsetInBytes,
    bytes.lengthInBytes,
  );
  final list = Float32List(data.lengthInBytes ~/ 4);
  for (var i = 0; i < list.length; i++) {
    list[i] = data.getFloat32(i * 4, Endian.little);
  }
  return list;
}

/// コサイン類似度（純粋関数）。
double cosineSimilarity(Float32List a, Float32List b) {
  var dot = 0.0;
  var na = 0.0;
  var nb = 0.0;
  final n = math.min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// 全 embedding 行をクエリベクトルと比較し類似度降順で上位を返す（純粋関数）。
///
/// [rows] は image_embeddings の行（illust_id + embedding BLOB）。
/// 自分自身（[queryIllustId]）とノルム 0 の行は除外される。
List<Map<String, dynamic>> rankBySimilarity(
  List<Map<String, dynamic>> rows,
  Float32List query, {
  required int queryIllustId,
  double minSimilarity = 0.4,
  int limit = 30,
}) {
  final qNorm = _l2Norm(query);
  if (qNorm == 0) return [];
  final scored = <(int, double)>[];
  for (final row in rows) {
    final id = row['illust_id'] as int;
    if (id == queryIllustId) continue;
    final emb = bytesToFloat32(row['embedding'] as Uint8List);
    final n = _l2Norm(emb);
    if (n == 0) continue;
    var dot = 0.0;
    final len = math.min(query.length, emb.length);
    for (var i = 0; i < len; i++) {
      dot += query[i] * emb[i];
    }
    final s = dot / (qNorm * n);
    if (s >= minSimilarity) scored.add((id, s));
  }
  scored.sort((a, b) => b.$2.compareTo(a.$2));
  return scored
      .take(limit)
      .map((e) => {'illust_id': e.$1, 'similarity': e.$2})
      .toList();
}

double _l2Norm(Float32List v) {
  var sq = 0.0;
  for (final x in v) {
    sq += x * x;
  }
  return math.sqrt(sq);
}
