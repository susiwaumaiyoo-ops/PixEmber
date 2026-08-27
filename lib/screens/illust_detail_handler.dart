import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart' as palette_generator;
import '../illust_model.dart';
import '../config/feature_flags.dart';
import '../services/pixiv_http_headers.dart';
import '../services/database_service.dart';
import '../services/pixiv_api_service.dart';
import '../services/download_service.dart';
import '../services/embedding_service.dart';
import '../services/ruri_model_manager.dart';
import '../services/illust_document_text.dart';
import '../services/rerank_service.dart';
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

      // 進捗・完了・エラーのコールバックを設定
      downloadService.onComplete = (groupId, workId, workType) async {
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
          state.showSuccessSnackBar('ダウンロードが完了しました');
        }
      };

      downloadService.onError =
          (groupId, workId, workType, errorCode, errorMessage) {
            if (state.mounted) {
              state.setState(() => state.isDownloading = false);
              state.showErrorSnackBar('ダウンロード失敗：$errorMessage');
            }
          };

      // キューに登録（非同期で処理開始）
      int? groupId;
      if (illust.type == 'ugoira') {
        groupId = await downloadService.enqueueUgoira(illust.id);
      } else {
        groupId = await downloadService.enqueueIllust(illust);
      }

      if (groupId == null) {
        // Web 等でダウンロード不可
        if (state.mounted) {
          state.setState(() => state.isDownloading = false);
          state.showErrorSnackBar('この環境ではダウンロードできません');
        }
      }
      // groupId が返った場合は非同期で処理が進行中。
      // 完了時に onComplete コールバックが呼ばれる。
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
            NetworkImage(previewUrl, headers: PixivHttpHeaders.image),
            maximumColorCount: 10,
          ).timeout(const Duration(seconds: 2));
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

  /// イラスト意味検索用に、キャプション+タグをベクトル化してDB保存する。
  ///
  /// - FeatureFlags.illustSemanticSearch が off の場合は完全 no-op。
  /// - モデル未導入時はスキップ（novel 詳細と同じ RuriModelManager 事前チェック）。
  /// - 失敗しても画面には一切影響しない（非同期・後回し・エラー握りつぶし）。
  /// - 呼び出し側は unawaited で UI スレッドをブロックしないこと。
  Future<void> ensureIllustEmbedding() async {
    if (!FeatureFlags.illustSemanticSearch) return;
    try {
      // 既存ベクトルの有無を確認（モデル未導入でも安全に呼べる）
      final missing = await DatabaseService().getIllustIdsWithoutEmbedding([
        illust.id,
      ]);
      if (missing.isEmpty) return; // 既に保存済み

      // AI モデル未ダウンロード時はスキップ（裏処理なのでユーザー動作をブロックしない）
      if (!await RuriModelManager().isModelPresent()) return;

      final embeddingService = EmbeddingService();
      final textForEmbedding = buildIllustDocumentText(illust);
      final embedding = await embeddingService.encodeDocument(textForEmbedding);
      final db = DatabaseService();
      await db.saveIllustEmbedding(workId: illust.id, embedding: embedding);
      // 検索用メタデータも合わせて保存（ハイブリッド検索の結合元）。
      // メタ保存失敗はベクトル検索を阻害しないよう個別に握りつぶす。
      try {
        await db.saveIllustMeta(illust);
      } catch (e) {
        debugPrint('イラスト検索メタ保存に失敗しました（無視して続行）: $e');
      }
    } catch (e) {
      debugPrint('イラストベクトル生成・保存に失敗しました（無視して続行）: $e');
    }
  }

  // ==========================================
  // ダイアログとスナックバー
  // ==========================================

  /// 購読登録ダイアログを表示し、ローカル（端末内 SQLite）に保存する。
  ///
  /// 外部バックエンドは使用しない。subscribed_tags テーブルへ (tag, 'illust')
  /// を保存し、重複登録は DatabaseService.addSubscribedTag 側で防止される。
  void showSubscriptionDialog(BuildContext context, String tag) {
    showDialog(
      context: context,
      builder: (dialogContext) {
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
                'この端末内に購読タグとして保存します。\n購読タグ一覧からタップで検索できます。',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(dialogContext);
                  try {
                    await DatabaseService().addSubscribedTag(tag, 'illust');
                    if (context.mounted) {
                      _showLocalSnackBar(
                        context,
                        '「$tag」を購読登録しました！',
                        Colors.green.shade800,
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      _showLocalSnackBar(
                        context,
                        '購読登録に失敗しました: $e',
                        Colors.red.shade800,
                      );
                    }
                  }
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

  /// 購読登録用の軽量 SnackBar（状態に依存しない context ベース）。
  void _showLocalSnackBar(
    BuildContext context,
    String message,
    Color backgroundColor,
  ) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // ==========================================
  // 関連作品・ブックマーク・ミュート
  // ==========================================

  Future<void> fetchRelatedIllusts(IllustDetailState state) async {
    try {
      final api = PixivApiService();
      final results = await api.getIllustRelated(illust.id);

      // 関連イラストの Rerank（高精度モード）。
      // flag off / モデル未ready / 失敗時は API の元順序を維持（no-op）。
      List<Illust> ordered = results;
      if (FeatureFlags.illustRelatedRerank) {
        try {
          if (await RerankService().isAvailable) {
            final query = buildIllustDocumentText(illust);
            final candidates = results.asMap().entries.map((e) {
              return RerankCandidate(
                workId: e.value.id,
                documentText: buildIllustDocumentText(e.value),
                baseScore: 1.0 / (e.key + 1), // 順位を残す（1.0固定禁止）
              );
            }).toList();
            final reranked = await RerankService().rerank(
              query: query,
              candidates: candidates,
            );
            // rerankScore で降順ソートした順に並べ替え
            final byWorkId = {for (final c in reranked) c.workId: c};
            final sorted = List<Illust>.from(results);
            sorted.sort((a, b) {
              final ra = byWorkId[a.id]?.rerankScore ?? 0.0;
              final rb = byWorkId[b.id]?.rerankScore ?? 0.0;
              return rb.compareTo(ra);
            });
            ordered = sorted;
          }
        } catch (e) {
          debugPrint('関連イラスト rerank に失敗しました（元順序で継続）: $e');
          ordered = results; // フォールバック
        }
      }

      if (state.mounted) {
        state.setState(() {
          state.relatedIllusts = ordered;
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
