import 'package:flutter/material.dart';
import 'dart:async';
import 'package:drift/drift.dart' show TableUpdateQuery;
import '../../core/models/active_user.dart';
import '../../data/daos/cash_session_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';
import '../../shared/widgets/app_workspace.dart';
import '../pos_checkout/pos_shift.dart';

class CashSessionScreen extends StatefulWidget {
  final ActiveUser user;
  final CashSessionRepository repository;
  final CashSessionSummary? currentShift;
  final CashSessionSummary? otherShift;
  final bool useSharedCurrent;
  final bool showTitle;
  final VoidCallback? onGoPos;
  const CashSessionScreen(
      {super.key,
      required this.user,
      required this.repository,
      this.currentShift,
      this.otherShift,
      this.useSharedCurrent = false,
      this.showTitle = true,
      this.onGoPos});
  @override
  State<CashSessionScreen> createState() => _CashSessionScreenState();
}

class _CashSessionScreenState extends State<CashSessionScreen> {
  List<CashSessionSummary> sessions = [];
  List<ZReading> zReadings = [];
  Map<String, String> userNames = {};
  String? sessionError, zError;
  bool loadingSessions = true, loadingZ = true;
  int _sessionsRevision = 0, _zRevision = 0;
  StreamSubscription<dynamic>? _changes;

  @override
  void initState() {
    super.initState();
    refresh();
    _changes = widget.repository.db
        .tableUpdates(TableUpdateQuery.onAllTables([
          widget.repository.db.cashSessions,
          widget.repository.db.cashMovements,
          widget.repository.db.zReadings,
        ]))
        .listen((_) => refresh());
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  Future<void> refresh() async =>
      Future.wait([_refreshSessions(), _refreshZ()]);

  Future<void> _refreshSessions() async {
    final revision = ++_sessionsRevision;
    if (mounted) setState(() => loadingSessions = true);
    try {
      final rows = await widget.repository.history();
      final users =
          await widget.repository.db.select(widget.repository.db.users).get();
      if (mounted && revision == _sessionsRevision) {
        setState(() {
          sessions = rows;
          userNames = {for (final user in users) user.id: user.name};
          sessionError = null;
        });
      }
    } catch (_) {
      if (mounted && revision == _sessionsRevision) {
        setState(() => sessionError = 'Could not load cash sessions.');
      }
    } finally {
      if (mounted && revision == _sessionsRevision) {
        setState(() => loadingSessions = false);
      }
    }
  }

  Future<void> _refreshZ() async {
    final revision = ++_zRevision;
    if (mounted) setState(() => loadingZ = true);
    try {
      final rows = await widget.repository.zHistory();
      if (mounted && revision == _zRevision) {
        setState(() {
          zReadings = rows;
          zError = null;
        });
      }
    } catch (_) {
      if (mounted && revision == _zRevision) {
        setState(() => zError = 'Could not load Z-readings.');
      }
    } finally {
      if (mounted && revision == _zRevision) setState(() => loadingZ = false);
    }
  }

  String _when(DateTime at) {
    final local = at.toLocal();
    final now = DateTime.now().toLocal();
    final date = DateUtils.isSameDay(local, now)
        ? 'Today'
        : DateUtils.isSameDay(local, now.subtract(const Duration(days: 1)))
            ? 'Yesterday'
            : MaterialLocalizations.of(context).formatMediumDate(local);
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(local),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
    return '$date · $time';
  }

  String _status(int value) => value == 0
      ? 'Balanced'
      : value < 0
          ? 'Short'
          : 'Over';
  String _signed(int value) => formatPeso(value.abs());
  String _name(String id) => userNames[id] ?? 'Team member';

  static Widget _metric(String label, String value, {bool strong = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(child: Text(label)),
          Text(value,
              style: TextStyle(
                  fontWeight: strong ? FontWeight.w700 : FontWeight.w500)),
        ]),
      );

  Widget _panel(Widget child) => Card(
      margin: EdgeInsets.zero,
      child: Padding(padding: const EdgeInsets.all(18), child: child));

