// Phase 9-B: 自動要約の実行状態を単一モデルで表現する（サービス/通知/UI 共通）。
//
// 設計方針（BRIEF.md §2）:
// - 実行主体（推論・仲裁）は FGS が管理する TaskHandler 側 FlutterEngine に置く。
//   UI isolate はこのスナップショットを「受信して表示するだけ」。
// - したがってこのモデルは ValueNotifier・ネイティブポインタ・Service 実体を
//   一切持たず、Map へ完全シリアライズ可能（engine 間/isolate 間送信対応）。
// - 件数は items（作品キュー）から毎回導出し、画面更新のたびに加算しない
//   （二重計上防止）。失敗・スキップを「保存済み」に含めない。
//
// pure Dart（flutter 非依存）: TaskHandler 側・UI 側の双方で import できる。

/// 全体の処理段階（サービスが1つだけ保持。UI/通知はこれを表示）。
enum AutoSummaryPhase {
  /// 無効（自動要約オフ、または実行主体なし）。
  disabled,

  /// 実行予約済み（条件が揃うまで待機予定）。
  scheduled,

  /// 条件待ち（[AutoSummarySnapshot.waitReason] に理由）。
  waitingCondition,

  /// 候補作品を取得中（タグ巡回・ページ取得）。
  fetchingCandidates,

  /// モデルを準備中（loadModel）。
  preparingModel,

  /// 本文を取得中（キャッシュ or ネットワーク）。
  fetchingBody,

  /// 本文を解析中（チャンク map／全文一括の生成前処理を含む）。
  parsingBody,

  /// 要点を統合中（reduce／最終生成）。
  integratingPoints,

  /// 結果を保存中（llm_summaries への最終保存）。
  saving,

  /// クールダウン中（作品間の端末冷却待ち）。
  coolingDown,

  /// 一時停止処理中（停止要求受理、ネティブ停止確認中）。
  pausing,

  /// 一時停止中（再開可能）。
  paused,

  /// 終了処理中（今回のキュー完走後の後始末）。
  finishing,

  /// 完了（全件成功）。
  completed,

  /// 一部失敗で完了（失敗・スキップが1件以上あり）。
  completedWithErrors,

  /// エラー／中断（復旧不能な障害、または OS による中断）。
  error;

  /// 実行中（=進捗・完了率が意味を持つ）段階か。
  bool get isActive =>
      this == AutoSummaryPhase.fetchingCandidates ||
      this == AutoSummaryPhase.preparingModel ||
      this == AutoSummaryPhase.fetchingBody ||
      this == AutoSummaryPhase.parsingBody ||
      this == AutoSummaryPhase.integratingPoints ||
      this == AutoSummaryPhase.saving ||
      this == AutoSummaryPhase.coolingDown;

  /// 終端段階（これ以上進まない）。
  bool get isTerminal =>
      this == AutoSummaryPhase.completed ||
      this == AutoSummaryPhase.completedWithErrors ||
      this == AutoSummaryPhase.error ||
      this == AutoSummaryPhase.disabled;
}

/// 「条件待ち」の理由（§1）。phase==waitingCondition のとき意味を持つ。
enum AutoSummaryWaitReason {
  none,

  /// 電源（充電器）接続待ち。chargeOnly 条件。
  power,

  /// Wi-Fi 接続待ち。wifiOnly 条件。
  wifi,

  /// 温度低下待ち（閾値超過で一時停止中）。
  temperature,

  /// 対象モデルが未導入（ダウンロード／取り込みが必要）。
  modelMissing,

  /// Pixiv ログイン（認証）が必要。
  loginRequired,

  /// 手動要約の終了待ち（共通仲裁で直列化中）。
  manualPending,

  /// OS の実行許可待ち（FGS 開始拒否・通知権限など）。
  osPermission;

