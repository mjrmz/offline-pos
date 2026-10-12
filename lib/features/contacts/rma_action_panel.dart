import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/daos/rma_lifecycle_repository.dart';
import '../../data/daos/rma_repository.dart';
import '../../data/daos/sales_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';

/// The routine RMA steps stay in the detail workspace. Physical handoff and
/// supplier fulfillment continue through their dedicated confirmation flows.
class RmaActionPanel extends StatefulWidget {
  final RmaCase row;
  final RmaRepository repository;
  final ActiveUser user;
  final String action;
  final List<RmaLifecycleEvent> events;
  final String product;
  final String? originalSerial;
  final String? supplierName;
  final RmaCase? relatedCase;
  final Future<void> Function() onSaved;
  final Future<void> Function() onOtherAction;
  final Future<void> Function(RmaCase) onOpenRelated;

  const RmaActionPanel(
      {super.key,
      required this.row,
      required this.repository,
      required this.user,
      required this.action,
      required this.events,
      required this.product,
      required this.originalSerial,
      required this.supplierName,
      required this.relatedCase,
      required this.onSaved,
      required this.onOtherAction,
      required this.onOpenRelated});

  @override
  State<RmaActionPanel> createState() => _RmaActionPanelState();
}

class _RmaActionPanelState extends State<RmaActionPanel> {
  final note = TextEditingController();
  final quantity = TextEditingController();
  final returnedSerial = TextEditingController();
  final finding = TextEditingController();
  final supplierReference = TextEditingController();
  String? condition;
  String? fault;
  String? outcome;
  String? disposition;
  String? supplierDecision;
  String refundMethod = 'cash';
  bool review = false;
  bool busy = false;
  String loadingLabel = 'Saving...';
  String? error;
  late Future<_Options> options = _load();

  Future<_Options> _load() async {
    final events = widget.events;
    final received = events
        .where((e) => e.action == 'received')
        .fold<int>(0, (sum, e) => sum + (e.quantityMilli ?? 0));
    final inspected = events
        .where((e) => e.action == 'inspected')
        .fold<int>(0, (sum, e) => sum + (e.quantityMilli ?? 0));
    final remaining = widget.action == 'Inspect returned item'
        ? received - inspected
        : widget.row.quantityMilli - received;
    if (remaining > 0) quantity.text = Quantity.format(remaining);
    ItemRefundQuote? quote;
    if (widget.action == 'Choose resolution') {
      try {
        quote = await SalesRepository(widget.repository.db)
            .quoteItemRefund(widget.row.id);
      } on StateError {/* Some sale modes cannot be refunded. */}
    }
    final replacements =
        widget.action == 'Choose resolution' && widget.row.serialUnitId != null
            ? await widget.repository.availableReplacementSerials(widget.row.id)
            : <SerialUnit>[];
    final inspections = events.where((e) => e.action == 'inspected').toList();
    final returned =
        events.where((e) => e.action == 'received').lastOrNull?.returnedSerial;
    final restock = inspections.isNotEmpty &&
        inspections.every(
            (e) => {'good', 'opened'}.contains(e.condition?.toLowerCase())) &&
        (widget.originalSerial == null || returned == widget.originalSerial);
    return _Options(
        received, inspected, quote, replacements.isNotEmpty, restock, returned);
  }

  @override
  void dispose() {
    note.dispose();
    quantity.dispose();
    returnedSerial.dispose();
    finding.dispose();
    supplierReference.dispose();
    super.dispose();
  }

  void fail(String message) => setState(() => error = message);

