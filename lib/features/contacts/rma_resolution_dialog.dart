import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../data/daos/rma_lifecycle_repository.dart';
import '../../data/daos/rma_repository.dart';
import '../../data/daos/sales_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';

Future<bool> showRmaResolutionDialog(
  BuildContext context, {
  required RmaRepository repository,
  required ActiveUser user,
  required RmaCase row,
}) async {
  final narrow = MediaQuery.sizeOf(context).width < 600;
  return await showDialog<bool>(
          context: context,
          builder: (context) {
            final content =
                _ResolutionDialog(repository: repository, user: user, row: row);
            return narrow
                ? Dialog.fullscreen(child: content)
                : Dialog(
                    insetPadding: const EdgeInsets.all(24),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(width: 720, height: 650, child: content));
          }) ??
      false;
}

class _ResolutionDialog extends StatefulWidget {
  final RmaRepository repository;
  final ActiveUser user;
  final RmaCase row;
  const _ResolutionDialog(
      {required this.repository, required this.user, required this.row});
  @override
  State<_ResolutionDialog> createState() => _ResolutionDialogState();
}

class _ResolutionDialogState extends State<_ResolutionDialog> {
  int step = 0;
  String? outcome;
  String? disposition;
  String method = 'cash';
  final notes = TextEditingController();
  String? error;
  bool saving = false;
  late final Future<_ResolutionFacts> facts = _load();

  Future<_ResolutionFacts> _load() async {
    final db = widget.repository.db;
    final events = await RmaLifecycleRepository(db).history(widget.row.id);
    final receipt =
        events.where((event) => event.action == 'received').lastOrNull;
    final inspections =
        events.where((event) => event.action == 'inspected').toList();
    final original = widget.row.serialUnitId == null
        ? null
        : (await db.select(db.serialUnits).get())
            .where((serial) => serial.id == widget.row.serialUnitId)
            .firstOrNull
            ?.serialNumber;
    ItemRefundQuote? quote;
    try {
      quote = await SalesRepository(db).quoteItemRefund(widget.row.id);
    } on StateError {/* Only supported sale modes receive a refund option. */}
    final replacementUnits = widget.row.serialUnitId == null
        ? <SerialUnit>[]
        : await widget.repository.availableReplacementSerials(widget.row.id);
    final restockEligible = inspections.isNotEmpty &&
        inspections.every((event) =>
            {'good', 'opened'}.contains(event.condition?.toLowerCase())) &&
        (original == null || receipt?.returnedSerial == original);
    return _ResolutionFacts(original, receipt?.returnedSerial, quote,
        replacementUnits.isNotEmpty, restockEligible);
  }

  @override
  void dispose() {
    notes.dispose();
    super.dispose();
  }

  void next() {
    if (step == 0 && outcome == null) {
      setState(() => error = 'Choose a customer outcome.');
      return;
    }
    if (step == 2 && disposition == null) {
      setState(() => error = 'Choose a physical disposition.');
      return;
    }
    setState(() {
      error = null;
      step++;
    });
  }

