// 10-B1 4-A: PCサーバー（PixEmber Companion）設定・状態画面。
//
// - 登録（ペアリング）: サーバ側の pairing_tool.py が発行した
//   https://host:8766 / 証明書SHA-256 / ワンタイムコード を人力で入力（TOFU禁止）。
// - 状態表示: 接続中/切断中/認証失効/証明書不一致 + サーバ stage・本日数・キュー。
// - 設定編集: tags / max_per_day / interval / active_hours / 自律巡回 ON-OFF。
//   すべて POST /config → GET /config の実効値で表示を更新（楽観UI禁止）。
// - 保存済みサーバー生成結果の一覧（GET /summaries）。
import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import '../widgets/design_system/app_panel.dart';
import '../widgets/design_system/app_section_header.dart';
import '../widgets/design_system/app_state_view.dart';
import '../widgets/design_system/app_status_banner.dart';
import '../services/companion/companion_models.dart';
import '../services/companion/companion_service.dart';
import '../services/companion/companion_transport.dart';

class CompanionSettingsScreen extends StatefulWidget {
  const CompanionSettingsScreen({super.key, this.service});

  final CompanionService? service;

  @override
  State<CompanionSettingsScreen> createState() =>
      _CompanionSettingsScreenState();
}

class _CompanionSettingsScreenState extends State<CompanionSettingsScreen> {
  late final CompanionService _svc = widget.service ?? CompanionService();

  bool _initializing = true;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  CompanionStatus? _status;
  CompanionConfig? _config;
  List<Map<String, dynamic>> _queue = const [];
  List<CompanionSummaryItem> _summaries = const [];

  // ペアリング入力
  final _urlCtrl = TextEditingController(text: 'https://192.168.11.24:8766');
  final _certCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController(text: 'Android');

