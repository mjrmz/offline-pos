import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/daos/rma_lifecycle_repository.dart';
import '../../data/daos/rma_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/safe_message.dart';

Future<bool> showRmaPhysicalDialog(
  BuildContext context, {
  required RmaRepository repository,
  required ActiveUser user,
  required RmaCase row,
  required bool inspection,
}) async {
  final width = MediaQuery.sizeOf(context).width;
  return await showDialog<bool>(
        context: context,
        builder: (context) {
          final content = _RmaPhysicalDialog(
              repository: repository,
              user: user,
              row: row,
              inspection: inspection);
          if (width < 600) return Dialog.fullscreen(child: content);
          return Dialog(
            insetPadding: const EdgeInsets.all(24),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(width: 700, height: 640, child: content),
          );
        },
      ) ??
      false;
}

class _RmaPhysicalDialog extends StatefulWidget {
  final RmaRepository repository;
  final ActiveUser user;
  final RmaCase row;
  final bool inspection;

  const _RmaPhysicalDialog(
      {required this.repository,
      required this.user,
      required this.row,
      required this.inspection});

  @override
  State<_RmaPhysicalDialog> createState() => _RmaPhysicalDialogState();
}

class _RmaPhysicalDialogState extends State<_RmaPhysicalDialog> {
  final quantity = TextEditingController();
  final returnedSerial = TextEditingController();
  final overrideReason = TextEditingController();
  final finding = TextEditingController();
  final notes = TextEditingController();
  String? condition;
  bool? fault;
  bool busy = false;
  String? error;
  late final Future<_PhysicalFacts> facts = _load();

  Future<_PhysicalFacts> _load() async {
    final lifecycle = RmaLifecycleRepository(widget.repository.db);
    final history = await lifecycle.history(widget.row.id);
    final received = history
        .where((event) => event.action == 'received')
        .fold<int>(0, (sum, event) => sum + (event.quantityMilli ?? 0));
    final inspected = history
        .where((event) => event.action == 'inspected')
        .fold<int>(0, (sum, event) => sum + (event.quantityMilli ?? 0));
    final expected = widget.row.serialUnitId == null
        ? null
        : (await widget.repository.db
                .select(widget.repository.db.serialUnits)
                .get())
            .where((unit) => unit.id == widget.row.serialUnitId)
            .firstOrNull
            ?.serialNumber;
    final actual = history
        .where((event) => event.action == 'received')
        .lastOrNull
        ?.returnedSerial;
    final remaining = widget.inspection
        ? received - inspected
        : widget.row.quantityMilli - received;
    if (remaining > 0 && quantity.text.isEmpty) {
      quantity.text = Quantity.format(remaining);
    }
    return _PhysicalFacts(received, inspected, expected, actual);
  }

  @override
  void dispose() {
    quantity.dispose();
    returnedSerial.dispose();
    overrideReason.dispose();
    finding.dispose();
    notes.dispose();
    super.dispose();
  }

