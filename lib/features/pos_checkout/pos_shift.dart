import 'package:flutter/material.dart';
import '../../core/models/active_user.dart';
import '../../data/daos/cash_session_repository.dart';
import '../../shared/utils/money.dart';

class PosShiftClosed extends StatefulWidget {
  final ActiveUser user;
  final CashSessionRepository repository;
  final String? otherUser;
  final VoidCallback onOpened;
  final VoidCallback onSessions;
  const PosShiftClosed(
      {super.key,
      required this.user,
      required this.repository,
      required this.onOpened,
      required this.onSessions,
      this.otherUser});
  @override
  State<PosShiftClosed> createState() => _PosShiftClosedState();
}

class _PosShiftClosedState extends State<PosShiftClosed> {
  final amount = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  Future<void> open() async {
    final cents = tryParsePeso(amount.text);
    if (cents == null || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.repository.open(widget.user, cents);
      widget.onOpened();
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
      widget.onOpened(); // Refresh if another window opened the session first.
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocked = widget.otherUser != null;
    return Center(
        child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Card(
                    child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.lock_clock_outlined,
                                  color: theme.colorScheme.primary, size: 32),
                              const SizedBox(height: 16),
                              Text('SHIFT CLOSED',
                                  style: theme.textTheme.labelLarge),
                              const SizedBox(height: 8),
                              Text(
                                  blocked
                                      ? 'Another cashier has an open shift'
                                      : 'Open your cashier shift',
                                  style: theme.textTheme.headlineSmall),
                              const SizedBox(height: 10),
                              Text(blocked
                                  ? '${widget.otherUser} owns the current shift. Ask them to close it before you sell.'
                                  : 'Enter the physical cash placed in your drawer before selling. No shift opens automatically.'),
                              if (!blocked) ...[
                                const SizedBox(height: 24),
                                TextField(
                                    key: const Key('pos-opening-cash'),
                                    controller: amount,
                                    onChanged: (_) => setState(() {}),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    decoration: const InputDecoration(
                                        labelText: 'Opening cash',
                                        prefixText: '₱ ',
                                        border: OutlineInputBorder())),
                                if (amount.text.isNotEmpty &&
                                    tryParsePeso(amount.text) == null)
                                  const Padding(
                                      padding: EdgeInsets.only(top: 8),
                                      child: Text(
                                          'Enter valid cash with up to two decimal places.')),
                                const SizedBox(height: 16),
                                FilledButton(
                                    key: const Key('pos-open-shift'),
                                    onPressed: busy ||
                                            tryParsePeso(amount.text) == null
                                        ? null
                                        : open,
                                    child: const Text('Open shift')),
                              ],
                              if (error != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(error!,
                                        style: TextStyle(
                                            color: theme.colorScheme.error))),
                              TextButton(
                                  onPressed: widget.onSessions,
                                  child: const Text('View cash sessions')),
                            ]))))));
  }
}

Future<bool> showPosCloseShift(
    BuildContext context,
    CashSessionRepository repository,
    ActiveUser user,
    CashSessionSummary shift) async {
  final amount = TextEditingController();
  bool busy = false;
  bool confirm = false;
  String? error;
  final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) =>
          StatefulBuilder(builder: (context, setDialogState) {
            final counted = tryParsePeso(amount.text);
            final variance =
                counted == null ? null : counted - shift.expectedCents;
            final status = variance == null
                ? null
                : variance == 0
                    ? 'Balanced'
                    : variance < 0
                        ? 'Short'
                        : 'Over';
            Widget metric(String label, String value) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child:
                    Row(children: [Expanded(child: Text(label)), Text(value)]));
            return AlertDialog(
                title: Text(confirm ? 'Close this shift?' : 'Close shift'),
                content: SizedBox(
                    width: 500,
                    child: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          metric('Opening cash',
                              formatPeso(shift.session.startingCashCents)),
                          metric(
                              'Expected cash', formatPeso(shift.expectedCents)),
                          if (!confirm) ...[
                            const SizedBox(height: 16),
                            TextField(
                                key: const Key('pos-counted-cash'),
                                controller: amount,
                                onChanged: (_) => setDialogState(() {}),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                decoration: const InputDecoration(
                                    labelText: 'Counted cash',
                                    prefixText: '₱ ',
                                    border: OutlineInputBorder())),
                            if (amount.text.isNotEmpty && counted == null)
                              const Text(
                                  'Enter valid cash with up to two decimal places.'),
                          ] else ...[
                            metric('Counted cash', formatPeso(counted!)),
                            const Text(
                                'Closing will finalize this cash session.'),
                          ],
                          if (variance != null)
                            metric('Variance',
                                '$status ${formatPeso(variance.abs())}'),
                          if (error != null)
                            Text(error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error)),
                        ]))),
                actions: [
                  TextButton(
                      onPressed: busy
                          ? null
                          : () {
                              if (confirm) {
                                setDialogState(() => confirm = false);
                              } else {
                                Navigator.pop(context, false);
                              }
                            },
                      child: Text(confirm ? 'Back' : 'Cancel')),
                  FilledButton(
                      key: const Key('pos-close-shift'),
                      onPressed: busy || counted == null
                          ? null
                          : () async {
                              if (!confirm) {
                                setDialogState(() => confirm = true);
                                return;
                              }
                              setDialogState(() => busy = true);
                              try {
                                await repository.close(user, counted);
                                if (context.mounted) {
                                  Navigator.pop(context, true);
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  setDialogState(() {
                                    busy = false;
                                    error = e.toString();
                                  });
                                }
                              }
                            },
                      child: Text(confirm ? 'Close shift' : 'Review close')),
                ]);
          }));
  amount.dispose();
  return result == true;
}
