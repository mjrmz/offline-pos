import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../data/daos/rma_lifecycle_repository.dart';
import '../../data/daos/rma_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';

Future<bool> showRmaCompletionDialog(
  BuildContext context, {
  required RmaRepository repository,
  required ActiveUser user,
  required RmaCase row,
  required bool handoff,
}) async {
  final narrow = MediaQuery.sizeOf(context).width < 600;
  return await showDialog<bool>(
          context: context,
          builder: (context) {
            final content = _CompletionDialog(
                repository: repository, user: user, row: row, handoff: handoff);
            return narrow
                ? Dialog.fullscreen(child: content)
                : Dialog(
                    insetPadding: const EdgeInsets.all(24),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                        width: handoff ? 680 : 480,
                        height: handoff ? 560 : 460,
                        child: content));
          }) ??
      false;
}

class _CompletionDialog extends StatefulWidget {
  final RmaRepository repository;
  final ActiveUser user;
  final RmaCase row;
  final bool handoff;
  const _CompletionDialog(
      {required this.repository,
      required this.user,
      required this.row,
      required this.handoff});
  @override
  State<_CompletionDialog> createState() => _CompletionDialogState();
}

class _CompletionDialogState extends State<_CompletionDialog> {
  final recipient = TextEditingController();
  final value = TextEditingController();
  final reference = TextEditingController();
  final notes = TextEditingController();
  String condition = 'good';
  String replacementCondition = 'new';
  String warrantyTreatment = 'continue_original';
  DateTime? warrantyEndAt;
  bool busy = false;
  String? error;
  late final Future<_CompletionFacts> facts = _load();

  @override
  void initState() {
    super.initState();
    if (!widget.handoff) warrantyTreatment = 'unknown';
  }

  Future<_CompletionFacts> _load() async {
    final db = widget.repository.db;
    final events = await RmaLifecycleRepository(db).history(widget.row.id);
    final decision = events
        .where((event) => event.action == 'supplier_decision')
        .lastOrNull
        ?.outcome;
    final original = widget.row.serialUnitId == null
        ? null
        : (await db.select(db.serialUnits).get())
            .where((serial) => serial.id == widget.row.serialUnitId)
            .firstOrNull
            ?.serialNumber;
    final reservation = events
        .where((event) => event.action == 'replacement_reserved')
        .lastOrNull;
    final released = reservation?.serialUnitId == null
        ? null
        : (await db.select(db.serialUnits).get())
            .where((serial) => serial.id == reservation!.serialUnitId)
            .firstOrNull
            ?.serialNumber;
    final outcome =
        events.where((event) => event.action == 'intent').firstOrNull?.outcome;
    String? supplierReplacementId;
    String? supplierReplacementSerial;
    final linkedCustomerId = events
        .where((event) => event.action == 'supplier_created')
        .lastOrNull
        ?.relatedCaseId;
    final linkedCustomerEvents = linkedCustomerId == null
        ? <RmaLifecycleEvent>[]
        : await RmaLifecycleRepository(db).history(linkedCustomerId);
    final supplierCustomerWaiting = linkedCustomerEvents.any((event) =>
            event.action == 'intent' && event.outcome == 'supplier_warranty') &&
        !linkedCustomerEvents.any((event) => event.action == 'completed');
    if (outcome == 'supplier_warranty') {
      final supplierId = events
          .where((event) => event.action == 'supplier_claim_opened')
          .lastOrNull
          ?.relatedCaseId;
      if (supplierId != null) {
        final supplierEvents =
            await RmaLifecycleRepository(db).history(supplierId);
        supplierReplacementId = supplierEvents
            .where((event) =>
                event.action == 'supplier_fulfilled' &&
                {'replacement', 'repair', 'no_fault', 'rejected'}
                    .contains(event.outcome))
            .lastOrNull
            ?.serialUnitId;
        supplierReplacementSerial = (await db.select(db.serialUnits).get())
            .where((serial) => serial.id == supplierReplacementId)
            .firstOrNull
            ?.serialNumber;
      }
    }
    return _CompletionFacts(
        decision,
        original,
        released,
        reservation?.serialUnitId,
        outcome,
        supplierReplacementId,
        supplierReplacementSerial,
        supplierCustomerWaiting);
  }

  @override
  void dispose() {
    recipient.dispose();
    value.dispose();
    reference.dispose();
    notes.dispose();
    super.dispose();
  }