  /// UI 表示用の自然な日本語メッセージ。
  String get userMessage {
    switch (this) {
      case AutoSummaryWaitReason.none:
        return '';
      case AutoSummaryWaitReason.power:
        return '充電器が接続されると再開します';
      case AutoSummaryWaitReason.wifi:
        return 'Wi-Fi に接続されると再開します';
      case AutoSummaryWaitReason.temperature:
        return '端末の温度が下がると再開します';
      case AutoSummaryWaitReason.modelMissing:
        return '要約モデルが未導入です。モデルライブラリで追加してください';
      case AutoSummaryWaitReason.loginRequired:
        return 'Pixiv へのログインが必要です';
      case AutoSummaryWaitReason.manualPending:
        return '手動要約の終了を待っています';
      case AutoSummaryWaitReason.osPermission:
        return 'システムの実行許可を待っています';
    }
  }
}

/// 作品1件のキュー上の状態。件数はここから導出する。
enum AutoSummaryItemStatus {
  waiting,
  processing,
  saved,
  failed,
  skipped;

  bool get isCountedAsSaved => this == AutoSummaryItemStatus.saved;
}

/// 1作品内の処理段階（§3-C の実処理順）。
enum AutoSummaryWorkStage {
  none,
  bodyFetch,
  modelPrepare,
  bodyParse,
  pointMerge,
  save;

  String get label {
    switch (this) {
      case AutoSummaryWorkStage.none:
        return '';
      case AutoSummaryWorkStage.bodyFetch:
        return '本文を取得中';
      case AutoSummaryWorkStage.modelPrepare:
        return 'モデルを準備中';
      case AutoSummaryWorkStage.bodyParse:
        return '本文を解析中';
      case AutoSummaryWorkStage.pointMerge:
        return '要点を統合中';
      case AutoSummaryWorkStage.save:
        return '結果を保存中';
    }
  }
}

/// 作品1件のキュー項目。
class AutoSummaryItem {
  const AutoSummaryItem({
    required this.workId,
    required this.tags,
    this.title = '',
    this.status = AutoSummaryItemStatus.waiting,
    this.errorReason,
    this.updatedAtMillis = 0,
  });

  /// 作品ID（重複排除のキー）。
  final int workId;

  /// この作品を拾った対象タグ（複数該当时可）。全体件数は workId でユニーク化。
  final List<String> tags;

  final String title;
  final AutoSummaryItemStatus status;

  /// 失敗・スキップ時の短い理由（作品詳細を開いても自動再試行しない）。
  final String? errorReason;
  final int updatedAtMillis;

  AutoSummaryItem copyWith({
    AutoSummaryItemStatus? status,
    String? title,
    String? errorReason,
    int? updatedAtMillis,
    List<String>? tags,
  }) {
    return AutoSummaryItem(
      workId: workId,
      tags: tags ?? this.tags,
      title: title ?? this.title,
      status: status ?? this.status,
      errorReason: errorReason ?? this.errorReason,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
    );
  }

  Map<String, dynamic> toMap() => {
    'workId': workId,
    'tags': tags,
    'title': title,
    'status': status.name,
    'errorReason': errorReason,
    'updatedAtMillis': updatedAtMillis,
  };

  static AutoSummaryItem fromMap(Map<dynamic, dynamic> m) {
    return AutoSummaryItem(
      workId: (m['workId'] as num).toInt(),
      tags:
          ((m['tags'] as List?)?.map((e) => e.toString()).toList()) ?? const [],
      title: m['title'] as String? ?? '',
      status: AutoSummaryItemStatus.values.firstWhere(
        (e) => e.name == m['status'],
        orElse: () => AutoSummaryItemStatus.waiting,
      ),
      errorReason: m['errorReason'] as String?,
      updatedAtMillis: (m['updatedAtMillis'] as num?)?.toInt() ?? 0,
    );
  }
}

/// タグ別の内訳（§2-B）。同じ作品が複数タグに該当しても全体は workId で重複排除。
class AutoSummaryTagStat {
  const AutoSummaryTagStat({
    required this.tag,
    this.candidatesChecked = 0,
    this.existingValid = 0,
    this.generatedSaved = 0,
    this.processing = 0,
    this.waiting = 0,
    this.failed = 0,
    this.hasMoreCandidates = false,
    this.reachedSessionLimit = false,
  });

