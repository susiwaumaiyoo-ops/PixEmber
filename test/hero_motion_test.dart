// Phase 16d-2: Hero タグ設計と重複回避の契約テスト。
//
// サムネ→詳細の Hero は「呼び出し元が渡した場合のみ有効」になる。
// 詳細画面の関連グリッドはタグを渡さない（同じ Navigator に Hero タグが
// 2 つできるとクラッシュする）。このファイルはその契約をコードレベルで検証する。
//
// 本番のイラスト詳細画面は DB/Pixiv API に依存して pump できないため、
// ここでは [IllustDetailUIComponents.build] のシグネチャと
// [_buildIllustGridItem] のタグ生成を静的に検証する。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('16d-2 Hero タグ設計', () {
    test('IllustDetailScreen が opt-in の heroTag を持つ', () {
      // Hero は任意（null = 無効）。既存の呼び出し元はそのまま動く。
      // 本物の Illust は複数の必須フィールドを持つため、ここでは
      // ソースレベルでフィールド定義を検証する（コンパイル不要）。
      final src = _readSource('lib/screens/illust_detail_state.dart');
      final cls = _extractClass(src, 'class IllustDetailScreen');
      expect(cls, contains('final String? heroTag;'));
      // コンストラクタ引数にも存在（null 既定 = opt-in）。
      final ctor = _extractBlock(cls, 'const IllustDetailScreen(');
      expect(ctor, contains('this.heroTag,'));
    });

    test('IllustDetailUIComponents.build が heroTag を受け取る', () {
      // シグネチャ検証: 名前付き引数 heroTag が生えていなければ
      // コンパイルエラーになる。これが build ルートの契約。
      final src = _readSource('lib/screens/illust_detail_ui_components.dart');
      final build = _extractBody(src, 'Widget build(');
      expect(build, contains('String? heroTag,'));
      // うごイラ以外の画像ビューアを _maybeHero で包む。
      // _maybeHero( そのものが部分文字列 "Hero(" を含むため、
      // 戻り値の行を直接検索する。
      final maybeHero = _extractBody(src, 'Widget _maybeHero(');
      expect(
        maybeHero,
        contains('return Hero(tag: heroTag, child: child);'),
        reason: 'タグが非 null なら Hero で包む',
      );
    });

    test('ホームグリッドはうごイラに Hero タグを付けない', () {
      // うごイラは詳細画面側が Hero にならない（フレーム取得 State が
      // フライトに追従できず崩れる）。そのためサムネ側も付けない。
      //
      // この判定は _buildIllustGridItem 内に閉じているため、
      // ここではタグ生成の「除外ルール」をソースレベルで検証する。
      final src = _readSource('lib/screens/home_ui_components.dart');
      final gridItem = _extractBody(src, 'Widget _buildIllustGridItem(');

      expect(gridItem, contains("'illust-hero-"), reason: 'タグ文字列を生成する');
      expect(
        gridItem,
        contains("illust.type == 'ugoira' ? null :"),
        reason: 'うごイラは null（Hero 無効）にする',
      );
      expect(
        gridItem,
        contains('heroTag: heroTag,'),
        reason: 'IllustDetailScreen にタグを渡す',
      );
      // Hero( と tag: heroTag, の間に改行が入ることを許容する
      //（dart format が引数を改行するため）。
      final heroIndex = gridItem.indexOf('Hero(');
      expect(heroIndex, isNonNegative, reason: 'サムネを Hero で包む');
      expect(
        gridItem.substring(heroIndex, heroIndex + 80),
        contains('tag: heroTag,'),
        reason: 'Hero タグにサムネと同じ文字列を渡す',
      );
    });

    test('詳細画面の関連グリッドは Hero タグを渡さない', () {
      // 重複クラッシュ回避の核心: 関連グリッドの IllustDetailScreen は
      // heroTag を持たない。このファイル内に heroTag 渡しが存在しないことを
      // 検証する。
      final src = _readSource('lib/screens/illust_detail_ui_components.dart');
      final relatedStart = src.indexOf('Widget _buildRelatedSection(');
      expect(relatedStart, isNonNegative, reason: '関連セクションが存在する');
      // メソッドの終わり（次のセクションコメント）までを範囲とする。
      final relatedEnd = src.indexOf(
        '// ==========================================',
        relatedStart + 100,
      );
      expect(relatedEnd, greaterThan(relatedStart));
      final related = src.substring(relatedStart, relatedEnd);

      expect(
        related,
        isNot(contains('heroTag')),
        reason: '関連グリッドは Hero を有効にしない',
      );
    });

    test('詳細画面の関連グリッドから開いた詳細もタグ無しで呼ばれる', () {
      // _openSimilarWork / 関連の push も同様。これらの遷移先に
      // Hero タグが渡らないことを保証する。
      final src = _readSource('lib/screens/illust_detail_ui_components.dart');
      final pushSites = <int>[];
      var cursor = 0;
      while (true) {
        final i = src.indexOf('IllustDetailScreen(', cursor);
        if (i < 0) break;
        pushSites.add(i);
        cursor = i + 1;
      }
      // build 内の _openSimilarWork と _buildRelatedSection の2箇所。
      expect(pushSites, isNotEmpty, reason: '詳細画面内の遷移先が存在する');
      for (final site in pushSites) {
        final call = src.substring(site, src.indexOf(')', site) + 1);
        expect(
          call,
          isNot(contains('heroTag')),
          reason: '詳細画面からの遷移は Hero を有効にしない: $call',
        );
      }
    });
  });
}

String _readSource(String path) {
  // テスト実行時のカレントディレクトリはパッケージルート。
  return File(path).readAsStringSync();
}

/// [src] 内の [startMarker] から、対応するカッコが閉じるまでを取り出す。
String _extractBlock(String src, String startMarker) {
  final start = src.indexOf(startMarker);
  expect(start, isNonNegative, reason: 'ブロックが存在する: $startMarker');
  var depth = 0;
  for (var i = start; i < src.length; i++) {
    final c = src[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  return src.substring(start);
}

/// [src] 内の [startMarker]（メソッド頭）から、その **本体**（波括弧が
/// 釣り合うまで）を取り出す。パラメタリストではなく実装全体が欲しいため。
String _extractBody(String src, String startMarker) {
  final start = src.indexOf(startMarker);
  expect(start, isNonNegative, reason: 'メソッドが存在する: $startMarker');
  final braceStart = src.indexOf('{', start);
  expect(braceStart, greaterThan(start), reason: '本体の開始波括弧がある');
  var depth = 0;
  for (var i = braceStart; i < src.length; i++) {
    final c = src[i];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  return src.substring(start);
}

/// [src] 内の [clsMarker]（例: `class Foo`）から次の `class` までを取り出す。
String _extractClass(String src, String clsMarker) {
  final start = src.indexOf(clsMarker);
  expect(start, isNonNegative, reason: 'クラスが存在する: $clsMarker');
  final next = src.indexOf('\nclass ', start + clsMarker.length);
  if (next < 0) return src.substring(start);
  return src.substring(start, next);
}
