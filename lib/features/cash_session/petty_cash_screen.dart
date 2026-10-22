import 'package:flutter/material.dart';
import '../../core/models/active_user.dart';
import '../../data/daos/cash_activity_repository.dart';
import '../../data/daos/cash_session_repository.dart';
import '../../data/daos/petty_cash_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/app_workspace.dart';

class PettyCashScreen extends StatefulWidget {
  final PettyCashRepository repository;
  final ActiveUser user;
  const PettyCashScreen(
      {super.key, required this.repository, required this.user});
  @override
  State<PettyCashScreen> createState() => _PettyCashScreenState();
}

class _PettyCashScreenState extends State<PettyCashScreen> {
  late final CashActivityRepository cash =
      CashActivityRepository(widget.repository.db);
  final search = TextEditingController();
  String fund = 'all', type = 'all';
  int tab = 0;
  String? categoryId, userId;
  DateTimeRange? dates;
  int revision = 0;
  Future<_Data>? data;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  void refresh() => setState(() {
        revision++;
        data = _load();
      });
  Future<_Data> _load() async {
    final db = widget.repository.db;
    final rows = await cash.history();
    final legacy = await widget.repository.history();
    final categories = await cash.categories();
    final users = await db.select(db.users).get();
    final session = await CashSessionRepository(db).active();
    return _Data(
        rows,
        legacy,
        categories,
        {for (final u in users) u.id: u.name},
        session,
        session == null
            ? null
            : await CashSessionRepository(db).expected(session.id),
        await cash.balance('petty'),
        await cash.balance('company'),
        await cash.reimbursementDue());
  }

