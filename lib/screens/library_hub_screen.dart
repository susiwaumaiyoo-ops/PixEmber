import 'package:flutter/material.dart';

import '../services/database_service.dart';
import '../theme/app_spacing.dart';
import '../widgets/design_system/app_panel.dart';
import '../widgets/design_system/app_section_header.dart';
import 'bookmark_list_screen.dart';
import 'duplicate_finder_screen.dart';
import 'download_queue_screen.dart';
import 'folder_list_screen.dart';
import 'history_screen.dart';
import 'offline_bookshelf_screen.dart';
import 'read_later_screen.dart';
import 'statistics_screen.dart';
import 'subscriptions_screen.dart';

/// ライブラリHub（Phase 16c-2b）。
///
/// Drawer にあった「保存・履歴・オフライン・整理」の9導線を1画面に集約し、
/// ボトムナビの「ライブラリ」目的地に対応する。
///
/// - **Drawer 側の項目は削除せず残す**（16c-2b は導線の複製のみ。
///   削除は 16c-3/16c-4 で到達性が確認できてから）。
/// - 未読数（あとで読む / 購読タグ）は [DatabaseService] から取得するが、
///   失敗時は Hub 全体をエラーにせず Badge を非表示にする。
/// - [onTagTap] は [StatisticsScreen] のタグタップをホームへ伝える。
///   16c-2c で AppShell がホームタブへ切り替えてから呼ぶ。
class LibraryHubScreen extends StatefulWidget {
  const LibraryHubScreen({
    super.key,
    this.onTagTap,
    this.loadReadLaterUnreadCount,
    this.loadSubscriptionUnreadCount,
  });

  /// 統計画面のタグがタップされたときに呼ばれる。
  final ValueChanged<String>? onTagTap;

  /// 「あとで読む」の未読数。テスト注入用。未指定なら [DatabaseService]。
  final Future<int> Function()? loadReadLaterUnreadCount;

  /// 「購読タグ」の未読数。テスト注入用。未指定なら [DatabaseService]。
  final Future<int> Function()? loadSubscriptionUnreadCount;

  @override
  State<LibraryHubScreen> createState() => LibraryHubScreenState();
}

class LibraryHubScreenState extends State<LibraryHubScreen> {
  /// 未読数のキャッシュ。null は「未取得 or 取得失敗」＝ Badge 非表示。
  int? _readLaterUnread;
  int? _subscriptionUnread;

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  /// 未読数を再取得する。
  ///
  /// 各対象画面（あとで読む / 購読タグ）から戻った後に AppShell が呼ぶ。
  /// 失敗時は例外を投げず、Badge を非表示のままにする（Hub 全体は表示する）。
  Future<void> refreshCounts() async {
    final readLater = await _loadReadLater();
    final subscription = await _loadSubscription();

    if (!mounted) return;
    setState(() {
      // -1 は失敗の sentinel → null（非表示）。
      _readLaterUnread = readLater >= 0 ? readLater : null;
      _subscriptionUnread = subscription >= 0 ? subscription : null;
    });
  }

  /// 失敗時は -1（Badge 非表示の sentinel）を返す。
  ///
  /// 注入された loader が `Future<Never>` に推論される場合、
  /// `Future.catchError` は「error handler が future の型を返さなければ
  /// ならない」ArgumentError を投げてしまう。そのため try/catch で包む。
  Future<int> _loadReadLater() async {
    try {
      return await (widget.loadReadLaterUnreadCount ??
          DatabaseService().getReadLaterUnreadCount)();
    } catch (_) {
      return -1;
    }
  }

  Future<int> _loadSubscription() async {
    try {
      return await (widget.loadSubscriptionUnreadCount ??
          DatabaseService().getSubscriptionUnreadCount)();
    } catch (_) {
      return -1;
    }
  }

  void _loadCounts() => refreshCounts();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ライブラリ')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          // ---- 保存 ----
          const AppSectionHeader('保存', icon: Icons.bookmarks_outlined),
          const SizedBox(height: AppSpacing.sm),
          AppPanel(
            onTap: null,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _entry(
                  icon: Icons.bookmark,
                  title: 'しおり一覧',
                  onTap: () => _push(const BookmarkListScreen()),
                ),
                _entry(
                  icon: Icons.bookmark_add_outlined,
                  title: 'あとで読む',
                  unread: _readLaterUnread,
                  onTap: () => _push(const ReadLaterScreen()),
                ),
                _entry(
                  icon: Icons.stars,
                  title: '購読タグ',
                  unread: _subscriptionUnread,
                  onTap: () => _push(
                    SubscriptionsScreen(
                      onTagSelected: (tag, type) {
                        // ホーム側でタグ検索を実行する必要があるが、
                        // この画面はその手段を持たない。16c-2c で AppShell
                        // 経由でホームへ伝える。
                        widget.onTagTap?.call(tag);
                      },
                    ),
                  ),
                ),
                _entry(
                  icon: Icons.folder,
                  title: 'お気に入りフォルダ',
                  onTap: () => _push(const FolderListScreen()),
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSpacing.sectionGap),

          // ---- 履歴とオフライン ----
          const AppSectionHeader('履歴とオフライン', icon: Icons.history_toggle_off),
          const SizedBox(height: AppSpacing.sm),
          AppPanel(
            onTap: null,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _entry(
                  icon: Icons.history,
                  title: '閲覧履歴',
                  onTap: () => _push(const HistoryScreen()),
                ),
                _entry(
                  icon: Icons.cloud_download,
                  title: 'オフライン本棚',
                  onTap: () => _push(const OfflineBookshelfScreen()),
                ),
                _entry(
                  icon: Icons.download_for_offline,
                  title: 'ダウンロード管理',
                  onTap: () => _push(const DownloadQueueScreen()),
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSpacing.sectionGap),

          // ---- 整理と分析 ----
          const AppSectionHeader('整理と分析', icon: Icons.insights),
          const SizedBox(height: AppSpacing.sm),
          AppPanel(
            onTap: null,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _entry(
                  icon: Icons.bar_chart,
                  title: '閲覧統計',
                  onTap: () =>
                      _push(StatisticsScreen(onTagTap: widget.onTagTap)),
                ),
                _entry(
                  icon: Icons.find_replace,
                  title: '重複画像の検出',
                  onTap: () => _push(const DuplicateFinderScreen()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _entry({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    int? unread,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    final showBadge = unread != null && unread > 0;

    return Semantics(
      button: true,
      label: showBadge ? '$title・未読$unread件' : title,
      child: ListTile(
        leading: Icon(icon, color: colorScheme.primary),
        title: Text(title),
        trailing: showBadge
            ? Badge(
                label: Text(
                  // M3 Badge の標準: 999 を超える場合は 999+。
                  unread > 999 ? '999+' : unread.toString(),
                ),
              )
            : null,
        onTap: onTap,
      ),
    );
  }

  Future<void> _push(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    // 対象画面から戻った後に未読数を再取得。
    await refreshCounts();
  }
}
