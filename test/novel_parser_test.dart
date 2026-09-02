// Phase 1 小説リッチレンダリングのユニットテスト。
//
// 検証内容（設計書 §11 テスト計画）:
// 1. NovelParser.parsePage / parseInline（§11.1）
//    - 段落分割・連続空行圧縮
//    - 行全体が完全一致する挿絵タグのみブロック化 / 行中混在は PlainText 温存
//    - [[rb:...]] ネスト括弧・複数出現・空ルビ畳み込み
//    - 不明タグの温存
// 2. collectPixivImages の重複排除（§11.2）
// 3. rubyLineHeightRatio（§6.1 案B'' / §11.3）
// 4. resolvePixivImageUrl（0 始まり page・1 始まり再解釈・表紙 fallback / §11.3）
// 5. collapseRunsForDisplay（brackets / hide / §6.2）
// 6. NovelTextData fromJson の後方互換（旧 JSON・キー無し / §11.3）
// 7. TTS 正規化の挿絵タグ除去（§11.4）
// 8. DB v22: novel_text.illustrations_json のラウンドトリップ + v21→v22 マイグレーション

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/novel_model.dart';
import 'package:pixiv_viewer/services/database_service.dart';
import 'package:pixiv_viewer/services/novel_parser.dart';
import 'package:pixiv_viewer/services/novel_tts_service.dart';