  Widget _failure(String message, VoidCallback retry) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(message),
        TextButton(onPressed: retry, child: const Text('Retry'))
      ]);

  @override
  Widget build(BuildContext context) {
    final active = widget.useSharedCurrent
        ? widget.currentShift
        : sessions.where((s) => s.session.closedAt == null).firstOrNull;
    final previous =
        sessions.where((s) => s.session.closedAt != null).take(8).toList();
    final wide = MediaQuery.sizeOf(context).width >= 850;
    return AppWorkspacePadding(
        child: ListView(padding: EdgeInsets.zero, children: [
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.showTitle) ...[
          const AppPageHeader(
            title: 'Cash Session',
            subtitle: 'Review shift cash and closing history.',
          ),
        ],
        if (loadingSessions && sessions.isEmpty)
          const Padding(
              padding: EdgeInsets.all(24), child: CircularProgressIndicator())
        else if (sessionError != null)
          _panel(_failure(sessionError!, _refreshSessions))
        else if (active == null)
          _panel(
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('No active cash session',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text(
                'Start and close your cashier shift from Point of Sale.'),
            if (widget.onGoPos != null) ...[
              const SizedBox(height: 14),
              FilledButton(
                  onPressed: widget.onGoPos, child: const Text('Go to POS')),
            ],
          ]))
        else ...[
          _panel(
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('CURRENT SHIFT',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 10),
            Text('Opened by ${_name(active.session.openedByUserId)}',
                style: Theme.of(context).textTheme.titleMedium),
            Text(_when(active.session.openedAt)),
            const Divider(height: 24),
            _metric(
                'Opening cash', formatPeso(active.session.startingCashCents)),
            _metric('Expected cash', formatPeso(active.expectedCents),
                strong: true),
          ])),
          const SizedBox(height: 10),
          TextButton(
              onPressed: () => _showShift(active),
              child: const Text('View details')),
          if (active.session.openedByUserId != widget.user.id &&
              widget.user.can(PosPermission.manageCashSession))
            TextButton(
                onPressed: () async {
                  if (await showPosCloseShift(
                      context, widget.repository, widget.user, active)) {
                    await refresh();
                  }
                },
                child: const Text('Close other user shift')),
        ],
        if (widget.otherShift != null &&
            widget.user.can(PosPermission.manageCashSession)) ...[
          const SizedBox(height: 12),
          _panel(
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('OTHER USER SHIFT',
                style: Theme.of(context).textTheme.labelLarge),
            Text(
                'Opened by ${_name(widget.otherShift!.session.openedByUserId)}'),
            _metric(
                'Expected cash', formatPeso(widget.otherShift!.expectedCents)),
            TextButton(
                onPressed: () async {
                  if (await showPosCloseShift(context, widget.repository,
                      widget.user, widget.otherShift!)) {
                    await refresh();
                  }
                },
                child: const Text('Close other user shift')),
          ])),
        ],
        const SizedBox(height: 24),
        Text('HISTORY', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 10),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 11, child: _history(previous)),
            const SizedBox(width: 14),
            Expanded(flex: 9, child: _zHistory()),
          ])
        else
          Column(children: [
            _history(previous),
            const SizedBox(height: 14),
            _zHistory()
          ]),
      ]),
    ]));
  }

  Widget _history(List<CashSessionSummary> rows) =>
      _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Previous shifts', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (loadingSessions && rows.isEmpty)
          const LinearProgressIndicator()
        else if (sessionError != null)
          _failure('Could not load previous shifts.', _refreshSessions)
        else if (rows.isEmpty)
          const Text('No previous shifts yet.')
        else
          for (final row in rows) ...[
            const Divider(height: 18),
            Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        '${_when(row.session.closedAt ?? row.session.openedAt)} · ${_name(row.session.openedByUserId)}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                        'Expected ${formatPeso(row.expectedCents)} · Actual ${formatPeso(row.session.actualCashCents ?? 0)}'),
                    Text(
                        '${_status(row.varianceCents ?? 0)} ${formatPeso((row.varianceCents ?? 0).abs())}'),
                  ])),
              TextButton(
                  onPressed: () => _showShift(row), child: const Text('View')),
            ]),
          ],
      ]));

  void _showShift(CashSessionSummary row) {
    final z =
        zReadings.where((z) => z.cashSessionId == row.session.id).firstOrNull;
    showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(row.session.closedAt == null
                  ? 'Current shift'
                  : 'Previous shift'),
              content: SizedBox(
                  width: 430,
                  child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    _metric('Opened by', _name(row.session.openedByUserId)),
                    _metric('Opened at', _when(row.session.openedAt)),
                    if (row.session.closedAt != null)
                      _metric('Closed at', _when(row.session.closedAt!)),
                    _metric('Opening cash',
                        formatPeso(row.session.startingCashCents)),
                    _metric('Expected cash', formatPeso(row.expectedCents)),
                    if (row.session.actualCashCents != null)
                      _metric('Actual cash',
                          formatPeso(row.session.actualCashCents!)),
                    if (row.varianceCents != null)
                      _metric(_status(row.varianceCents!),
                          _signed(row.varianceCents!)),
                    if (z != null) _metric('Z-reading', 'Z #${z.number}'),
                    const Divider(),
                    FutureBuilder(
                      future: (widget.repository.db
                              .select(widget.repository.db.cashMovements)
                            ..where((m) => m.sessionId.equals(row.session.id)))
                          .get(),
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return const LinearProgressIndicator();
                        }
                        final movements = snapshot.data!;
                        int sum(String kind) => movements
                            .where((m) => m.kind == kind)
                            .fold(0, (total, m) => total + m.amountCents);
                        return Column(children: [
                          _metric(
                              'Cash sales and other inflows',
                              formatPeso(movements
                                  .where((m) =>
                                      m.amountCents > 0 &&
                                      m.kind != 'business_expense_reversal')
                                  .fold(
                                      0, (total, m) => total + m.amountCents))),
                          _metric(
                              'Cash expenses',
                              formatPeso(sum('business_expense').abs() +
                                  sum('petty_cash').abs())),
                          _metric('Expense reversals',
                              formatPeso(sum('business_expense_reversal'))),
                          _metric('Supplier payments',
                              formatPeso(sum('supplier_payment').abs())),
                          _metric(
                              'Refunds and other cash out',
                              formatPeso(movements
                                  .where((m) =>
                                      m.amountCents < 0 &&
                                      m.kind != 'business_expense' &&
                                      m.kind != 'supplier_payment' &&
                                      m.kind != 'petty_cash')
                                  .fold<int>(
                                      0, (total, m) => total - m.amountCents))),
                          for (final movement in movements.where((m) =>
                              m.kind == 'business_expense' ||
                              m.kind == 'business_expense_reversal' ||
                              m.kind == 'petty_cash'))
                            _metric(
                                movement.kind == 'business_expense_reversal'
                                    ? 'Expense reversal'
                                    : 'Drawer expense',
                                formatPeso(movement.amountCents)),
                        ]);
                      },
                    ),
                  ]))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'))
              ],
            ));
  }

  Widget _zHistory() =>
      _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Z-reading history',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (loadingZ && zReadings.isEmpty)
          const LinearProgressIndicator()
        else if (zError != null)
          _failure(zError!, _refreshZ)
        else if (zReadings.isEmpty)
          const Text('No Z-readings yet.')
        else
          for (final z in zReadings.take(8)) ...[
            const Divider(height: 18),
            Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('Z #${z.number}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(_when(z.generatedAt)),
                    Text(
                        'Invoices ${z.beginningInvoiceNumber ?? 'none'}–${z.endingInvoiceNumber ?? 'none'}'),
                    Text(
                        'Sales ${formatPeso(z.periodSalesCents)} · Reversals ${formatPeso(z.reversalCents)}'),
                    Text('Grand total ${formatPeso(z.grandTotalCents)}'),
                  ])),
              TextButton(
                  onPressed: () => _showZ(z),
                  child: const Text('View details')),
            ]),
          ],
      ]));

  void _showZ(ZReading z) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
            title: Text('Z #${z.number}'),
            content: SizedBox(
                width: 380,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  _metric('Generated', _when(z.generatedAt)),
                  _metric('Invoices',
                      '${z.beginningInvoiceNumber ?? 'none'}–${z.endingInvoiceNumber ?? 'none'}'),
                  _metric('Sales', formatPeso(z.periodSalesCents)),
                  _metric('Reversals', formatPeso(z.reversalCents)),
                  _metric('Grand total', formatPeso(z.grandTotalCents),
                      strong: true),
                ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'))
            ],
          ));
}