  Future<void> save(_ResolutionFacts facts) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await RmaLifecycleRepository(widget.repository.db).authorize(
          widget.user, widget.row.id, outcome!, disposition!,
          amountCents: outcome == 'refund' ? facts.quote!.amountCents : null,
          method: outcome == 'refund' ? method : null,
          note: notes.text);
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget choice(
          String title, String value, String? selected, VoidCallback onTap,
          {String? subtitle}) =>
      Card(
        child: ListTile(
          selected: selected == value,
          leading: Icon(selected == value
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          onTap: onTap,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<_ResolutionFacts>(
        future: facts,
        builder: (context, snapshot) {
          final data = snapshot.data;
          return Column(children: [
            Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text('Resolve item', style: theme.textTheme.titleLarge),
                        Text('${widget.row.reference} · ${const [
                          'Customer outcome',
                          'Resolution details',
                          'Physical disposition',
                          'Review'
                        ][step]}'),
                      ])),
                  IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed:
                          saving ? null : () => Navigator.pop(context, false)),
                ])),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: LinearProgressIndicator(value: (step + 1) / 4)),
            const Divider(),
            Expanded(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Step ${step + 1} of 4',
                              style: theme.textTheme.labelLarge),
                          Text('Product claim: ${widget.row.issueDescription}'),
                          if (snapshot.hasError)
                            Text(safeMessage(snapshot.error!)),
                          if (!snapshot.hasData && !snapshot.hasError)
                            const Text('Loading resolution options...'),
                          if (data != null) ...[
                            if (data.originalSerial != null)
                              Text('Original serial: ${data.originalSerial}'),
                            if (data.returnedSerial != null)
                              Text('Returned serial: ${data.returnedSerial}'),
                            const SizedBox(height: 12),
                            if (step == 0) ...[
                              Text('Customer outcome',
                                  style: theme.textTheme.titleMedium),
                              if (data.quote != null)
                                choice(
                                    'Refund',
                                    'refund',
                                    outcome,
                                    () => setState(() {
                                          outcome = 'refund';
                                          disposition = null;
                                        })),
                              if (data.replacementAvailable)
                                choice(
                                    'Replace now',
                                    'replacement',
                                    outcome,
                                    () => setState(() {
                                          outcome = 'replacement';
                                          disposition = null;
                                        }),
                                    subtitle:
                                        'An exact available serial will be reserved after authorization.'),
                              if (!data.replacementAvailable)
                                const Text(
                                    'No eligible replacement inventory available.'),
                              if (data.originalSerial != null)
                                choice(
                                    'Supplier warranty / repair',
                                    'supplier_warranty',
                                    outcome,
                                    () => setState(() {
                                          outcome = 'supplier_warranty';
                                          disposition = 'supplier';
                                        }),
                                    subtitle:
                                        'Customer completion waits for supplier fulfillment and final handoff.'),
                              choice(
                                  'No fault found',
                                  'no_fault',
                                  outcome,
                                  () => setState(() {
                                        outcome = 'no_fault';
                                        disposition = 'return_to_customer';
                                      }),
                                  subtitle:
                                      'The exact returned item will be handed back to the customer.'),
                              choice(
                                  'Reject claim',
                                  'reject_claim',
                                  outcome,
                                  () => setState(() {
                                        outcome = 'reject_claim';
                                        disposition = 'return_to_customer';
                                      }),
                                  subtitle:
                                      'Customer property must be handed back before completion.'),
                            ],
                            if (step == 1) ...[
                              Text('Resolution details',
                                  style: theme.textTheme.titleMedium),
                              if (outcome == 'refund') ...[
                                Text(
                                    'Eligible refund amount: ${formatPeso(data.quote!.amountCents)}'),
                                choice('Cash from drawer', 'cash', method,
                                    () => setState(() => method = 'cash')),
                                if (widget.row.customerId != null)
                                  choice(
                                      'Customer refund obligation',
                                      'obligation',
                                      method,
                                      () => setState(
                                          () => method = 'obligation')),
                                const Text(
                                    'Authorization is separate from payout and settlement.'),
                              ],
                              if (outcome == 'replacement')
                                const Text(
                                    'The exact available replacement serial is selected after authorization. Inventory is issued only at handoff.'),
                              if (outcome == 'no_fault' ||
                                  outcome == 'reject_claim')
                                const Text(
                                    'The exact returned item will be handed back to the customer and will not be restocked.'),
                              if (outcome == 'supplier_warranty')
                                const Text(
                                    'The customer remains waiting until the exact supplier item is handed over.'),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: notes,
                                  maxLines: 2,
                                  decoration: InputDecoration(
                                      labelText: outcome == 'reject_claim'
                                          ? 'Rejection reason *'
                                          : 'Notes (optional)',
                                      border: const OutlineInputBorder())),
                            ],
                            if (step == 2) ...[
                              Text('Physical disposition',
                                  style: theme.textTheme.titleMedium),
                              if (outcome == 'no_fault' ||
                                  outcome == 'reject_claim')
                                choice(
                                    'Return to customer',
                                    'return_to_customer',
                                    disposition,
                                    () => setState(() =>
                                        disposition = 'return_to_customer')),
                              if (outcome != 'no_fault' &&
                                  outcome != 'reject_claim' &&
                                  outcome != 'supplier_warranty') ...[
                                if (data.restockEligible)
                                  choice(
                                      'Restock',
                                      'restock',
                                      disposition,
                                      () => setState(
                                          () => disposition = 'restock')),
                                choice(
                                    'Scrap',
                                    'scrap',
                                    disposition,
                                    () =>
                                        setState(() => disposition = 'scrap')),
                                choice(
                                    'Send to supplier',
                                    'supplier',
                                    disposition,
                                    () => setState(
                                        () => disposition = 'supplier'),
                                    subtitle:
                                        'Supplier recovery continues separately after the customer is satisfied.'),
                              ],
                              if (outcome == 'supplier_warranty')
                                choice(
                                    'Send to supplier',
                                    'supplier',
                                    disposition,
                                    () => setState(
                                        () => disposition = 'supplier')),
                            ],
                            if (step == 3) ...[
                              Text('Review',
                                  style: theme.textTheme.titleMedium),
                              Card(
                                  child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text('Outcome: ${outcome ?? ''}'),
                                            Text(
                                                'Disposition: ${disposition ?? ''}'),
                                            if (outcome == 'refund')
                                              Text(
                                                  'Amount: ${formatPeso(data.quote!.amountCents)}'),
                                            if (outcome == 'refund')
                                              Text('Method: $method'),
                                            if (data.returnedSerial != null)
                                              Text(
                                                  'Returned serial: ${data.returnedSerial}'),
                                            if (notes.text.trim().isNotEmpty)
                                              Text('Notes: ${notes.text}'),
                                          ]))),
                              const Text(
                                  'This records resolution intent. Further payout, inventory, or handoff actions remain separate.'),
                            ],
                          ],
                          if (error != null)
                            Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(error!,
                                    style: TextStyle(
                                        color: theme.colorScheme.error))),
                        ]))),
            const Divider(height: 1),
            SafeArea(
                top: false,
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      if (step > 0)
                        OutlinedButton(
                            onPressed:
                                saving ? null : () => setState(() => step--),
                            child: const Text('Back')),
                      const Spacer(),
                      FilledButton(
                          onPressed: saving || data == null
                              ? null
                              : step == 3
                                  ? () => save(data)
                                  : next,
                          child: Text(saving
                              ? 'Saving...'
                              : step == 3
                                  ? outcome == 'refund'
                                      ? 'Authorize refund'
                                      : outcome == 'replacement'
                                          ? 'Choose replacement'
                                          : 'Prepare customer return'
                                  : 'Continue')),
                    ]))),
          ]);
        });
  }
}

class _ResolutionFacts {
  final String? originalSerial;
  final String? returnedSerial;
  final ItemRefundQuote? quote;
  final bool replacementAvailable;
  final bool restockEligible;
  const _ResolutionFacts(this.originalSerial, this.returnedSerial, this.quote,
      this.replacementAvailable, this.restockEligible);
}
