import 'package:flutter/material.dart';
import '../../data/daos/cash_session_repository.dart';

import '../../core/models/active_user.dart';
import '../../data/daos/petty_cash_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';

class PettyCashScreen extends StatefulWidget {
  final PettyCashRepository repository;
  final ActiveUser user;
  const PettyCashScreen(
      {super.key, required this.repository, required this.user});
  @override
  State<PettyCashScreen> createState() => _PettyCashScreenState();
}

class _PettyCashScreenState extends State<PettyCashScreen> {
  Future<void> add() async {
    final amount = TextEditingController();
    final note = TextEditingController();
    final sessions = CashSessionRepository(widget.repository.db);
    final active = await sessions.active();
    final expected = active == null ? null : await sessions.expected(active.id);
    if (!mounted) {
      amount.dispose();
      note.dispose();
      return;
    }
    String category = 'Transport';
    String? error;
    try {
      await showDialog<void>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: const Text('Record cash expense'),
                    content: SizedBox(
                        width: 350,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(active == null
                              ? 'Shift closed · Open a shift first'
                              : 'Current expected drawer: ${formatPeso(expected!)}'),
                          TextField(
                              controller: amount,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: InputDecoration(
                                  labelText: 'Amount (pesos)',
                                  errorText: error),
                              onChanged: (_) => update(() {})),
                          if (expected != null &&
                              tryParsePeso(amount.text) != null)
                            Text(
                                'After expense: ${formatPeso(expected - tryParsePeso(amount.text)!)}'),
                          DropdownButtonFormField<String>(
                              initialValue: category,
                              decoration:
                                  const InputDecoration(labelText: 'Category'),
                              items: [
                                'Transport',
                                'Office supplies',
                                'Food',
                                'Repair',
                                'Miscellaneous'
                              ]
                                  .map((value) => DropdownMenuItem(
                                      value: value, child: Text(value)))
                                  .toList(),
                              onChanged: (value) =>
                                  update(() => category = value ?? category)),
                          TextField(
                              controller: note,
                              decoration: const InputDecoration(
                                  labelText: 'Note (optional)')),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () async {
                            final cents = tryParsePeso(amount.text);
                            if (cents == null || cents <= 0) {
                              update(
                                  () => error = 'Enter a positive peso amount');
                              return;
                            }
                            try {
                              await widget.repository.record(widget.user,
                                  amountCents: cents,
                                  category: category,
                                  note: note.text);
                              if (context.mounted) Navigator.pop(context);
                              if (mounted) setState(() {});
                            } catch (failure) {
                              update(() => error = safeMessage(failure));
                            }
                          },
                          child: const Text('Record expense')),
                    ],
                  )));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      amount.dispose();
      note.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Petty cash')),
        body: FutureBuilder(
            future: widget.repository.history(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text(safeMessage(snapshot.error!)));
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final entries = snapshot.data!;
              if (entries.isEmpty) {
                return const Center(
                    child: Card(
                        child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                                'No cash expenses yet. Record a drawer expense during an open shift.'))));
              }
              return ListView(children: [
                for (final entry in entries)
                  ListTile(
                      title: Text(
                          '${entry.category} · ${formatPeso(entry.amountCents)}'),
                      subtitle: Text(
                          '${MaterialLocalizations.of(context).formatMediumDate(entry.createdAt)} · ${entry.note ?? ''}'))
              ]);
            }),
        floatingActionButton: FloatingActionButton.extended(
            heroTag: 'petty-cash-add',
            onPressed: add,
            icon: const Icon(Icons.remove),
            label: const Text('Cash expense')),
      );
}