  final String tag;
  final int candidatesChecked;
  final int existingValid;
  final int generatedSaved;
  final int processing;
  final int waiting;
  final int failed;

  /// 追加候補があるか（nextUrl 継続可否）。
  final bool hasMoreCandidates;

  /// 今回のセッション上限に到達して停止したか（=追加候補なしとは区別）。
  final bool reachedSessionLimit;

  AutoSummaryTagStat copyWith({
    int? candidatesChecked,
    int? existingValid,
    int? generatedSaved,
    int? processing,
    int? waiting,
    int? failed,
    bool? hasMoreCandidates,
    bool? reachedSessionLimit,
  }) {
    return AutoSummaryTagStat(
      tag: tag,
      candidatesChecked: candidatesChecked ?? this.candidatesChecked,
      existingValid: existingValid ?? this.existingValid,
      generatedSaved: generatedSaved ?? this.generatedSaved,
      processing: processing ?? this.processing,
      waiting: waiting ?? this.waiting,
      failed: failed ?? this.failed,
      hasMoreCandidates: hasMoreCandidates ?? this.hasMoreCandidates,
      reachedSessionLimit: reachedSessionLimit ?? this.reachedSessionLimit,
    );
  }

  Map<String, dynamic> toMap() => {
    'tag': tag,
    'candidatesChecked': candidatesChecked,
    'existingValid': existingValid,
    'generatedSaved': generatedSaved,
    'processing': processing,
    'waiting': waiting,
    'failed': failed,
    'hasMoreCandidates': hasMoreCandidates,
    'reachedSessionLimit': reachedSessionLimit,
  };

  static AutoSummaryTagStat fromMap(Map<dynamic, dynamic> m) {
    return AutoSummaryTagStat(
      tag: m['tag'] as String? ?? '',
      candidatesChecked: (m['candidatesChecked'] as num?)?.toInt() ?? 0,
      existingValid: (m['existingValid'] as num?)?.toInt() ?? 0,
      generatedSaved: (m['generatedSaved'] as num?)?.toInt() ?? 0,
      processing: (m['processing'] as num?)?.toInt() ?? 0,
      waiting: (m['waiting'] as num?)?.toInt() ?? 0,
      failed: (m['failed'] as num?)?.toInt() ?? 0,
      hasMoreCandidates: m['hasMoreCandidates'] as bool? ?? false,
      reachedSessionLimit: m['reachedSessionLimit'] as bool? ?? false,
    );
  }
}

/// 自動要約全体の実行状態スナップショット。サービス側が正本を保持し更新、
/// UI・通知は受信したこれを表示する。件数は [items] から毎回導出する。
class AutoSummarySnapshot {
  const AutoSummarySnapshot({
    this.runId = '',
    this.startedAtMillis = 0,
    this.updatedAtMillis = 0,
    this.phase = AutoSummaryPhase.disabled,
    this.waitReason = AutoSummaryWaitReason.none,
    this.currentTag,
    this.currentWorkId,
    this.currentWorkTitle,
    this.modelLabel,
    this.backendName,
    this.workStage = AutoSummaryWorkStage.none,
    this.chunkCurrent = 0,
    this.chunkTotal = 0,
    this.inputTokensProcessed,
    this.inputTokensTotal,
    this.outputTokensGenerated,
    this.cooldownUntilMillis = 0,
    this.stopReason,
    this.items = const [],
    this.tagStats = const [],
    this.candidatesFetched = 0,
    this.hasMoreCandidates = false,
  });

  final String runId;
  final int startedAtMillis;
  final int updatedAtMillis;
  final AutoSummaryPhase phase;
  final AutoSummaryWaitReason waitReason;

  final String? currentTag;
  final int? currentWorkId;
  final String? currentWorkTitle;
  final String? modelLabel;
  final String? backendName;

  final AutoSummaryWorkStage workStage;
  final int chunkCurrent;
  final int chunkTotal;

  // トークン進捗は「実測できたときだけ」非null（不定進捗と区別）。
  final int? inputTokensProcessed;
  final int? inputTokensTotal;
  final int? outputTokensGenerated;

