/// 検索フィルターの統一モデル（検索リビルド Phase 2）。
///
/// 不変クラス。既存フィルター項目と、新規プレミアム相当項目
/// （期間 / 日付範囲 / ブックマーク数範囲）を含む。
///
/// - [duration] と [startDate]/[endDate] を同時に指定した場合は
///   [startDate]/[endDate] が優先される（API では start_date/end_date
///   として送信し、duration は送信しない）。
/// - [bookmarkFilter] は従来の「Nusers入り」ワード接尾方式（既存互換）、
///   [bookmarkNumMin]/[bookmarkNumMax] は API パラメータ方式（新規）。
class SearchFilter {
  const SearchFilter({
    this.searchTarget = 'partial_match_for_tags',
    this.sort = 'date_desc',
    this.ageLimit = 'all',
    this.workType = 'all',
    this.aiFilter = 'all',
    this.bookmarkFilter = 0,
    this.duration,
    this.startDate,
    this.endDate,
    this.bookmarkNumMin,
    this.bookmarkNumMax,
  });

  /// 検索ターゲット: partial_match_for_tags / exact_match_for_tags /
  /// title_and_caption（小説は text / keyword / all_text も可）
  final String searchTarget;

  /// ソート: date_desc / date_asc / popular_desc / relevant（後者はローカル）
  final String sort;

  /// 年齢制限: all / include_r18 / r18 / r18g（イラスト）、all / safe / r18（小説）
  final String ageLimit;

  /// 作品タイプ: all / manga / illustration / none
  final String workType;

  /// AI フィルター: all / hide / only
  final String aiFilter;

  /// 従来のブックマークフィルター（「Nusers入り」ワード接尾方式）。
  /// 0 = 指定なし、-1 = マイブックマーク（未対応=無視）。
  final int bookmarkFilter;

  /// 期間: within_last_day / within_last_week / within_last_month /
  /// within_last_halfyear / within_last_year。null または 'all' = 指定なし。
  final String? duration;

  /// 日付範囲開始（ローカル日付）。設定時は [duration] より優先。
  final DateTime? startDate;

  /// 日付範囲終了（ローカル日付）。設定時は [duration] より優先。
  final DateTime? endDate;

  /// ブックマーク数範囲・下限（API パラメータ bookmark_num_min）。
  final int? bookmarkNumMin;

  /// ブックマーク数範囲・上限（API パラメータ bookmark_num_max）。
  final int? bookmarkNumMax;

  /// 日付範囲が指定されているか。
  static bool hasDateRange(DateTime? start, DateTime? end) =>
      start != null || end != null;

  /// 従来の値を API の duration 値へ変換する。
  ///
  /// - null / '' / 'all' → null（送信しない）
  /// - '1d' / '7d' / '30d' / '180d' / '365d' →
  ///   within_last_day / within_last_week / within_last_month /
  ///   within_last_halfyear / within_last_year
  /// - それ以外 → そのまま返す（UI 側が有効値のみ選択させる前提）
  static String? durationToApiValue(String? d) {
    switch (d) {
      case null:
      case '':
      case 'all':
        return null;
      case '1d':
        return 'within_last_day';
      case '7d':
        return 'within_last_week';
      case '30d':
        return 'within_last_month';
      case '180d':
        return 'within_last_halfyear';
      case '365d':
        return 'within_last_year';
      default:
        return d;
    }
  }

  /// 選択日付を Unix 秒に変換する（開始日 = 当日の 00:00:00・ローカル）。
  static int? startDateTimeToUnixSeconds(DateTime? d) => d == null
      ? null
      : DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 1000;

  /// 選択日付を Unix 秒に変換する（終了日 = 当日の 23:59:59・ローカル）。
  static int? endDateTimeToUnixSeconds(DateTime? d) => d == null
      ? null
      : DateTime(d.year, d.month, d.day, 23, 59, 59).millisecondsSinceEpoch ~/
            1000;

  SearchFilter copyWith({
    String? searchTarget,
    String? sort,
    String? ageLimit,
    String? workType,
    String? aiFilter,
    int? bookmarkFilter,
    String? duration,
    DateTime? startDate,
    DateTime? endDate,
    int? bookmarkNumMin,
    int? bookmarkNumMax,
  }) {
    return SearchFilter(
      searchTarget: searchTarget ?? this.searchTarget,
      sort: sort ?? this.sort,
      ageLimit: ageLimit ?? this.ageLimit,
      workType: workType ?? this.workType,
      aiFilter: aiFilter ?? this.aiFilter,
      bookmarkFilter: bookmarkFilter ?? this.bookmarkFilter,
      duration: duration ?? this.duration,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      bookmarkNumMin: bookmarkNumMin ?? this.bookmarkNumMin,
      bookmarkNumMax: bookmarkNumMax ?? this.bookmarkNumMax,
    );
  }

  Map<String, dynamic> toJson() => {
    'searchTarget': searchTarget,
    'sort': sort,
    'ageLimit': ageLimit,
    'workType': workType,
    'aiFilter': aiFilter,
    'bookmarkFilter': bookmarkFilter,
    if (duration != null) 'duration': duration,
    if (startDate != null) 'startDate': startDate!.toIso8601String(),
    if (endDate != null) 'endDate': endDate!.toIso8601String(),
    if (bookmarkNumMin != null) 'bookmarkNumMin': bookmarkNumMin,
    if (bookmarkNumMax != null) 'bookmarkNumMax': bookmarkNumMax,
  };

  factory SearchFilter.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic v) => v is String ? DateTime.tryParse(v) : null;
    return SearchFilter(
      searchTarget: json['searchTarget'] as String? ?? 'partial_match_for_tags',
      sort: json['sort'] as String? ?? 'date_desc',
      ageLimit: json['ageLimit'] as String? ?? 'all',
      workType: json['workType'] as String? ?? 'all',
      aiFilter: json['aiFilter'] as String? ?? 'all',
      bookmarkFilter: (json['bookmarkFilter'] as num?)?.toInt() ?? 0,
      duration: json['duration'] as String?,
      startDate: parseDate(json['startDate']),
      endDate: parseDate(json['endDate']),
      bookmarkNumMin: (json['bookmarkNumMin'] as num?)?.toInt(),
      bookmarkNumMax: (json['bookmarkNumMax'] as num?)?.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchFilter &&
          other.runtimeType == runtimeType &&
          other.searchTarget == searchTarget &&
          other.sort == sort &&
          other.ageLimit == ageLimit &&
          other.workType == workType &&
          other.aiFilter == aiFilter &&
          other.bookmarkFilter == bookmarkFilter &&
          other.duration == duration &&
          other.startDate == startDate &&
          other.endDate == endDate &&
          other.bookmarkNumMin == bookmarkNumMin &&
          other.bookmarkNumMax == bookmarkNumMax;

  @override
  int get hashCode => Object.hash(
    searchTarget,
    sort,
    ageLimit,
    workType,
    aiFilter,
    bookmarkFilter,
    duration,
    startDate,
    endDate,
    bookmarkNumMin,
    bookmarkNumMax,
  );
}
