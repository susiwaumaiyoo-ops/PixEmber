part of 'database_service.dart';

/// 整合性維持（Integrity）: 無効な小説レコードの遅延削除
/// Phase 7a: DatabaseService から分離（ロジック変更なし）。
abstract class DatabaseServiceIntegrity extends DatabaseServiceEmotionCurves {
  /// 起動時に1回だけ実行する軽量なデータ修復。
  ///
  /// 旧バグ版で保存された「id=0（無効）」の小説レコードを novels / novel_embeddings
  /// から削除する。これらは getNovelById(0) で必ず 404 になるため、検索結果に
  /// 二度と出ないよう排除する。DBバージョンは変更しない（単純な DELETE のみ）。
  /// 費用は最大でも既存件数分の数行 DELETE なので、起動時のブロックは無視できる。
  Future<void> cleanupInvalidNovelRecords() async {
    try {
      final db = await database;
      // id=0 は明らかに無効なレコード
      final deletedNovels = await db.delete(
        'novels',
        where: 'id = ?',
        whereArgs: [0],
      );
      final deletedEmbeddings = await db.delete(
        'novel_embeddings',
        where: 'work_id = ?',
        whereArgs: [0],
      );
      final deletedText = await db.delete(
        'novel_text',
        where: 'work_id = ?',
        whereArgs: [0],
      );
      if (deletedNovels > 0 || deletedEmbeddings > 0 || deletedText > 0) {
        debugPrint(
          '[Cleanup] 無効な小説レコード(id=0)を削除しました: '
          'novels=$deletedNovels, embeddings=$deletedEmbeddings, text=$deletedText',
        );
      }
    } catch (e) {
      debugPrint('[Cleanup] 無効レコード削除中にエラー: $e');
    }
  }

  /// 指定した小説IDが「削除済み / 存在しない（404）」と判定された場合に呼び出し、
  /// novels / novel_embeddings / novel_text から該当レコードを遅延削除する。
  ///
  /// 一括APIバリデーションは行わず、ユーザーが実際にタップして 404 になった時点で
  /// のみ呼ぶ（レート制限回避）。次回検索・一覧からは該当作品が出なくなる。
  /// 小説詳細取得エラーから「本当にローカル削除してよいか」を判定する。
  ///
  /// 削除してよい（真の削除・非公開・閲覧不可）:
  ///   - エラー本文が「小説が見つかりませんでした」等、作品単位の不存在
  ///   - 404 かつエンドポイント不存在系の文言を含まない
  ///
  /// 削除してはいけない（API側仕様変更・認証・通信・レート制限の疑い）:
  ///   - 「指定されたエンドポイントは存在しません」「エンドポイントが存在しない」
  ///   - 401 / 403 / 429（認証・権限・レート制限）
  ///   - それ以外の通信エラー・例外
  static bool isGenuineNovelMissing(String errorMessage) {
    final msg = errorMessage.toLowerCase();
    // エンドポイント不存在系は絶対に削除しない（API仕様変更の誤判定）
    if (msg.contains('指定されたエンドポイント') ||
        msg.contains('エンドポイント') ||
        msg.contains('endpoint') ||
        msg.contains('存在しません')) {
      return false;
    }
    // 認証・権限・レート制限は削除しない
    if (msg.contains('401') ||
        msg.contains('403') ||
        msg.contains('429') ||
        msg.contains('unauthorized') ||
        msg.contains('forbidden') ||
        msg.contains('rate limit')) {
      return false;
    }
    // 作品が存在しない（404 / 見つかりませんでした）のみ削除対象
    return msg.contains('404') || msg.contains('見つかりませんでした');
  }

  /// 404等で存在しないと判定された小説のローカル残骸を遅延削除（novels/embeddings/text）。
  /// ただし [errorMessage] が与えられた場合は [isGenuineNovelMissing] で
  /// 真の削除かどうかを厳格に判定し、API側仕様変更等の疑いがあれば削除しない。
  Future<void> removeInvalidNovel(int novelId, {String? errorMessage}) async {
    if (novelId <= 0) return;
    if (errorMessage != null && !isGenuineNovelMissing(errorMessage)) {
      debugPrint(
        '[Cleanup] エラーが「真の小説削除」ではないため削除を見送りました: id=$novelId (error=$errorMessage)',
      );
      return;
    }
    try {
      final db = await database;
      await db.delete('novels', where: 'id = ?', whereArgs: [novelId]);
      await db.delete(
        'novel_embeddings',
        where: 'work_id = ?',
        whereArgs: [novelId],
      );
      await db.delete('novel_text', where: 'work_id = ?', whereArgs: [novelId]);
      debugPrint('[Cleanup] 404 小説を削除しました: id=$novelId');
    } catch (e) {
      debugPrint('[Cleanup] 404 小説削除中にエラー(id=$novelId): $e');
    }
  }
}
