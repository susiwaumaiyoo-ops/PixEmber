import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart' as palette_generator;
import '../illust_model.dart';
import '../services/database_service.dart';
import '../services/pixiv_api_service.dart';
import '../services/download_service.dart';
import 'illust_detail_state.dart';

class IllustDetailHandler {
  final Illust illust;
  final ValueChanged<String>? onTagTap;
  final ValueChanged<bool>? onBookmarkChanged;

  IllustDetailHandler({
    required this.illust,
    this.onTagTap,
    this.onBookmarkChanged,
  });

  // ==========================================
  // 初期化とヘルパーメソッド
  // ==========================================

  Future<void> downloadIllust(IllustDetailState state) async {
    if (state.isDownloading) return;
    state.setState(() => state.isDownloading = true);

    try {
      final downloadService = DownloadService();
      if (illust.type == 'ugoira') {
        downloadService.addUgoiraToQueue(illust.id);
      } else {
        downloadService.addToQueue(illust);
      }

      await downloadService.processQueue(
        onProgress: (workId, progress) {},
        onSuccess: (workId, path) async {
          final db = DatabaseService();
          await db.insertDownloadedIllust(
            workId: illust.id,
            title: illust.title,
            authorName: illust.author.name,
            type: illust.type,
          );
          if (state.mounted) {
            state.setState(() {
              state.isDownloaded = true;
              state.isDownloading = false;
            });
            state.showSuccessSnackBar('ダウンロード成功：$path');
          }
        },
        onError: (workId, error) {
          if (state.mounted) {
            state.setState(() => state.isDownloading = false);
            state.showErrorSnackBar('ダウンロード失敗：$error');
          }
        },
      );
    } catch (e) {
      if (state.mounted) {
        state.setState(() => state.isDownloading = false);
        state.showErrorSnackBar('エラーが発生しました：$e');
      }
    }
  }

  Future<void> generatePalette(IllustDetailState state) async {
    final previewUrl = illust.urls.preview;
    if (previewUrl == null || previewUrl.isEmpty) return;
    try {
      final palette =
          await palette_generator.PaletteGenerator.fromImageProvider(
            NetworkImage(previewUrl),
            maximumColorCount: 10,
          ).timeout(const Duration(seconds: 5));
      if (state.mounted) {
        state.setState(() {
          state.paletteGenerator = palette;
        });
      }
    } catch (e) {
      debugPrint('パレット抽出に失敗しました: $e');
    }
  }

  Future<void> recordHistory(IllustDetailState state) async {
    try {
      final db = DatabaseService();
      await db.insertOrUpdateHistory(
        workId: illust.id,
        title: illust.title,
        authorName: illust.author.name,
        previewUrl: illust.urls.preview ?? '',
        type: 'illust',
      );
    } catch (e) {
      debugPrint('閲覧履歴の追加に失敗しました: $e');
    }
  }

  // ==========================================
  // ダイアログとスナックバー
  // ==========================================

  void showSubscriptionDialog(BuildContext context, String tag) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF222222),
          title: Text(
            'タグ「$tag」の購読登録',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'このタグの新しい作品が投稿されたときに通知を受け取ります。',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  // TODO: サブスクリプション登録実装
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.pinkAccent,
                  foregroundColor: Colors.white,
                ),
                child: const Text('登録する'),
              ),
            ],
          ),
        );
      },
    );
  }

  void showSuccessSnackBar(IllustDetailState state, String message) {
    if (state.context != null) {
      ScaffoldMessenger.of(state.context!).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green.shade800,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  void showErrorSnackBar(IllustDetailState state, String message) {
    if (state.context != null) {
      ScaffoldMessenger.of(state.context!).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red.shade800,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  // ==========================================
  // 関連作品・ブックマーク・ミュート
  // ==========================================

  Future<void> fetchRelatedIllusts(IllustDetailState state) async {
    try {
      final api = PixivApiService();
      final results = await api.getIllustRelated(illust.id);
      if (state.mounted) {
        state.setState(() {
          state.relatedIllusts = results;
          state.isLoadingRelated = false;
        });
      }
    } catch (_) {
      if (state.mounted) {
        state.setState(() {
          state.isLoadingRelated = false;
          state.hasRelatedError = true;
        });
      }
    }
  }

  Future<void> toggleBookmark(IllustDetailState state) async {
    if (state.isToggling) return;
    state.setState(() => state.isToggling = true);

    final toAdd = !state.isBookmarked;
    final api = PixivApiService();
    final success = await api.toggleBookmark(illust.id, false, toAdd);

    if (!state.mounted) return;

    if (success) {
      state.setState(() {
        state.isBookmarked = toAdd;
        state.bookmarkCountOffset += toAdd ? 1 : -1;
        if (onBookmarkChanged != null) {
          onBookmarkChanged!(toAdd);
        }
      });
      if (state.context != null) {
        ScaffoldMessenger.of(state.context!).showSnackBar(
          SnackBar(
            content: Text(toAdd ? 'ブックマークに追加しました' : 'ブックマークを解除しました'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } else {
      state.setState(() => state.isToggling = false);
      if (state.context != null) {
        ScaffoldMessenger.of(state.context!).showSnackBar(
          SnackBar(
            content: const Text('ブックマーク操作に失敗しました'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> muteAuthor(IllustDetailState state) async {
    final userId = illust.author.id;
    final authorName = illust.author.name;

    showDialog(
      context: state.context!,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF222222),
          title: Text(
            '作者「$authorName」をミュートしますか？',
            style: const TextStyle(color: Colors.white),
          ),
          content: const Text(
            'この作者の作品が表示されなくなります。',
            style: TextStyle(color: Colors.grey),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル', style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () async {
                final navigator = Navigator.of(context);
                final messenger = state.context != null
                    ? ScaffoldMessenger.of(state.context!)
                    : null;
                final db = DatabaseService();
                await db.addMute(muteType: 'user', value: userId.toString());
                navigator.pop();
                if (messenger != null) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text('作者「$authorName」をミュートしました'),
                      backgroundColor: Colors.green.shade800,
                    ),
                  );
                }
              },
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('ミュートする'),
            ),
          ],
        );
      },
    );
  }
}
