// 設定ハブ画面（非AI機能パック Phase N7）。
//
// 設計メモ:
// - 新規の設定ストレージを作らず、既存の各画面と同一キー
//   （novel_pref_* / search_presets_v1）に読み書きすることで、
//   画面内既存設定との互換性を保つ。
// - 導線先はすべて既存画面をそのまま push する。
// - 検索UX（3タブ・アシストビュー）には一切変更を入れない。
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_spacing.dart';
import '../services/auto_summary_bridge_controller.dart';
import '../services/auto_summary_controller.dart';
import '../services/auto_summary_settings.dart';
import '../services/auto_summary_snapshot.dart';
import '../services/local_llm_service.dart';
import '../services/llm_model_import_service.dart';
import '../services/search_preset_service.dart';
import '../services/theme_service.dart';
import 'auto_summary_status_screen.dart';
import 'ai_index_maintenance_screen.dart';
import 'ai_recommend_feed_screen.dart';
import 'backup_manager_screen.dart';
import 'bookmark_list_screen.dart';
import 'companion_settings_screen.dart';
import 'download_queue_screen.dart';
import 'folder_list_screen.dart';
import 'llm_model_library_screen.dart';
import 'offline_bookshelf_screen.dart';
import 'read_later_screen.dart';

/// 設定ハブ画面。ホーム画面の Drawer から開く。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // 小説リーダー設定（リーダー HUD と同一キー: novel_reader_data.dart 参照）
  double _fontSize = 18.0;
  double _lineHeight = 1.8;
  double _scrollSpeed = 3.0;
  double _ttsRate = 1.0;
  int _themeMode = 1;
  String _rubyModeName = 'show';
  bool _ttsReadRuby = false;
  bool _showReadingTime = true;
  bool _showEmotionColor = false;

  // 保存した検索プリセット
  List<SearchPreset> _presets = const [];

  // ローカルAI（実験）: 小説AI要約のモデル状態
  bool _llmSupported = false;
  bool _llmLoading = false;
  String? _llmSelectedPath;

  // ローカルAI（実験）: 実行設定（A/B: CPUスレッド・推論バックエンド）
  LlmRuntimeSettings _llmRuntime = const LlmRuntimeSettings();
  AutoSummarySettings _autoSummary = const AutoSummarySettings();

  // 自動要約の実行主体コントローラ（B2-4: FGS ブリッジへ切替済み）。
  late final AutoSummaryController _autoSummaryController =
      AutoSummaryBridgeController();

  @override
  void dispose() {
    _autoSummaryController.dispose();
    super.dispose();
  }

  // Phase 11d: アプリのテーマモード（System / Light / Dark）。
  ThemeMode _appThemeMode = ThemeMode.system;

  void _openAutoSummaryStatus() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            AutoSummaryStatusScreen(controller: _autoSummaryController),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // Phase 11d: シングルトンの現在値で即座に描画（遅延なし）。
    _appThemeMode = ThemeService().themeMode;
    _loadAll();
    _loadLlmModel();
    _loadLlmRuntime();
    _loadAutoSummary();
  }

  /// Phase 11d: テーマモードを切り替えて永続化する。
  Future<void> _setAppThemeMode(ThemeMode mode) async {
    if (_appThemeMode == mode) return;
    setState(() => _appThemeMode = mode);
    await ThemeService().setMode(mode);
  }

  /// 自動要約の設定を読み込む。
  Future<void> _loadAutoSummary() async {
    final s = await AutoSummarySettings.load();
    if (mounted) setState(() => _autoSummary = s);
  }

  /// 自動要約の設定を保存して反映する。
  Future<void> _setAutoSummary(AutoSummarySettings next) async {
    if (mounted) setState(() => _autoSummary = next);
    await next.save();
  }

  /// 「今すぐ実行」ボタン: controller.runNow()（内部で ensureServiceReady）を呼ぶ。
  /// ensure は controller 側に一本化済み（二重 ensure しない）。
  Future<void> _runAutoSummaryNow() async {
    final ok = await _autoSummaryController.runNow();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '自動要約を開始しました' : '自動要約サービスの起動に失敗しました')),
    );
  }

  /// タグ追加ダイアログ。
  ///
  /// controller のライフサイクルは [_TagAddDialog] 側に委譲する。
  /// 呼び出し側で await 直後に dispose すると、exit アニメ中は TextField が
  /// まだ生存しており '_dependents.isEmpty' アサートで落ちるため。
  Future<void> _addAutoSummaryTag() async {
    final tag = await showDialog<String>(
      context: context,
      builder: (context) => const _TagAddDialog(),
    );
    final t = tag?.trim();
    if (t == null || t.isEmpty) return;
    if (_autoSummary.tags.contains(t)) return;
    await _setAutoSummary(
      _autoSummary.copyWith(tags: [..._autoSummary.tags, t]),
    );
  }

  Future<void> _removeAutoSummaryTag(String tag) async {
    await _setAutoSummary(
      _autoSummary.copyWith(
        tags: _autoSummary.tags.where((e) => e != tag).toList(),
      ),
    );
  }

  /// ローカルAI（実験）の実行設定を読み込む。
  Future<void> _loadLlmRuntime() async {
    final s = await LlmRuntimeSettings.load();
    if (mounted) setState(() => _llmRuntime = s);
  }

  /// CPU スレッド要求を変更して保存する。
  Future<void> _setLlmCpuThreads(int threads) async {
    final next = _llmRuntime.copyWith(cpuThreads: threads);
    if (mounted) setState(() => _llmRuntime = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(LlmRuntimeSettings.prefKeyCpuThreads, next.cpuThreads);
    } catch (e) {
      debugPrint('スレッド設定の保存に失敗しました: $e');
    }
  }

  /// 推論バックエンド（自動/NPU/GPU/CPU）を切り替えて保存する。
  Future<void> _setLlmBackend(LlmBackend value) async {
    final next = _llmRuntime.copyWith(backend: value);
    if (mounted) setState(() => _llmRuntime = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        LlmRuntimeSettings.prefKeyBackend,
        next.backend.name,
      );
    } catch (e) {
      debugPrint('バックエンド設定の保存に失敗しました: $e');
    }
  }

  /// ローカルAI（実験）のモデル状態を読み込む。
  Future<void> _loadLlmModel() async {
    if (!LlmModelPaths.isSupportedPlatform()) {
      if (mounted) setState(() => _llmSupported = false);
      return;
    }
    if (mounted) setState(() => _llmLoading = true);
    try {
      final selected = await LlmModelPaths.resolveModelPath();
      if (!mounted) return;
      setState(() {
        _llmSupported = true;
        _llmSelectedPath = selected;
        _llmLoading = false;
      });
    } catch (e) {
      debugPrint('ローカルAIモデルの読み込みに失敗しました: $e');
      if (mounted) setState(() => _llmLoading = false);
    }
  }

  /// モデル選択シートを開き、保存があれば状態を更新する。
  Future<void> _showLlmModelSheet() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const _LlmModelSheet(),
    );
    if (changed == true) {
      await _loadLlmModel();
    }
  }

  /// 非 Android 向けの案内ダイアログ。
  void _showLlmUnsupportedDialog() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colorScheme.surfaceContainerHigh,
        title: Text(
          'AI要約（実験）',
          style: theme.textTheme.titleLarge?.copyWith(
            color: colorScheme.onSurface,
          ),
        ),
        content: Text(
          'この機能は実験中です。現時点では Android のみ利用できます。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('OK', style: TextStyle(color: colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  Future<void> _loadAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final presets = await SearchPresetService().load();
      if (!mounted) return;
      setState(() {
        _fontSize = prefs.getDouble('novel_pref_font_size') ?? 18.0;
        _lineHeight = prefs.getDouble('novel_pref_line_height') ?? 1.8;
        _scrollSpeed = prefs.getDouble('novel_pref_scroll_speed') ?? 3.0;
        _ttsRate = prefs.getDouble('novel_pref_tts_rate') ?? 1.0;
        final theme = prefs.getInt('novel_pref_theme_mode') ?? 1;
        _themeMode = (theme >= 0 && theme <= 2) ? theme : 1;
        final ruby = prefs.getString('novel_pref_ruby_mode') ?? 'show';
        _rubyModeName = const ['show', 'brackets', 'hide'].contains(ruby)
            ? ruby
            : 'show';
        _ttsReadRuby = prefs.getBool('novel_pref_tts_read_ruby') ?? false;
        _showReadingTime =
            prefs.getBool('novel_pref_show_reading_time') ?? true;
        _showEmotionColor =
            prefs.getBool('novel_pref_show_emotion_color') ?? false;
        _presets = presets;
      });
    } catch (e) {
      debugPrint('設定の読み込みに失敗しました: $e');
    }
  }

  /// シート閉じ後に件数ラベルを更新する。
  Future<void> _loadPresets() async {
    try {
      final list = await SearchPresetService().load();
      if (!mounted) return;
      setState(() => _presets = list);
    } catch (e) {
      debugPrint('保存した検索の読み込みに失敗しました: $e');
    }
  }

  Future<void> _saveDouble(String key, double value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(key, value);
    } catch (e) {
      debugPrint('設定の保存に失敗しました ($key): $e');
    }
  }

  Future<void> _saveInt(String key, int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, value);
    } catch (e) {
      debugPrint('設定の保存に失敗しました ($key): $e');
    }
  }

  Future<void> _saveString(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (e) {
      debugPrint('設定の保存に失敗しました ($key): $e');
    }
  }

  Future<void> _saveBool(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (e) {
      debugPrint('設定の保存に失敗しました ($key): $e');
    }
  }

  void _open(Widget Function() builder) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => builder()));
  }

  void _showPresetSheet() {
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: colorScheme.surfaceContainerHigh,
      isScrollControlled: true,
      builder: (_) => const _PresetManagerSheet(),
    ).then((_) {
      if (mounted) _loadPresets();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Phase 11d: Theme.of 経由で色を解決（ハードコード色を駆逐）。
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        iconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
        title: Text('設定', style: theme.textTheme.titleLarge),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
        children: [
          _sectionHeader('外観'),
          _themeSelectorCard(colorScheme),
          _sectionHeader('検索'),
          _tile(
            icon: Icons.history,
            title: '保存した検索',
            subtitle: '${_presets.length}件・最大30件',
            onTap: _showPresetSheet,
          ),
          _sectionHeader('レコメンド'),
          _tile(
            icon: Icons.auto_awesome,
            title: 'AIレコメンド',
            subtitle: '閲覧履歴に基づく推薦フィード',
            onTap: () => _open(() => const AiRecommendFeedScreen()),
          ),
          _tile(
            icon: Icons.storage,
            title: 'AIインデックス管理',
            subtitle: 'AIモデルとインデックスの管理',
            onTap: () => _open(() => const AiIndexMaintenanceScreen()),
          ),
          _sectionHeader('小説リーダー'),
          _readerSection(),
          _sectionHeader('ライブラリ'),
          _tile(
            icon: Icons.folder,
            title: 'お気に入りフォルダ',
            subtitle: 'お気に入りフォルダの一覧',
            onTap: () => _open(() => const FolderListScreen()),
          ),
          _tile(
            icon: Icons.bookmark,
            title: 'あとで読む',
            subtitle: 'あとで読む一覧と整理',
            onTap: () => _open(() => const ReadLaterScreen()),
          ),
          _tile(
            icon: Icons.download_done,
            title: 'オフライン本棚',
            subtitle: 'ダウンロード済みの作品',
            onTap: () => _open(() => const OfflineBookshelfScreen()),
          ),
          _tile(
            icon: Icons.bookmark_outline,
            title: 'しおり一覧',
            subtitle: 'つけたしおりの一覧',
            onTap: () => _open(() => const BookmarkListScreen()),
          ),
          _sectionHeader('バックアップ'),
          _tile(
            icon: Icons.cloud_upload,
            title: 'バックアップ管理',
            subtitle: 'Googleドライブへのバックアップ・復元',
            onTap: () => _open(() => const BackupManagerScreen()),
          ),
          _tile(
            icon: Icons.download,
            title: 'ダウンロード管理',
            subtitle: 'ダウンロードキューの管理',
            onTap: () => _open(() => const DownloadQueueScreen()),
          ),
          _sectionHeader('ローカルAI（実験）'),
          _tile(
            icon: Icons.auto_awesome,
            title: '小説AI要約（実験）',
            subtitle: _llmSupported
                ? (_llmSelectedPath != null
                      ? 'モデル準備完了'
                      : _llmLoading
                      ? '読み込み中…'
                      : 'GGUFファイル未配置')
                : '実験中（Androidのみ）',
            onTap: _llmSupported
                ? _showLlmModelSheet
                : _showLlmUnsupportedDialog,
          ),
          _tile(
            icon: Icons.storage,
            title: 'モデルライブラリ',
            subtitle: '厳選モデル一覧・GGUFの管理（実験）',
            onTap: () => _open(() => const LlmModelLibraryScreen()),
          ),
          _llmRuntimeCard(),
          _autoSummaryCard(),
          _tile(
            icon: Icons.dns,
            title: 'PCサーバー（Companion）',
            subtitle: 'LAN経由でPC側で要約生成（実験）',
            onTap: () => _open(() => const CompanionSettingsScreen()),
          ),
          _sectionHeader('ライセンス'),
          _licenseBlock(),
        ],
      ),
    );
  }

  /// Phase 11d: アプリのテーマ（外観）切り替えカード。
  ///
  /// System / Light / Dark を [ThemeService] 経由で永続化し、
  /// main.dart の ValueListenableBuilder が即座に反映する。
  Widget _themeSelectorCard(ColorScheme colorScheme) {
    final theme = Theme.of(context);
    final modes = [
      (ThemeMode.system, 'システム設定に従う', Icons.brightness_auto),
      (ThemeMode.light, 'ライト', Icons.light_mode_outlined),
      (ThemeMode.dark, 'ダーク', Icons.dark_mode_outlined),
    ];
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      width: double.infinity,
      child: Material(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md - 2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('アプリテーマ', style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                'アプリ全体の色調を切り替えます。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  for (final (mode, label, icon) in modes)
                    ChoiceChip(
                      avatar: Icon(icon, size: 18),
                      label: Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _appThemeMode == mode
                              ? colorScheme.onPrimary
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      selected: _appThemeMode == mode,
                      selectedColor: colorScheme.primary,
                      backgroundColor: colorScheme.surfaceContainerHighest,
                      onSelected: (_) => _setAppThemeMode(mode),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// ローカルAI（実験）の実行設定（A: CPUスレッド比較候補、B: バックエンド選択）。
  ///
  /// 変更は SharedPreferences に保存され、次回のモデルロードから反映される
  /// （ロード済みエンジンの再利用条件に設定一致が含まれるため、
  /// 設定変更後は古いエンジンが再利用されない）。
  Widget _llmRuntimeCard() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      width: double.infinity,
      child: Material(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md - 2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('推論バックエンド', style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                '自動は NPU（Hexagon）→ GPU（OpenCL）→ CPU の順で検出します。'
                '非対応環境は自動で CPU に戻ります。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  for (final (value, label) in const [
                    (LlmBackend.auto, '自動'),
                    (LlmBackend.npu, 'NPU（Hexagon）'),
                    (LlmBackend.gpu, 'GPU（OpenCL）'),
                    (LlmBackend.cpu, 'CPU'),
                  ])
                    ChoiceChip(
                      label: Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _llmRuntime.backend == value
                              ? colorScheme.onPrimary
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      selected: _llmRuntime.backend == value,
                      selectedColor: colorScheme.primary,
                      backgroundColor: colorScheme.surfaceContainerHighest,
                      onSelected: (_) => _setLlmBackend(value),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm - 2),
              Divider(color: colorScheme.outlineVariant, height: 16),
              Text('CPU スレッド数（要求値）', style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                '比較用の候補です（自動 = 現状の基準・1/2 は診断用）。'
                '実効値は取得できないため要求値のみ表示します。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  for (final t in LlmRuntimeSettings.cpuThreadChoices)
                    ChoiceChip(
                      label: Text(
                        t == 0 ? '自動' : '$t',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _llmRuntime.cpuThreads == t
                              ? colorScheme.onPrimary
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      selected: _llmRuntime.cpuThreads == t,
                      selectedColor: colorScheme.primary,
                      backgroundColor: colorScheme.surfaceContainerHighest,
                      onSelected: (_) => _setLlmCpuThreads(t),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm - 2),
              Text(
                '次回のモデルロードから反映（要約シート再表示で再ロードされます）。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// バックグラウンド自動要約の設定カード（Phase 9-B）。
  Widget _autoSummaryCard() {
    final s = _autoSummary;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      width: double.infinity,
      child: Material(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md - 2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('自動要約（実験）', style: theme.textTheme.titleSmall),
                  ),
                  Switch(
                    value: s.enabled,
                    activeThumbColor: colorScheme.primary,
                    onChanged: (v) => _setAutoSummary(s.copyWith(enabled: v)),
                  ),
                ],
              ),
              Text(
                '登録タグの小説を、充電中・WiFi時にバックグラウンドで'
                '自動要約しキャッシュへ蓄積します。'
                'バックグラウンド実行は準備中です。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _autoSummaryStatusRow(),
              const SizedBox(height: AppSpacing.xs),
              Text('対象タグ', style: theme.textTheme.bodyMedium),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.sm - 2,
                runSpacing: AppSpacing.sm - 2,
                children: [
                  for (final t in s.tags)
                    InputChip(
                      label: Text(
                        t,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      backgroundColor: colorScheme.surfaceContainerHighest,
                      onDeleted: () => _removeAutoSummaryTag(t),
                      deleteIconColor: colorScheme.onSurfaceVariant,
                    ),
                  ActionChip(
                    avatar: Icon(
                      Icons.add,
                      color: colorScheme.primary,
                      size: 18,
                    ),
                    label: Text(
                      '追加',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.primary,
                      ),
                    ),
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    onPressed: _addAutoSummaryTag,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Divider(color: colorScheme.outlineVariant, height: 16),
              _autoSummaryToggleRow(
                '充電中のみ実行',
                s.chargeOnly,
                (v) => s.copyWith(chargeOnly: v),
              ),
              _autoSummaryToggleRow(
                'WiFi接続時のみ実行',
                s.wifiOnly,
                (v) => s.copyWith(wifiOnly: v),
              ),
              _autoSummaryToggleRow(
                '推論中 画面ON維持（高速）',
                s.keepScreenOn,
                (v) => s.copyWith(keepScreenOn: v),
              ),
              const SizedBox(height: AppSpacing.xs),
              _autoSummaryChipRow<int>(
                label: '1セッション最大件数',
                choices: AutoSummarySettings.maxChoices,
                selected: s.maxPerSession,
                display: (v) => '$v件',
                onSelect: (v) => s.copyWith(maxPerSession: v),
              ),
              _autoSummaryChipRow<int>(
                label: 'クールダウン',
                choices: AutoSummarySettings.cooldownChoices,
                selected: s.cooldownSeconds,
                display: (v) => '$v秒',
                onSelect: (v) => s.copyWith(cooldownSeconds: v),
              ),
              _autoSummaryChipRow<double>(
                label: '温度閾値',
                choices: AutoSummarySettings.tempChoices,
                selected: s.temperatureLimitCelsius,
                display: (v) => '${v.toInt()}℃',
                onSelect: (v) => s.copyWith(temperatureLimitCelsius: v),
              ),
              const SizedBox(height: AppSpacing.sm - 2),
              Text(
                '最終実行: ${s.lastRunAtMillis == 0 ? '未実行' : _fmtEpoch(s.lastRunAtMillis)}'
                '　累計処理: ${s.totalProcessed}件',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.sm - 2),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _runAutoSummaryNow,
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('今すぐ実行'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colorScheme.primary,
                        side: BorderSide(color: colorScheme.primary),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 自動要約カード内のステータス行。実行主体コントローラのバッチング済み
  /// スナップショットを購読して表示するだけ（件数はここで数えない・§3-A）。
  Widget _autoSummaryStatusRow() {
    return ValueListenableBuilder<AutoSummarySnapshot>(
      valueListenable: _autoSummaryController.state,
      builder: (context, s, _) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md - 2,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                autoSummaryPhaseIcon(s.phase),
                color: colorScheme.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${autoSummaryRunStateLabel(s)}　${s.savedCount}/${s.targetCount}件保存',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      autoSummaryStatusLabel(s),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: _openAutoSummaryStatus,
                child: Text(
                  '状況を見る',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _autoSummaryToggleRow(
    String label,
    bool value,
    AutoSummarySettings Function(bool) apply,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: colorScheme.primary,
          onChanged: (v) => _setAutoSummary(apply(v)),
        ),
      ],
    );
  }

  Widget _autoSummaryChipRow<T>({
    required String label,
    required List<T> choices,
    required T selected,
    required String Function(T) display,
    required AutoSummarySettings Function(T) onSelect,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              for (final c in choices)
                ChoiceChip(
                  label: Text(
                    display(c),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: c == selected
                          ? colorScheme.onPrimary
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                  selected: c == selected,
                  selectedColor: colorScheme.primary,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  onSelected: (_) => _setAutoSummary(onSelect(c)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _fmtEpoch(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}/${two(dt.month)}/${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  Widget _sectionHeader(String title) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: AppSpacing.sm - 2,
      ),
      child: Text(
        title,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListTile(
      leading: Icon(icon, color: colorScheme.primary),
      title: Text(
        title,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: colorScheme.onSurface,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
      onTap: onTap,
    );
  }

  /// 小説リーダー設定（novel_pref_* を直接読み書き）。
  Widget _readerSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Material(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md - 2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sliderRow(
                label: '文字サイズ',
                value: _fontSize,
                min: 12,
                max: 26,
                decimals: 0,
                onChanged: (v) => setState(() => _fontSize = v),
                onChangeEnd: (v) => _saveDouble('novel_pref_font_size', v),
              ),
              _sliderRow(
                label: '行間',
                value: _lineHeight,
                min: 1.4,
                max: 2.6,
                decimals: 1,
                onChanged: (v) => setState(() => _lineHeight = v),
                onChangeEnd: (v) => _saveDouble('novel_pref_line_height', v),
              ),
              _sliderRow(
                label: '自動スクロール速度',
                value: _scrollSpeed,
                min: 1,
                max: 10,
                decimals: 1,
                onChanged: (v) => setState(() => _scrollSpeed = v),
                onChangeEnd: (v) => _saveDouble('novel_pref_scroll_speed', v),
              ),
              _sliderRow(
                label: 'TTS 読み上げ速度',
                value: _ttsRate,
                min: 0.5,
                max: 2,
                decimals: 1,
                onChanged: (v) => setState(() => _ttsRate = v),
                onChangeEnd: (v) => _saveDouble('novel_pref_tts_rate', v),
              ),
              _dropdownRow(
                label: 'テーマ',
                value: _themeMode,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('白')),
                  DropdownMenuItem(value: 1, child: Text('セピア')),
                  DropdownMenuItem(value: 2, child: Text('漆黒')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _themeMode = v);
                  _saveInt('novel_pref_theme_mode', v);
                },
              ),
              _dropdownRow(
                label: 'ルビ',
                value: _rubyModeName,
                items: const [
                  DropdownMenuItem(value: 'show', child: Text('表示')),
                  DropdownMenuItem(value: 'brackets', child: Text('括弧')),
                  DropdownMenuItem(value: 'hide', child: Text('非表示')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _rubyModeName = v);
                  _saveString('novel_pref_ruby_mode', v);
                },
              ),
              Divider(height: 16, color: colorScheme.outlineVariant),
              SwitchListTile(
                dense: true,
                secondary: Icon(Icons.timer, color: colorScheme.primary),
                title: Text(
                  '読書時間を表示',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
                activeThumbColor: colorScheme.primary,
                activeTrackColor: colorScheme.primary.withValues(alpha: 0.3),
                value: _showReadingTime,
                onChanged: (v) {
                  setState(() => _showReadingTime = v);
                  _saveBool('novel_pref_show_reading_time', v);
                },
              ),
              SwitchListTile(
                dense: true,
                secondary: Icon(Icons.color_lens, color: colorScheme.primary),
                title: Text(
                  '感情カラーを表示',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
                activeThumbColor: colorScheme.primary,
                activeTrackColor: colorScheme.primary.withValues(alpha: 0.3),
                value: _showEmotionColor,
                onChanged: (v) {
                  setState(() => _showEmotionColor = v);
                  _saveBool('novel_pref_show_emotion_color', v);
                },
              ),
              SwitchListTile(
                dense: true,
                secondary: Icon(
                  Icons.record_voice_over,
                  color: colorScheme.primary,
                ),
                title: Text(
                  'TTS でルビも読み上げる',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
                activeThumbColor: colorScheme.primary,
                activeTrackColor: colorScheme.primary.withValues(alpha: 0.3),
                value: _ttsReadRuby,
                onChanged: (v) {
                  setState(() => _ttsReadRuby = v);
                  _saveBool('novel_pref_tts_read_ruby', v);
                },
              ),
              const SizedBox(height: AppSpacing.sm - 2),
              Text(
                'リーダー内の HUD でも同じ値を変更できます（値は共有されます）。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int decimals,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              value.toStringAsFixed(decimals),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          activeColor: colorScheme.primary,
          inactiveColor: colorScheme.surfaceContainerHighest,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }

  Widget _dropdownRow({
    required String label,
    required dynamic value,
    required List<DropdownMenuItem<dynamic>> items,
    required ValueChanged<dynamic> onChanged,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          DropdownButton<dynamic>(
            value: value,
            underline: const SizedBox.shrink(),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface,
            ),
            icon: Icon(
              Icons.arrow_drop_down,
              color: colorScheme.onSurfaceVariant,
            ),
            items: items,
            onChanged: (v) => onChanged(v),
          ),
        ],
      ),
    );
  }

  Widget _licenseBlock() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md + 2),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PixEmber',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'このアプリは、検索・推薦・統計・読書・バックアップ管理のすべての機能'
            'を端末内で処理します。Pixiv API への要求と Google Drive バックアップ'
            'を除き、個人データは外部サーバーへ送信されません。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Version 3.1.0',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 保存した検索プリセットの管理シート（Phase N1 の SearchPresetService を再利用）。
class _PresetManagerSheet extends StatefulWidget {
  const _PresetManagerSheet();

  @override
  State<_PresetManagerSheet> createState() => _PresetManagerSheetState();
}

class _PresetManagerSheetState extends State<_PresetManagerSheet> {
  final SearchPresetService _service = SearchPresetService();
  List<SearchPreset> _presets = const [];
  bool _loading = true;

  // 改名ダイアログのコンティローラ。
  // ダイアログの終了アニメーション中も TextField が参照するため、
  // unmount 時まで破棄しない（use-after-dispose 回避）。
  TextEditingController? _dialogController;

  @override
  void dispose() {
    _dialogController?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _service.load();
      if (!mounted) return;
      setState(() {
        _presets = list;
        _loading = false;
      });
    } catch (e) {
      debugPrint('保存した検索の読み込みに失敗しました: $e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _rename(SearchPreset preset) async {
    _dialogController?.dispose();
    final controller = TextEditingController(text: preset.name);
    _dialogController = controller;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final colorScheme = theme.colorScheme;
        return AlertDialog(
          backgroundColor: colorScheme.surfaceContainerHigh,
          title: Text(
            '名前を変更',
            style: theme.textTheme.titleLarge?.copyWith(
              color: colorScheme.onSurface,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface,
            ),
            decoration: const InputDecoration(hintText: '新しい名前'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('変更する'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (result == null) return;
    final name = result.trim();
    if (name.isEmpty) return;
    await _service.rename(preset.id, name);
    await _load();
  }

  Future<void> _delete(SearchPreset preset) async {
    await _service.delete(preset.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(Icons.search, color: colorScheme.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      _loading ? '読み込み中…' : '保存した検索（${_presets.length}件）',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? Center(
                      child: CircularProgressIndicator(
                        color: colorScheme.primary,
                      ),
                    )
                  : _presets.isEmpty
                  ? Center(
                      child: Text(
                        '保存した検索はありません。\n'
                        '検索バーから保存するとここに表示されます。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final preset in _presets) _buildPresetRow(preset),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.lg,
                bottom: AppSpacing.sm,
              ),
              child: Text(
                '検索アシストビューからも管理できます。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetRow(SearchPreset preset) {
    final isNovel = preset.category == 'novel';
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs - 1,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm - 2,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: isNovel
                  ? colorScheme.tertiaryContainer
                  : colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              isNovel ? '小説' : 'イラスト',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preset.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (preset.keyword.isNotEmpty)
                  Text(
                    preset.keyword,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.edit,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
            tooltip: '名前を変更',
            onPressed: () => _rename(preset),
          ),
          IconButton(
            icon: Icon(
              Icons.delete,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
            tooltip: '削除',
            onPressed: () => _delete(preset),
          ),
        ],
      ),
    );
  }
}

/// ローカルAI（実験）: GGUF モデル選択シート。
class _LlmModelSheet extends StatefulWidget {
  const _LlmModelSheet();

  @override
  State<_LlmModelSheet> createState() => _LlmModelSheetState();
}

class _LlmModelSheetState extends State<_LlmModelSheet> {
  final TextEditingController _manualPathController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  List<String> _models = const [];

  /// null = 自動（設定なし）。それ以外 = 選択済み GGUF の絶対パス。
  String? _selected;
  String? _defaultDirPath;
  String? _error;

  // モデルインポート（SAF ピッカー → アプリ内部コピー）の状態。
  final LlmModelImportService _importer = LlmModelImportService();
  bool _importing = false;
  bool _importCancelRequested = false;
  int _importCopied = 0;
  int _importTotal = 0;
  String? _importSuccess;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _manualPathController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final dir = await LlmModelPaths.defaultDir();
      final models = await LlmModelPaths.discover();
      final prefs = await SharedPreferences.getInstance();
      final configured = prefs.getString(LlmModelPaths.prefsKey)?.trim() ?? '';
      if (!mounted) return;
      setState(() {
        _defaultDirPath = dir.path;
        _models = models;
        _selected = (configured.isNotEmpty && models.contains(configured))
            ? configured
            : null;
        _loading = false;
      });
    } catch (e) {
      debugPrint('GGUF 一覧の取得に失敗しました: $e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// SAF ピッカーで GGUF を選択し、アプリ内部ストレージへ取り込む。
  ///
  /// コピー中はスピナーと進捗バーを表示する（数GBで数十秒かかるため）。
  /// 成功したら一覧を更新し、取り込んだモデルを自動選択して保存する。
  Future<void> _startImport() async {
    if (_saving || _importing) return;
    if (!mounted) return;
    setState(() {
      _importing = true;
      _importCancelRequested = false;
      _importSuccess = null;
      _error = null;
      _importCopied = 0;
      _importTotal = 0;
    });
    try {
      final result = await _importer.importFromPicker(
        onProgress: (copied, total) {
          if (!mounted) return;
          setState(() {
            _importCopied = copied;
            _importTotal = total;
          });
        },
        isCancelled: () => _importCancelRequested,
      );
      if (!mounted) return;
      if (result == null) {
        // ピッカーがキャンセルされた場合は何もせずシートに戻る。
        setState(() => _importing = false);
        return;
      }
      await LlmModelPaths.setModelPath(result.path);
      // C-2: NPU(HTP) 非対応の量子化（K/IQ 系）は非ブロッキングの警告ダイアログ。
      if (!result.npuCompatible && mounted) {
        _showNpuWarning(result.quantization, result.fileName);
      }
      final models = await LlmModelPaths.discover();
      if (!mounted) return;
      setState(() {
        _importing = false;
        _importSuccess = '${result.fileName} を取り込みました';
        _selected = result.path;
        if (!_models.contains(result.path)) {
          _models = [...models, if (!models.contains(result.path)) result.path]
            ..sort((a, b) => a.compareTo(b));
        }
      });
    } on LlmModelImportCancelledException {
      debugPrint('モデルの取り込みをキャンセルしました');
      if (!mounted) return;
      setState(() => _importing = false);
    } on LlmModelImportException catch (e) {
      debugPrint('モデルの取り込みに失敗しました: ${e.message}');
      if (!mounted) return;
      setState(() {
        _importing = false;
        _error = e.message;
      });
    } catch (e) {
      debugPrint('モデルの取り込みに失敗しました: $e');
      if (!mounted) return;
      setState(() {
        _importing = false;
        _error = '取り込みに失敗しました。もう一度お試しください。';
      });
    }
  }

  /// NPU(HTP) 非対応量子化モデルを取り込んだ際の警告（C-2）。非ブロッキング。
  void _showNpuWarning(String? quantization, String fileName) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        return AlertDialog(
          backgroundColor: colorScheme.surfaceContainerHigh,
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: colorScheme.error),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'NPU 非対応の量子化形式',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          content: Text(
            'このモデル（${quantization ?? '不明'}）はNPU(HTP)非対応の量子化形式です。\n'
            'CPU実行になり生成速度が大幅に低下します。\n'
            'Q4_0 または Q8_0 形式を推奨します。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'OK',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.primary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 進行中のコピーのキャンセルを要求する。
  void _cancelImport() {
    if (!_importing) return;
    setState(() => _importCancelRequested = true);
  }

  Future<void> _save(String? path) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      if (path == null) {
        await prefs.remove(LlmModelPaths.prefsKey);
      } else {
        await LlmModelPaths.setModelPath(path);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      debugPrint('モデル設定の保存に失敗しました: $e');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存に失敗しました。もう一度お試しください。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Text(
                  'ローカルAIモデル（実験）',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close, color: colorScheme.onSurfaceVariant),
                  tooltip: '閉じる',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colorScheme.outlineVariant),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: _loading
                  ? Center(
                      child: CircularProgressIndicator(
                        color: colorScheme.primary,
                      ),
                    )
                  : _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_importing) ...[
          Text(
            'モデルを取り込んでいます…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          LinearProgressIndicator(
            value: _importTotal > 0 ? _importCopied / _importTotal : null,
            backgroundColor: colorScheme.surfaceContainerHighest,
            color: colorScheme.primary,
          ),
          const SizedBox(height: AppSpacing.sm - 2),
          Text(
            _importTotal > 0
                ? '${(_importCopied / (1024 * 1024)).toStringAsFixed(0)} MB / '
                      '${(_importTotal / (1024 * 1024)).toStringAsFixed(0)} MB'
                : 'ファイルを確認中…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _cancelImport,
              child: Text(
                'キャンセル',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.error,
                ),
              ),
            ),
          ),
          Divider(height: 24, color: colorScheme.outlineVariant),
        ],
        if (_importSuccess != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md - 2),
            margin: const EdgeInsets.only(bottom: AppSpacing.md),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: colorScheme.primary.withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              _importSuccess!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
        Text(
          _models.isEmpty
              ? '端末内の .gguf ファイルを選択して取り込むか、'
                    '下記ディレクトリに手動で配置してください。'
              : '端末内の .gguf ファイルを追加で取り込めます。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _saving ? null : _startImport,
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.primary,
              side: BorderSide(color: colorScheme.primary),
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            ),
            icon: const Icon(Icons.file_open, size: 20),
            label: Text(
              'モデルをインポート',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.primary,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '手動配置用ディレクトリ',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sm - 2),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.md - 2),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            _defaultDirPath ?? '',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        RadioGroup<String?>(
          groupValue: _selected,
          onChanged: (v) {
            if (!_saving) _save(v);
          },
          child: Column(
            children: [
              RadioListTile<String?>(
                title: Text(
                  '自動（既定ディレクトリの唯一のモデルを使用）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
                secondary: Icon(
                  Icons.auto_fix_high,
                  color: colorScheme.primary,
                  size: 20,
                ),
                value: null,
                activeColor: colorScheme.primary,
                dense: true,
              ),
              for (final m in _models)
                RadioListTile<String?>(
                  title: Text(
                    p.basename(m),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    m,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  value: m,
                  activeColor: colorScheme.primary,
                  dense: true,
                ),
            ],
          ),
        ),
        if (_models.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            margin: const EdgeInsets.only(top: AppSpacing.xs),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: colorScheme.error.withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              'GGUFファイルが未配置です。'
              '「モデルをインポート」から端末内の .gguf を取り込むか、'
              '下記ディレクトリに手動で配置して再読み込みしてください。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          '手動でパスを指定',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sm - 2),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _manualPathController,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface,
                ),
                decoration: InputDecoration(
                  hintText: 'ファイル名または絶対パス',
                  hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                  isDense: true,
                  filled: true,
                  fillColor: colorScheme.surfaceContainerHighest,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: colorScheme.outlineVariant),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: colorScheme.primary),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _saving
                  ? null
                  : () {
                      final v = _manualPathController.text.trim();
                      if (v.isNotEmpty) _save(v);
                    },
              style: OutlinedButton.styleFrom(
                foregroundColor: colorScheme.primary,
                side: BorderSide(color: colorScheme.primary),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        TextButton(
          onPressed: _loading || _saving ? null : _load,
          child: Text(
            '再読み込み',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}

/// 自動要約の「対象タグを追加」ダイアログ。
///
/// TextEditingController の所有権をこの State が持つことで、
/// await showDialog 直後に呼び出し側が dispose してしまう
/// '_dependents.isEmpty' アサート(exit アニメ中の生存 TextField 競合)を回避する。
class _TagAddDialog extends StatefulWidget {
  const _TagAddDialog();

  @override
  State<_TagAddDialog> createState() => _TagAddDialogState();
}

class _TagAddDialogState extends State<_TagAddDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: colorScheme.surfaceContainerHigh,
      title: const Text('対象タグを追加'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: '例: 百合',
          hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        style: TextStyle(color: colorScheme.onSurface),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(onPressed: _submit, child: const Text('追加')),
      ],
    );
  }
}