  // config 編集（GET /config 実効値から流し込む）
  final _tagsCtrl = TextEditingController();
  final _maxDayCtrl = TextEditingController();
  final _intervalMinCtrl = TextEditingController();
  final _hoursCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _certCtrl.dispose();
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    _tagsCtrl.dispose();
    _maxDayCtrl.dispose();
    _intervalMinCtrl.dispose();
    _hoursCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    await _svc.init();
    if (mounted) setState(() => _initializing = false);
    if (_svc.isPaired) await _refresh();
  }

  void _setMsg(String m, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = m;
      _messageIsError = error;
    });
  }

  String _describeError(Object e) {
    if (e is CompanionAuthException) {
      switch (e.code) {
        case 'device_revoked':
          return '認証失効: この端末の登録はPC側で取り消されました。再登録してください。';
        case 'pairing_required':
          return 'PCサーバーにまだ端末が登録されていません。PC側でペアリングを実行してください。';
        case 'invalid_pairing_code':
          return 'ペアリングコードが無効です（期限切れ・使用済み・試行超過）。PC側で再発行してください。';
        case 'pairing_disabled':
          return 'ペアリング窓口が閉じています。PC側で pair 実行後にもう一度試してください。';
        default:
          return '認証エラー（${e.code}）。トークンの再発行が必要な可能性があります。';
      }
    }
    if (e is CompanionCertException) {
      return '証明書不一致: サーバーの証明書が登録時と変わりました。通信を中断します（再登録が必要）。';
    }
    if (e is CompanionNetworkException) {
      return '接続できません: ${e.message}（PCサーバーと同じLANに接続し、サービスが起動しているか確認）';
    }
    if (e is CompanionApiException) {
      switch (e.code) {
        case 'manual_daily_cap':
          return '本日の手動生成上限に達しました。';
        case 'queue_full':
          return 'ジョブキューが満杯です。完了を待ってから再試行してください。';
        default:
          return 'サーバーエラー（${e.code}）';
      }
    }
    return 'エラー: $e';
  }

  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } catch (e) {
      _setMsg(_describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- ペアリング ----

  Future<void> _pair() => _run(() async {
    final url = _urlCtrl.text.trim();
    final cert = _certCtrl.text.trim().toLowerCase();
    final code = _codeCtrl.text.trim();
    if (!url.startsWith('https://')) {
      _setMsg('URL は https:// で入力してください（HTTP 入口はありません）。', error: true);
      return;
    }
    if (cert.length != 64 ||
        RegExp(r'^[0-9a-f]{64}$').hasMatch(cert) == false) {
      _setMsg('証明書SHA-256 は64桁の16進数で貼り付けてください。', error: true);
      return;
    }
    if (code.isEmpty) {
      _setMsg('ペアリングコードを入力してください。', error: true);
      return;
    }
    await _svc.pair(
      baseUrl: url,
      certSha256: cert,
      code: code,
      deviceName: _nameCtrl.text.trim().isEmpty
          ? 'Android'
          : _nameCtrl.text.trim(),
    );
    _codeCtrl.clear();
    _setMsg('登録に成功しました。');
    await _refresh();
  });

  Future<void> _unregister() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('この端末の登録を解除しますか？'),
        content: const Text(
          'この端末に保存された接続情報（トークン）を削除します。\n'
          'PC側の登録を完全に失効させるには、PCの端末管理ツールで '
          'revoke 操作が必要です（本画面からは行いません）。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('戻る'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('解除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _svc.unregister();
      if (mounted) {
        setState(() {
          _status = null;
          _config = null;
          _queue = const [];
          _summaries = const [];
        });
        _setMsg('登録を解除しました。');
      }
    }
  }

  // ---- 状態・設定・一覧 ----

  Future<void> _refresh() => _run(() async {
    final status = await _svc.status();
    final config = await _svc.getConfig();
    final queue = await _svc.queue();
    if (!mounted) return;
    setState(() {
      _status = status;
      _config = config;
      _queue = queue;
      // 編集フィールドは GET /config の実効値から毎回同期（楽観値を使わない）
      _tagsCtrl.text = config.tags.join(', ');
      _maxDayCtrl.text = '${config.maxPerDay ?? ''}';
      _intervalMinCtrl.text = config.intervalSeconds == null
          ? ''
          : '${(config.intervalSeconds! / 60).round()}';
      _hoursCtrl.text = config.activeHours ?? '';
    });
  });

  Future<void> _loadSummaries() => _run(() async {
    final page = await _svc.listSummaries(limit: 20);
    if (!mounted) return;
    setState(() => _summaries = page.items);
    if (page.items.isEmpty) _setMsg('サーバー上の保存済み要約はまだありません。');
  });

  Future<void> _applyConfig({bool? enabled}) => _run(() async {
    final patch = <String, dynamic>{};
    if (enabled != null) patch['enabled'] = enabled;
    if (enabled == null) {
      final tags = _tagsCtrl.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      patch['tags'] = tags;
      final maxDay = int.tryParse(_maxDayCtrl.text.trim());
      if (maxDay != null) patch['max_per_day'] = maxDay;
      final intervalMin = int.tryParse(_intervalMinCtrl.text.trim());
      if (intervalMin != null && intervalMin > 0) {
        patch['pull_interval_minutes'] = intervalMin;
      }
      final hours = _hoursCtrl.text.trim();
      patch['active_hours'] = hours.isEmpty ? null : hours;
    }
    final confirmed = await _svc.postConfig(patch);
    if (!mounted) return;
    setState(() => _config = confirmed);
    _setMsg('設定をサーバー実効値で確認できました。');
    await _refresh();
  });

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('PCサーバー（Companion）'),
        foregroundColor: colorScheme.onSurface,
        actions: [
          if (_svc.isPaired)
            IconButton(
              tooltip: '更新',
              icon: const Icon(Icons.refresh),
              onPressed: _busy ? null : _refresh,
            ),
        ],
      ),
      body: _initializing
          ? const AppStateView(type: AppStateViewType.loading)
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                _linkBanner(),
                if (_message != null)
                  AppStatusBanner(
                    type: _messageIsError
                        ? AppStatusType.error
                        : AppStatusType.success,
                    title: _message!,
                    margin: const EdgeInsets.only(bottom: AppSpacing.md),
                  ),
                if (!_svc.isPaired) ...[
                  _pairingCard(),
                ] else ...[
                  _statusCard(),
                  _configCard(),
                  _queueCard(),
                  _summariesCard(),
                  _dangerCard(),
                ],
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _linkBanner() {
    final colorScheme = Theme.of(context).colorScheme;
    final color = switch (_svc.link) {
      CompanionLink.connected => colorScheme.primary,
      CompanionLink.certMismatch => colorScheme.error,
      CompanionLink.authExpired => colorScheme.tertiary,
      _ => colorScheme.onSurfaceVariant,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 6),
          Text(
            '状態: ${companionLinkLabel(_svc.link)}',
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          if (_busy)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _card({
    required String title,
    required List<Widget> children,
    String? subtitle,
  }) {
    return AppPanel(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSectionHeader(title, subtitle: subtitle),
          const SizedBox(height: AppSpacing.sm),
          ...children,
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    int maxLines = 1,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        style: TextStyle(color: colorScheme.onSurface, fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: TextStyle(
            color: colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
          hintStyle: TextStyle(
            color: colorScheme.onSurfaceVariant,
            fontSize: 11,
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: colorScheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: colorScheme.primary),
          ),
        ),
      ),
    );
  }

  Widget _pairingCard() {
    return _card(
      title: 'PCサーバーを登録',
      subtitle:
          'PC 上で pairing_tool.py pair を実行し、表示される接続情報'
          '（pairing.json）を貼り付けてください。コードは使い捨て・有効期限があります。',
      children: [
        _field(_urlCtrl, '接続先 URL', hint: 'https://192.168.11.24:8766'),
        _field(_certCtrl, '証明書 SHA-256', hint: '64桁の16進（cert_sha256）'),
        _field(_codeCtrl, 'ペアリングコード', hint: '10桁の英数字（失効前に）'),
        _field(_nameCtrl, 'この端末の名前'),
        FilledButton.icon(
          onPressed: _busy ? null : _pair,
          icon: const Icon(Icons.link, size: 16),
          label: const Text('登録する'),
        ),
      ],
    );
  }

  Widget _statusCard() {
    final s = _status;
    final colorScheme = Theme.of(context).colorScheme;
    return _card(
      title: 'サーバー状態',
      children: [
        if (s == null)
          Text(
            '未取得（更新を押してください）',
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
          )
        else
          ...[
            ('ステージ', s.stage ?? '-'),
            ('自律巡回', s.autoEnabled == true ? '有効' : '無効'),
            ('Pixiv認証', s.pixivAuth ?? '-'),
            ('本日生成（自動）', '${s.generatedToday ?? '-'} / ${s.maxPerDay ?? '-'}'),
            (
              '本日生成（手動）',
              '${s.manualToday ?? '-'} / ${s.manualMaxPerDay ?? '-'}',
            ),
            ('実行中ジョブ', '${s.jobsActive ?? 0}'),
            ('サーバー版', s.version ?? '-'),
            ('サーバーID', s.serverId ?? '-'),
            if (s.raw['last_error'] is String) ...[
              ('直近エラー', s.raw['last_error'] as String),
            ],
          ].map(
            (row) => Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      row.$1,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.$2,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: _busy ? null : _refresh,
          icon: const Icon(Icons.refresh, size: 14),
          label: const Text('接続テスト／更新'),
          style: OutlinedButton.styleFrom(
            foregroundColor: colorScheme.onSurfaceVariant,
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
        ),
      ],
    );
  }

  Widget _configCard() {
    final enabled = _config?.enabled ?? false;
    final colorScheme = Theme.of(context).colorScheme;
    return _card(
      title: 'サーバー設定（PCの自律巡回）',
      subtitle:
          '変更はPOST送信後、GET /config の実効値で表示が確定します。'
          '巡回を有効にすると PC が勝手にタグ検索→生成を再開します。',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: enabled,
          activeThumbColor: colorScheme.primary,
          title: Text(
            '自律巡回を有効',
            style: TextStyle(color: colorScheme.onSurface, fontSize: 13),
          ),
          onChanged: _busy
              ? null
              : (v) {
                  _applyConfig(enabled: v);
                },
        ),
        _field(_tagsCtrl, '巡回タグ（カンマ区切り・最大20）'),
        Row(
          children: [
            Expanded(child: _field(_maxDayCtrl, '日次上限')),
            const SizedBox(width: 8),
            Expanded(child: _field(_intervalMinCtrl, '巡回間隔（分）')),
          ],
        ),
        _field(_hoursCtrl, '稼働時間帯 JST（例 22-06、空=常時）'),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _applyConfig(),
          icon: const Icon(Icons.upload, size: 14),
          label: const Text('設定を送信'),
          style: OutlinedButton.styleFrom(
            foregroundColor: colorScheme.primary,
            side: BorderSide(color: colorScheme.primary),
          ),
        ),
      ],
    );
  }

  Widget _queueCard() {
    final colorScheme = Theme.of(context).colorScheme;
    return _card(
      title: '自律キュー（先頭 ${_queue.length} 件）',
      children: [
        if (_queue.isEmpty)
          Text(
            '空です',
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
          )
        else
          ..._queue
              .take(10)
              .map(
                (e) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '${e['work_id']}  ${e['title'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
      ],
    );
  }

  Widget _summariesCard() {
    final colorScheme = Theme.of(context).colorScheme;
    return _card(
      title: 'サーバー生成済み要約',
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _loadSummaries,
          icon: const Icon(Icons.download, size: 14),
          label: const Text('一覧を取得'),
          style: OutlinedButton.styleFrom(
            foregroundColor: colorScheme.onSurfaceVariant,
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
        ),
        const SizedBox(height: 6),
        ..._summaries.map(
          (e) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              '#${e.workId}（${e.modelId}）',
              style: TextStyle(color: colorScheme.onSurface, fontSize: 12),
            ),
            subtitle: Text(
              e.synopsis
                  .replaceAll('\n', ' ')
                  .substring(
                    0,
                    e.synopsis.length > 60 ? 60 : e.synopsis.length,
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _dangerCard() {
    final colorScheme = Theme.of(context).colorScheme;
    return _card(
      title: '登録の解除',
      subtitle: 'この端末のトークンを削除します。PC側の失効は pairing_tool.py revoke 。',
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _unregister,
          icon: const Icon(Icons.delete_outline, size: 14),
          label: const Text('この端末の登録を解除'),
          style: OutlinedButton.styleFrom(
            foregroundColor: colorScheme.error,
            side: BorderSide(color: colorScheme.error),
          ),
        ),
      ],
    );
  }
}