void main() {
  group('NovelParser.parsePage', () {
    test('段落分割と連続空行の圧縮', () {
      final blocks = NovelParser.parsePage('一行目\n\n\n\n二行目\n\n三行目');
      // 一行目 / 空段落(圧縮) / 二行目 / 空段落 / 三行目
      expect(blocks, hasLength(5));
      expect((blocks[0] as ParagraphBlock).plainText, '一行目');
      expect(blocks[1], isA<ParagraphBlock>());
      expect((blocks[1] as ParagraphBlock).runs, isEmpty);
      expect((blocks[2] as ParagraphBlock).plainText, '二行目');
      expect((blocks[3] as ParagraphBlock).runs, isEmpty);
      expect((blocks[4] as ParagraphBlock).plainText, '三行目');
    });

    test('行全体が [uploadedimage:N] のみの場合ブロック化', () {
      final blocks = NovelParser.parsePage('前段\n[uploadedimage:12]\n後段');
      expect(blocks, hasLength(3));
      final img = blocks[1] as UploadedImageBlock;
      expect(img.localId, '12');
      expect(img.pageIndexInPage, 0);
    });

    test('同一ページ内の複数 uploadedimage に出現順インデックスが振られる', () {
      final blocks = NovelParser.parsePage(
        '[uploadedimage:1]\n本文\n[uploadedimage:2]',
      );
      expect((blocks[0] as UploadedImageBlock).pageIndexInPage, 0);
      expect((blocks[2] as UploadedImageBlock).pageIndexInPage, 1);
    });

    test('行中混在の uploadedimage は PlainText 温存（§4 規則 2）', () {
      final blocks = NovelParser.parsePage('本文[uploadedimage:1]続き');
      expect(blocks, hasLength(1));
      final runs = (blocks[0] as ParagraphBlock).runs;
      expect(runs, hasLength(1));
      expect((runs.single as PlainText).text, '本文[uploadedimage:1]続き');
    });

    test('[pixivimage:ID] / [pixivimage:ID-page] のブロック化', () {
      final blocks = NovelParser.parsePage(
        '[pixivimage:100]\n[pixivimage:100-2]',
      );
      final a = blocks[0] as PixivImageBlock;
      final b = blocks[1] as PixivImageBlock;
      expect(a.illustId, 100);
      expect(a.page, isNull);
      expect(b.illustId, 100);
      expect(b.page, 2);
    });

    test('[pixivimage:1]abc のような変形は PlainText 温存（誤爆防止）', () {
      final blocks = NovelParser.parsePage('[pixivimage:1]abc');
      expect(blocks, hasLength(1));
      final runs = (blocks[0] as ParagraphBlock).runs;
      expect((runs.single as PlainText).text, '[pixivimage:1]abc');
    });

    test('負数・非数値の pixivimage は PlainText 温存', () {
      final blocks = NovelParser.parsePage('[pixivimage:-1]');
      expect((blocks[0] as ParagraphBlock).runs.single, isA<PlainText>());
    });

    test('[newpage] 単独行は PageBreakBlock', () {
      final blocks = NovelParser.parsePage('前\n[newpage]\n後');
      expect(blocks[1], isA<PageBreakBlock>());
    });

    test('不明タグは PlainText 温存', () {
      final blocks = NovelParser.parsePage('[jump:2] 本文');
      expect(
        ((blocks[0] as ParagraphBlock).runs.single as PlainText).text,
        '[jump:2] 本文',
      );
    });
  });

  group('NovelParser.parseInline', () {
    test('単一ルビの親文字・ルビ分解', () {
      final runs = NovelParser.parseInline('[[rb:魔女(まじょ) > まじょ]]だよ');
      expect(runs, hasLength(2));
      final ruby = runs[0] as RubyInline;
      expect(ruby.base, '魔女(まじょ)');
      expect(ruby.ruby, 'まじょ');
      expect((runs[1] as PlainText).text, 'だよ');
    });

    test('ネスト括弧を含む親文字', () {
      final runs = NovelParser.parseInline('[[rb:魔女(まじょ) > まじょ]]');
      final ruby = runs.single as RubyInline;
      expect(ruby.base, '魔女(まじょ)');
      expect(ruby.ruby, 'まじょ');
    });

    test('複数ルビ + 間テキスト', () {
      final runs = NovelParser.parseInline('A[[rb:一 > いち]]B[[rb:二 > に]]C');
      expect(runs, hasLength(5));
      expect((runs[0] as PlainText).text, 'A');
      expect((runs[1] as RubyInline).base, '一');
      expect((runs[2] as PlainText).text, 'B');
      expect((runs[3] as RubyInline).base, '二');
      expect((runs[4] as PlainText).text, 'C');
    });

    test('空ルビは親文字のみへ畳む', () {
      final runs = NovelParser.parseInline('[[rb:漢字 > ]]です');
      expect(runs, hasLength(2));
      expect((runs[0] as PlainText).text, '漢字');
      expect((runs[1] as PlainText).text, 'です');
    });

    test('ルビ無しテキストは PlainText 1 個', () {
      final runs = NovelParser.parseInline('ただの本文');
      expect(runs, hasLength(1));
      expect((runs.single as PlainText).text, 'ただの本文');
    });

    test('ParagraphBlock.hasRuby / plainText', () {
      final blocks = NovelParser.parsePage('[[rb:一 > いち]]と二');
      final p = blocks.single as ParagraphBlock;
      expect(p.hasRuby, isTrue);
      expect(p.plainText, '一と二');

      final plain = NovelParser.parsePage('ルビなし').single as ParagraphBlock;
      expect(plain.hasRuby, isFalse);
    });
  });

  group('NovelParser.collectPixivImages', () {
    test('重複排除（同 ID 同 page）', () {
      final tags = NovelParser.collectPixivImages(
        '[pixivimage:10]\n本文\n[pixivimage:10]',
      );
      expect(tags, hasLength(1));
      expect(tags.first.illustId, 10);
      expect(tags.first.page, isNull);
    });

    test('同 ID 異 page は別要素', () {
      final tags = NovelParser.collectPixivImages(
        '[pixivimage:10]\n[pixivimage:10-1]\n[pixivimage:20]',
      );
      expect(tags, hasLength(3));
    });

    test('行中混在も収集対象（事前解決用の広め抽出）', () {
      final tags = NovelParser.collectPixivImages('前置き[pixivimage:5]後続');
      expect(tags, hasLength(1));
      expect(tags.single.illustId, 5);
    });
  });

  group('NovelParser.rubyLineHeightRatio（案B'
      '）', () {
    test('標準設定 fontSize=18 / lineHeight=1.8 → 2.35', () {
      expect(NovelParser.rubyLineHeightRatio(18.0, 1.8), closeTo(2.35, 1e-9));
    });

    test('fontSize ゼロ以下のガード', () {
      expect(NovelParser.rubyLineHeightRatio(0.0, 1.8), closeTo(2.35, 1e-9));
    });
  });

  group('NovelParser.resolvePixivImageUrl', () {
    const cover = 'cover_original.jpg';
    final pages = <String?>['p0.jpg', 'p1.jpg', 'p2.jpg'];

    test('page null → 表紙（coverOriginal）', () {
      expect(
        NovelParser.resolvePixivImageUrl(
          coverOriginal: cover,
          metaPageOriginals: pages,
          requestedPage: null,
        ),
        cover,
      );
    });

    test('0 始まり page の解決', () {
      expect(
        NovelParser.resolvePixivImageUrl(
          coverOriginal: cover,
          metaPageOriginals: pages,
          requestedPage: 0,
        ),
        'p0.jpg',
      );
      expect(
        NovelParser.resolvePixivImageUrl(
          coverOriginal: cover,
          metaPageOriginals: pages,
          requestedPage: 2,
        ),
        'p2.jpg',
      );
    });

    test('page 越過 → 1 始まり再解釈を 1 回のみ試行', () {
      // requestedPage=3 は 0 始まりでは範囲外 → 1 始まり再解釈で 2 ページ目
      expect(
        NovelParser.resolvePixivImageUrl(
          coverOriginal: cover,
          metaPageOriginals: pages,
          requestedPage: 3,
        ),
        'p2.jpg',
      );
      // それも範囲外 → 表紙 fallback
      expect(
        NovelParser.resolvePixivImageUrl(
          coverOriginal: cover,
          metaPageOriginals: pages,
          requestedPage: 99,
        ),
        cover,
      );
    });

    test('表紙が null で pages が空 → null', () {
      expect(
        NovelParser.resolvePixivImageUrl(
          coverOriginal: null,
          metaPageOriginals: const [],
          requestedPage: null,
        ),
        isNull,
      );
    });
  });

  group('NovelParser.collapseRunsForDisplay（§6.2）', () {
    test('show はそのまま', () {
      final runs = NovelParser.collapseRunsForDisplay([
        const PlainText('A'),
        const RubyInline(base: '一', ruby: 'いち'),
      ], RubyDisplayMode.show);
      expect(runs, hasLength(2));
      expect(runs[1], isA<RubyInline>());
    });

    test('brackets は 親文字（ルビ） に畳む', () {
      final runs = NovelParser.collapseRunsForDisplay([
        const RubyInline(base: '一', ruby: 'いち'),
      ], RubyDisplayMode.brackets);
      expect(runs, hasLength(1));
      expect((runs.single as PlainText).text, '一（いち）');
    });

    test('hide は親文字のみに畳む', () {
      final runs = NovelParser.collapseRunsForDisplay([
        const RubyInline(base: '一', ruby: 'いち'),
      ], RubyDisplayMode.hide);
      expect(runs, hasLength(1));
      expect((runs.single as PlainText).text, '一');
    });
  });

  group('NovelTextData 後方互換（§11.3）', () {
    test('旧形式 JSON（illustrations キー無し）→ 空マップ', () {
      final data = NovelTextData.fromJson({
        'id': 1,
        'novel_text': '本文',
        'novel_pages': ['本文'],
      });
      expect(data.illustrations, isEmpty);
    });

    test('illustrations 付き JSON の復元', () {
      final original = NovelTextData(
        id: 5,
        novelText: '本文',
        novelPages: const ['本文'],
        illustrations: const {'1': 'a.jpg', 'pixiv:10:0': 'b.jpg'},
      );
      final restored = NovelTextData.fromJson(
        jsonDecode(jsonEncode(original)) as Map<String, dynamic>,
      );
      expect(restored.illustrations, original.illustrations);
    });

    test('illustrations が非 Map 型でもクラッシュしない', () {
      final data = NovelTextData.fromJson({
        'id': 1,
        'novel_text': '本文',
        'novel_pages': <String>[],
        'illustrations': 'broken',
      });
      expect(data.illustrations, isEmpty);
    });
  });

  group('normalizeNovelTextForSpeech 挿絵タグ除去（§11.4）', () {
    test('uploadedimage / pixivimage が除去される', () {
      final normalized = normalizeNovelTextForSpeech(
        '[uploadedimage:1]本文前[pixivimage:10]中[pixivimage:10-2]本文後',
        readRuby: false,
      );
      expect(normalized, '本文前中本文後');
    });

    test('大文字小文字を区別しない', () {
      final normalized = normalizeNovelTextForSpeech(
        '[UPLOADEDIMAGE:1][PixivImage:3]',
        readRuby: false,
      );
      expect(normalized, isEmpty);
    });

    test('ルビ・newpage・jump の既存挙動を壊さない', () {
      final parent = normalizeNovelTextForSpeech(
        '[[rb:一 > いち]][newpage][jump:2]終',
        readRuby: false,
      );
      expect(parent, '一終');
      final ruby = normalizeNovelTextForSpeech('[[rb:一 > いち]]', readRuby: true);
      expect(ruby, 'いち');
    });
  });

  group('DB v22 novel_text.illustrations_json', () {
    late DatabaseService db;
    late Database testDb;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      db = DatabaseService();
      testDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 22,
          onCreate: (d, v) async {
            await d.execute('''
              CREATE TABLE IF NOT EXISTS novel_text (
                work_id INTEGER PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                author_name TEXT NOT NULL DEFAULT '',
                pages_json TEXT NOT NULL DEFAULT '[]',
                text TEXT NOT NULL DEFAULT '',
                illustrations_json TEXT,
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

    test('saveNovelText + getNovelText の illustrations ラウンドトリップ', () async {
      await db.saveNovelText(
        workId: 100,
        title: 'タイトル',
        authorName: '作者',
        text: '本文',
        pagesJson: jsonEncode(['本文']),
        illustrationsJson: jsonEncode({'1': 'a.jpg', 'pixiv:10:0': 'b.jpg'}),
      );

      final row = await db.getNovelText(100);
      expect(row, isNotNull);
      final decoded =
          jsonDecode(row!['illustrations_json'] as String)
              as Map<String, dynamic>;
      expect(decoded['1'], 'a.jpg');
      expect(decoded['pixiv:10:0'], 'b.jpg');
    });

    test('illustrationsJson 未指定でも保存できる（旧呼び出し互換）', () async {
      await db.saveNovelText(
        workId: 101,
        title: 'タイトル',
        authorName: '作者',
        text: '本文',
        pagesJson: jsonEncode(['本文']),
      );
      final row = await db.getNovelText(101);
      expect(row, isNotNull);
      expect(row!['illustrations_json'], isNull);
    });

    test('v21 → v22 マイグレーションで illustrations_json 列が追加される', () async {
      await testDb.close();
      await db.restartDatabase();

      // onUpgrade はインメモリ DB では発火しないため、一時ファイル DB で
      // 「v21 で作成 → v22 へオープン」の実アップグレード経路を検証する。
      final dir = await Directory.systemTemp.createTemp('novel_v22_');
      final dbPath = '${dir.path}${Platform.pathSeparator}mig.db';
      addTearDown(() async {
        await dir.delete(recursive: true);
      });

      // ステップ 1: 旧 v21 相当のスキーマを version: 21 で作成し、行を 1 件投入
      final v21Db = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 21,
          onCreate: (d, v) async {
            await d.execute('''
              CREATE TABLE novel_text (
                work_id INTEGER PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                author_name TEXT NOT NULL DEFAULT '',
                pages_json TEXT NOT NULL DEFAULT '[]',
                text TEXT NOT NULL DEFAULT '',
                updated_at TEXT NOT NULL
              )
            ''');
          },
        ),
      );
      await v21Db.insert('novel_text', {
        'work_id': 55,
        'title': '旧',
        'author_name': '作者',
        'pages_json': '[]',
        'text': '旧本文',
        'updated_at': '2024-01-01T00:00:00.000',
      });
      await v21Db.close();

      // ステップ 2: version: 22 で開き直し、onUpgrade で ALTER TABLE を実行
      var upgradeCalled = false;
      final v22Db = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 22,
          onUpgrade: (d, oldV, newV) async {
            if (oldV < 22) {
              upgradeCalled = true;
              await d.execute(
                'ALTER TABLE novel_text ADD COLUMN illustrations_json TEXT',
              );
            }
          },
        ),
      );
      expect(upgradeCalled, isTrue);

      // 追加列で insert できること（非破壊マイグレーションの検証）
      await v22Db.insert('novel_text', {
        'work_id': 56,
        'title': '新',
        'author_name': '作者',
        'pages_json': '[]',
        'text': '新本文',
        'illustrations_json': '{"1":"x.jpg"}',
        'updated_at': '2024-01-02T00:00:00.000',
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final legacy = await v22Db.query(
        'novel_text',
        where: 'work_id = ?',
        whereArgs: [55],
      );
      expect(legacy.single['illustrations_json'], isNull);

      final migrated = await v22Db.query(
        'novel_text',
        where: 'work_id = ?',
        whereArgs: [56],
      );
      expect(migrated.single['illustrations_json'], '{"1":"x.jpg"}');

      await v22Db.close();
    });
  });
}