  final int cooldownUntilMillis;
  final String? stopReason;

  /// 今回のキュー（作品単位）。全体件数の正本。
  final List<AutoSummaryItem> items;

  /// タグ別内訳。
  final List<AutoSummaryTagStat> tagStats;

  /// 今回取得した候補総数（重複排除前でも workId ユニークで数える）。
  final int candidatesFetched;

  /// まだ追加候補があるか（タグ総数は取得不能 = 真偽のみ）。
  final bool hasMoreCandidates;

  // ---- 件数の導出（items から毎回算出。加算状態を持たない）----

  /// 今回の対象（ユニーク作品数 = items の長さ）。
  int get targetCount => items.length;

  int get savedCount =>
      items.where((e) => e.status == AutoSummaryItemStatus.saved).length;

  /// 処理中（最大1件になるよう設計。実データが複数なら件数を返す）。
  int get processingCount =>
      items.where((e) => e.status == AutoSummaryItemStatus.processing).length;

  int get waitingCount =>
      items.where((e) => e.status == AutoSummaryItemStatus.waiting).length;

  int get failedCount =>
      items.where((e) => e.status == AutoSummaryItemStatus.failed).length;

  int get skippedCount =>
      items.where((e) => e.status == AutoSummaryItemStatus.skipped).length;

  /// 完了率分子（保存済のみ。失敗・スキップは進行に含めない）。
  int get progressDone => savedCount;

  AutoSummaryItem? get currentItem {
    final id = currentWorkId;
    if (id == null) return null;
    for (final it in items) {
      if (it.workId == id) return it;
    }
    return null;
  }

  bool get isRunning =>
      phase == AutoSummaryPhase.scheduled ||
      phase == AutoSummaryPhase.waitingCondition ||
      phase.isActive ||
      phase == AutoSummaryPhase.pausing ||
      phase == AutoSummaryPhase.finishing;

  AutoSummarySnapshot copyWith({
    String? runId,
    int? startedAtMillis,
    int? updatedAtMillis,
    AutoSummaryPhase? phase,
    AutoSummaryWaitReason? waitReason,
    String? currentTag,
    int? currentWorkId,
    String? currentWorkTitle,
    String? modelLabel,
    String? backendName,
    AutoSummaryWorkStage? workStage,
    int? chunkCurrent,
    int? chunkTotal,
    int? inputTokensProcessed,
    int? inputTokensTotal,
    int? outputTokensGenerated,
    int? cooldownUntilMillis,
    String? stopReason,
    List<AutoSummaryItem>? items,
    List<AutoSummaryTagStat>? tagStats,
    int? candidatesFetched,
    bool? hasMoreCandidates,
  }) {
    return AutoSummarySnapshot(
      runId: runId ?? this.runId,
      startedAtMillis: startedAtMillis ?? this.startedAtMillis,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
      phase: phase ?? this.phase,
      waitReason: waitReason ?? this.waitReason,
      currentTag: currentTag ?? this.currentTag,
      currentWorkId: currentWorkId ?? this.currentWorkId,
      currentWorkTitle: currentWorkTitle ?? this.currentWorkTitle,
      modelLabel: modelLabel ?? this.modelLabel,
      backendName: backendName ?? this.backendName,
      workStage: workStage ?? this.workStage,
      chunkCurrent: chunkCurrent ?? this.chunkCurrent,
      chunkTotal: chunkTotal ?? this.chunkTotal,
      inputTokensProcessed: inputTokensProcessed ?? this.inputTokensProcessed,
      inputTokensTotal: inputTokensTotal ?? this.inputTokensTotal,
      outputTokensGenerated:
          outputTokensGenerated ?? this.outputTokensGenerated,
      cooldownUntilMillis: cooldownUntilMillis ?? this.cooldownUntilMillis,
      stopReason: stopReason ?? this.stopReason,
      items: items ?? this.items,
      tagStats: tagStats ?? this.tagStats,
      candidatesFetched: candidatesFetched ?? this.candidatesFetched,
      hasMoreCandidates: hasMoreCandidates ?? this.hasMoreCandidates,
    );
  }

