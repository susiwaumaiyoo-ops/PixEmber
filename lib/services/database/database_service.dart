import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../ruri_model_manager.dart';
import '../../novel_model.dart';
import '../../illust_model.dart';

part 'database_core.part.dart';
part 'database_schema.part.dart';
part 'database_novel_meta.part.dart';
part 'database_history.part.dart';
part 'database_download_queue.part.dart';
part 'database_read_later.part.dart';
part 'database_mutes.part.dart';
part 'database_folders.part.dart';
part 'database_subscriptions.part.dart';
part 'database_search_history.part.dart';
part 'database_reading_notes.part.dart';
part 'database_tts.part.dart';
part 'database_usage_sessions.part.dart';
part 'database_image_vectors.part.dart';
part 'database_emotion_curves.part.dart';
part 'database_integrity.part.dart';
part 'database_backup.part.dart';

/// データベース初期化・管理用クラス
class DatabaseService extends DatabaseServiceBackup {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();
}