  Future<void> submit(_CompletionFacts data) async {
    if ((widget.handoff || data.decision == 'replacement') &&
        {'restart', 'custom'}.contains(warrantyTreatment) &&
        warrantyEndAt == null) {
      setState(() => error = 'Choose an explicit warranty end date.');
      return;
    }
    if (widget.handoff && recipient.text.trim().isEmpty) {
      setState(() => error = 'Enter the recipient.');
      return;
    }
    if (!widget.handoff &&
        data.decision == 'credit' &&
        ((tryParsePeso(value.text) ?? 0) <= 0 ||
            reference.text.trim().isEmpty)) {
      setState(() =>
          error = 'Enter a positive credit amount and supplier reference.');
      return;
    }
    if (!widget.handoff &&
        {'repair', 'no_fault', 'rejected'}.contains(data.decision) &&
        value.text.trim() != data.originalSerial) {
      setState(() => error = 'Enter the exact original serial.');
      return;
    }
    if (!widget.handoff &&
        data.decision == 'replacement' &&
        (value.text.trim().isEmpty || reference.text.trim().isEmpty)) {
      setState(() =>
          error = 'Enter the new replacement serial and supplier reference.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final lifecycle = RmaLifecycleRepository(widget.repository.db);
      if (widget.handoff) {
        await lifecycle.handoff(widget.user, widget.row.id, recipient.text,
            serialUnitId: data.outcome == 'replacement'
                ? data.reservedSerialId
                : data.outcome == 'supplier_warranty'
                    ? data.supplierReplacementId
                    : widget.row.serialUnitId,
            note: notes.text,
            warrantyTreatment: warrantyTreatment,
            warrantyEndAt: warrantyEndAt,
            warrantyNote: notes.text);
      } else if (data.decision == 'credit') {
        await lifecycle.supplierCredit(widget.user, widget.row.id,
            tryParsePeso(value.text)!, reference.text);
      } else if (data.decision == 'replacement') {
        await lifecycle.supplierReplacement(
            widget.user, widget.row.id, value.text,
            reference: reference.text,
            condition: replacementCondition,
            warrantyTreatment: warrantyTreatment,
            warrantyEndAt: warrantyEndAt);
      } else if ({'repair', 'no_fault', 'rejected'}.contains(data.decision)) {
        await lifecycle.supplierReturnOriginal(
            widget.user, widget.row.id, value.text, condition,
            reference: reference.text, note: notes.text);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<Widget> warrantyFields(BuildContext context, {required bool supplier}) =>
      [
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: warrantyTreatment,
          decoration: InputDecoration(
              labelText: supplier
                  ? 'Supplier warranty treatment'
                  : 'Customer warranty treatment'),
          items: [
            const DropdownMenuItem(
                value: 'continue_original',
                child: Text('Continue original warranty')),
            if (widget.user.can(PosPermission.manageUsers)) ...const [
              DropdownMenuItem(
                  value: 'restart',
                  child: Text('Restart from handoff / fulfillment')),
              DropdownMenuItem(value: 'custom', child: Text('Custom warranty')),
            ],
            if (supplier)
              const DropdownMenuItem(
                  value: 'unknown', child: Text('Unknown / not provided'))
            else if (widget.user.can(PosPermission.manageUsers))
              const DropdownMenuItem(value: 'none', child: Text('No warranty')),
          ],
          onChanged: (value) => setState(() {
            warrantyTreatment = value ?? warrantyTreatment;
            warrantyEndAt = null;
          }),
        ),
        if (warrantyTreatment == 'continue_original')
          const Text(
              'Original expiry is preserved when documented; otherwise warranty remains Legacy / unknown.'),
        if (warrantyTreatment == 'restart' || warrantyTreatment == 'custom')
          OutlinedButton(
            onPressed: () async {
              final date = await showDatePicker(
                  context: context,
                  firstDate: DateTime.now().add(const Duration(days: 1)),
                  lastDate: DateTime(2100),
                  initialDate: warrantyEndAt ??
                      DateTime.now().add(const Duration(days: 365)));
              if (date != null) setState(() => warrantyEndAt = date);
            },
            child: Text(warrantyEndAt == null
                ? 'Choose explicit warranty end date *'
                : 'Warranty ends ${MaterialLocalizations.of(context).formatMediumDate(warrantyEndAt!)}'),
          ),
      ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<_CompletionFacts>(
        future: facts,
        builder: (context, snapshot) {
          final data = snapshot.data;
          return Column(children: [
            Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Expanded(
                      child: Text(
                          widget.handoff
                              ? 'Customer handoff'
                              : data?.decision == 'credit'
                                  ? 'Record supplier credit'
                                  : 'Receive supplier replacement',
                          style: theme.textTheme.titleLarge)),
                  IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed:
                          busy ? null : () => Navigator.pop(context, false)),
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
                          if (snapshot.hasError)
                            Text(safeMessage(snapshot.error!)),
                          if (!snapshot.hasData && !snapshot.hasError)
                            const Text('Loading claim facts...'),
                          if (data != null) ...[
                            if (data.originalSerial != null)
                              Text('Original serial: ${data.originalSerial}'),
                            if (widget.handoff) ...[
                              Text('Resolution: ${data.outcome ?? 'Recorded'}'),
                              Text(
                                  'Unit being released: ${data.supplierReplacementSerial ?? data.releasedSerial ?? data.originalSerial ?? 'Non-serialized item'}'),
                              Text(
                                  'Handoff date/time: ${DateTime.now().toLocal()}'),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: recipient,
                                  decoration: const InputDecoration(
                                      labelText: 'Recipient / customer *',
                                      border: OutlineInputBorder())),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: notes,
                                  maxLines: 2,
                                  decoration: const InputDecoration(
                                      labelText: 'Handoff notes (optional)',
                                      border: OutlineInputBorder())),
                              ...warrantyFields(context, supplier: false),
                            ] else if (data.decision == 'credit') ...[
                              const Text(
                                  'Supplier credit is business recovery and does not automatically refund the customer.'),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: value,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                  decoration: const InputDecoration(
                                      labelText: 'Credit amount received *',
                                      border: OutlineInputBorder())),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: reference,
                                  decoration: const InputDecoration(
                                      labelText: 'Supplier credit reference *',
                                      border: OutlineInputBorder())),
                            ] else if (data.decision == 'replacement') ...[
                              const Text(
                                  'Record the new physical serial. The original and replacement identities stay separate.'),
                              Text(
                                  'Original defective serial: ${data.originalSerial ?? 'Unknown'}'),
                              Text(
                                  'Destination: ${data.supplierCustomerWaiting ? 'Held for customer' : 'Store recovery inventory'}'),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: value,
                                  decoration: const InputDecoration(
                                      labelText: 'New replacement serial *',
                                      border: OutlineInputBorder())),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: reference,
                                  decoration: const InputDecoration(
                                      labelText: 'Supplier reference *',
                                      border: OutlineInputBorder())),
                              DropdownButtonFormField<String>(
                                  initialValue: replacementCondition,
                                  decoration: const InputDecoration(
                                      labelText: 'Condition'),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'new', child: Text('New')),
                                    DropdownMenuItem(
                                        value: 'good', child: Text('Good')),
                                  ],
                                  onChanged: (value) => setState(() =>
                                      replacementCondition = value ?? 'new')),
                              ...warrantyFields(context, supplier: true),
                            ] else if ({'repair', 'no_fault', 'rejected'}
                                .contains(data.decision)) ...[
                              Text(
                                  'Expected original serial: ${data.originalSerial ?? 'Unknown'}'),
                              TextField(
                                  controller: value,
                                  decoration: const InputDecoration(
                                      labelText: 'Returned original serial *',
                                      border: OutlineInputBorder())),
                              DropdownButtonFormField<String>(
                                  initialValue: condition,
                                  decoration: const InputDecoration(
                                      labelText: 'Condition'),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'good', child: Text('Good')),
                                    DropdownMenuItem(
                                        value: 'opened', child: Text('Opened')),
                                    DropdownMenuItem(
                                        value: 'damaged',
                                        child: Text('Damaged')),
                                  ],
                                  onChanged: (value) => setState(
                                      () => condition = value ?? 'good')),
                              TextField(
                                  controller: reference,
                                  decoration: const InputDecoration(
                                      labelText:
                                          'Supplier reference (optional)')),
                              TextField(
                                  controller: notes,
                                  maxLines: 2,
                                  decoration: const InputDecoration(
                                      labelText: 'Notes (optional)')),
                            ] else
                              const Text(
                                  'This supplier fulfillment path is unavailable.'),
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
                    child: OverflowBar(
                        alignment: MainAxisAlignment.end,
                        spacing: 8,
                        overflowSpacing: 8,
                        children: [
                          TextButton(
                              onPressed: busy
                                  ? null
                                  : () => Navigator.pop(context, false),
                              child: const Text('Cancel')),
                          FilledButton(
                              onPressed: busy ||
                                      data == null ||
                                      (!widget.handoff &&
                                          !{
                                            'credit',
                                            'replacement',
                                            'repair',
                                            'no_fault',
                                            'rejected'
                                          }.contains(data.decision))
                                  ? null
                                  : () => submit(data),
                              child: Text(busy
                                  ? 'Recording...'
                                  : widget.handoff
                                      ? 'Confirm customer handoff'
                                      : data?.decision == 'credit'
                                          ? 'Record supplier credit'
                                          : 'Receive replacement unit')),
                        ]))),
          ]);
        });
  }
}

class _CompletionFacts {
  final String? decision;
  final String? originalSerial;
  final String? releasedSerial;
  final String? reservedSerialId;
  final String? outcome;
  final String? supplierReplacementId;
  final String? supplierReplacementSerial;
  final bool supplierCustomerWaiting;
  const _CompletionFacts(
      this.decision,
      this.originalSerial,
      this.releasedSerial,
      this.reservedSerialId,
      this.outcome,
      this.supplierReplacementId,
      this.supplierReplacementSerial,
      this.supplierCustomerWaiting);
}
