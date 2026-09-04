import 'dart:async' show unawaited;
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart' as palette_generator;
import '../illust_model.dart';
import 'illust_detail_handler.dart';
import 'illust_detail_ui_components.dart';
import '../services/similar_works_service.dart';
import '../services/usage_tracking_service.dart';

/// イラスト詳細画面のステートクラス（public）
class IllustDetailState extends ChangeNotifier {
  final Illust illust;
  final ValueChanged<String>? onTagTap;
  final ValueChanged<bool>? onBookmarkChanged;

  bool _isBookmarked = false;
  int _bookmarkCountOffset = 0;
  bool _isToggling = false;

  final List<Illust> _relatedIllusts = [];
  bool _isLoadingRelated = true;
  bool _hasRelatedError = false;

  // 似た作品（Phase D）
  SimilarWorksResult? _similar;
  bool _isLoadingSimilar = true;

  palette_generator.PaletteGenerator? _paletteGenerator;
  final bool _isZooming = false;
  final int _currentPage = 0;
  bool _isDownloaded = false;
  bool _isDownloading = false;

  final String host = '';
  late IllustDetailHandler handler;
  late IllustDetailUIComponents uiComponents;

  // State との連携用コールバック（protected メンバーに直接触れない）
  bool Function()? _isMounted;
  void Function(VoidCallback fn)? _onStateChanged;
  BuildContext? Function()? _contextProvider;

  bool get mounted => _isMounted?.call() ?? false;
  void setState(VoidCallback fn) {
    final onStateChanged = _onStateChanged;
    if (onStateChanged != null) {
      onStateChanged(fn);
    } else {
      fn();
    }
  }

  BuildContext? get context => _contextProvider?.call();

  IllustDetailState({
    required this.illust,
    this.onTagTap,
    this.onBookmarkChanged,
  }) {
    _isBookmarked = illust.isBookmarked;
    handler = IllustDetailHandler(
      illust: illust,
      onTagTap: onTagTap,
      onBookmarkChanged: onBookmarkChanged,
    );
    uiComponents = IllustDetailUIComponents();
  }

  /// State 側から自身の操作手段（コールバック）を受け取る
  void attachState({
    required bool Function() isMounted,
    required void Function(VoidCallback fn) onStateChanged,
    required BuildContext? Function() contextProvider,
  }) {
    _isMounted = isMounted;
    _onStateChanged = onStateChanged;
    _contextProvider = contextProvider;
  }

  // Getters
  bool get isBookmarked => _isBookmarked;
  bool get isToggling => _isToggling;
  bool get isLoadingRelated => _isLoadingRelated;
  bool get hasRelatedError => _hasRelatedError;
  bool get isDownloading => _isDownloading;
  bool get isDownloaded => _isDownloaded;
  SimilarWorksResult? get similar => _similar;
  bool get isLoadingSimilar => _isLoadingSimilar;
  bool get isZooming => _isZooming;
  int get currentPage => _currentPage;
  String get getHost => host;
  int get bookmarkCountOffset => _bookmarkCountOffset;
  palette_generator.PaletteGenerator? get paletteGenerator => _paletteGenerator;
  List<Illust> get relatedIllusts => _relatedIllusts;

  // Setters with notify
  set isBookmarked(bool value) {
    _isBookmarked = value;
    notifyListeners();
  }

  set isToggling(bool value) {
    _isToggling = value;
    notifyListeners();
  }

  set isLoadingRelated(bool value) {
    _isLoadingRelated = value;
    notifyListeners();
  }

  set hasRelatedError(bool value) {
    _hasRelatedError = value;
    notifyListeners();
  }

  set isDownloading(bool value) {
    _isDownloading = value;
    notifyListeners();
  }

  set isDownloaded(bool value) {
    _isDownloaded = value;
    notifyListeners();
  }

  set paletteGenerator(palette_generator.PaletteGenerator? value) {
    _paletteGenerator = value;
    notifyListeners();
  }

  set bookmarkCountOffset(int value) {
    _bookmarkCountOffset = value;
    notifyListeners();
  }

  set relatedIllusts(List<Illust> value) {
    _relatedIllusts.clear();
    _relatedIllusts.addAll(value);
    notifyListeners();
  }

  /// 似た作品の読み込み（Phase D）。失敗しても空表示で継続。
  Future<void> loadSimilarWorks() async {
    if (!_isLoadingSimilar) return;
    try {
      final result = await SimilarWorksService.resolve().buildForIllust(
        illust,
        limit: 12,
      );
      if (!mounted) return;
      setStateValue(() {
        _similar = result;
        _isLoadingSimilar = false;
      });
    } catch (_) {
      if (!mounted) return;
      setStateValue(() => _isLoadingSimilar = false);
    }
  }

  // State update methods
  void setStateValue(void Function() fn) {
    fn();
    notifyListeners();
  }

  void showSuccessSnackBar(String message) {
    handler.showSuccessSnackBar(this, message);
  }

  void showErrorSnackBar(String message) {
    handler.showErrorSnackBar(this, message);
  }
}

class IllustDetailScreen extends StatefulWidget {
  final Illust illust;
  final ValueChanged<String>? onTagTap;
  final ValueChanged<bool>? onBookmarkChanged;

  const IllustDetailScreen({
    super.key,
    required this.illust,
    this.onTagTap,
    this.onBookmarkChanged,
  });

  @override
  State<IllustDetailScreen> createState() => _IllustDetailScreenState();
}

class _IllustDetailScreenState extends State<IllustDetailScreen> {
  late IllustDetailState state;

  // 閲覧時間トラッキング（Phase 4）。この画面を開いている間＝閲覧時間。
  UsageSessionHandle? _usageSession;

  @override
  void initState() {
    super.initState();
    state = IllustDetailState(
      illust: widget.illust,
      onTagTap: widget.onTagTap,
      onBookmarkChanged: widget.onBookmarkChanged,
    );
    state.attachState(
      isMounted: () => mounted,
      onStateChanged: (fn) {
        if (mounted) setState(fn);
      },
      contextProvider: () => mounted ? context : null,
    );
    state.handler.fetchRelatedIllusts(state);
    state.loadSimilarWorks();
    state.handler.recordHistory(state);
    state.handler.generatePalette(state);
    // バックグラウンドでイラスト意味検索用ベクトルを生成・保存（UIブロックなし）
    unawaited(state.handler.ensureIllustEmbedding());
    // 閲覧時間トラッキング開始（Phase 4）
    _usageSession = UsageTrackingService().startSession(
      workId: widget.illust.id,
      workType: 'illust',
    );
  }

  @override
  void dispose() {
    final usage = _usageSession;
    if (usage != null) {
      unawaited(UsageTrackingService().endSession(usage));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return state.uiComponents.build(context, state);
  }
}