  Future<void> run(Future<void> Function() work, String loading) async {
    setState(() {
      busy = true;
      loadingLabel = loading;
      error = null;
    });
    try {
      await work();
      if (mounted) await widget.onSaved();
    } catch (e) {
      if (mounted) fail(safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> approve() => run(
      () => RmaLifecycleRepository(widget.repository.db)
          .approve(widget.user, widget.row.id, note: note.text),
      'Approving claim...');

  Future<void> reject() async {
    final reason = TextEditingController();
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: const Text('Reject claim?'),
              content: TextField(
                  controller: reason,
                  autofocus: true,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Reason *')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('Reject claim')),
              ],
            ));
    if (confirmed == true) {
      if (reason.text.trim().isEmpty) {
        fail('Enter a rejection reason.');
      } else {
        await run(
            () => RmaLifecycleRepository(widget.repository.db)
                .reject(widget.user, widget.row.id, reason.text),
            'Rejecting claim...');
      }
    }
    reason.dispose();
  }

  Future<void> receive(_Options data) async {
    final amount = Quantity.tryParse(quantity.text, fractional: true);
    final remaining = widget.row.quantityMilli - data.received;
    if (amount == null || amount <= 0 || amount > remaining) {
      fail('Enter a quantity from 1 to ${Quantity.format(remaining)}.');
      return;
    }
    final serial = returnedSerial.text.trim();
    if (widget.originalSerial != null && serial.isEmpty) {
      fail('Scan or enter the physical returned serial.');
      return;
    }
    String? override;
    if (widget.originalSerial != null && serial != widget.originalSerial) {
      final reason = TextEditingController();
      override = await showDialog<String>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                title: const Text('Serial mismatch override'),
                content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Expected: ${widget.originalSerial}'),
                      Text('Returned: $serial'),
                      const Text('Owner authorization required.'),
                      TextField(
                          controller: reason,
                          autofocus: true,
                          maxLines: 2,
                          decoration:
                              const InputDecoration(labelText: 'Reason *')),
                    ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(dialogContext, reason.text.trim()),
                      child: const Text('Confirm override')),
                ],
              ));
      reason.dispose();
      if (override == null) return;
      if (override.isEmpty) {
        fail('Enter an override reason.');
        return;
      }
    }
    await run(
        () => RmaLifecycleRepository(widget.repository.db).receive(
            widget.user, widget.row.id, amount,
            returnedSerial: serial, overrideReason: override, note: note.text),
        'Recording receipt...');
  }

  Future<void> inspect(_Options data) async {
    final amount = Quantity.tryParse(quantity.text, fractional: true);
    final remaining = data.received - data.inspected;
    if (amount == null || amount <= 0 || amount > remaining) {
      fail('Enter a quantity from 1 to ${Quantity.format(remaining)}.');
      return;
    }
    if (condition == null) {
      fail('Select a condition.');
      return;
    }
    if (fault == null) {
      fail('Choose whether the fault was reproduced.');
      return;
    }
    if (finding.text.trim().isEmpty) {
      fail('Enter an inspection finding.');
      return;
    }
    await run(
        () => RmaLifecycleRepository(widget.repository.db).inspect(
            widget.user,
            widget.row.id,
            amount,
            condition!,
            switch (fault) { 'yes' => true, 'no' => false, _ => null },
            finding.text,
            note: note.text),
        'Saving inspection...');
  }

  void reviewResolution() {
    if (outcome == null) {
      fail('Choose a customer outcome.');
      return;
    }
    if (disposition == null) {
      fail('Choose a returned-item disposition.');
      return;
    }
    if (outcome == 'reject_claim' && note.text.trim().isEmpty) {
      fail('Enter a rejection reason.');
      return;
    }
    setState(() {
      review = true;
      error = null;
    });
  }

  Future<void> authorize(_Options data) => run(
      () => RmaLifecycleRepository(widget.repository.db).authorize(
          widget.user, widget.row.id, outcome!, disposition!,
          amountCents: outcome == 'refund' ? data.quote?.amountCents : null,
          method: outcome == 'refund' ? refundMethod : null,
          note: note.text),
      'Authorizing resolution...');

  Future<void> send() async {
    final lifecycle = RmaLifecycleRepository(widget.repository.db);
    final supplierCase =
        widget.row.origin == 'inbound' ? widget.row : widget.relatedCase;
    if (supplierCase == null) {
      fail('Supplier provenance unavailable.');
      return;
    }
    await run(() async {
      final history = await lifecycle.history(supplierCase.id);
      if (history.any((e) => e.action == 'supplier_created')) {
        await lifecycle.sendLinkedSupplier(widget.user, supplierCase.id,
            supplierReference: supplierReference.text, note: note.text);
      } else {
        await lifecycle.sendDirectSupplier(widget.user, supplierCase.id,
            note: [supplierReference.text, note.text]
                .where((e) => e.trim().isNotEmpty)
                .join(' · '));
      }
    }, 'Sending to supplier...');
  }

  Future<void> decide() async {
    if (supplierDecision == null) {
      fail('Choose a supplier decision.');
      return;
    }
    await run(
        () => RmaLifecycleRepository(widget.repository.db).supplierDecision(
            widget.user, widget.row.id, supplierDecision!,
            note: note.text),
        'Recording decision...');
  }

  Widget field(TextEditingController controller, String label,
          {int lines = 1, ValueChanged<String>? changed}) =>
      Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextField(
              controller: controller,
              maxLines: lines,
              onChanged: changed,
              decoration: InputDecoration(
                  labelText: label, border: const OutlineInputBorder())));

  Widget choice(String title, String value, String? selected, VoidCallback tap,
      {String? subtitle}) {
    final theme = Theme.of(context);
    final chosen = selected == value;
    return Card(
        key: ValueKey('rma-choice-$value'),
        elevation: 0,
        color: chosen
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
            : theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
                color: chosen
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant)),
        margin: const EdgeInsets.only(top: 6),
        child: ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            leading: Icon(
                chosen
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: chosen
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant),
            title: Text(title,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            subtitle: subtitle == null
                ? null
                : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: busy ? null : tap));
  }

  Widget button(String title, VoidCallback action) => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
              onPressed: busy ? null : action,
              child: Text(busy ? loadingLabel : title))));

  int _stepNumber() => switch (widget.action) {
        'Approve claim' => 2,
        'Receive returned item' => 3,
        'Inspect returned item' => 4,
        'Choose resolution' => 5,
        'Send to supplier' || 'Send item to supplier' => 2,
        'Record supplier decision' => 3,
        'Record supplier fulfillment' => 5,
        'Complete' || 'Supplier fulfilled' => 6,
        _ => 6,
      };

  String? _actionHint() => switch (widget.action) {
        'Approve claim' =>
          'Review the reported issue before receiving the item.',
        'Receive returned item' =>
          'Record the physical item now in store custody.',
        'Inspect returned item' => 'Document the condition and test result.',
        'Choose resolution' => review
            ? 'Confirm the customer outcome and returned-item disposition.'
            : 'Choose how to resolve the customer claim.',
        'Send to supplier' ||
        'Send item to supplier' =>
          'Confirm the physical item has left store custody.',
        'Record supplier decision' =>
          'Record the supplier response before receiving fulfillment.',
        'Waiting on supplier' => 'No customer action is due right now.',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
        key: const ValueKey('rma-action-panel'),
        elevation: 0,
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.28))),
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: FutureBuilder<_Options>(
                future: options,
                builder: (context, snap) {
                  final data = snap.data;
                  final action = widget.action;
                  final passive = action == 'Waiting on supplier' ||
                      action == 'Supplier fulfilled' ||
                      action == 'Complete' ||
                      action == 'Closed' ||
                      action.startsWith('Legacy');
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(children: [
                          Text(passive ? 'CURRENT STATUS' : 'CURRENT STEP',
                              style: theme.textTheme.labelLarge?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.6)),
                          const Spacer(),
                          Text('${_stepNumber()} OF 6',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                        ]),
                        const SizedBox(height: 8),
                        Text(
                            review
                                ? 'Review resolution'
                                : action == 'Approve claim'
                                    ? 'Review claim'
                                    : action,
                            style: theme.textTheme.titleLarge),
                        if (_actionHint() != null) ...[
                          const SizedBox(height: 4),
                          Text(_actionHint()!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                        ],
                        const SizedBox(height: 12),
                        if (snap.hasError)
                          Text(safeMessage(snap.error!),
                              style: TextStyle(color: theme.colorScheme.error)),
                        if (!snap.hasData && !snap.hasError)
                          const LinearProgressIndicator(),
                        if (data != null) ...[
                          if (action == 'Approve claim') ...[
                            Text('Claim: ${widget.row.issueDescription}'),
                            field(note, 'Approval note (optional)', lines: 2),
                            button('Approve claim', approve),
                            TextButton(
                                onPressed: busy ? null : reject,
                                child: const Text('Reject claim')),
                          ],
                          if (action == 'Receive returned item') ...[
                            Text('Product: ${widget.product}'),
                            Text(
                                'Approved: ${Quantity.format(widget.row.quantityMilli)} · '
                                'Already received: ${Quantity.format(data.received)}'),
                            Text(
                                'Remaining: ${Quantity.format(widget.row.quantityMilli - data.received)}'),
                            if (widget.originalSerial != null) ...[
                              Text('Expected serial: ${widget.originalSerial}'),
                              field(returnedSerial, 'Returned serial *',
                                  changed: (_) => setState(() {})),
                              if (returnedSerial.text.trim().isNotEmpty)
                                Text(
                                    returnedSerial.text.trim() ==
                                            widget.originalSerial
                                        ? 'Serial match'
                                        : 'SERIAL MISMATCH · Owner authorization required',
                                    style: TextStyle(
                                        color: returnedSerial.text.trim() ==
                                                widget.originalSerial
                                            ? theme.colorScheme.primary
                                            : theme.colorScheme.error)),
                            ] else
                              field(quantity, 'Receive now *'),
                            field(note, 'Notes (optional)', lines: 2),
                            button(
                                widget.originalSerial != null &&
                                        returnedSerial.text.trim().isNotEmpty &&
                                        returnedSerial.text.trim() !=
                                            widget.originalSerial
                                    ? 'Request override'
                                    : 'Record receipt',
                                () => receive(data)),
                          ],
                          if (action == 'Inspect returned item') ...[
                            Text(
                                'Customer reported: ${widget.row.issueDescription}'),
                            Text('Product: ${widget.product}'),
                            if (data.returnedSerial != null)
                              Text('Returned serial: ${data.returnedSerial}'),
                            Text(
                                'Awaiting inspection: ${Quantity.format(data.received - data.inspected)}'),
                            if (widget.originalSerial == null)
                              field(quantity, 'Inspect quantity *'),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                                initialValue: condition,
                                decoration: const InputDecoration(
                                    labelText: 'Condition *',
                                    border: OutlineInputBorder()),
                                items: const [
                                  'Good',
                                  'Opened',
                                  'Damaged',
                                  'Liquid damage',
                                  'Burnt',
                                  'Cracked',
                                  'Physically broken',
                                  'Missing parts',
                                  'Other'
                                ]
                                    .map((s) => DropdownMenuItem(
                                        value: s
                                            .toLowerCase()
                                            .replaceAll(' ', '_'),
                                        child: Text(s)))
                                    .toList(),
                                onChanged: busy
                                    ? null
                                    : (v) => setState(() => condition = v)),
                            const SizedBox(height: 12),
                            const Text('Fault reproduced?'),
                            SegmentedButton<String>(
                                segments: const [
                                  ButtonSegment(
                                      value: 'yes', label: Text('Yes')),
                                  ButtonSegment(value: 'no', label: Text('No')),
                                  ButtonSegment(
                                      value: 'untested',
                                      label: Text('Not tested')),
                                ],
                                selected: {
                                  if (fault != null) fault!
                                },
                                emptySelectionAllowed: true,
                                onSelectionChanged: busy
                                    ? null
                                    : (v) => setState(() => fault = v.single)),
                            field(finding, 'Inspection finding *', lines: 2),
                            field(note, 'Notes (optional)', lines: 2),
                            button('Record inspection', () => inspect(data)),
                          ],
                          if (action == 'Choose resolution') ...[
                            if (!review) ...[
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
                                          refundMethod =
                                              widget.row.customerId == null
                                                  ? 'cash'
                                                  : 'obligation';
                                        }),
                                    subtitle:
                                        'Return eligible value to the customer.'),
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
                                        'Reserve an available exact serial for handoff.'),
                              if (widget.originalSerial != null)
                                choice(
                                    'Supplier warranty / repair',
                                    'supplier_warranty',
                                    outcome,
                                    () => setState(() {
                                          outcome = 'supplier_warranty';
                                          disposition = 'supplier';
                                        }),
                                    subtitle:
                                        'Send the returned item for supplier recovery.'),
                              choice(
                                  'No fault found',
                                  'no_fault',
                                  outcome,
                                  () => setState(() {
                                        outcome = 'no_fault';
                                        disposition = 'return_to_customer';
                                      }),
                                  subtitle:
                                      'Return the exact inspected item to the customer.'),
                              choice(
                                  'Reject claim',
                                  'reject_claim',
                                  outcome,
                                  () => setState(() {
                                        outcome = 'reject_claim';
                                        disposition = 'return_to_customer';
                                      }),
                                  subtitle:
                                      'Resolve the claim and return customer property.'),
                              if (outcome != null) ...[
                                const SizedBox(height: 12),
                                if (outcome == 'refund') ...[
                                  Text(
                                      'Eligible refund: ${formatPeso(data.quote!.amountCents)}'),
                                  DropdownButtonFormField<String>(
                                      initialValue: refundMethod,
                                      decoration: const InputDecoration(
                                          labelText: 'Method'),
                                      items: [
                                        const DropdownMenuItem(
                                            value: 'cash',
                                            child: Text('Cash from drawer')),
                                        if (widget.row.customerId != null)
                                          const DropdownMenuItem(
                                              value: 'obligation',
                                              child: Text(
                                                  'Customer refund obligation'))
                                      ],
                                      onChanged: (v) =>
                                          setState(() => refundMethod = v!)),
                                ],
                                if (outcome == 'replacement')
                                  const Text(
                                      'Exact serial selection and warranty are recorded at reservation and handoff.'),
                                if (outcome == 'no_fault' ||
                                    outcome == 'reject_claim')
                                  const Text(
                                      'The exact returned item must be handed back to the customer.'),
                                field(
                                    note,
                                    outcome == 'reject_claim'
                                        ? 'Rejection reason *'
                                        : 'Notes (optional)',
                                    lines: 2),
                                const SizedBox(height: 12),
                                Text('Returned item disposition',
                                    style: theme.textTheme.titleMedium),
                                if (outcome == 'no_fault' ||
                                    outcome == 'reject_claim')
                                  choice(
                                      'Return to customer',
                                      'return_to_customer',
                                      disposition,
                                      () => setState(() =>
                                          disposition = 'return_to_customer')),
                                if (outcome == 'supplier_warranty')
                                  choice(
                                      'Send to supplier',
                                      'supplier',
                                      disposition,
                                      () => setState(
                                          () => disposition = 'supplier')),
                                if (outcome == 'refund' ||
                                    outcome == 'replacement') ...[
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
                                      () => setState(
                                          () => disposition = 'scrap')),
                                  choice(
                                      'Send to supplier',
                                      'supplier',
                                      disposition,
                                      () => setState(
                                          () => disposition = 'supplier')),
                                  choice(
                                      'Hold',
                                      'hold',
                                      disposition,
                                      () =>
                                          setState(() => disposition = 'hold')),
                                ],
                              ],
                              button('Review resolution', reviewResolution),
                            ] else ...[
                              Text('Outcome: ${_name(outcome)}'),
                              if (outcome == 'refund') ...[
                                Text(
                                    'Amount: ${formatPeso(data.quote!.amountCents)}'),
                                Text('Method: ${_name(refundMethod)}'),
                              ],
                              Text('Disposition: ${_name(disposition)}'),
                              if (data.returnedSerial != null)
                                Text('Returned serial: ${data.returnedSerial}'),
                              if (note.text.trim().isNotEmpty)
                                Text('Notes: ${note.text}'),
                              const Text(
                                  'Payout, inventory disposition, and handoff remain separate actions.'),
                              button('Authorize resolution',
                                  () => authorize(data)),
                              TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => setState(() => review = false),
                                  child: const Text('Back')),
                            ],
                          ],
                          if (action == 'Send to supplier' ||
                              action == 'Send item to supplier') ...[
                            Text(
                                'SRMA: ${widget.row.origin == 'inbound' ? widget.row.reference : widget.relatedCase?.reference ?? 'Unavailable'}'),
                            Text(
                                'Supplier: ${widget.supplierName ?? 'Unknown'}'),
                            Text('Product: ${widget.product}'),
                            Text(widget.originalSerial == null
                                ? 'Quantity: ${Quantity.format(widget.row.quantityMilli)}'
                                : 'Serial: ${widget.originalSerial}'),
                            const Text('Current custody: Store'),
                            Text(
                                'Send date: ${MaterialLocalizations.of(context).formatMediumDate(DateTime.now())}'),
                            field(supplierReference,
                                'Supplier reference (optional)'),
                            field(note, 'Notes (optional)', lines: 2),
                            button('Confirm sent to supplier', send),
                          ],
                          if (action == 'Record supplier decision') ...[
                            Text(
                                'Supplier: ${widget.supplierName ?? 'Unknown'}'),
                            for (final (label, value) in [
                              if (widget.originalSerial != null)
                                ('Repaired original', 'repair'),
                              if (widget.originalSerial != null)
                                ('Replacement', 'replacement'),
                              ('Credit', 'credit'),
                              if (widget.originalSerial != null)
                                ('No fault found', 'no_fault'),
                              if (widget.originalSerial != null)
                                ('Rejected', 'rejected'),
                            ])
                              choice(
                                  label,
                                  value,
                                  supplierDecision,
                                  () =>
                                      setState(() => supplierDecision = value)),
                            field(note, 'Notes (optional)', lines: 2),
                            button('Record decision', decide),
                          ],
                          if (passive) ...[
                            if (action == 'Waiting on supplier') ...[
                              Text(
                                  'Supplier: ${widget.supplierName ?? 'Unknown'}'),
                              if (widget.relatedCase != null)
                                Text('SRMA: ${widget.relatedCase!.reference}'),
                              if (widget.relatedCase != null)
                                TextButton.icon(
                                    onPressed: () => widget
                                        .onOpenRelated(widget.relatedCase!),
                                    icon: const Icon(Icons.open_in_new),
                                    label: const Text('View Supplier RMA')),
                            ],
                            if (action == 'Complete' &&
                                widget.relatedCase != null) ...[
                              const Text('Customer case: Completed'),
                              Text(
                                  'Business recovery: ${widget.relatedCase!.reference}'),
                              Text(
                                  'Status: ${_supplierStatus(widget.relatedCase!.status)}'),
                              TextButton.icon(
                                  onPressed: () =>
                                      widget.onOpenRelated(widget.relatedCase!),
                                  icon: const Icon(Icons.open_in_new),
                                  label: const Text('View Supplier RMA')),
                            ],
                          ],
                          if (!passive &&
                              !{
                                'Approve claim',
                                'Receive returned item',
                                'Inspect returned item',
                                'Choose resolution',
                                'Send to supplier',
                                'Send item to supplier',
                                'Record supplier decision',
                                'Resolve held property'
                              }.contains(action))
                            button(action, () async {
                              await widget.onOtherAction();
                              if (mounted) await widget.onSaved();
                            }),
                          if (action == 'Resolve held property')
                            const Text('Hold execution is not yet supported.'),
                        ],
                        if (error != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(error!,
                                  style: TextStyle(
                                      color: theme.colorScheme.error))),
                      ]);
                })));
  }
}

String _name(String? value) => value == null
    ? 'Not recorded'
    : value
        .split('_')
        .map((s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}')
        .join(' ');

String _supplierStatus(String status) => switch (status) {
      'pending' => 'Ready to send',
      'sent_to_supplier' => 'Awaiting supplier decision or fulfillment',
      'resolved' => 'Complete',
      _ => _name(status),
    };

class _Options {
  final int received;
  final int inspected;
  final ItemRefundQuote? quote;
  final bool replacementAvailable;
  final bool restockEligible;
  final String? returnedSerial;
  const _Options(this.received, this.inspected, this.quote,
      this.replacementAvailable, this.restockEligible, this.returnedSerial);
}