  /// 完了時に phase を savedCount/failedCount から自動判定したコピーを返す。
  /// 失敗・スキップが0なら completed、1件以上あれば completedWithErrors。
  AutoSummarySnapshot resolvedFinished({int? nowMillis}) {
    final errs = failedCount + skippedCount;
    return copyWith(
      phase: errs == 0
          ? AutoSummaryPhase.completed
          : AutoSummaryPhase.completedWithErrors,
      updatedAtMillis: nowMillis ?? updatedAtMillis,
    );
  }

  Map<String, dynamic> toMap() => {
    'runId': runId,
    'startedAtMillis': startedAtMillis,
    'updatedAtMillis': updatedAtMillis,
    'phase': phase.name,
    'waitReason': waitReason.name,
    'currentTag': currentTag,
    'currentWorkId': currentWorkId,
    'currentWorkTitle': currentWorkTitle,
    'modelLabel': modelLabel,
    'backendName': backendName,
    'workStage': workStage.name,
    'chunkCurrent': chunkCurrent,
    'chunkTotal': chunkTotal,
    'inputTokensProcessed': inputTokensProcessed,
    'inputTokensTotal': inputTokensTotal,
    'outputTokensGenerated': outputTokensGenerated,
    'cooldownUntilMillis': cooldownUntilMillis,
    'stopReason': stopReason,
    'items': items.map((e) => e.toMap()).toList(),
    'tagStats': tagStats.map((e) => e.toMap()).toList(),
    'candidatesFetched': candidatesFetched,
    'hasMoreCandidates': hasMoreCandidates,
  };

  static AutoSummarySnapshot fromMap(Map<dynamic, dynamic> m) {
    return AutoSummarySnapshot(
      runId: m['runId'] as String? ?? '',
      startedAtMillis: (m['startedAtMillis'] as num?)?.toInt() ?? 0,
      updatedAtMillis: (m['updatedAtMillis'] as num?)?.toInt() ?? 0,
      phase: AutoSummaryPhase.values.firstWhere(
        (e) => e.name == m['phase'],
        orElse: () => AutoSummaryPhase.disabled,
      ),
      waitReason: AutoSummaryWaitReason.values.firstWhere(
        (e) => e.name == m['waitReason'],
        orElse: () => AutoSummaryWaitReason.none,
      ),
      currentTag: m['currentTag'] as String?,
      currentWorkId: (m['currentWorkId'] as num?)?.toInt(),
      currentWorkTitle: m['currentWorkTitle'] as String?,
      modelLabel: m['modelLabel'] as String?,
      backendName: m['backendName'] as String?,
      workStage: AutoSummaryWorkStage.values.firstWhere(
        (e) => e.name == m['workStage'],
        orElse: () => AutoSummaryWorkStage.none,
      ),
      chunkCurrent: (m['chunkCurrent'] as num?)?.toInt() ?? 0,
      chunkTotal: (m['chunkTotal'] as num?)?.toInt() ?? 0,
      inputTokensProcessed: (m['inputTokensProcessed'] as num?)?.toInt(),
      inputTokensTotal: (m['inputTokensTotal'] as num?)?.toInt(),
      outputTokensGenerated: (m['outputTokensGenerated'] as num?)?.toInt(),
      cooldownUntilMillis: (m['cooldownUntilMillis'] as num?)?.toInt() ?? 0,
      stopReason: m['stopReason'] as String?,
      items:
          ((m['items'] as List?)
              ?.map((e) => AutoSummaryItem.fromMap(e as Map))
              .toList()) ??
          const [],
      tagStats:
          ((m['tagStats'] as List?)
              ?.map((e) => AutoSummaryTagStat.fromMap(e as Map))
              .toList()) ??
          const [],
      candidatesFetched: (m['candidatesFetched'] as num?)?.toInt() ?? 0,
      hasMoreCandidates: m['hasMoreCandidates'] as bool? ?? false,
    );
  }
}
