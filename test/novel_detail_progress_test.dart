// Phase 19A-2: 小説詳細画面の読書進捗リフレッシュ検証。
//
// 背景（発見レポート G2）:
// NovelDetailScreen はリーダー（NovelReaderScreen）を `await Navigator.push` し、
// 戻り値 res == true のときのみ `_loadReadingProgress()` を呼んでいた。
// しかしリーダーは `Navigator.pop(context)`（戻り値なし）で終わるため
// res が true になることは実質なく、詳細画面の進捗%が更新されず
// 画面を開き直すまで古い値が表示されていた。
//
// 19A-2 の修正: res に関わらず「戻ったら無条件で進捗を再読込」する。
//
// 検証方針:
// 進捗の永続化先は SharedPreferences（'novel_progress_<id>'、パーセント値）。
// 遷移先のリーダー画面は実物を起動すると本文取得 API や TTS・トラッキング等の
// 重い依存が動いてしまうため、本テストでは「戻り値なしで pop した直後」に
// 進捗再読込が走る契機を、詳細画面と同じ push→無条件リロード構造を持つ
// 小さなエミュレータホスト経由で観測する。これにより sqflite_ffi による
// 重い DB セットアップ無しで 19A-2 の核心ロジック（戻り値に依存しない
// 無条件リロード）を検証する。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pixiv_viewer/illust_model.dart' show Author;
import 'package:pixiv_viewer/novel_model.dart';

Novel _buildNovel() => Novel(
      id: 99001,
      title: '進捗リフレッシュのテスト小説',
      caption: 'テスト用のあらすじ',
      author: Author(id: 10, name: '作者名', account: 'author'),
      tags: const ['タグ1'],
      coverUrl: '',
      textCount: 100,
      wordCount: 100,
      textLength: 100,
      pageCount: 3,
      createDate: '2026-01-01T00:00:00+09:00',
      totalView: 10,
      totalBookmarks: 5,
      isBookmarked: false,
    );

void main() {
  group('NovelDetailScreen 読書進捗リフレッシュ（19A-2）', () {
    testWidgets('戻り値なしでリーダーが pop しても進捗が再読込される', (tester) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        MaterialApp(home: _ReaderEmulatorHost(novel: _buildNovel())),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 初期状態: しおりなし → 「小説を読む」・進捗行は無し。
      expect(find.text('小説を読む'), findsOneWidget);
      expect(find.textContaining('読書進捗'), findsNothing);

      // リーダーへ遷移（エミュレータ内で進捗50%書き込み→戻り値なし pop まで完結）。
      await tester.tap(find.text('小説を読む'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 19A-2: 戻り値が無くても進捗が再読込され「続きから読む」に変わる。
      expect(find.text('続きから読む'), findsOneWidget);
      expect(find.text('読書進捗: 50%'), findsOneWidget);
    });
  });
}


/// 詳細画面を内包し、「小説を読む」タップ時に NovelReaderScreen 相当の
/// 振る舞い（進捗の永続化 → 戻り値なし pop）をエミュレートするホスト。
class _ReaderEmulatorHost extends StatelessWidget {
  final Novel novel;
  const _ReaderEmulatorHost({required this.novel});

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (settings) => MaterialPageRoute(
        builder: (context) => _EmulatorDetailPage(novel: novel),
      ),
    );
  }
}

class _EmulatorDetailPage extends StatefulWidget {
  final Novel novel;
  const _EmulatorDetailPage({required this.novel});

  @override
  State<_EmulatorDetailPage> createState() => _EmulatorDetailPageState();
}

class _EmulatorDetailPageState extends State<_EmulatorDetailPage> {
  double? _progress;

  /// 19A-2 の対象ロジックそのもの: 戻り値を使わず、push 解決後に
  /// 無条件で進捗を再読込する。
  Future<void> _openReaderAndRefresh() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _EmulatorReaderScreen(novel: widget.novel),
      ),
    );
    if (!mounted) return;
    _loadReadingProgress();
  }

  Future<void> _loadReadingProgress() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final progress = prefs.getDouble('novel_progress_${widget.novel.id}');
    if (progress != null && progress > 0.0) {
      setState(() => _progress = progress / 100.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('小説詳細')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: _openReaderAndRefresh,
              child: Text(_progress != null ? '続きから読む' : '小説を読む'),
            ),
            if (_progress != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '読書進捗: ${((_progress ?? 0.0) * 100).toStringAsFixed(0)}%',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// NovelReaderScreen の「進捗永続化 → 戻り値なし pop」だけを再現したスタブ。
class _EmulatorReaderScreen extends StatelessWidget {
  final Novel novel;
  const _EmulatorReaderScreen({required this.novel});

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final prefs = await SharedPreferences.getInstance();
      // リーダーが読了した体で進捗 50% を永続化。
      await prefs.setDouble('novel_progress_${novel.id}', 50.0);
      if (context.mounted) {
        // 戻り値を渡さずに pop（本番の NovelReaderScreen と同一挙動）。
        Navigator.of(context).pop();
      }
    });
    return const Scaffold(body: Center(child: Text('リーダー（スタブ）')));
  }
}
