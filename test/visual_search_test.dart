// Phase 5 視覚類似画像検索のユニットテスト。
//
// 対象:
// - ColorGridEncoder: 単色画像の既知ベクトル・次元数・L2正規化
// - decodeAndEncode: PNG バイト列からの復号→エンコード
// - cosineSimilarity / rankBySimilarity: 類似度計算・除外・降順
// - float32ToBytes / bytesToFloat32: BLOB roundtrip
// - image_embeddings（DB v20）CRUD（sqflite_ffi インメモリDB）
//
// 実画像ファイル・ネットワーク・モデルには依存しない（テスト内でPNGを生成）。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/services/database_service.dart';
import 'package:pixiv_viewer/services/visual_search_service.dart';

void main() {
  // テスト用画像ビルダー。
  img.Image solidImage(int r, int g, int b, {int w = 64, int h = 64}) {
    final image = img.Image(width: w, height: h);
    img.fill(image, color: img.ColorRgb8(r, g, b));
    return image;
  }

  group('ColorGridEncoder', () {
    const encoder = ColorGridEncoder();

    test('次元数は grid*grid*3（デフォルト192）', () {
      expect(encoder.dimension, 192);
      expect(ColorGridEncoder(grid: 4).dimension, 48);
    });

    test('単色画像は全セル同値の L2 正規化済みベクトルを返す', () {
      // 赤 (255,0,0) → 各セル (1, -1, -1)、全体のノルムは sqrt(64*3)。
      final vec = encoder.encode(solidImage(255, 0, 0));
      expect(vec.length, 192);
      final unit = 1.0 / math.sqrt(192);
      for (var cell = 0; cell < 64; cell++) {
        expect(vec[cell * 3], closeTo(unit, 1e-6));
        expect(vec[cell * 3 + 1], closeTo(-unit, 1e-6));
        expect(vec[cell * 3 + 2], closeTo(-unit, 1e-6));
      }
      // L2 ノルム ≈ 1
      var sq = 0.0;
      for (final v in vec) {
        sq += v * v;
      }
      expect(math.sqrt(sq), closeTo(1.0, 1e-6));
    });

    test('上下二色画像は上半分と下半分で別々のセル値になる', () {
      final image = img.Image(width: 64, height: 64);
      img.fill(image, color: img.ColorRgb8(0, 0, 255));
      img.fillRect(
        image,
        x1: 0,
        y1: 0,
        x2: 63,
        y2: 31,
        color: img.ColorRgb8(255, 0, 0),
      );
      final vec = encoder.encode(image);
      // 上段セル（0..31）は赤、下段（32..63）は青。
      expect(vec[0], greaterThan(0));
      expect(vec[32 * 3 + 2], greaterThan(0));
      expect(vec[32 * 3], lessThan(0));
    });

    test('空画像はゼロベクトルを返す', () {
      final vec = encoder.encode(img.Image(width: 0, height: 0));
      expect(vec.length, 192);
      for (final v in vec) {
        expect(v, 0);
      }
    });
  });

  group('decodeAndEncode / BLOB 変換', () {
    const encoder = ColorGridEncoder();

    test('PNG バイト列をデコードして特徴ベクトルを返す', () {
      final bytes = img.encodePng(solidImage(255, 0, 0));
      final vec = decodeAndEncode(bytes, encoder);
      expect(vec, isNotNull);
      expect(vec!.length, 192);
      var sq = 0.0;
      for (final v in vec) {
        sq += v * v;
      }
      expect(math.sqrt(sq), closeTo(1.0, 1e-6));
    });

    test('不正バイト列は null を返す', () {
      expect(
        decodeAndEncode(Uint8List.fromList([1, 2, 3, 4]), encoder),
        isNull,
      );
    });

    test('float32ToBytes / bytesToFloat32 は値を保存する（roundtrip）', () {
      final v = Float32List(3)
        ..[0] = 0.5
        ..[1] = -0.25
        ..[2] = 0.125;
      final restored = bytesToFloat32(float32ToBytes(v));
      expect(restored.length, 3);
      expect(restored[0], closeTo(0.5, 1e-7));
      expect(restored[1], closeTo(-0.25, 1e-7));
      expect(restored[2], closeTo(0.125, 1e-7));
    });

    test('オフセット付き Uint8List でも正しく復元できる', () {
      final v = Float32List(2)
        ..[0] = 1.0
        ..[1] = -1.0;
      final blob = float32ToBytes(v);
      // 前後にダミーバイトを付けてオフセット付き Uint8List を作る
      final padded = Uint8List(blob.length + 4);
      padded.setRange(4, padded.length, blob);
      final view = Uint8List.sublistView(padded, 4);
      final restored = bytesToFloat32(view);
      expect(restored[0], closeTo(1.0, 1e-7));
      expect(restored[1], closeTo(-1.0, 1e-7));
    });
  });

  group('cosineSimilarity / rankBySimilarity', () {
    const encoder = ColorGridEncoder();

    test('同一画像は類似度 1.0、赤 vs 青は -1/3', () {
      final red = encoder.encode(solidImage(255, 0, 0));
      final red2 = encoder.encode(solidImage(255, 0, 0, w: 32, h: 32));
      final blue = encoder.encode(solidImage(0, 0, 255));
      expect(cosineSimilarity(red, red2), closeTo(1.0, 1e-6));
      // 赤セル (1,-1,-1) と青セル (-1,-1,1) のコサインは -1/3。
      expect(cosineSimilarity(red, blue), closeTo(-1.0 / 3.0, 1e-6));
    });

    test('rankBySimilarity は自分自身を除外し類似度降順で返す', () {
      final red = encoder.encode(solidImage(255, 0, 0));
      final red2 = encoder.encode(solidImage(255, 0, 0));
      final blue = encoder.encode(solidImage(0, 0, 255));
      final rows = <Map<String, dynamic>>[
        {'illust_id': 1, 'embedding': float32ToBytes(red)},
        {'illust_id': 2, 'embedding': float32ToBytes(blue)},
        {'illust_id': 3, 'embedding': float32ToBytes(red2)},
      ];
      final results = rankBySimilarity(
        rows,
        red,
        queryIllustId: 1,
        minSimilarity: 0.5,
      );
      // 青は -1/3 で閾値未満のため除外、赤のみ残る。
      expect(results.length, 1);
      expect(results.first['illust_id'], 3);
      expect(results.first['similarity'], closeTo(1.0, 1e-6));
    });

    test('limit で上位のみ返す', () {
      final red = encoder.encode(solidImage(255, 0, 0));
      final rows = List.generate(
        10,
        (i) => {'illust_id': i + 100, 'embedding': float32ToBytes(red)},
      );
      final results = rankBySimilarity(
        rows,
        red,
        queryIllustId: 1,
        minSimilarity: 0.5,
        limit: 3,
      );
      expect(results.length, 3);
    });

    test('ゼロベクトルのクエリは空を返す', () {
      final rows = <Map<String, dynamic>>[
        {'illust_id': 1, 'embedding': float32ToBytes(Float32List(192))},
      ];
      expect(
        rankBySimilarity(rows, Float32List(192), queryIllustId: 0),
        isEmpty,
      );
    });
  });

  group('image_embeddings CRUD（DB v20）', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    late DatabaseService db;
    late Database testDb;

    setUp(() async {
      db = DatabaseService();
      testDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 20,
          onCreate: (d, v) async {
            // v20 の image_embeddings と同一スキーマ
            await d.execute('''
              CREATE TABLE IF NOT EXISTS image_embeddings (
                illust_id INTEGER PRIMARY KEY,
                embedding BLOB NOT NULL,
                dim INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL
              )
            ''');
          },
        ),
      );
      db.setTestDatabase(testDb);
    });

    tearDown(() async {
      await testDb.close();
      await db.restartDatabase();
    });

    test('save / getAll / delete・BLOB roundtrip', () async {
      const encoder = ColorGridEncoder();
      final vec = encoder.encode(solidImage(10, 200, 30, w: 16, h: 16));
      final saved = await db.saveImageEmbedding(
        illustId: 123,
        embedding: float32ToBytes(vec),
        dim: vec.length,
      );
      expect(saved, greaterThan(0));
      await db.saveImageEmbedding(
        illustId: 456,
        embedding: float32ToBytes(vec),
        dim: vec.length,
      );

      final all = await db.getAllImageEmbeddings();
      expect(all.length, 2);
      final first = all.firstWhere((r) => r['illust_id'] == 123);
      expect(first['dim'], 192);
      // BLOB → Float32List で元ベクトルと一致
      final restored = bytesToFloat32(first['embedding'] as Uint8List);
      expect(restored.length, vec.length);
      for (var i = 0; i < vec.length; i++) {
        expect(restored[i], closeTo(vec[i], 1e-7));
      }

      // UPSERT: 同じ illust_id は置換される
      await db.saveImageEmbedding(
        illustId: 123,
        embedding: float32ToBytes(Float32List(192)),
        dim: 192,
      );
      expect((await db.getAllImageEmbeddings()).length, 2);

      // 削除
      expect(await db.deleteImageEmbedding(123), 1);
      expect(await db.deleteImageEmbedding(999), 0);
      final after = await db.getAllImageEmbeddings();
      expect(after.length, 1);
      expect(after.first['illust_id'], 456);
    });
  });
}
