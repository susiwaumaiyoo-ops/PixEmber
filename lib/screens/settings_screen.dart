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

import '../services/auto_summary_bridge_controller.dart';
import '../services/auto_summary_controller.dart';
import '../services/fgs_lifecycle_service.dart';
import '../services/auto_summary_settings.dart';
import '../services/auto_summary_snapshot.dart';
import '../services/local_llm_service.dart';
import '../services/llm_model_import_service.dart';
import '../services/search_preset_service.dart';
import 'auto_summary_status_screen.dart';
import 'ai_index_maintenance_screen.dart';
import 'ai_recommend_feed_screen.dart';
import 'backup_manager_screen.dart';
import 'bookmark_list_screen.dart';
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

  void _openAutoSummaryStatus() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AutoSummaryStatusScreen(controller: _autoSummaryController),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadAll();
    _loadLlmModel();
    _loadLlmRuntime();
    _loadAutoSummary();
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

  /// 「今すぐ実行」ボタン: FGS を ensure してから runNow を送る。
  Future<void> _runAutoSummaryNow() async {
    final ready = await FgsLifecycleService().ensureServiceReady();
    if (!ready) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('自動要約サービスの起動に失敗しました')),
        );
      }
      return;
    }
    _autoSummaryController.runNow();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('自動要約を開始しました')),
      );
    }
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
    await _setAutoSummary(_autoSummary.copyWith(
      tags: _autoSummary.tags.where((e) => e != tag).toList(),
    ));
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
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1C),
        title: const Text(
          'AI要約（実験）',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: const Text(
          'この機能は実験中です。現時点では Android のみ利用できます。',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK', style: TextStyle(color: Colors.pinkAccent)),
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
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      builder: (_) => const _PresetManagerSheet(),
    ).then((_) {
      if (mounted) _loadPresets();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        iconTheme: const IconThemeData(color: Colors.white70),
        title: const Text(
          '設定',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
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
          _sectionHeader('ライセンス'),
          _licenseBlock(),
        ],
      ),
    );
  }

  /// ローカルAI（実験）の実行設定（A: CPUスレッド比較候補、B: バックエンド選択）。
  ///
  /// 変更は SharedPreferences に保存され、次回のモデルロードから反映される
  /// （ロード済みエンジンの再利用条件に設定一致が含まれるため、
  /// 設定変更後は古いエンジンが再利用されない）。
  Widget _llmRuntimeCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      width: double.infinity,
      child: Material(
        color: const Color(0xFF242424),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '推論バックエンド',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 2),
              const Text(
                '自動は NPU（Hexagon）→ GPU（OpenCL）→ CPU の順で検出します。'
                '非対応環境は自動で CPU に戻ります。',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
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
                        style: TextStyle(
                          color: _llmRuntime.backend == value
                              ? Colors.white
                              : Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      selected: _llmRuntime.backend == value,
                      selectedColor: Colors.pinkAccent,
                      backgroundColor: Colors.white12,
                      onSelected: (_) => _setLlmBackend(value),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              const Divider(color: Colors.white12, height: 16),
              const Text(
                'CPU スレッド数（要求値）',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 2),
              const Text(
                '比較用の候補です（自動 = 現状の基準・1/2 は診断用）。'
                '実効値は取得できないため要求値のみ表示します。',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final t in LlmRuntimeSettings.cpuThreadChoices)
                    ChoiceChip(
                      label: Text(
                        t == 0 ? '自動' : '$t',
                        style: TextStyle(
                          color: _llmRuntime.cpuThreads == t
                              ? Colors.white
                              : Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      selected: _llmRuntime.cpuThreads == t,
                      selectedColor: Colors.pinkAccent,
                      backgroundColor: Colors.white12,
                      onSelected: (_) => _setLlmCpuThreads(t),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '次回のモデルロードから反映（要約シート再表示で再ロードされます）。',
                style: TextStyle(color: Colors.grey[500], fontSize: 10.5),
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
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      width: double.infinity,
      child: Material(
        color: const Color(0xFF242424),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '自動要約（実験）',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                  Switch(
                    value: s.enabled,
                    activeThumbColor: Colors.pinkAccent,
                    onChanged: (v) => _setAutoSummary(s.copyWith(enabled: v)),
                  ),
                ],
              ),
              const Text(
                '登録タグの小説を、充電中・WiFi時にバックグラウンドで'
                '自動要約しキャッシュへ蓄積します。'
                'バックグラウンド実行は準備中です。',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
              const SizedBox(height: 8),
              _autoSummaryStatusRow(),
              const SizedBox(height: 4),
              const Text('対象タグ',
                  style: TextStyle(color: Colors.white, fontSize: 13)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in s.tags)
                    InputChip(
                      label: Text(t,
                          style: const TextStyle(color: Colors.white70)),
                      backgroundColor: Colors.white12,
                      onDeleted: () => _removeAutoSummaryTag(t),
                      deleteIconColor: Colors.white54,
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add, color: Colors.pinkAccent, size: 18),
                    label: const Text('追加',
                        style: TextStyle(color: Colors.pinkAccent)),
                    backgroundColor: Colors.white12,
                    onPressed: _addAutoSummaryTag,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Divider(color: Colors.white12, height: 16),
              _autoSummaryToggleRow(
                  '充電中のみ実行', s.chargeOnly, (v) => s.copyWith(chargeOnly: v)),
              _autoSummaryToggleRow(
                  'WiFi接続時のみ実行', s.wifiOnly, (v) => s.copyWith(wifiOnly: v)),
              _autoSummaryToggleRow('推論中 画面ON維持（高速）', s.keepScreenOn,
                  (v) => s.copyWith(keepScreenOn: v)),
              const SizedBox(height: 4),
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
              const SizedBox(height: 6),
              Text(
                '最終実行: ${s.lastRunAtMillis == 0 ? '未実行' : _fmtEpoch(s.lastRunAtMillis)}'
                '　累計処理: ${s.totalProcessed}件',
                style: TextStyle(color: Colors.grey[500], fontSize: 10.5),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _runAutoSummaryNow,
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('今すぐ実行'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.pinkAccent,
                        side: const BorderSide(color: Colors.pinkAccent),
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
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(autoSummaryPhaseIcon(s.phase), color: Colors.pinkAccent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${autoSummaryRunStateLabel(s)}　${s.savedCount}/${s.targetCount}件保存',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      autoSummaryStatusLabel(s),
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: _openAutoSummaryStatus,
                child: const Text('状況を見る',
                    style: TextStyle(color: Colors.pinkAccent, fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _autoSummaryToggleRow(
      String label, bool value, AutoSummarySettings Function(bool) apply) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ),
        Switch(
          value: value,
          activeThumbColor: Colors.pinkAccent,
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              for (final c in choices)
                ChoiceChip(
                  label: Text(
                    display(c),
                    style: TextStyle(
                      color: c == selected ? Colors.white : Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                  selected: c == selected,
                  selectedColor: Colors.pinkAccent,
                  backgroundColor: Colors.white12,
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
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 16, bottom: 6),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 12,
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
    return ListTile(
      leading: Icon(icon, color: Colors.pinkAccent),
      title: Text(
        title,
        style: const TextStyle(color: Colors.white, fontSize: 15),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: Colors.white70, fontSize: 12.5),
      ),
      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
      onTap: onTap,
    );
  }

  /// 小説リーダー設定（novel_pref_* を直接読み書き）。
  Widget _readerSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: const Color(0xFF242424),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
              const Divider(height: 16, color: Colors.white24),
              SwitchListTile(
                dense: true,
                secondary: const Icon(Icons.timer, color: Colors.pinkAccent),
                title: const Text(
                  '読書時間を表示',
                  style: TextStyle(fontSize: 14, color: Colors.white),
                ),
                activeThumbColor: Colors.pinkAccent,
                activeTrackColor: const Color(0x55FF4081),
                value: _showReadingTime,
                onChanged: (v) {
                  setState(() => _showReadingTime = v);
                  _saveBool('novel_pref_show_reading_time', v);
                },
              ),
              SwitchListTile(
                dense: true,
                secondary: const Icon(
                  Icons.color_lens,
                  color: Colors.pinkAccent,
                ),
                title: const Text(
                  '感情カラーを表示',
                  style: TextStyle(fontSize: 14, color: Colors.white),
                ),
                activeThumbColor: Colors.pinkAccent,
                activeTrackColor: const Color(0x55FF4081),
                value: _showEmotionColor,
                onChanged: (v) {
                  setState(() => _showEmotionColor = v);
                  _saveBool('novel_pref_show_emotion_color', v);
                },
              ),
              SwitchListTile(
                dense: true,
                secondary: const Icon(
                  Icons.record_voice_over,
                  color: Colors.pinkAccent,
                ),
                title: const Text(
                  'TTS でルビも読み上げる',
                  style: TextStyle(fontSize: 14, color: Colors.white),
                ),
                activeThumbColor: Colors.pinkAccent,
                activeTrackColor: const Color(0x55FF4081),
                value: _ttsReadRuby,
                onChanged: (v) {
                  setState(() => _ttsReadRuby = v);
                  _saveBool('novel_pref_tts_read_ruby', v);
                },
              ),
              const SizedBox(height: 6),
              const Text(
                'リーダー内の HUD でも同じ値を変更できます（値は共有されます）。',
                style: TextStyle(color: Colors.white38, fontSize: 11),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            Text(
              value.toStringAsFixed(decimals),
              style: const TextStyle(
                color: Colors.pinkAccent,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          activeColor: Colors.pinkAccent,
          inactiveColor: Colors.white24,
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          DropdownButton<dynamic>(
            value: value,
            underline: const SizedBox.shrink(),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            icon: const Icon(Icons.arrow_drop_down, color: Colors.white54),
            items: items,
            onChanged: (v) => onChanged(v),
          ),
        ],
      ),
    );
  }

  Widget _licenseBlock() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF242424),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PixEmber',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'このアプリは、検索・推薦・統計・読書・バックアップ管理のすべての機能'
            'を端末内で処理します。Pixiv API への要求と Google Drive バックアップ'
            'を除き、個人データは外部サーバーへ送信されません。',
            style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.6),
          ),
          SizedBox(height: 8),
          Text(
            'Version 3.1.0',
            style: TextStyle(color: Colors.white38, fontSize: 11),
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
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('名前を変更', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
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
      ),
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
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.search, color: Colors.pinkAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _loading ? '読み込み中…' : '保存した検索（${_presets.length}件）',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Colors.pinkAccent,
                      ),
                    )
                  : _presets.isEmpty
                  ? const Center(
                      child: Text(
                        '保存した検索はありません。\n'
                        '検索バーから保存するとここに表示されます。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final preset in _presets) _buildPresetRow(preset),
                      ],
                    ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 16, bottom: 8),
              child: Text(
                '検索アシストビューからも管理できます。',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetRow(SearchPreset preset) {
    final isNovel = preset.category == 'novel';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isNovel
                  ? const Color(0xFF4A3B6B)
                  : const Color(0xFF5A2A4A),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              isNovel ? '小説' : 'イラスト',
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preset.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (preset.keyword.isNotEmpty)
                  Text(
                    preset.keyword,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit, size: 18, color: Colors.white54),
            tooltip: '名前を変更',
            onPressed: () => _rename(preset),
          ),
          IconButton(
            icon: const Icon(Icons.delete, size: 18, color: Colors.white54),
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
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1C),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'NPU 非対応の量子化形式',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          ],
        ),
        content: Text(
          'このモデル（${quantization ?? '不明'}）はNPU(HTP)非対応の量子化形式です。\n'
          'CPU実行になり生成速度が大幅に低下します。\n'
          'Q4_0 または Q8_0 形式を推奨します。',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'OK',
              style: TextStyle(color: Colors.pinkAccent),
            ),
          ),
        ],
      ),
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
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1C),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                const Text(
                  'ローカルAIモデル（実験）',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  tooltip: '閉じる',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Colors.pinkAccent,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_importing) ...[
          const Text(
            'モデルを取り込んでいます…',
            style: TextStyle(color: Colors.white, fontSize: 13),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: _importTotal > 0 ? _importCopied / _importTotal : null,
            backgroundColor: Colors.white12,
            color: Colors.pinkAccent,
          ),
          const SizedBox(height: 6),
          Text(
            _importTotal > 0
                ? '${(_importCopied / (1024 * 1024)).toStringAsFixed(0)} MB / '
                      '${(_importTotal / (1024 * 1024)).toStringAsFixed(0)} MB'
                : 'ファイルを確認中…',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _cancelImport,
              child: const Text(
                'キャンセル',
                style: TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ),
          ),
          const Divider(height: 24, color: Colors.white12),
        ],
        if (_importSuccess != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
            ),
            child: Text(
              _importSuccess!,
              style: const TextStyle(color: Colors.greenAccent, fontSize: 12),
            ),
          ),
        ],
        Text(
          _models.isEmpty
              ? '端末内の .gguf ファイルを選択して取り込むか、'
                    '下記ディレクトリに手動で配置してください。'
              : '端末内の .gguf ファイルを追加で取り込めます。',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _saving ? null : _startImport,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.pinkAccent,
              side: const BorderSide(color: Colors.pinkAccent),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            icon: const Icon(Icons.file_open, size: 20),
            label: const Text('モデルをインポート', style: TextStyle(fontSize: 13)),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '手動配置用ディレクトリ',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            _defaultDirPath ?? '',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ),
        const SizedBox(height: 16),
        RadioGroup<String?>(
          groupValue: _selected,
          onChanged: (v) {
            if (!_saving) _save(v);
          },
          child: Column(
            children: [
              RadioListTile<String?>(
                title: const Text(
                  '自動（既定ディレクトリの唯一のモデルを使用）',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
                secondary: const Icon(
                  Icons.auto_fix_high,
                  color: Colors.pinkAccent,
                  size: 20,
                ),
                value: null,
                activeColor: Colors.pinkAccent,
                dense: true,
              ),
              for (final m in _models)
                RadioListTile<String?>(
                  title: Text(
                    p.basename(m),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    m,
                    style: TextStyle(color: Colors.white38, fontSize: 10),
                    overflow: TextOverflow.ellipsis,
                  ),
                  value: m,
                  activeColor: Colors.pinkAccent,
                  dense: true,
                ),
            ],
          ),
        ),
        if (_models.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
            ),
            child: const Text(
              'GGUFファイルが未配置です。'
              '「モデルをインポート」から端末内の .gguf を取り込むか、'
              '下記ディレクトリに手動で配置して再読み込みしてください。',
              style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
            ),
          ),
        const SizedBox(height: 16),
        const Text(
          '手動でパスを指定',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _manualPathController,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'ファイル名または絶対パス',
                  hintStyle: const TextStyle(color: Colors.white38),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.black54,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.white12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.pinkAccent),
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
                foregroundColor: Colors.pinkAccent,
                side: const BorderSide(color: Colors.pinkAccent),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          ),
        ],
        const SizedBox(height: 8),
        TextButton(
          onPressed: _loading || _saving ? null : _load,
          child: const Text(
            '再読み込み',
            style: TextStyle(color: Colors.pinkAccent, fontSize: 12),
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
    return AlertDialog(
      backgroundColor: const Color(0xFF1C1C1C),
      title: const Text('対象タグを追加'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: '例: 百合',
          hintStyle: TextStyle(color: Colors.white38),
        ),
        style: const TextStyle(color: Colors.white),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('追加'),
        ),
      ],
    );
  }
}
