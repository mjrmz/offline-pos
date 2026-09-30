import 'package:flutter/material.dart';
import '../../core/models/active_user.dart';
import '../../data/daos/cash_session_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/safe_message.dart';

class CashSessionScreen extends StatefulWidget {
  final ActiveUser user;
  final CashSessionRepository repository;
  const CashSessionScreen(
      {super.key, required this.user, required this.repository});
  @override
  State<CashSessionScreen> createState() => _CashSessionScreenState();
}

class _CashSessionScreenState extends State<CashSessionScreen> {
  final amount = TextEditingController();
  List<CashSessionSummary> sessions = [];
  List<ZReading> zReadings = [];
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final rows = await widget.repository.history();
      final zRows = await widget.repository.zHistory();
      if (mounted) {
        setState(() {
          sessions = rows;
          zReadings = zRows;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  Future<void> execute(bool close) async {
    final cents = int.tryParse(amount.text.trim());
    if (cents == null || cents < 0) {
      setState(() => error = 'Enter a nonnegative amount in cents');
      return;
    }
    setState(() => busy = true);
    try {
      if (close) {
        final result = await widget.repository.close(widget.user, cents);
        amount.clear();
        await refresh();
        if (result.protectionWarning && mounted) {
          setState(() => error =
              'Session closed, but Z-reading finalization is pending. Stop BIR checkout and restart for recovery.');
        }
      } else {
        await widget.repository.open(widget.user, cents);
        amount.clear();
        await refresh();
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active =
        sessions.where((s) => s.session.closedAt == null).firstOrNull;
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Cash session', style: TextStyle(fontSize: 22)),
      if (error != null)
        Text(error!, style: const TextStyle(color: Colors.red)),
      if (active != null) ...[
        Text(
            'Opened by user ${active.session.openedByUserId} at ${active.session.openedAt}'),
        Text('Starting cash: ${active.session.startingCashCents} cents'),
        Text('Expected cash: ${active.expectedCents} cents'),
      ],
      TextField(
          controller: amount,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: active == null
                  ? 'Starting cash (cents)'
                  : 'Actual cash (cents)')),
      FilledButton(
          onPressed: busy ? null : () => execute(active != null),
          child: Text(active == null ? 'Open session' : 'Close session')),
      if (active != null)
        Text('Variance on close = actual - ${active.expectedCents} cents'),
      const Divider(),
      const Text('History'),
      for (final row in sessions.where((s) => s.session.closedAt != null))
        ListTile(
            title: Text('${row.session.openedAt}'),
            subtitle: Text(
                'Expected ${row.expectedCents}, actual ${row.session.actualCashCents}, variance ${row.varianceCents} cents')),
      if (zReadings.isNotEmpty) ...[
        const Divider(),
        const Text('Z-reading history'),
        for (final z in zReadings)
          ListTile(
              title: Text('Z ${z.number} · ${z.generatedAt}'),
              subtitle: Text(
                  'Invoices ${z.beginningInvoiceNumber ?? "none"}–${z.endingInvoiceNumber ?? "none"}; sales ${z.periodSalesCents} cents; reversals ${z.reversalCents} cents; grand total ${z.grandTotalCents} cents')),
      ],
    ]);
  }
}
