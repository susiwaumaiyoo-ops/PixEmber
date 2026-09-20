// 17c: 検索目的地を削除し、[HomeSurfaceMode] は完全に削除された。
//
// 16c-3a ではホーム/検索の表示モード（surfaceMode）とリスナー寿命・
// コンテンツ種別の正規化を検証していたが、17c で検索がホーム内の
// 検索バー/SearchAssistView（[HomeSearchUiMode]）だけで完結するように
// なったため、これらは全て不要になった。
//
// 本テストは「サーフェスモードの仕組みが二度と復活しないこと」を
// 監視する（ソース監査）。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/screens/home_screen_state.dart';

/// ソース監査: 本番コード（lib/）にだけ現れたかを判定する。
/// （テストファイルの名前や中身に「HomeSurfaceMode」が含まれていても
///  偽陽性にならないよう、lib/ のみを対象にする）
Future<String> _readLibSource() async {
  return File('lib/screens/home_screen_state.dart').readAsString();
}

void main() {
  group('HomeSurfaceMode は削除された（17c）', () {
    test('enum がソースに存在しない', () async {
      final src = await _readLibSource();
      expect(
        src.contains('enum HomeSurfaceMode'),
        isFalse,
        reason: '17c: 検索目的地と共に HomeSurfaceMode を削除した',
      );
      expect(
        src.contains('HomeSurfaceMode'),
        isFalse,
        reason: 'enum への参照も残さない',
      );
    });

    test('サーフェスモードのフィールド・getter が存在しない', () async {
      final src = await _readLibSource();
      expect(src.contains('attachSurfaceMode'), isFalse);
      expect(src.contains('surfaceModeListenable'), isFalse);
      expect(src.contains('_surfaceMode'), isFalse);
      expect(src.contains('isSearchMode'), isFalse);
      expect(src.contains('isFeedMode'), isFalse);
    });

    test('コンテンツ種別の正規化機構が存在しない', () async {
      // 検索モードでフィーリング発掘を抑止していた仕組み。
      // 17c で検索モード自体がなくなったため不要。
      final src = await _readLibSource();
      expect(src.contains('_isFeelingDiscoveryAllowed'), isFalse);
      expect(src.contains('_lastSearchableContentIndex'), isFalse);
      expect(src.contains('normalizeContentIndex'), isFalse);
    });

    test('PixivViewerHome はサーフェスモードのパラメータを持たない', () {
      // 17c: AppShell とのやり取りは onSearchDestinationRequested /
      // onHomeDestinationRequested だけだった。両方とも削除したため、
      // const で必須パラメータなしの構築ができる。
      // （コールバックの getter が存在すればコンパイルエラーになるので、
      //  これが「削除された」ことの回帰テストになる）
      expect(const PixivViewerHome(), isNotNull);
    });
  });
}
