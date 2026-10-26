import 'package:flutter/material.dart';
import '../../core/models/active_user.dart';
import '../../data/daos/auth_repository.dart';
import '../../data/daos/cash_shift_handover_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';

class ShiftHandoverPanel extends StatefulWidget {
  final AppDatabase db;
  final ActiveUser user;
  final String? sessionId;
  const ShiftHandoverPanel(
      {super.key,
      required this.db,
      required this.user,
      required this.sessionId});
  @override
  State<ShiftHandoverPanel> createState() => _ShiftHandoverPanelState();
}

class _ShiftHandoverPanelState extends State<ShiftHandoverPanel> {
  late final CashShiftHandoverRepository repo =
      CashShiftHandoverRepository(widget.db);
  CashShiftHandover? current;
  CashShiftHandover? completed;
  bool conflictingHandover = false;
  List<CashShiftHandover> history = [];
  List<ActiveUser> users = [];
  final count = <int, int>{};
  final notes = TextEditingController();
  final credential = TextEditingController();
  String? incomingId, managerId, error;
  String statusFilter = 'all';
  bool varianceOnly = false, busy = false;
  int page = 0, step = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ShiftHandoverPanel old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId) _load();
  }

  @override
  void dispose() {
    notes.dispose();
    credential.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final people = await AuthRepository(widget.db).loginUsers();
      final conflict = widget.sessionId == null
          ? false
          : await repo.hasActive(widget.sessionId!);
      final active = widget.sessionId == null
          ? null
          : await repo.active(widget.user, widget.sessionId!);
      final rows = widget.user.can(PosPermission.acknowledgeShiftHandover)
          ? await repo.history(widget.user,
              offset: page * 50,
              status: statusFilter == 'all' ? null : statusFilter,
              varianceOnly: varianceOnly)
          : <CashShiftHandover>[];
      if (!mounted) return;
      setState(() {
        users = people;
        conflictingHandover = conflict;
        current = active != null &&
                (active.outgoingId == widget.user.id ||
                    active.incomingId == widget.user.id ||
                    widget.user.can(PosPermission.acknowledgeShiftHandover))
            ? active
            : null;
        history = rows;
        incomingId = current?.incomingId.isEmpty == false
            ? current!.incomingId
            : incomingId;
        if (current == null) {
          step = 0;
          count.clear();
          notes.clear();
        } else if (current!.status == 'awaiting_acknowledgment') {
          step = 3;
        }
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _name(String id) =>
      users.where((u) => u.id == id).map((u) => u.name).firstOrNull ??
      'Former team member';
  String _variance(int cents) => cents == 0
      ? 'Balanced'
      : cents < 0
          ? 'Short by ${formatPeso(-cents)}'
          : 'Over by ${formatPeso(cents)}';
  String _date(int millis) => MaterialLocalizations.of(context)
      .formatMediumDate(DateTime.fromMillisecondsSinceEpoch(millis));
  int get _actual => count.entries.fold(0, (sum, e) => sum + e.key * e.value);

  @override
  Widget build(BuildContext context) {
    final row = current;
    final canStart = widget.sessionId != null &&
        row == null &&
        !conflictingHandover &&
        widget.user.can(PosPermission.manageCashSession);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 24),
      Text('SHIFT HANDOVER', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 10),
      if (error != null)
        Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (canStart)
        FilledButton.icon(
            onPressed: busy
                ? null
                : () => _run(() async {
                      current =
                          await repo.start(widget.user, widget.sessionId!);
                      completed = null;
                      step = 0;
                    }),
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Start Shift Handover')),
      if (row != null)
        Card(
            child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          '${row.reference} • ${row.status.replaceAll('_', ' ')}',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      if (row.status == 'draft')
                        _draft(row)
                      else
                        _acknowledge(row),
                      const SizedBox(height: 12),
                      TextButton.icon(
                          onPressed: busy
                              ? null
                              : () =>
                                  _run(() => repo.cancel(widget.user, row.id)),
                          icon: const Icon(Icons.cancel_outlined),
                          label: const Text('Cancel handover')),
                    ]))),
      if (row == null && completed != null)
        Card(
            child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Handover Complete • ${completed!.reference}',
                          style: Theme.of(context).textTheme.titleMedium),
                      Text(
                          '${_name(completed!.outgoingId)} → ${_name(completed!.incomingId)}'),
                      Text(
                          'Expected ${formatPeso(completed!.expected)} • Counted ${formatPeso(completed!.actual)}'),
                      Text(_variance(completed!.variance)),
                      Text('Acknowledged by ${_name(completed!.managerId!)}'),
                    ]))),
      if (widget.user.can(PosPermission.acknowledgeShiftHandover)) ...[
        const SizedBox(height: 24),
        Text('HANDOVER HISTORY', style: Theme.of(context).textTheme.labelLarge),
        Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                  value: statusFilter,
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All statuses')),
                    DropdownMenuItem(
                        value: 'completed', child: Text('Completed')),
                    DropdownMenuItem(
                        value: 'cancelled', child: Text('Cancelled')),
                  ],
                  onChanged: (v) {
                    setState(() {
                      statusFilter = v!;
                      page = 0;
                    });
                    _load();
                  }),
              FilterChip(
                  label: const Text('Variance only'),
                  selected: varianceOnly,
                  onSelected: (v) {
                    setState(() {
                      varianceOnly = v;
                      page = 0;
                    });
                    _load();
                  }),
            ]),
        Card(
            child: Column(children: [
          if (history.isEmpty) const ListTile(title: Text('No handovers yet')),
          for (final item in history)
            ListTile(
              title: Text('${item.reference} • ${_date(item.createdAt)}'),
              subtitle: Text(
                  '${_name(item.outgoingId)} → ${_name(item.incomingId)}\n'
                  'Expected ${formatPeso(item.expected)} • Actual ${formatPeso(item.actual)} • ${_variance(item.variance)}'),
              isThreeLine: true,
              trailing: Text(item.status.replaceAll('_', ' ')),
              onTap: () => _detail(item),
            ),
        ])),
        Row(children: [
          TextButton(
              onPressed: page == 0
                  ? null
                  : () {
                      setState(() => page--);
                      _load();
                    },
              child: const Text('Previous')),
          Text('Page ${page + 1}'),
          TextButton(
              onPressed: history.length < 50
                  ? null
                  : () {
                      setState(() => page++);
                      _load();
                    },
              child: const Text('Next')),
        ]),
      ],
    ]);
  }

  Widget _draft(CashShiftHandover row) {
    final eligible = users
        .where((u) =>
            u.id != row.outgoingId &&
            u.can(PosPermission.sell) &&
            u.can(PosPermission.manageCashSession))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Step ${step + 1} of 3'),
      if (step == 0) ...[
        Text('Outgoing: ${_name(row.outgoingId)}'),
        DropdownButtonFormField<String>(
            initialValue:
                eligible.any((u) => u.id == incomingId) ? incomingId : null,
            decoration: const InputDecoration(labelText: 'Incoming cashier'),
            items: [
              for (final u in eligible)
                DropdownMenuItem(value: u.id, child: Text(u.name))
            ],
            onChanged: (value) => setState(() => incomingId = value)),
        const SizedBox(height: 12),
        FilledButton(
            onPressed:
                incomingId == null ? null : () => setState(() => step = 1),
            child: const Text('Count cash')),
      ] else if (step == 1) ...[
        Text('Expected cash at count start: ${formatPeso(row.expected)}'),
        const SizedBox(height: 8),
        for (final denomination in handoverDenominations)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(width: 85, child: Text(formatPeso(denomination))),
                SizedBox(
                    width: 110,
                    child: TextFormField(
                        key: ValueKey('${row.id}-$denomination'),
                        initialValue: '${count[denomination] ?? 0}',
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'Quantity', isDense: true),
                        onChanged: (value) => setState(() =>
                            count[denomination] = int.tryParse(value) ?? 0))),
                const SizedBox(width: 12),
                Text(formatPeso(denomination * (count[denomination] ?? 0))),
              ])),
        Text('Counted total: ${formatPeso(_actual)}',
            style: Theme.of(context).textTheme.titleMedium),
        Row(children: [
          TextButton(
              onPressed: () => setState(() => step = 0),
              child: const Text('Back')),
          FilledButton(
              onPressed: () => setState(() => step = 2),
              child: const Text('Review')),
        ]),
      ] else ...[
        Text('${_name(row.outgoingId)} → ${_name(incomingId ?? '')}'),
        Text('Expected: ${formatPeso(row.expected)}'),
        Text('Counted: ${formatPeso(_actual)}'),
        Text(_variance(_actual - row.expected)),
        TextField(
            controller: notes,
            maxLines: 2,
            decoration: InputDecoration(
                labelText: _actual == row.expected
                    ? 'Handover notes (optional)'
                    : 'Variance reason and notes (required)')),
        Row(children: [
          TextButton(
              onPressed: () => setState(() => step = 1),
              child: const Text('Back to count')),
          FilledButton(
              onPressed: busy || incomingId == null
                  ? null
                  : () => _run(() async {
                        await repo.submit(widget.user, row.id, incomingId!,
                            count, notes.text);
                      }),
              child: const Text('Submit for acknowledgment')),
        ]),
      ],
    ]);
  }

  Widget _acknowledge(CashShiftHandover row) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${_name(row.outgoingId)} → ${_name(row.incomingId)}'),
      Text(
          'Expected ${formatPeso(row.expected)} • Counted ${formatPeso(row.actual)}'),
      Text(_variance(row.variance)),
      if (row.notes.isNotEmpty) Text('Notes: ${row.notes}'),
      const SizedBox(height: 10),
      Row(children: [
        TextButton(
            onPressed: busy
                ? null
                : () => _run(() async {
                      await repo.recount(widget.user, row.id);
                      step = 1;
                    }),
            child: const Text('Recount')),
        FilledButton(
            onPressed: busy ? null : () => _showAcknowledgment(row),
            child: const Text('Manager acknowledgment')),
      ]),
    ]);
  }

  Future<void> _showAcknowledgment(CashShiftHandover row) async {
    final managers = users
        .where((u) => u.can(PosPermission.acknowledgeShiftHandover))
        .toList();
    managerId = managers.any((u) => u.id == widget.user.id)
        ? widget.user.id
        : managers.firstOrNull?.id;
    credential.clear();
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: Text('Acknowledge ${row.reference}'),
                    content: SizedBox(
                        width: 390,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text('Outgoing: ${_name(row.outgoingId)}'),
                              Text('Incoming: ${_name(row.incomingId)}'),
                              Text('Expected: ${formatPeso(row.expected)}'),
                              Text('Counted: ${formatPeso(row.actual)}'),
                              Text(_variance(row.variance)),
                              if (row.notes.isNotEmpty)
                                Text('Notes: ${row.notes}'),
                              DropdownButtonFormField<String>(
                                  initialValue: managerId,
                                  decoration: const InputDecoration(
                                      labelText: 'Manager'),
                                  items: [
                                    for (final u in managers)
                                      DropdownMenuItem(
                                          value: u.id, child: Text(u.name))
                                  ],
                                  onChanged: (v) =>
                                      update(() => managerId = v)),
                              if (managerId != widget.user.id)
                                TextField(
                                    controller: credential,
                                    obscureText: true,
                                    decoration: const InputDecoration(
                                        labelText: 'Manager password')),
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: managerId == null
                              ? null
                              : () => Navigator.pop(dialogContext, true),
                          child: const Text('Acknowledge and complete')),
                    ])));
    if (confirmed != true || !mounted) return;
    await _run(() async {
      completed = await repo.complete(widget.user, row.id, managerId!,
          credential: managerId == widget.user.id ? null : credential.text);
      credential.clear();
    });
  }

  void _detail(CashShiftHandover row) {
    showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Close handover details',
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (context, _, __) => Align(
            alignment: Alignment.centerRight,
            child: Material(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: SizedBox(
                    width: 420,
                    height: double.infinity,
                    child: SafeArea(
                        child: SingleChildScrollView(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    Expanded(
                                        child: Text(row.reference,
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineSmall)),
                                    IconButton(
                                        onPressed: () => Navigator.pop(context),
                                        icon: const Icon(Icons.close))
                                  ]),
                                  const Text(
                                      'Linked to the existing Cash Session'),
                                  const Divider(),
                                  Text('Outgoing: ${_name(row.outgoingId)}'),
                                  Text('Incoming: ${_name(row.incomingId)}'),
                                  Text('Expected: ${formatPeso(row.expected)}'),
                                  Text('Counted: ${formatPeso(row.actual)}'),
                                  Text(_variance(row.variance)),
                                  Text(
                                      'Status: ${row.status.replaceAll('_', ' ')}'),
                                  Text(
                                      'Notes: ${row.notes.isEmpty ? 'None' : row.notes}'),
                                  Text(
                                      'Manager: ${row.managerId == null ? 'Pending' : _name(row.managerId!)}'),
                                  Text('Created: ${_date(row.createdAt)}'),
                                  if (row.acknowledgedAt != null)
                                    Text(
                                        'Acknowledged: ${_date(row.acknowledgedAt!)}'),
                                  const Divider(),
                                  Text('Denomination breakdown',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  FutureBuilder<Map<int, int>>(
                                      future: repo.denominations(
                                          row.id, widget.user),
                                      builder: (context, snapshot) => snapshot
                                              .hasData
                                          ? Column(children: [
                                              for (final e
                                                  in snapshot.data!.entries)
                                                ListTile(
                                                    title:
                                                        Text(formatPeso(e.key)),
                                                    subtitle: Text(
                                                        'Quantity ${e.value}'),
                                                    trailing: Text(formatPeso(
                                                        e.key * e.value)))
                                            ])
                                          : const LinearProgressIndicator()),
                                ])))))));
  }
}