  Future<void> submit(_PhysicalFacts facts) async {
    final amount = Quantity.tryParse(quantity.text, fractional: true);
    final available = widget.inspection
        ? facts.received - facts.inspected
        : widget.row.quantityMilli - facts.received;
    if (amount == null || amount <= 0 || amount > available) {
      setState(() =>
          error = 'Enter a quantity from 1 to ${Quantity.format(available)}.');
      return;
    }
    if (widget.inspection && condition == null) {
      setState(() => error = 'Choose a condition.');
      return;
    }
    if (widget.inspection && finding.text.trim().isEmpty) {
      setState(() => error = 'Enter an inspection finding.');
      return;
    }
    if (!widget.inspection &&
        facts.expectedSerial != null &&
        returnedSerial.text.trim().isEmpty) {
      setState(() => error = 'Scan or enter the physical returned serial.');
      return;
    }
    if (!widget.inspection &&
        facts.expectedSerial != null &&
        returnedSerial.text.trim() != facts.expectedSerial &&
        overrideReason.text.trim().isEmpty) {
      setState(
          () => error = 'Enter an override reason for the serial mismatch.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final lifecycle = RmaLifecycleRepository(widget.repository.db);
      if (widget.inspection) {
        await lifecycle.inspect(
            widget.user, widget.row.id, amount, condition!, fault, finding.text,
            note: notes.text);
      } else {
        await lifecycle.receive(widget.user, widget.row.id, amount,
            returnedSerial: returnedSerial.text.trim(),
            overrideReason: overrideReason.text.trim(),
            note: notes.text);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<_PhysicalFacts>(
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
                        Text(
                            widget.inspection
                                ? 'Inspect received items'
                                : 'Receive returned items',
                            style: theme.textTheme.titleLarge),
                        const SizedBox(height: 4),
                        Text(widget.inspection
                            ? 'Only physically received quantities and exact units are available.'
                            : 'Scan or type the physical serial. A mismatch is never silently accepted.'),
                      ])),
                  IconButton(
                      onPressed:
                          busy ? null : () => Navigator.pop(context, false),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close)),
                ])),
            const Divider(height: 1),
            Expanded(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.row.reference,
                              style: theme.textTheme.titleMedium),
                          Text(
                              'Customer reported: ${widget.row.issueDescription}'),
                          const SizedBox(height: 12),
                          if (snapshot.hasError)
                            Text(safeMessage(snapshot.error!),
                                style:
                                    TextStyle(color: theme.colorScheme.error)),
                          if (!snapshot.hasData && !snapshot.hasError)
                            const Text('Loading received items...'),
                          if (data != null) ...[
                            Text(widget.inspection
                                ? 'Received: ${Quantity.format(data.received)} · Already inspected: ${Quantity.format(data.inspected)}'
                                : 'Approved: ${Quantity.format(widget.row.quantityMilli)} · Already received: ${Quantity.format(data.received)}'),
                            Text(
                                'Remaining: ${Quantity.format(widget.inspection ? data.received - data.inspected : widget.row.quantityMilli - data.received)}'),
                            const SizedBox(height: 12),
                            if (data.expectedSerial != null)
                              Text(
                                  'Original sold serial: ${data.expectedSerial}'),
                            if (widget.inspection && data.actualSerial != null)
                              Text('Returned serial: ${data.actualSerial}'),
                            TextField(
                                controller: quantity,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                decoration: InputDecoration(
                                    labelText: widget.inspection
                                        ? 'Inspect quantity *'
                                        : 'Receive quantity *',
                                    border: const OutlineInputBorder())),
                            const SizedBox(height: 12),
                            if (!widget.inspection &&
                                data.expectedSerial != null) ...[
                              TextField(
                                  controller: returnedSerial,
                                  onChanged: (_) => setState(() {}),
                                  decoration: const InputDecoration(
                                      labelText: 'Returned serial *',
                                      border: OutlineInputBorder())),
                              if (returnedSerial.text.trim().isNotEmpty &&
                                  returnedSerial.text.trim() !=
                                      data.expectedSerial) ...[
                                const SizedBox(height: 8),
                                Card(
                                    color: theme.colorScheme.errorContainer,
                                    child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Text(
                                            'Serial mismatch: expected ${data.expectedSerial}, returned ${returnedSerial.text.trim()}'))),
                                TextField(
                                    controller: overrideReason,
                                    decoration: const InputDecoration(
                                        labelText: 'Override reason *',
                                        border: OutlineInputBorder())),
                              ],
                            ],
                            if (widget.inspection) ...[
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
                                    .map((value) => DropdownMenuItem(
                                        value: value
                                            .toLowerCase()
                                            .replaceAll(' ', '_'),
                                        child: Text(value)))
                                    .toList(),
                                onChanged: (value) =>
                                    setState(() => condition = value),
                              ),
                              const Text('Fault reproduced?'),
                              SegmentedButton<String>(
                                  segments: const [
                                    ButtonSegment(
                                        value: 'yes', label: Text('Yes')),
                                    ButtonSegment(
                                        value: 'no', label: Text('No')),
                                    ButtonSegment(
                                        value: 'untested',
                                        label: Text('Not tested')),
                                  ],
                                  selected: {
                                    fault == null
                                        ? 'untested'
                                        : fault!
                                            ? 'yes'
                                            : 'no'
                                  },
                                  onSelectionChanged: (value) => setState(
                                      () => fault = switch (value.single) {
                                            'yes' => true,
                                            'no' => false,
                                            _ => null,
                                          })),
                              TextField(
                                  controller: finding,
                                  maxLines: 2,
                                  decoration: const InputDecoration(
                                      labelText: 'Inspection finding *',
                                      border: OutlineInputBorder())),
                            ],
                            const SizedBox(height: 12),
                            TextField(
                                controller: notes,
                                maxLines: 2,
                                decoration: const InputDecoration(
                                    labelText: 'Notes (optional)',
                                    border: OutlineInputBorder())),
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
                      TextButton(
                          onPressed:
                              busy ? null : () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      const Spacer(),
                      FilledButton(
                          onPressed:
                              busy || data == null ? null : () => submit(data),
                          child: Text(busy
                              ? 'Recording...'
                              : widget.inspection
                                  ? 'Record inspection'
                                  : 'Record physical receipt')),
                    ]))),
          ]);
        });
  }
}

class _PhysicalFacts {
  final int received;
  final int inspected;
  final String? expectedSerial;
  final String? actualSerial;
  const _PhysicalFacts(
      this.received, this.inspected, this.expectedSerial, this.actualSerial);
}