  String name(String? id, _Data d) =>
      id == null ? '—' : d.users[id] ?? 'Team member';
  String fundName(String? key) => switch (key) {
        'drawer' => 'Current cash drawer',
        'petty' => 'Petty cash',
        'company' => 'Company cash',
        'personal' => 'Paid personally',
        _ => 'Historical drawer',
      };
  String when(DateTime date) {
    final local = date.toLocal();
    final l = MaterialLocalizations.of(context);
    return '${l.formatMediumDate(local)} · ${l.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  Future<void> expense(_Data d, {String? preferredSource}) async {
    String source = preferredSource ?? (d.session == null ? 'petty' : 'drawer');
    String? category = d.categories.where((c) => c.active).firstOrNull?.id;
    String? error;
    bool saving = false;
    await showDialog<void>(
        context: context,
        builder: (dialog) => _CashDialogControllers(
              count: 5,
              builder: (dialog, controllers) {
                final amount = controllers[0];
                final payee = controllers[1];
                final reference = controllers[2];
                final note = controllers[3];
                final payer = controllers[4];
                return StatefulBuilder(builder: (dialog, update) {
                  final cents = tryParsePeso(amount.text);
                  final before = switch (source) {
                    'drawer' => d.drawer ?? 0,
                    'petty' => d.petty,
                    'company' => d.company,
                    _ => 0
                  };
                  return AlertDialog(
                    title: const Text('Record expense'),
                    content: SizedBox(
                        width: 680,
                        child: ConstrainedBox(
                            constraints: BoxConstraints(
                                maxHeight:
                                    MediaQuery.sizeOf(dialog).height * .68),
                            child: SingleChildScrollView(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                  const Text(
                                      'Record business cash spent outside a sale.'),
                                  const SizedBox(height: 18),
                                  Text('PAID FROM',
                                      style: Theme.of(dialog)
                                          .textTheme
                                          .labelLarge),
                                  const SizedBox(height: 8),
                                  RadioGroup<String>(
                                      groupValue: source,
                                      onChanged: (value) {
                                        if (value != null) {
                                          update(() => source = value);
                                        }
                                      },
                                      child: Column(children: [
                                        for (final key in [
                                          'drawer',
                                          'petty',
                                          'company',
                                          'personal'
                                        ])
                                          if (key != 'drawer' ||
                                              d.session != null)
                                            RadioListTile<String>(
                                              dense: true,
                                              contentPadding: EdgeInsets.zero,
                                              value: key,
                                              title: Text(fundName(key)),
                                              subtitle: Text(switch (key) {
                                                'drawer' =>
                                                  'Current shift · Expected ${formatPeso(d.drawer ?? 0)}',
                                                'petty' =>
                                                  'Available ${formatPeso(d.petty)}',
                                                'company' =>
                                                  'Available ${formatPeso(d.company)}',
                                                _ =>
                                                  'Creates reimbursement due',
                                              }),
                                            ),
                                      ])),
                                  const Divider(height: 28),
                                  Text('EXPENSE DETAILS',
                                      style: Theme.of(dialog)
                                          .textTheme
                                          .labelLarge),
                                  const SizedBox(height: 12),
                                  TextField(
                                      controller: amount,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                              decimal: true),
                                      decoration: const InputDecoration(
                                          labelText: 'Amount *',
                                          prefixText: '₱ '),
                                      onChanged: (_) => update(() {})),
                                  const SizedBox(height: 12),
                                  DropdownButtonFormField<String>(
                                      initialValue: category,
                                      decoration: const InputDecoration(
                                          labelText: 'Category *'),
                                      items: d.categories
                                          .where((c) => c.active)
                                          .map((c) => DropdownMenuItem(
                                              value: c.id, child: Text(c.name)))
                                          .toList(),
                                      onChanged: (value) =>
                                          update(() => category = value)),
                                  if (source == 'personal') ...[
                                    const SizedBox(height: 12),
                                    TextField(
                                        controller: payer,
                                        decoration: const InputDecoration(
                                            labelText: 'Paid by *'))
                                  ],
                                  const SizedBox(height: 12),
                                  TextField(
                                      controller: payee,
                                      decoration: const InputDecoration(
                                          labelText: 'Payee / Merchant')),
                                  const SizedBox(height: 12),
                                  TextField(
                                      controller: reference,
                                      decoration: const InputDecoration(
                                          labelText: 'Receipt / Reference #')),
                                  const SizedBox(height: 12),
                                  TextField(
                                      controller: note,
                                      maxLines: 3,
                                      decoration: const InputDecoration(
                                          labelText: 'Notes')),
                                  const SizedBox(height: 16),
                                  Text('CASH EFFECT',
                                      style: Theme.of(dialog)
                                          .textTheme
                                          .labelLarge),
                                  const SizedBox(height: 6),
                                  if (source == 'personal')
                                    Text(
                                        'No business cash changes now. Reimbursement due increases by ${formatPeso(cents ?? 0)}')
                                  else
                                    Text(
                                        'Available before ${formatPeso(before)}  ·  Expense −${formatPeso(cents ?? 0)}  ·  Available after ${formatPeso(before - (cents ?? 0))}'),
                                  if (error != null)
                                    Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: Text(error!,
                                            style: TextStyle(
                                                color: Theme.of(dialog)
                                                    .colorScheme
                                                    .error))),
                                ])))),
                    actions: [
                      TextButton(
                          onPressed:
                              saving ? null : () => Navigator.pop(dialog),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: saving
                              ? null
                              : () async {
                                  if (cents == null ||
                                      cents <= 0 ||
                                      category == null) {
                                    update(() => error =
                                        'Enter a valid amount and category');
                                    return;
                                  }
                                  update(() {
                                    saving = true;
                                    error = null;
                                  });
                                  try {
                                    await cash.expense(widget.user,
                                        amountCents: cents,
                                        source: source,
                                        categoryId: category!,
                                        payee: payee.text,
                                        reference: reference.text,
                                        note: note.text,
                                        personallyPaidBy: payer.text);
                                    if (dialog.mounted) Navigator.pop(dialog);
                                    refresh();
                                  } catch (e) {
                                    update(() => error = safeMessage(e));
                                  } finally {
                                    if (dialog.mounted) {
                                      update(() => saving = false);
                                    }
                                  }
                                },
                          child: Text(cents == null
                              ? 'Record expense'
                              : 'Record ${formatPeso(cents)} expense'))
                    ],
                  );
                });
              },
            ));
  }

  Future<void> addCash(
      {required String title,
      required String destination,
      required bool opening}) async {
    final fromBalance = opening ? 0 : await cash.balance('company');
    final toBalance = await cash.balance(destination);
    if (!mounted) return;
    String? error;
    await showDialog<void>(
        context: context,
        builder: (dialog) => _CashDialogControllers(
              count: 3,
              builder: (dialog, controllers) {
                final amount = controllers[0];
                final note = controllers[1];
                final reference = controllers[2];
                return StatefulBuilder(builder: (dialog, update) {
                  final cents = tryParsePeso(amount.text) ?? 0;
                  return AlertDialog(
                    title: Text(title),
                    content: SizedBox(
                        width: 500,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(opening
                              ? 'Record the initial ${fundName(destination).toLowerCase()} balance.'
                              : 'From: Company cash   →   To: Petty cash'),
                          const SizedBox(height: 16),
                          TextField(
                              controller: amount,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                  labelText: 'Amount *', prefixText: '₱ '),
                              onChanged: (_) => update(() {})),
                          const SizedBox(height: 12),
                          TextField(
                              controller: reference,
                              decoration: const InputDecoration(
                                  labelText: 'Reference #')),
                          const SizedBox(height: 12),
                          TextField(
                              controller: note,
                              decoration: InputDecoration(
                                  labelText: opening ? 'Reason *' : 'Notes')),
                          if (!opening) ...[
                            const SizedBox(height: 16),
                            Text(
                                'Company cash: ${formatPeso(fromBalance)} → ${formatPeso(fromBalance - cents)}'),
                            Text(
                                'Petty cash: ${formatPeso(toBalance)} → ${formatPeso(toBalance + cents)}'),
                          ],
                          if (error != null)
                            Text(error!,
                                style: TextStyle(
                                    color: Theme.of(dialog).colorScheme.error)),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialog),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () async {
                            final cents = tryParsePeso(amount.text);
                            if (cents == null || cents <= 0) {
                              update(() => error = 'Enter a positive amount');
                              return;
                            }
                            try {
                              if (opening) {
                                await cash.addOpeningCash(widget.user,
                                    fund: destination,
                                    amountCents: cents,
                                    note: note.text);
                              } else {
                                await cash.replenish(widget.user,
                                    amountCents: cents,
                                    destination: destination,
                                    reference: reference.text,
                                    note: note.text);
                              }
                              if (dialog.mounted) Navigator.pop(dialog);
                              refresh();
                            } catch (e) {
                              update(() => error = safeMessage(e));
                            }
                          },
                          child: Text(opening
                              ? 'Set opening balance'
                              : 'Transfer ${formatPeso(cents)}'))
                    ],
                  );
                });
              },
            ));
  }

  Future<void> detail(BusinessCashMovement row, _Data d) async {
    final reversed = d.rows.any((m) => m.reversalOfId == row.id);
    await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Close details',
        pageBuilder: (dialog, _, __) => Align(
            alignment: Alignment.centerRight,
            child: Material(
                elevation: 12,
                child: SafeArea(
                    child: SizedBox(
                        width: 430,
                        height: double.infinity,
                        child: ListView(
                            padding: const EdgeInsets.all(24),
                            children: [
                              Row(children: [
                                Expanded(
                                    child: Text(_typeName(row).toUpperCase(),
                                        style: Theme.of(dialog)
                                            .textTheme
                                            .titleLarge)),
                                IconButton(
                                    onPressed: () => Navigator.pop(dialog),
                                    icon: const Icon(Icons.close))
                              ]),
                              Text(formatPeso(row.amountCents),
                                  style: Theme.of(dialog)
                                      .textTheme
                                      .headlineMedium),
                              const Divider(height: 32),
                              _fact('Category', row.categoryName ?? '—'),
                              _fact('Payee', row.payee ?? '—'),
                              if (row.type == 'replenishment')
                                _fact('From → To',
                                    '${fundName(row.source)} → ${fundName(row.destination)}')
                              else if (row.type == 'opening')
                                _fact('Fund', fundName(row.destination))
                              else
                                _fact('Paid from', fundName(row.source)),
                              if (row.cashSessionId != null)
                                _fact('Cash session',
                                    'Shift opened ${d.session?.id == row.cashSessionId ? when(d.session!.openedAt) : 'previous shift'}'),
                              _fact('Recorded', when(row.createdAt)),
                              _fact(
                                  'Recorded by', name(row.recordedByUserId, d)),
                              _fact('Reference', row.reference ?? '—'),
                              _fact('Notes', row.note ?? '—'),
                              if (row.personallyPaidBy != null)
                                _fact('Paid personally by',
                                    row.personallyPaidBy!),
                              if (row.type == 'expense' &&
                                  row.source == 'personal')
                                _fact('Cash effect',
                                    'Reimbursement due; no business cash reduced'),
                              if (row.source != 'personal' &&
                                  row.destination != 'personal')
                                FutureBuilder<String?>(
                                  future: _cashEffect(row, d),
                                  builder: (context, snapshot) =>
                                      snapshot.hasData && snapshot.data != null
                                          ? _fact('Cash effect', snapshot.data!)
                                          : const SizedBox.shrink(),
                                ),
                              if (reversed) const Chip(label: Text('Reversed')),
                              if (!reversed &&
                                  row.type != 'reversal' &&
                                  widget.user
                                      .can(PosPermission.manageExpenseFunds) &&
                                  (row.cashSessionId == null ||
                                      d.session?.id == row.cashSessionId))
                                OutlinedButton.icon(
                                    onPressed: () async {
                                      Navigator.pop(dialog);
                                      await reverse(row);
                                    },
                                    icon: const Icon(Icons.undo),
                                    label: Text(row.type == 'expense'
                                        ? 'Reverse expense'
                                        : 'Reverse movement')),
                            ]))))));
  }

  Future<String?> _cashEffect(BusinessCashMovement row, _Data d) async {
    final fund = row.type == 'replenishment' || row.type == 'opening'
        ? row.destination
        : row.source ?? row.destination;
    if (fund == null) return null;
    if (fund == 'drawer') {
      if (row.cashSessionId == null || row.drawerMovementId == null) {
        return null;
      }
      final db = widget.repository.db;
      final session = await (db.select(db.cashSessions)
            ..where((s) => s.id.equals(row.cashSessionId!)))
          .getSingleOrNull();
      if (session == null) return null;
      final movements = await (db.select(db.cashMovements)
            ..where((m) => m.sessionId.equals(session.id)))
          .get();
      var before = session.startingCashCents;
      for (final movement in movements) {
        if (movement.id == row.drawerMovementId) {
          return '${formatPeso(before)}  →  ${formatPeso(before + movement.amountCents)}';
        }
        before += movement.amountCents;
      }
      return null;
    }
    var before = 0;
    for (final movement in d.rows.reversed) {
      final delta = (movement.destination == fund ? movement.amountCents : 0) -
          (movement.source == fund ? movement.amountCents : 0);
      if (movement.id == row.id) {
        return '${formatPeso(before)}  →  ${formatPeso(before + delta)}';
      }
      before += delta;
    }
    return null;
  }

  Widget _fact(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 135, child: Text(label)),
        Expanded(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w600)))
      ]));
  Future<void> reverse(BusinessCashMovement row) async {
    String? error;
    await showDialog<void>(
        context: context,
        builder: (dialog) => _CashDialogControllers(
              count: 1,
              builder: (dialog, controllers) {
                final reason = controllers[0];
                return StatefulBuilder(
                    builder: (dialog, update) => AlertDialog(
                          title: const Text('Reverse cash movement?'),
                          content: SizedBox(
                              width: 420,
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                        'This adds an audit entry that offsets ${formatPeso(row.amountCents)}.'),
                                    const SizedBox(height: 16),
                                    TextField(
                                        controller: reason,
                                        maxLines: 2,
                                        decoration: const InputDecoration(
                                            labelText: 'Reason *')),
                                    if (error != null)
                                      Text(error!,
                                          style: TextStyle(
                                              color: Theme.of(dialog)
                                                  .colorScheme
                                                  .error)),
                                  ])),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(dialog),
                                child: const Text('Cancel')),
                            FilledButton(
                                onPressed: () async {
                                  try {
                                    await cash.reverse(
                                        widget.user, row.id, reason.text);
                                    if (dialog.mounted) Navigator.pop(dialog);
                                    refresh();
                                  } catch (e) {
                                    update(() => error = safeMessage(e));
                                  }
                                },
                                child: const Text('Reverse movement'))
                          ],
                        ));
              },
            ));
  }

  Future<void> manageCategories(_Data d) async {
    await showDialog<void>(
        context: context,
        builder: (dialog) => StatefulBuilder(
            builder: (dialog, update) => AlertDialog(
                  title: const Text('Expense categories'),
                  content: SizedBox(
                      width: 500,
                      height: 390,
                      child: FutureBuilder<List<CashExpenseCategory>>(
                          future: cash.categories(),
                          builder: (dialog, snapshot) {
                            if (!snapshot.hasData) {
                              return const Center(
                                  child: CircularProgressIndicator());
                            }
                            return ListView(children: [
                              for (final c in snapshot.data!)
                                ListTile(
                                    title: Text(c.name),
                                    subtitle:
                                        Text(c.active ? 'Active' : 'Inactive'),
                                    trailing: PopupMenuButton<String>(
                                        onSelected: (action) async {
                                          if (action == 'toggle') {
                                            await cash.saveCategory(widget.user,
                                                id: c.id,
                                                name: c.name,
                                                active: !c.active);
                                            update(() {});
                                            refresh();
                                          } else {
                                            await categoryName(c);
                                            update(() {});
                                            refresh();
                                          }
                                        },
                                        itemBuilder: (_) => [
                                              PopupMenuItem(
                                                  value: 'rename',
                                                  child: const Text('Rename')),
                                              PopupMenuItem(
                                                  value: 'toggle',
                                                  child: Text(c.active
                                                      ? 'Deactivate'
                                                      : 'Activate'))
                                            ]))
                            ]);
                          })),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialog),
                        child: const Text('Close')),
                    FilledButton(
                        onPressed: () async {
                          await categoryName(null);
                          update(() {});
                          refresh();
                        },
                        child: const Text('New category'))
                  ],
                )));
  }

  Future<void> categoryName(CashExpenseCategory? category) async {
    String? error;
    await showDialog<void>(
        context: context,
        builder: (dialog) => _CashDialogControllers(
              count: 1,
              initialValues: [category?.name ?? ''],
              builder: (dialog, controllers) {
                final controller = controllers[0];
                return StatefulBuilder(
                    builder: (dialog, update) => AlertDialog(
                          title: Text(category == null
                              ? 'New category'
                              : 'Rename category'),
                          content: SizedBox(
                              width: 380,
                              child: TextField(
                                  controller: controller,
                                  decoration: InputDecoration(
                                      labelText: 'Name *', errorText: error))),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(dialog),
                                child: const Text('Cancel')),
                            FilledButton(
                                onPressed: () async {
                                  try {
                                    await cash.saveCategory(widget.user,
                                        id: category?.id,
                                        name: controller.text,
                                        active: category?.active ?? true);
                                    if (dialog.mounted) Navigator.pop(dialog);
                                  } catch (e) {
                                    update(() => error = safeMessage(e));
                                  }
                                },
                                child: const Text('Save'))
                          ],
                        ));
              },
            ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      body: FutureBuilder<_Data>(
          future: data,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text(safeMessage(snapshot.error!)));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final d = snapshot.data!;
            final now = DateTime.now();
            final expenses = d.rows.where((m) => m.type == 'expense').toList();
            final month = expenses
                .where((m) =>
                    m.createdAt.toLocal().year == now.year &&
                    m.createdAt.toLocal().month == now.month)
                .toList();
            final today = expenses
                .where((m) => DateUtils.isSameDay(m.createdAt.toLocal(), now))
                .toList();
            return ListView(padding: const EdgeInsets.all(20), children: [
              AppPageHeader(
                title: 'Expenses',
                subtitle: 'Track business spending and cash-funded expenses.',
                action: FilledButton.icon(
                  onPressed: () => expense(d),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Record expense'),
                ),
              ),
              Row(children: [
                PopupMenuButton<String>(
                    tooltip: 'More',
                    onSelected: (value) {
                      if (value == 'categories') manageCategories(d);
                      if (value == 'funds') _fundSettings(d);
                    },
                    itemBuilder: (_) => [
                          if (widget.user.can(PosPermission.manageExpenseFunds))
                            const PopupMenuItem(
                                value: 'categories',
                                child: Text('Expense categories')),
                          const PopupMenuItem(
                              value: 'funds', child: Text('Fund settings')),
                        ],
                    child: const Padding(
                        padding: EdgeInsets.all(12), child: Text('More ▾'))),
              ]),
              const SizedBox(height: 14),
              AppWorkspaceTabs(
                labels: const [
                  'Overview',
                  'Expense Records',
                  'Petty Cash',
                  'Cash Activity'
                ],
                selectedIndex: tab,
                onSelected: (index) => setState(() => tab = index),
              ),
              const Divider(),
              if (tab == 0) ...[
                _section('THIS MONTH'),
                Wrap(spacing: 12, runSpacing: 10, children: [
                  _metric('Expenses',
                      month.fold<int>(0, (s, m) => s + m.amountCents)),
                  _metric(
                      'Today', today.fold<int>(0, (s, m) => s + m.amountCents)),
                  _metric(
                      'Petty cash spent',
                      month
                          .where((m) => m.source == 'petty')
                          .fold<int>(0, (s, m) => s + m.amountCents)),
                  _metric(
                      'Drawer expenses',
                      month
                          .where((m) => m.source == 'drawer')
                          .fold<int>(0, (s, m) => s + m.amountCents)),
                ]),
                const SizedBox(height: 20),
                _section('CURRENT SHIFT'),
                Text(d.drawer == null
                    ? 'Cash drawer · No open shift'
                    : 'Cash drawer · ${formatPeso(d.drawer!)} expected · Controlled by Cash Session'),
                const SizedBox(height: 16),
                _section('BUSINESS FUNDS'),
                Text('Petty cash · ${formatPeso(d.petty)} available'),
                Text('Company cash · ${formatPeso(d.company)} available'),
                const SizedBox(height: 16),
                _section('OBLIGATIONS'),
                Text('Reimbursements due · ${formatPeso(d.due)}'),
                const SizedBox(height: 24),
                _section('RECENT EXPENSES'),
                if (expenses.isEmpty && d.legacy.isEmpty)
                  const Text('No expenses recorded yet.'),
                ...expenses.take(6).map((m) => _movementTile(m, d)),
                ...d.legacy.take(3).map((m) => _legacyTile(m, d)),
                const SizedBox(height: 20),
                _section('SPENDING BY CATEGORY'),
                ..._categoryTotals(month).entries.take(5).map((e) => ListTile(
                    dense: true,
                    title: Text(e.key),
                    trailing: Text(formatPeso(e.value)))),
              ] else if (tab == 2) ...[
                _section('PETTY CASH'),
                Text(formatPeso(d.petty),
                    style: Theme.of(context).textTheme.headlineMedium),
                const Text('Available balance'),
                const SizedBox(height: 12),
                Wrap(spacing: 8, children: [
                  FilledButton.icon(
                      onPressed: () => expense(d, preferredSource: 'petty'),
                      icon: const Icon(Icons.add),
                      label: const Text('Record petty cash expense')),
                  if (widget.user.can(PosPermission.manageExpenseFunds))
                    OutlinedButton.icon(
                        onPressed: () => addCash(
                            title: 'Add cash to petty cash',
                            destination: 'petty',
                            opening: false),
                        icon: const Icon(Icons.add),
                        label: const Text('Add cash')),
                ]),
                const SizedBox(height: 16),
                Text(
                    'This month spent · ${formatPeso(month.where((m) => m.source == 'petty').fold<int>(0, (s, m) => s + m.amountCents))}'),
                Text('Last cash added · ${_lastCashAdded(d)}'),
                const SizedBox(height: 20),
                _section('PETTY CASH ACTIVITY'),
                ...d.rows
                    .where(
                        (m) => m.source == 'petty' || m.destination == 'petty')
                    .map((m) => _movementTile(m, d)),
                if (!d.rows.any(
                    (m) => m.source == 'petty' || m.destination == 'petty'))
                  const Text('No petty cash activity yet.'),
              ] else ...[
                _section(tab == 1 ? 'EXPENSE RECORDS' : 'CASH ACTIVITY'),
                _filters(d),
                const SizedBox(height: 12),
                ..._visibleRows(d, expensesOnly: tab == 1)
                    .map((m) => _movementTile(m, d)),
                if (tab == 1 || tab == 3)
                  ...d.legacy
                      .where((m) => _legacyVisible(
                          m, d, search.text.trim().toLowerCase()))
                      .map((m) => _legacyTile(m, d)),
                if (_visibleRows(d, expensesOnly: tab == 1).isEmpty &&
                    (tab != 1 || d.legacy.isEmpty))
                  const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No matching records.')),
              ],
            ]);
          }));

  Widget _section(String label) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(label, style: Theme.of(context).textTheme.labelLarge));
  Widget _metric(String label, int amount) => AppMetricTile(
        label: label,
        value: formatPeso(amount),
        width: 180,
      );
  Map<String, int> _categoryTotals(List<BusinessCashMovement> rows) {
    final totals = <String, int>{};
    for (final row in rows) {
      final key = row.categoryName ?? 'Uncategorized';
      totals[key] = (totals[key] ?? 0) + row.amountCents;
    }
    return Map.fromEntries(
        totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
  }

  String _lastCashAdded(_Data d) {
    final items = d.rows
        .where((m) => m.destination == 'petty' && m.type == 'replenishment');
    return items.isEmpty
        ? 'None yet'
        : '${when(items.first.createdAt)} · ${formatPeso(items.first.amountCents)}';
  }

  String _typeName(BusinessCashMovement m) => switch (m.type) {
        'expense' => 'Expense',
        'replenishment' => 'Transfer',
        'opening' => 'Opening balance',
        'reversal' => 'Reversal',
        _ => 'Cash movement',
      };
  Widget _movementTile(BusinessCashMovement m, _Data d) => Card(
          child: ListTile(
        onTap: () => detail(m, d),
        title: Text(m.type == 'expense'
            ? [m.categoryName, m.payee]
                .where((s) => s != null && s.isNotEmpty)
                .join(' · ')
            : _typeName(m)),
        subtitle: Text(
            '${when(m.createdAt)} · ${m.type == 'replenishment' ? '${fundName(m.source)} → ${fundName(m.destination)}' : m.type == 'opening' ? fundName(m.destination) : fundName(m.source)} · ${name(m.recordedByUserId, d)}'),
        trailing: Text(
            '${m.type == 'expense' ? '−' : m.type == 'reversal' ? '↩ ' : '+'}${formatPeso(m.amountCents)}'),
      ));
  Widget _legacyTile(PettyCashEntry m, _Data d) => Card(
      child: ListTile(
          title: Text(m.category),
          subtitle: Text(
              '${when(m.createdAt)} · Historical drawer · Legacy · ${name(m.userId, d)}'),
          trailing: Text('−${formatPeso(m.amountCents)}')));
  List<BusinessCashMovement> _visibleRows(_Data d,
      {required bool expensesOnly}) {
    final query = search.text.trim().toLowerCase();
    return d.rows.where((m) {
      if (expensesOnly && m.type != 'expense') return false;
      if (query.isNotEmpty &&
          ![m.categoryName, m.payee, m.note, m.reference]
              .join(' ')
              .toLowerCase()
              .contains(query)) {
        return false;
      }
      if (fund != 'all' && m.source != fund && m.destination != fund) {
        return false;
      }
      if (!expensesOnly && type != 'all' && m.type != type) return false;
      if (categoryId != null && m.categoryId != categoryId) return false;
      if (userId != null && m.recordedByUserId != userId) return false;
      if (dates != null &&
          (m.createdAt.isBefore(dates!.start) ||
              !m.createdAt.isBefore(dates!.end.add(const Duration(days: 1))))) {
        return false;
      }
      return true;
    }).toList();
  }

  Widget _filters(_Data d) => Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
                width: 230,
                child: TextField(
                    controller: search,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        labelText: 'Search payee, reference, notes, category',
                        prefixIcon: Icon(Icons.search),
                        isDense: true))),
            _filter(
                'Paid from',
                fund,
                ['all', 'drawer', 'petty', 'company', 'personal'],
                (v) => setState(() => fund = v)),
            if (tab == 3)
              _filter(
                  'Type',
                  type,
                  ['all', 'expense', 'replenishment', 'opening', 'reversal'],
                  (v) => setState(() => type = v)),
            DropdownButton<String?>(
                value: categoryId,
                hint: const Text('Category: All'),
                items: [
                  const DropdownMenuItem(
                      value: null, child: Text('Category: All')),
                  ...d.categories.map((c) => DropdownMenuItem(
                      value: c.id, child: Text('Category: ${c.name}')))
                ],
                onChanged: (v) => setState(() => categoryId = v)),
            DropdownButton<String?>(
                value: userId,
                hint: const Text('User: All'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('User: All')),
                  ...d.users.entries.map((u) => DropdownMenuItem(
                      value: u.key, child: Text('User: ${u.value}')))
                ],
                onChanged: (v) => setState(() => userId = v)),
            TextButton.icon(
                onPressed: () async {
                  final picked = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 1)),
                      initialDateRange: dates);
                  if (picked != null) setState(() => dates = picked);
                },
                icon: const Icon(Icons.date_range),
                label: Text(dates == null
                    ? 'Date: All'
                    : 'Date: ${dates!.start.month}/${dates!.start.day}–${dates!.end.month}/${dates!.end.day}')),
            if (dates != null)
              IconButton(
                  onPressed: () => setState(() => dates = null),
                  icon: const Icon(Icons.close),
                  tooltip: 'Clear dates'),
          ]);
  Future<void> _fundSettings(_Data d) => showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
            title: const Text('Fund settings'),
            content: SizedBox(
                width: 480,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final fund in ['petty', 'company']) ...[
                    const Divider(),
                    ListTile(
                        title: Text(fundName(fund)),
                        subtitle: Text(() {
                          final openings = d.rows.where((m) =>
                              m.type == 'opening' && m.destination == fund);
                          return openings.isEmpty
                              ? d.rows.any((m) =>
                                      m.source == fund || m.destination == fund)
                                  ? 'Existing fund activity · Opening unavailable'
                                  : 'Not initialized'
                              : 'Opening balance ${formatPeso(openings.first.amountCents)} · ${when(openings.first.createdAt)} · ${name(openings.first.recordedByUserId, d)}';
                        }()),
                        trailing: Text(
                            formatPeso(fund == 'petty' ? d.petty : d.company))),
                    if (widget.user.role == UserRole.owner &&
                        !d.rows.any(
                            (m) => m.source == fund || m.destination == fund))
                      TextButton(
                          onPressed: () {
                            Navigator.pop(dialog);
                            addCash(
                                title: 'Set opening balance',
                                destination: fund,
                                opening: true);
                          },
                          child: const Text('Set opening balance')),
                  ],
                ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: const Text('Close'))
            ],
          ));

  bool _legacyVisible(PettyCashEntry row, _Data data, String query) {
    if (fund != 'all' && fund != 'drawer') return false;
    if (type != 'all' && type != 'expense') return false;
    if (categoryId != null &&
        !data.categories.any((category) =>
            category.id == categoryId && category.name == row.category)) {
      return false;
    }
    if (userId != null && userId != row.userId) return false;
    if (query.isNotEmpty &&
        !'${row.category} ${row.note ?? ''}'.toLowerCase().contains(query)) {
      return false;
    }
    if (dates != null &&
        (row.createdAt.isBefore(dates!.start) ||
            !row.createdAt.isBefore(dates!.end.add(const Duration(days: 1))))) {
      return false;
    }
    return true;
  }

  Widget _filter(String label, String current, List<String> options,
          ValueChanged<String> changed) =>
      DropdownButton<String>(
          value: current,
          items: options
              .map((v) => DropdownMenuItem(
                  value: v,
                  child: Text(
                      '$label: ${v == 'all' ? 'All' : v == 'drawer' ? 'Current cash drawer' : v == 'petty' ? 'Petty cash' : v == 'company' ? 'Company cash' : v == 'personal' ? 'Paid personally' : v == 'replenishment' ? 'Transfer' : v == 'opening' ? 'Opening balance' : v[0].toUpperCase() + v.substring(1)}')))
              .toList(),
          onChanged: (v) {
            if (v != null) changed(v);
          });
}

class _Data {
  final List<BusinessCashMovement> rows;
  final List<PettyCashEntry> legacy;
  final List<CashExpenseCategory> categories;
  final Map<String, String> users;
  final CashSession? session;
  final int? drawer;
  final int petty, company, due;
  _Data(this.rows, this.legacy, this.categories, this.users, this.session,
      this.drawer, this.petty, this.company, this.due);
}

/// Keeps field controllers alive until Flutter unmounts the dialog subtree.
class _CashDialogControllers extends StatefulWidget {
  final int count;
  final List<String>? initialValues;
  final Widget Function(BuildContext, List<TextEditingController>) builder;
  const _CashDialogControllers(
      {required this.count, required this.builder, this.initialValues});

  @override
  State<_CashDialogControllers> createState() => _CashDialogControllersState();
}

class _CashDialogControllersState extends State<_CashDialogControllers> {
  late final List<TextEditingController> controllers = List.generate(
      widget.count,
      (index) => TextEditingController(
          text: widget.initialValues == null
              ? null
              : widget.initialValues![index]));

  @override
  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, controllers);
}
