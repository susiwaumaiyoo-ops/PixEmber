// Phase 6 重複・近似重複検出のユニットテスト。
//
// 対象:
// - computeSha256Hex: 既知ダイジェスト・同一バイト一致
// - computeDHash: 単色画像は 0・水平グラデーションで全ビット立つ・同一画像同一ハッシュ
// - computeFingerprint: PNG からの指紋計算・不正バイトは null
// - hammingDistance / similarityPercent: ビット差計算・%変換
// - findDuplicateGroups: SHA-256 完全一致グループ化・dHash 近似（Union-Find）
// - image_fingerprints（DB v21）CRUD（sqflite_ffi インメモリDB）
//
// 実画像ファイル・ネットワークには依存しない（テスト内でPNGを生成）。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/services/database_service.dart';
import 'package:pixiv_viewer/services/duplicate_detection_service.dart';

void main() {
  // テスト用画像ビルダー。
  img.Image solidImage(int r, int g, int b, {int w = 64, int h = 64}) {
    final image = img.Image(width: w, height: h);
    img.fill(image, color: img.ColorRgb8(r, g, b));
    return image;
  }

  group('computeSha256Hex', () {
    test('空バイト列の SHA-256 は既知の値', () {
      // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
      expect(
        computeSha256Hex(Uint8List(0)),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('同一バイト列は同じ SHA-256、異なれば変わる', () {
      final a = Uint8List.fromList([1, 2, 3]);
      final b = Uint8List.fromList([1, 2, 3]);
      final c = Uint8List.fromList([1, 2, 4]);
      expect(computeSha256Hex(a), computeSha256Hex(b));
      expect(computeSha256Hex(a), isNot(computeSha256Hex(c)));
    });
  });

  group('computeDHash', () {
    test('単色画像は差分なしでハッシュ 0', () {
      expect(computeDHash(solidImage(128, 128, 128)), 0);
      expect(computeDHash(solidImage(255, 0, 0, w: 256, h: 256)), 0);
    });

    test('左白→右黒の水平勾配では全ビットが立つ', () {
      final image = img.Image(width: 64, height: 64);
      img.fill(image, color: img.ColorRgb8(0, 0, 0));
      for (final p in image) {
        // 左ほど明るい勾配: x=0 で 255、x=63 で 3。
        final v = 255 - (p.x * 4).clamp(0, 255);
        image.setPixelR(p.x, p.y, v);
      }
      final hash = computeDHash(image);
      // 「左 > 右」が全行で成立するため 64bit 全部 1（= -1）。
      expect(hash, -1);
      expect(hammingDistance(hash, 0), 64);
    });

    test('同一画像は同じハッシュ・サイズが違っても勾配が同じなら同じハッシュ', () {
      final a = solidImage(255, 0, 0);
      final b = solidImage(255, 0, 0, w: 32, h: 32);
      expect(computeDHash(a), computeDHash(b));
    });

    test('小さすぎる画像（1x1）は 0', () {
      expect(computeDHash(img.Image(width: 1, height: 1)), 0);
    });
  });

  group('computeFingerprint', () {
    test('PNG バイト列から SHA-256 と dHash を計算する', () {
      final bytes = img.encodePng(solidImage(255, 0, 0));
      final fp = computeFingerprint(
        illustId: 7,
        localPath: '/tmp/a.png',
        bytes: bytes,
      );
      expect(fp, isNotNull);
      expect(fp!.illustId, 7);
      expect(fp.localPath, '/tmp/a.png');
      expect(fp.sha256Hex, hasLength(64));
      expect(fp.dhash, 0); // 単色
    });

    test('同一バイト列の指紋は完全一致', () {
      final bytes = img.encodePng(solidImage(0, 255, 0));
      final a = computeFingerprint(
        illustId: 1,
        localPath: '/tmp/a.png',
        bytes: bytes,
      );
      final b = computeFingerprint(
        illustId: 2,
        localPath: '/tmp/b.png',
        bytes: bytes,
      );
      expect(a!.sha256Hex, b!.sha256Hex);
      expect(a.dhash, b.dhash);
    });

    test('不正バイト列は null', () {
      expect(
        computeFingerprint(
          illustId: 1,
          localPath: '/tmp/x.png',
          bytes: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        ),
        isNull,
      );
    });
  });

  group('hammingDistance / similarityPercent', () {
    test('ビット差の数を数える', () {
      expect(hammingDistance(0, 0), 0);
      expect(hammingDistance(0, 1), 1);
      // 0b1010=10 と 0b0101=5 は全4ビットが異なる。
      expect(hammingDistance(10, 5), 4);
      expect(hammingDistance(0xFF, 0x00), 8);
    });

    test('近似度%は一致ビット割合', () {
      expect(similarityPercent(0), 100);
      expect(similarityPercent(64), 0);
      expect(similarityPercent(16), 75);
      expect(similarityPercent(6), 91); // (64-6)/64 = 90.625 → 91
    });
  });

  group('findDuplicateGroups', () {
    ImageFingerprint fp(int id, String sha, int dhash) => ImageFingerprint(
      illustId: id,
      localPath: '/tmp/$id.png',
      sha256Hex: sha,
      dhash: dhash,
    );

    test('SHA-256 完全一致でグループ化', () {
      final prints = [
        fp(1, 'aaa', 0),
        fp(2, 'aaa', 0),
        fp(3, 'bbb', 0),
        fp(4, 'aaa', 0),
        fp(5, 'bbb', 0),
      ];
      final groups = findDuplicateGroups(prints, exact: true);
      expect(groups.length, 2);
      final aaa = groups.firstWhere((g) => g.members.first.illustId == 1);
      expect(aaa.members.length, 3);
      expect(aaa.exact, isTrue);
    });

    test('重複なし（全ユニーク）なら空', () {
      final prints = [fp(1, 'a', 0), fp(2, 'b', 1), fp(3, 'c', 2)];
      expect(findDuplicateGroups(prints, exact: true), isEmpty);
    });

    test('dHash 近似: ハミング距離閾値以内を連結', () {
      // 0,1,2,3,...,7 は順に距離1ずつ → 閾値4なら全て同一グループに連結。
      final prints = [for (var i = 0; i < 8; i++) fp(100 + i, 'sha$i', i)];
      final groups = findDuplicateGroups(
        prints,
        exact: false,
        maxHammingDistance: 4,
      );
      expect(groups.length, 1);
      expect(groups.first.members.length, 8);
      expect(groups.first.exact, isFalse);
    });

    test('dHash 近似: 距離が遠い画像は別グループ', () {
      final prints = [
        fp(1, 'a', 0),
        fp(2, 'b', 0xFFFFFFFF), // 全ビット異なる → 距離64
        fp(3, 'c', 0xFFFFFFFF),
      ];
      final groups = findDuplicateGroups(
        prints,
        exact: false,
        maxHammingDistance: 4,
      );
      // 0 と 0xFFFFFFFF... は距離64で孤立。2と3は互いに距離0でグループ。
      expect(groups.length, 1);
      expect(groups.first.members.map((m) => m.illustId), [2, 3]);
    });

    test('メンバーは illustId 昇順でソートされる', () {
      final prints = [fp(30, 'x', 5), fp(10, 'y', 5), fp(20, 'z', 5)];
      final groups = findDuplicateGroups(
        prints,
        exact: false,
        maxHammingDistance: 4,
      );
      expect(groups.first.members.map((m) => m.illustId), [10, 20, 30]);
    });
  });

  group('image_fingerprints CRUD（DB v21）', () {
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
          version: 21,
          onCreate: (d, v) async {
            // v21 の image_fingerprints と同一スキーマ
            await d.execute('''
              CREATE TABLE IF NOT EXISTS image_fingerprints (
                illust_id INTEGER PRIMARY KEY,
                sha256 TEXT NOT NULL,
                dhash INTEGER NOT NULL,
                updated_at TEXT NOT NULL
              )
            ''');
            await d.execute(
              'CREATE INDEX IF NOT EXISTS idx_image_fingerprints_sha256 '
              'ON image_fingerprints(sha256)',
            );
          },
        ),
      );
      db.setTestDatabase(testDb);
    });

    tearDown(() async {
      await testDb.close();
      await db.restartDatabase();
    });

    test('save / getAll / delete・UPSERT', () async {
      final saved = await db.saveImageFingerprint(
        illustId: 11,
        sha256: 'abc',
        dhash: 42,
      );
      expect(saved, greaterThan(0));
      await db.saveImageFingerprint(illustId: 12, sha256: 'abc', dhash: 43);
      var all = await db.getAllImageFingerprints();
      expect(all.length, 2);

      // UPSERT: 同じ illust_id は置換
      await db.saveImageFingerprint(illustId: 11, sha256: 'def', dhash: 0);
      all = await db.getAllImageFingerprints();
      expect(all.length, 2);
      final row11 = all.firstWhere((r) => r['illust_id'] == 11);
      expect(row11['sha256'], 'def');
      expect(row11['dhash'], 0);

      // 削除
      expect(await db.deleteImageFingerprint(11), 1);
      expect(await db.deleteImageFingerprint(999), 0);
      all = await db.getAllImageFingerprints();
      expect(all.length, 1);
      expect(all.first['illust_id'], 12);
    });
  });
}
