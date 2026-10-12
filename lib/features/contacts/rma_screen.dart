import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/daos/rma_repository.dart';
import '../../data/daos/rma_lifecycle_repository.dart';
import '../../data/daos/sales_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/utils/money.dart';
import 'rma_detail_page.dart';
import 'new_customer_rma_page.dart';
import 'new_supplier_rma_page.dart';
import 'rma_physical_dialogs.dart';
import 'rma_resolution_dialog.dart';
import 'rma_completion_dialogs.dart';

class RmaScreen extends StatefulWidget {
  final RmaRepository repository;
  final ActiveUser user;
  final String? initialCaseId;
  const RmaScreen(
      {super.key,
      required this.repository,
      required this.user,
      this.initialCaseId});
  @override
  State<RmaScreen> createState() => _RmaScreenState();
}

class _RmaScreenState extends State<RmaScreen> {
  List<RmaCase> rows = [];
  final Map<String, String> stages = {};
  final Map<String, String> nextActions = {};
  final Map<String, String> summaries = {};
  final Map<String, String> parties = {};
  final Map<String, String> productTitles = {};
  final Map<String, String> serialLabels = {};
  final Map<String, String> receiptLabels = {};
  final Map<String, String> searchKeys = {};
  final Map<String, String> sourceLabels = {};
  final Map<String, String> linkedReferences = {};
  final Map<String, String> receivingReferences = {};
  String? error;
  String origin = 'customer';
  String filter = 'All';
  String searchText = '';
  final searchController = TextEditingController();

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    refresh();
    if (widget.initialCaseId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final row = (await widget.repository.cases())
            .where((r) => r.id == widget.initialCaseId)
            .firstOrNull;
        if (row != null && mounted) await showCaseDetail(row);
      });
    }
  }

  Future<void> refresh() async {
    try {
      final next = await widget.repository.cases();
      final lifecycle = RmaLifecycleRepository(widget.repository.db);
      final db = widget.repository.db;
      final customers = await db.select(db.customers).get();
      final suppliers = await db.select(db.suppliers).get();
      final sales = await db.select(db.sales).get();
      final saleItems = await db.select(db.saleItems).get();
      final receivingItems = await db.select(db.stockReceivingItems).get();
      final receivings = await db.select(db.stockReceivings).get();
      final products = await db.select(db.products).get();
      final serials = await db.select(db.serialUnits).get();
      final newStages = <String, String>{};
      final newActions = <String, String>{};
      final newSummaries = <String, String>{};
      final newParties = <String, String>{};
      final newProducts = <String, String>{};
      final newSerialLabels = <String, String>{};
      final newReceiptLabels = <String, String>{};
      final customersById = {for (final value in customers) value.id: value};
      final suppliersById = {for (final value in suppliers) value.id: value};
      final salesById = {for (final value in sales) value.id: value};
      final saleItemsById = {for (final value in saleItems) value.id: value};
      final receivingItemsById = {
        for (final value in receivingItems) value.id: value
      };
      final receivingsById = {for (final value in receivings) value.id: value};
      final productsById = {for (final value in products) value.id: value};
      final serialsById = {for (final value in serials) value.id: value};
      final casesById = {for (final value in next) value.id: value};
      final newSearchKeys = <String, String>{};
      final newSourceLabels = <String, String>{};
      final newLinkedReferences = <String, String>{};
      final newReceivingReferences = <String, String>{};
      for (final row in next) {
        final customer = customersById[row.customerId];
        final supplier = suppliersById[row.supplierId];
        final sale = salesById[row.saleId];
        final saleItem = saleItemsById[row.saleItemId];
        final receivingItem = receivingItemsById[row.receivingItemId];
        final product =
            productsById[saleItem?.productId ?? receivingItem?.productId];
        final serial = serialsById[row.serialUnitId];
        final party = row.origin == 'inbound'
            ? supplier?.name ?? 'Supplier'
            : customer?.name ?? 'Walk-in customer';
        final productName = saleItem?.productName ?? product?.name ?? 'Item';
        newParties[row.id] = party;
        newProducts[row.id] = productName;
        if (serial != null) newSerialLabels[row.id] = serial.serialNumber;
        if (sale != null) {
          newReceiptLabels[row.id] = sale.receiptNumber == null
              ? 'Legacy sale'
              : 'Receipt #${sale.receiptNumber}';
        }
        newSummaries[row.id] = '$party · $productName'
            '${serial == null ? '' : ' · Serial ${serial.serialNumber}'}';
        newSearchKeys[row.id] =
            '${row.reference} $party ${customer?.phone ?? ''} '
            '${sale?.receiptNumber ?? ''} ${sale?.birInvoiceNumber ?? ''} $productName ${product?.sku ?? ''} '
            '${product?.barcode ?? ''} ${serial?.serialNumber ?? ''} '
            '${row.issueDescription}';
        final facts = await lifecycle.history(row.id);
        if (row.origin == 'inbound') {
          final receiving = receivingsById[row.receivingId];
          final receivingRef = receiving?.externalReference?.trim();
          if (receivingRef != null && receivingRef.isNotEmpty) {
            newReceivingReferences[row.id] = receivingRef;
            newSearchKeys[row.id] = '${newSearchKeys[row.id]} $receivingRef';
          }
          final linkedId = facts
              .where((e) => e.relatedCaseId != null)
              .firstOrNull
              ?.relatedCaseId;
          final linked = casesById[linkedId];
          newSourceLabels[row.id] =
              linked == null ? 'Inventory / Receiving' : 'Customer RMA';
          if (linked != null) newLinkedReferences[row.id] = linked.reference;
        }
        final action = await lifecycle.nextAction(row.id);
        newActions[row.id] = action;
        final names = facts.map((fact) => fact.action).toSet();
        final received = facts
            .where((fact) => fact.action == 'received')
            .fold<int>(0, (sum, fact) => sum + (fact.quantityMilli ?? 0));
        final inspected = facts
            .where((fact) => fact.action == 'inspected')
            .fold<int>(0, (sum, fact) => sum + (fact.quantityMilli ?? 0));
        newStages[row.id] = facts.isEmpty
            ? 'Legacy'
            : names.contains('cancelled')
                ? row.origin == 'inbound'
                    ? 'Cancelled'
                    : 'Rejected / Cancelled'
                : names.contains('rejected') || row.status == 'rejected'
                    ? row.origin == 'inbound'
                        ? 'Rejected'
                        : 'Rejected / Cancelled'
                    : row.origin == 'inbound'
                        ? names.contains('completed') ||
                                names.contains('supplier_fulfilled')
                            ? 'Resolved'
                            : names.contains('supplier_decision')
                                ? 'Fulfillment pending'
                                : names.contains('supplier_requested')
                                    ? 'Awaiting supplier'
                                    : names.contains('supplier_intake')
                                        ? 'Ready to send'
                                        : 'Requested'
                        : names.contains('completed')
                            ? 'Completed'
                            : !names.contains('approved')
                                ? 'Awaiting approval'
                                : received < row.quantityMilli
                                    ? 'Awaiting receipt'
                                    : inspected < row.quantityMilli
                                        ? 'Awaiting inspection'
                                        : !names.contains('intent')
                                            ? 'Awaiting resolution'
                                            : action.contains('supplier') ||
                                                    action.contains('Supplier')
                                                ? 'Awaiting supplier'
                                                : action.startsWith('Hand')
                                                    ? 'Ready for handoff'
                                                    : 'Awaiting resolution';
      }
      if (mounted) {
        setState(() {
          rows = next;
          stages
            ..clear()
            ..addAll(newStages);
          nextActions
            ..clear()
            ..addAll(newActions);
          summaries
            ..clear()
            ..addAll(newSummaries);
          parties
            ..clear()
            ..addAll(newParties);
          productTitles
            ..clear()
            ..addAll(newProducts);
          serialLabels
            ..clear()
            ..addAll(newSerialLabels);
          receiptLabels
            ..clear()
            ..addAll(newReceiptLabels);
          searchKeys
            ..clear()
            ..addAll(newSearchKeys);
          sourceLabels
            ..clear()
            ..addAll(newSourceLabels);
          linkedReferences
            ..clear()
            ..addAll(newLinkedReferences);
          receivingReferences
            ..clear()
            ..addAll(newReceivingReferences);
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  Future<void> create(String origin) async {
    if (origin != 'customer' && origin != 'inbound') return;
    final wizard = origin == 'customer'
        ? NewCustomerRmaPage(repository: widget.repository, user: widget.user)
        : NewSupplierRmaPage(repository: widget.repository, user: widget.user);
    final size = MediaQuery.sizeOf(context);
    final RmaCase? row;
    if (size.width < 600) {
      row = await Navigator.of(context)
          .push<RmaCase>(MaterialPageRoute(builder: (_) => wizard));
    } else {
      row = await showDialog<RmaCase>(
          context: context,
          builder: (_) => Dialog(
                insetPadding: const EdgeInsets.all(24),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                    width: 900, height: size.height - 48, child: wizard),
              ));
    }
    if (row != null && mounted) {
      await refresh();
      if (mounted) await showCaseDetail(row);
    }
  }

  Future<void> advance(RmaCase row) async {
    if ((await RmaLifecycleRepository(widget.repository.db).history(row.id))
        .isNotEmpty) {
      await advanceLifecycle(row);
      return;
    }
    final note = TextEditingController();
    String? resolution;
    String? replacementSerialId;
    final replacementSerials =
        await widget.repository.availableReplacementSerials(row.id);
    ItemRefundQuote? refundQuote;
    if (row.origin == 'customer') {
      try {
        refundQuote =
            await SalesRepository(widget.repository.db).quoteItemRefund(row.id);
      } on StateError {
        // Other resolutions remain available for unsupported sale modes.
      }
    }
    final saleItem = row.saleItemId == null
        ? null
        : (await widget.repository.db
                .select(widget.repository.db.saleItems)
                .get())
            .where((i) => i.id == row.saleItemId)
            .firstOrNull;
    if (!mounted) return;
    String? disposition;
    bool payCashNow = row.customerId == null;
    String status = row.status == 'pending' ? 'sent_to_supplier' : 'resolved';
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: Text(row.reference),
                    content: SizedBox(
                        width: 400,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              DropdownButtonFormField<String>(
                                  initialValue: status,
                                  items: [
                                    if (row.status == 'pending')
                                      const DropdownMenuItem(
                                          value: 'sent_to_supplier',
                                          child: Text('Sent to supplier')),
                                    const DropdownMenuItem(
                                        value: 'resolved',
                                        child: Text('Resolved')),
                                    const DropdownMenuItem(
                                        value: 'rejected',
                                        child: Text('Rejected')),
                                  ],
                                  onChanged: (value) =>
                                      update(() => status = value ?? status)),
                              if (status == 'resolved' &&
                                  row.origin == 'customer')
                                DropdownButtonFormField<String>(
                                    decoration: const InputDecoration(
                                        labelText: 'Customer resolution'),
                                    items: [
                                      DropdownMenuItem(
                                          value: 'repaired_return',
                                          child: Text('Return repaired item')),
                                      DropdownMenuItem(
                                          value: 'same_item_replacement',
                                          child: Text('Replace same item')),
                                      if (refundQuote != null)
                                        const DropdownMenuItem(
                                            value: 'refund',
                                            child: Text('Refund item')),
                                    ],
                                    onChanged: (value) =>
                                        update(() => resolution = value)),
                              if (status == 'resolved' &&
                                  resolution == 'refund' &&
                                  refundQuote != null) ...[
                                Text(
                                    'Refund item: ${saleItem?.productName ?? 'Item'}'),
                                Text(
                                    'Refund quantity: ${Quantity.format(refundQuote.quantityMilli)}'),
                                Text(
                                    'Refund amount: ${formatPeso(refundQuote.amountCents)}'),
                                Text(
                                    'Receivable reduction: ${formatPeso(refundQuote.receivableReductionCents)}'),
                                Text(
                                    'Refund owed: ${formatPeso(refundQuote.dueCents)}'),
                                CheckboxListTile(
                                    title: const Text(
                                        'Pay refund now from drawer'),
                                    value: payCashNow,
                                    onChanged: row.customerId == null
                                        ? null
                                        : (value) => update(
                                            () => payCashNow = value ?? false)),
                              ],
                              if (status == 'resolved' &&
                                  resolution == 'same_item_replacement' &&
                                  replacementSerials.isNotEmpty)
                                DropdownButtonFormField<String>(
                                    decoration: const InputDecoration(
                                        labelText: 'Replacement serial'),
                                    items: replacementSerials
                                        .map((serial) => DropdownMenuItem(
                                            value: serial.id,
                                            child: Text(serial.serialNumber)))
                                        .toList(),
                                    onChanged: (value) => update(
                                        () => replacementSerialId = value)),
                              if (status == 'resolved' || status == 'rejected')
                                DropdownButtonFormField<String>(
                                    decoration: const InputDecoration(
                                        labelText: 'Unit disposition'),
                                    items: [
                                      const DropdownMenuItem(
                                          value: 'restock',
                                          child: Text('Restock')),
                                      const DropdownMenuItem(
                                          value: 'scrap', child: Text('Scrap')),
                                      const DropdownMenuItem(
                                          value: 'return_to_supplier',
                                          child: Text('Return to supplier')),
                                      if (row.origin == 'customer')
                                        const DropdownMenuItem(
                                            value: 'return_to_customer',
                                            child: Text('Return to customer')),
                                    ],
                                    onChanged: (value) =>
                                        update(() => disposition = value)),
                              TextField(
                                  controller: note,
                                  decoration: const InputDecoration(
                                      labelText: 'Event note')),
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(
                              status == 'resolved' && resolution == 'refund'
                                  ? 'Confirm refund'
                                  : 'Record event')),
                    ],
                  )));
      if (confirmed != true) return;
      await widget.repository.transition(widget.user, row.id, status,
          note: note.text,
          customerResolution: resolution,
          unitDisposition: disposition,
          replacementSerialUnitId: replacementSerialId,
          payCashNow: resolution == 'refund' && payCashNow);
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      note.dispose();
    }
  }

  Future<void> advanceLifecycle(RmaCase row) async {
    final lifecycle = RmaLifecycleRepository(widget.repository.db);
    final action = await lifecycle.nextAction(row.id);
    if (action == 'Send to supplier' || action == 'Send item to supplier') {
      await sendSupplierDialog(row);
      return;
    }
    if (action == 'Resolve rejected item') {
      await resolveReturnedSupplier(row);
      return;
    }
    if (action == 'Approve claim') {
      if (!mounted) return;
      final note = TextEditingController();
      String? decision;
      try {
        decision = await showDialog<String>(
            context: context,
            builder: (dialogContext) => StatefulBuilder(
                builder: (dialogContext, update) => AlertDialog(
                      title: const Text('Review claim'),
                      content: SizedBox(
                          width: 480,
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Source: ${row.reference}'),
                                Text('Reported issue: ${row.issueDescription}'),
                                const SizedBox(height: 12),
                                TextField(
                                    controller: note,
                                    onChanged: (_) => update(() {}),
                                    maxLines: 2,
                                    decoration: InputDecoration(
                                        labelText: decision == 'reject'
                                            ? 'Rejection reason *'
                                            : 'Approval note (optional)')),
                              ])),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('Cancel')),
                        OutlinedButton(
                            onPressed: () {
                              if (decision != 'reject') {
                                update(() => decision = 'reject');
                              } else if (note.text.trim().isNotEmpty) {
                                Navigator.pop(dialogContext, 'reject');
                              }
                            },
                            child: Text(decision == 'reject'
                                ? 'Confirm rejection'
                                : 'Reject claim')),
                        FilledButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, 'approve'),
                            child: const Text('Approve claim')),
                      ],
                    )));
        if (decision == 'approve') {
          await lifecycle.approve(widget.user, row.id, note: note.text);
          await refresh();
        } else if (decision == 'reject') {
          await lifecycle.reject(widget.user, row.id, note.text);
          await refresh();
        }
      } catch (failure) {
        if (mounted) setState(() => error = safeMessage(failure));
      } finally {
        note.dispose();
      }
      return;
    }
    if (action == 'Receive returned item' ||
        action == 'Inspect returned item') {
      if (!mounted) return;
      final changed = await showRmaPhysicalDialog(context,
          repository: widget.repository,
          user: widget.user,
          row: row,
          inspection: action == 'Inspect returned item');
      if (changed) await refresh();
      return;
    }
    if (action == 'Choose resolution') {
      if (!mounted) return;
      final changed = await showRmaResolutionDialog(context,
          repository: widget.repository, user: widget.user, row: row);
      if (changed) await refresh();
      return;
    }
    if (action == 'Record supplier fulfillment' ||
        action == 'Hand replacement to customer' ||
        action == 'Hand supplier replacement to customer' ||
        action == 'Hand repaired item to customer' ||
        action == 'Hand returned item to customer' ||
        action == 'Hand item to customer') {
      if (!mounted) return;
      final changed = await showRmaCompletionDialog(context,
          repository: widget.repository,
          user: widget.user,
          row: row,
          handoff: action != 'Record supplier fulfillment');
      if (changed) await refresh();
      return;
    }
    final actionFacts = await lifecycle.history(row.id);
    final receivedQuantity = actionFacts
        .where((event) => event.action == 'received')
        .fold<int>(0, (sum, event) => sum + (event.quantityMilli ?? 0));
    final inspectedQuantity = actionFacts
        .where((event) => event.action == 'inspected')
        .fold<int>(0, (sum, event) => sum + (event.quantityMilli ?? 0));
    final value = TextEditingController();
    final detail = TextEditingController();
    final note = TextEditingController();
    final finding = TextEditingController();
    final overrideReason = TextEditingController();
    final expectedSerial = row.serialUnitId == null
        ? null
        : (await widget.repository.db
                .select(widget.repository.db.serialUnits)
                .get())
            .where((serial) => serial.id == row.serialUnitId)
            .firstOrNull
            ?.serialNumber;
    final supplierOutcome = action == 'Record supplier fulfillment'
        ? (await lifecycle.history(row.id))
            .where((event) => event.action == 'supplier_decision')
            .lastOrNull
            ?.outcome
        : null;
    String? decision;
    String? disposition;
    String refundMethod = row.customerId == null ? 'cash' : 'obligation';
    bool fault = false;
    String? inspectionCondition;
    ItemRefundQuote? resolutionQuote;
    if (action == 'Choose resolution') {
      try {
        resolutionQuote =
            await SalesRepository(widget.repository.db).quoteItemRefund(row.id);
      } on StateError {
        // Refund is only offered for supported sale modes.
      }
    }
    if (!mounted) return;
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: Text('${row.reference} · $action'),
                    content: SizedBox(
                        width: 480,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              if (action == 'Approve claim')
                                DropdownButtonFormField<String>(
                                    decoration: const InputDecoration(
                                        labelText: 'Decision'),
                                    items: const [
                                      DropdownMenuItem(
                                          value: 'approve',
                                          child: Text('Approve')),
                                      DropdownMenuItem(
                                          value: 'reject',
                                          child: Text('Reject')),
                                      DropdownMenuItem(
                                          value: 'cancel',
                                          child: Text('Cancel')),
                                    ],
                                    onChanged: (v) => update(() {
                                          decision = v;
                                          disposition = null;
                                        })),
                              if (action == 'Receive returned item') ...[
                                Text(
                                    'Approved quantity: ${Quantity.format(row.quantityMilli)}'),
                                TextField(
                                    controller: value,
                                    decoration: const InputDecoration(
                                        labelText: 'Received quantity')),
                                if (row.serialUnitId != null)
                                  TextField(
                                      controller: detail,
                                      decoration: const InputDecoration(
                                          labelText:
                                              'Physical returned serial'),
                                      onChanged: (_) => update(() {})),
                                if (expectedSerial != null)
                                  Text('Expected serial: $expectedSerial'),
                                if (expectedSerial != null &&
                                    detail.text.trim().isNotEmpty &&
                                    detail.text.trim() != expectedSerial) ...[
                                  const Text(
                                      'Serial mismatch. Expected and returned identities remain distinct.'),
                                  TextField(
                                      controller: overrideReason,
                                      decoration: const InputDecoration(
                                          labelText:
                                              'Owner override reason *')),
                                ],
                                const Text(
                                    'Receipt creates store custody. This item is not sellable inventory yet.'),
                              ],
                              if (action == 'Approve claim' &&
                                  decision == 'reject')
                                const Text(
                                    'Rejecting the request keeps it in history. Enter a reason below.'),
                              if (action == 'Inspect returned item') ...[
                                Text(
                                    'Customer reported: ${row.issueDescription}'),
                                const SizedBox(height: 8),
                                const Text(
                                    'Only physically received quantities can be inspected.'),
                                Text(
                                    'Received: ${Quantity.format(receivedQuantity)}  ·  '
                                    'Already inspected: ${Quantity.format(inspectedQuantity)}'),
                                if (expectedSerial != null)
                                  Text('Exact sold serial: $expectedSerial'),
                                TextField(
                                    controller: value,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    decoration: const InputDecoration(
                                        labelText: 'Inspect quantity *'),
                                    onChanged: (_) => update(() {})),
                                DropdownButtonFormField<String>(
                                    initialValue: inspectionCondition,
                                    decoration: const InputDecoration(
                                        labelText: 'Condition *'),
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
                                        .map((condition) => DropdownMenuItem(
                                            value: condition
                                                .toLowerCase()
                                                .replaceAll(' ', '_'),
                                            child: Text(condition)))
                                        .toList(),
                                    onChanged: (condition) => update(
                                        () => inspectionCondition = condition)),
                                CheckboxListTile(
                                    title: const Text('Fault reproduced'),
                                    value: fault,
                                    onChanged: (v) =>
                                        update(() => fault = v ?? false)),
                                TextField(
                                    controller: finding,
                                    decoration: const InputDecoration(
                                        labelText: 'Inspection finding *')),
                                if (Quantity.tryParse(value.text,
                                            fractional: true) ==
                                        null ||
                                    Quantity.tryParse(value.text,
                                            fractional: true)! <=
                                        0)
                                  const Text('Enter a quantity to inspect.'),
                                if ((Quantity.tryParse(value.text,
                                            fractional: true) ??
                                        0) >
                                    receivedQuantity - inspectedQuantity)
                                  const Text(
                                      'Quantity exceeds received items awaiting inspection.'),
                                if (inspectionCondition == null)
                                  const Text('Choose a condition.'),
                              ],
                              if (action == 'Choose resolution') ...[
                                DropdownButtonFormField<String>(
                                    decoration: const InputDecoration(
                                        labelText: 'Customer outcome'),
                                    items: [
                                      if (resolutionQuote != null)
                                        const DropdownMenuItem(
                                            value: 'refund',
                                            child: Text('Refund')),
                                      const DropdownMenuItem(
                                          value: 'replacement',
                                          child: Text('Replacement')),
                                      const DropdownMenuItem(
                                          value: 'no_fault',
                                          child: Text('No fault found')),
                                    ],
                                    onChanged: (v) => update(() {
                                          decision = v;
                                          disposition = null;
                                        })),
                                DropdownButtonFormField<String>(
                                    key: ValueKey(decision),
                                    decoration: const InputDecoration(
                                        labelText: 'Physical disposition'),
                                    items: [
                                      if (decision != 'no_fault') ...const [
                                        DropdownMenuItem(
                                            value: 'restock',
                                            child: Text('Restock')),
                                        DropdownMenuItem(
                                            value: 'scrap',
                                            child: Text('Scrap')),
                                        DropdownMenuItem(
                                            value: 'supplier',
                                            child: Text('Send to supplier')),
                                      ],
                                      if (decision == 'no_fault')
                                        const DropdownMenuItem(
                                            value: 'return_to_customer',
                                            child: Text('Return to customer')),
                                    ],
                                    onChanged: (v) =>
                                        update(() => disposition = v)),
                                if (decision == 'refund')
                                  Text(
                                      'Authorized amount: ${formatPeso(resolutionQuote!.amountCents)}'),
                                if (decision == 'refund')
                                  DropdownButtonFormField<String>(
                                      initialValue: refundMethod,
                                      decoration: const InputDecoration(
                                          labelText: 'Refund method'),
                                      items: [
                                        const DropdownMenuItem(
                                            value: 'cash',
                                            child: Text('Cash from drawer')),
                                        if (row.customerId != null)
                                          const DropdownMenuItem(
                                              value: 'obligation',
                                              child: Text(
                                                  'Customer refund obligation')),
                                      ],
                                      onChanged: (v) => update(() =>
                                          refundMethod = v ?? refundMethod)),
                              ],
                              if (action == 'Reserve replacement')
                                FutureBuilder<List<SerialUnit>>(
                                    future: widget.repository
                                        .availableReplacementSerials(row.id),
                                    builder: (context, snapshot) =>
                                        DropdownButtonFormField<String>(
                                            decoration: const InputDecoration(
                                                labelText:
                                                    'Exact replacement serial'),
                                            items: [
                                              for (final serial
                                                  in snapshot.data ??
                                                      <SerialUnit>[])
                                                DropdownMenuItem(
                                                    value: serial.id,
                                                    child: Text(
                                                        serial.serialNumber))
                                            ],
                                            onChanged: (v) =>
                                                update(() => decision = v))),
                              if (action == 'Record supplier decision')
                                DropdownButtonFormField<String>(
                                    decoration: const InputDecoration(
                                        labelText: 'Supplier decision'),
                                    items: [
                                      if (row.serialUnitId != null)
                                        const DropdownMenuItem(
                                            value: 'repair',
                                            child: Text('Repaired original')),
                                      const DropdownMenuItem(
                                          value: 'credit',
                                          child: Text('Credit')),
                                      if (row.serialUnitId != null)
                                        const DropdownMenuItem(
                                            value: 'replacement',
                                            child: Text('Replacement')),
                                      if (row.serialUnitId != null)
                                        const DropdownMenuItem(
                                            value: 'no_fault',
                                            child: Text('No fault found')),
                                      if (row.serialUnitId != null)
                                        const DropdownMenuItem(
                                            value: 'rejected',
                                            child: Text('Rejected')),
                                    ],
                                    onChanged: (v) =>
                                        update(() => decision = v)),
                              if (action == 'Record supplier decision')
                                const Text(
                                    'Recording the supplier decision does not receive inventory or automatically resolve the customer claim.'),
                              if (action == 'Record supplier fulfillment')
                                TextField(
                                    controller: value,
                                    decoration: InputDecoration(
                                        labelText: supplierOutcome == 'credit'
                                            ? 'Credit received (peso)'
                                            : 'New replacement serial')),
                              if (action == 'Hand replacement to customer' ||
                                  action == 'Hand item to customer')
                                TextField(
                                    controller: value,
                                    decoration: const InputDecoration(
                                        labelText: 'Recipient')),
                              TextField(
                                  controller: note,
                                  decoration: InputDecoration(
                                      labelText: action == 'Approve claim' &&
                                              decision != 'approve'
                                          ? 'Reason *'
                                          : 'Note (optional)')),
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Back')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(switch (action) {
                            'Approve claim' => 'Record decision',
                            'Receive returned item' => 'Receive item',
                            'Inspect returned item' => 'Complete inspection',
                            'Choose resolution' => 'Authorize resolution',
                            'Complete refund' => 'Record refund completion',
                            'Hand replacement to customer' ||
                            'Hand item to customer' =>
                              'Confirm handoff',
                            _ => action,
                          })),
                    ],
                  )));
      if (confirmed != true) return;
      switch (action) {
        case 'Approve claim':
          if (decision == 'approve') {
            await lifecycle.approve(widget.user, row.id, note: note.text);
          } else if (decision == 'reject') {
            await lifecycle.reject(widget.user, row.id, note.text);
          } else if (decision == 'cancel') {
            await lifecycle.cancel(widget.user, row.id, note.text);
          } else {
            throw StateError('Choose a decision');
          }
        case 'Receive returned item':
          final quantity = Quantity.tryParse(value.text, fractional: true);
          if (quantity == null) throw StateError('Enter received quantity');
          await lifecycle.receive(widget.user, row.id, quantity,
              returnedSerial: detail.text,
              overrideReason: overrideReason.text,
              note: note.text);
        case 'Inspect returned item':
          final quantity = Quantity.tryParse(value.text, fractional: true);
          if (quantity == null || quantity <= 0) {
            throw StateError('Enter a quantity to inspect');
          }
          if (inspectionCondition == null) {
            throw StateError('Choose a condition');
          }
          await lifecycle.inspect(widget.user, row.id, quantity,
              inspectionCondition!, fault, finding.text,
              note: note.text);
        case 'Choose resolution':
          if (decision == null || disposition == null) {
            throw StateError('Choose outcome and disposition');
          }
          final amount =
              decision == 'refund' ? resolutionQuote?.amountCents : null;
          await lifecycle.authorize(
              widget.user, row.id, decision!, disposition!,
              amountCents: amount, method: refundMethod, note: note.text);
        case 'Complete refund':
          final events = await lifecycle.history(row.id);
          final intent = events.firstWhere((e) => e.action == 'intent');
          await lifecycle.executeRefund(widget.user, row.id,
              payCashNow: intent.method == 'cash');
        case 'Settle refund obligation':
          await lifecycle.confirmRefundSettled(widget.user, row.id);
        case 'Execute physical disposition':
          await lifecycle.executeDisposition(widget.user, row.id);
        case 'Reserve replacement':
          if (decision == null) throw StateError('Select replacement serial');
          await lifecycle.reserveReplacement(widget.user, row.id, decision!);
        case 'Send item to supplier':
          await lifecycle.sendToSupplier(widget.user, row.id, note: note.text);
        case 'Send to supplier':
          await lifecycle.sendDirectSupplier(widget.user, row.id,
              note: note.text);
        case 'Record supplier decision':
          if (decision == null) throw StateError('Choose supplier decision');
          await lifecycle.supplierDecision(widget.user, row.id, decision!,
              note: note.text);
        case 'Record supplier fulfillment':
          final events = await lifecycle.history(row.id);
          final decision =
              events.firstWhere((e) => e.action == 'supplier_decision').outcome;
          if (decision == 'credit') {
            final amount = tryParsePeso(value.text);
            if (amount == null) {
              throw StateError('Enter the credit received in pesos');
            }
            await lifecycle.supplierCredit(
                widget.user, row.id, amount, note.text);
          } else if (decision == 'replacement') {
            await lifecycle.supplierReplacement(widget.user, row.id, value.text,
                reference: note.text);
          } else {
            throw StateError(
                'This supplier fulfillment requires further support');
          }
        case 'Hand replacement to customer':
          final events = await lifecycle.history(row.id);
          final serial = events
              .where((e) => e.action == 'replacement_reserved')
              .last
              .serialUnitId;
          await lifecycle.handoff(widget.user, row.id, value.text,
              serialUnitId: serial, note: note.text);
        case 'Hand item to customer':
          await lifecycle.handoff(widget.user, row.id, value.text,
              serialUnitId: row.serialUnitId, note: note.text);
        default:
          throw StateError('Action requires further workflow support');
      }
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      value.dispose();
      detail.dispose();
      note.dispose();
      finding.dispose();
      overrideReason.dispose();
    }
  }

  Future<void> sendSupplierDialog(RmaCase row) async {
    final db = widget.repository.db;
    final lifecycle = RmaLifecycleRepository(db);
    RmaCase supplierCase = row;
    if (row.origin == 'customer') {
      final link = (await lifecycle.history(row.id))
          .where((e) => e.action == 'supplier_claim_opened')
          .lastOrNull;
      if (link?.relatedCaseId == null) return;
      supplierCase = (await db.select(db.rmaCases).get())
          .singleWhere((e) => e.id == link!.relatedCaseId);
    }
    final supplier = (await db.select(db.suppliers).get())
        .where((e) => e.id == supplierCase.supplierId)
        .firstOrNull;
    final source = (await db.select(db.stockReceivingItems).get())
        .where((e) => e.id == supplierCase.receivingItemId)
        .firstOrNull;
    final product = (await db.select(db.products).get())
        .where((e) => e.id == source?.productId)
        .firstOrNull;
    final serial = (await db.select(db.serialUnits).get())
        .where((e) => e.id == supplierCase.serialUnitId)
        .firstOrNull;
    final reference = TextEditingController();
    final note = TextEditingController();
    try {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                title: const Text('Send item to supplier'),
                content: SizedBox(
                    width: 490,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('SRMA: ${supplierCase.reference}'),
                        Text('Supplier: ${supplier?.name ?? 'Unknown'}'),
                        Text('Product: ${product?.name ?? 'Unknown'}'),
                        Text(serial == null
                            ? 'Quantity: ${Quantity.format(supplierCase.quantityMilli)}'
                            : 'Serial: ${serial.serialNumber}'),
                        const Text('Current custody: Store'),
                        Text(
                            'Send date: ${MaterialLocalizations.of(dialogContext).formatMediumDate(DateTime.now())}'),
                        TextField(
                            controller: reference,
                            decoration: const InputDecoration(
                                labelText:
                                    'Supplier / external RMA reference (optional)')),
                        TextField(
                            controller: note,
                            maxLines: 2,
                            decoration: const InputDecoration(
                                labelText: 'Notes (optional)')),
                      ],
                    )),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Confirm sent to supplier')),
                ],
              ));
      if (confirmed != true) return;
      if ((await lifecycle.history(supplierCase.id))
          .any((e) => e.action == 'supplier_created')) {
        await lifecycle.sendLinkedSupplier(widget.user, supplierCase.id,
            supplierReference: reference.text, note: note.text);
      } else {
        await lifecycle.sendDirectSupplier(widget.user, supplierCase.id,
            note: [reference.text, note.text]
                .where((e) => e.trim().isNotEmpty)
                .join(' · '));
      }
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      reference.dispose();
      note.dispose();
    }
  }

  Future<void> resolveReturnedSupplier(RmaCase row) async {
    final lifecycle = RmaLifecycleRepository(widget.repository.db);
    final supplierFacts = await lifecycle.history(row.id);
    final customerId = supplierFacts
        .where((e) => e.action == 'supplier_created')
        .lastOrNull
        ?.relatedCaseId;
    final customerFacts = customerId == null
        ? <RmaLifecycleEvent>[]
        : await lifecycle.history(customerId);
    final waiting = customerFacts.any(
            (e) => e.action == 'intent' && e.outcome == 'supplier_warranty') &&
        !customerFacts.any((e) => e.action == 'completed');
    String disposition = waiting ? 'return_to_customer' : 'hold';
    final note = TextEditingController();
    try {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
              builder: (dialogContext, update) => AlertDialog(
                    title: const Text('Resolve supplier-returned item'),
                    content: SizedBox(
                        width: 450,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(waiting
                                ? 'The customer is still waiting. Return the exact original item to the customer.'
                                : 'Record what happens to the returned business item.'),
                            DropdownButtonFormField<String>(
                              initialValue: disposition,
                              decoration: const InputDecoration(
                                  labelText: 'Disposition'),
                              items: waiting
                                  ? const [
                                      DropdownMenuItem(
                                          value: 'return_to_customer',
                                          child: Text('Return to customer'))
                                    ]
                                  : const [
                                      DropdownMenuItem(
                                          value: 'hold', child: Text('Hold')),
                                      DropdownMenuItem(
                                          value: 'scrap', child: Text('Scrap')),
                                      DropdownMenuItem(
                                          value: 'restock',
                                          child: Text('Restock if eligible')),
                                    ],
                              onChanged: (value) => update(
                                  () => disposition = value ?? disposition),
                            ),
                            TextField(
                                controller: note,
                                maxLines: 2,
                                decoration: const InputDecoration(
                                    labelText: 'Notes (optional)')),
                          ],
                        )),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('Record disposition')),
                    ],
                  )));
      if (confirmed != true) return;
      await lifecycle.supplierReturnedDisposition(
          widget.user, row.id, disposition,
          note: note.text);
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      note.dispose();
    }
  }

  Future<void> receiveReplacement(RmaCase row) async {
    final serial = TextEditingController();
    final batch = TextEditingController();
    final expiry = TextEditingController();
    final reference = TextEditingController();
    final notes = TextEditingController();
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text('Supplier replacement · ${row.reference}'),
                content: SizedBox(
                    width: 420,
                    child: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                          'Receive ${Quantity.format(row.quantityMilli)} replacement units. Available stock increases once.'),
                      TextField(
                          controller: serial,
                          decoration: const InputDecoration(
                              labelText: 'New serial (if serialized)')),
                      TextField(
                          controller: batch,
                          decoration: const InputDecoration(
                              labelText: 'Replacement batch (if tracked)')),
                      TextField(
                          controller: expiry,
                          decoration: const InputDecoration(
                              labelText: 'Expiry YYYY-MM-DD (if tracked)')),
                      TextField(
                          controller: reference,
                          decoration: const InputDecoration(
                              labelText: 'Supplier reference')),
                      TextField(
                          controller: notes,
                          decoration:
                              const InputDecoration(labelText: 'Notes')),
                    ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Record replacement')),
                ],
              ));
      if (confirmed != true) return;
      DateTime? expiryDate;
      if (expiry.text.trim().isNotEmpty) {
        expiryDate = DateTime.tryParse(expiry.text.trim());
        if (expiryDate == null ||
            expiryDate.toIso8601String().substring(0, 10) !=
                expiry.text.trim()) {
          throw StateError('Use YYYY-MM-DD for expiry');
        }
      }
      await widget.repository.receiveSupplierReplacement(widget.user, row.id,
          serialNumber: serial.text.trim().isEmpty ? null : serial.text.trim(),
          batchNumber: batch.text.trim().isEmpty ? null : batch.text.trim(),
          expiryDate: expiryDate,
          supplierReference: reference.text,
          notes: notes.text);
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      serial.dispose();
      batch.dispose();
      expiry.dispose();
      reference.dispose();
      notes.dispose();
    }
  }

  Future<void> showCaseDetail(RmaCase row) async {
    final page = RmaDetailPage(
      row: row,
      repository: widget.repository,
      user: widget.user,
      onAction: () => advance(row),
      onRefresh: refresh,
      onRelease: () => RmaLifecycleRepository(widget.repository.db)
          .releaseReplacement(widget.user, row.id),
      onSendToSupplier: () => sendSupplierDialog(row),
      onDisposition: () => RmaLifecycleRepository(widget.repository.db)
          .executeDisposition(widget.user, row.id),
      onSupplierDisposition: () => resolveReturnedSupplier(row),
      onOpenRelated: showCaseDetail,
    );
    final size = MediaQuery.sizeOf(context);
    if (size.width < 600) {
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => page));
    } else {
      await showDialog<void>(
          context: context,
          builder: (_) => Dialog(
                insetPadding: const EdgeInsets.all(24),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                    width: (size.width - 48).clamp(0.0, 1600.0),
                    height: size.height - 48,
                    child: page),
              ));
    }
    await refresh();
  }

  String ageLabel(RmaCase row) {
    final days = DateTime.now().difference(row.createdAt).inDays;
    if (days <= 0) return 'Today';
    return '$days ${days == 1 ? 'day' : 'days'}';
  }

  Widget metricTiles(BuildContext context) {
    final customer = origin == 'customer';
    final metrics = <(String, String)>[
      ('Open', 'Open'),
      if (customer) ...[
        ('Approval', 'Awaiting approval'),
        ('Receipt', 'Awaiting receipt'),
        ('Inspection', 'Awaiting inspection'),
        ('Resolution', 'Awaiting resolution'),
        ('Supplier', 'Awaiting supplier'),
        ('Handoff', 'Ready for handoff'),
      ] else ...[
        ('Ready to send', 'Ready to send'),
        ('Awaiting supplier', 'Awaiting supplier'),
        ('Fulfillment pending', 'Fulfillment pending'),
        ('Resolved', 'Resolved'),
      ],
    ];
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('rma-status-strip'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(spacing: 4, runSpacing: 2, children: [
        for (final metric in metrics)
          TextButton(
            onPressed: metric.$2 == 'Open'
                ? () => setState(() => filter = 'All')
                : () => setState(() => filter = metric.$2),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              minimumSize: const Size(0, 36),
              backgroundColor: filter == metric.$2 && metric.$2 != 'Open'
                  ? scheme.primaryContainer
                  : null,
            ),
            child: Text.rich(TextSpan(children: [
              TextSpan(
                  text:
                      '${rows.where((row) => row.origin == origin && (metric.$2 == 'Open' ? !{
                          'Completed',
                          'Resolved',
                          'Rejected',
                          'Cancelled',
                          'Rejected / Cancelled',
                          'Legacy'
                        }.contains(stages[row.id]) : stages[row.id] == metric.$2)).length}  ',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 17)),
              TextSpan(text: metric.$1, style: const TextStyle(fontSize: 12)),
            ])),
          ),
      ]),
    );
  }

  Widget queueRow(BuildContext context, RmaCase row) {
    final stage = stages[row.id] ?? 'Loading';
    final legacy = stage == 'Legacy';
    final supplier = row.origin == 'inbound';
    final source = supplier
        ? linkedReferences[row.id] != null
            ? 'Linked ${linkedReferences[row.id]}'
            : 'Source · ${receivingReferences[row.id] ?? 'Inventory / Receiving'}'
        : null;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    final done = {
      'Completed',
      'Resolved',
      'Rejected',
      'Cancelled',
      'Rejected / Cancelled'
    }.contains(stage);
    final waiting = stage == 'Awaiting supplier';
    final badgeColor = done
        ? scheme.surfaceContainerHighest
        : waiting
            ? scheme.secondaryContainer
            : scheme.primaryContainer;
    final badgeText = done
        ? scheme.onSurfaceVariant
        : waiting
            ? scheme.onSecondaryContainer
            : scheme.onPrimaryContainer;
    final action = nextActions[row.id] ?? 'Loading';
    final next = legacy
        ? 'Detailed physical history unavailable'
        : waiting
            ? 'Waiting on supplier'
            : 'Next · $action';
    Widget badge() => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
              color: badgeColor, borderRadius: BorderRadius.circular(6)),
          child: Text(stage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: badgeText, fontSize: 11, fontWeight: FontWeight.w600)),
        );
    Widget twoLines(String first, String? second, {bool strong = false}) =>
        Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(first,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: strong ? 14 : 13,
                      fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
                      color:
                          done ? scheme.onSurfaceVariant : scheme.onSurface)),
              if (second != null)
                Text(second,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
            ]);
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 800;
      return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Material(
              color: done ? scheme.surfaceContainerLow : scheme.surface,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                  key: ValueKey('rma-row-${row.id}'),
                  borderRadius: BorderRadius.circular(8),
                  hoverColor: scheme.primary.withValues(alpha: .06),
                  focusColor: scheme.primary.withValues(alpha: .12),
                  onTap: () => showCaseDetail(row),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: wide
                          ? Row(children: [
                              Expanded(
                                  flex: 28,
                                  child: twoLines(
                                      row.reference, parties[row.id],
                                      strong: true)),
                              const SizedBox(width: 10),
                              Expanded(
                                  flex: 27,
                                  child: twoLines(
                                      productTitles[row.id] ?? 'Item',
                                      serialLabels[row.id] == null
                                          ? null
                                          : 'Serial ${serialLabels[row.id]}')),
                              const SizedBox(width: 10),
                              Expanded(
                                  flex: 29,
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        badge(),
                                        Text(
                                            source ??
                                                receiptLabels[row.id] ??
                                                '',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: muted),
                                        Text(next,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: muted),
                                      ])),
                              const SizedBox(width: 8),
                              Expanded(
                                  flex: 16,
                                  child: Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        Text(ageLabel(row), style: muted),
                                        const SizedBox(width: 6),
                                        const Icon(Icons.chevron_right,
                                            size: 18)
                                      ])),
                            ])
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                  Row(children: [
                                    Expanded(
                                        child: twoLines(
                                            row.reference, parties[row.id],
                                            strong: true)),
                                    badge(),
                                    const Icon(Icons.chevron_right, size: 18),
                                  ]),
                                  const SizedBox(height: 3),
                                  twoLines(
                                      productTitles[row.id] ?? 'Item',
                                      serialLabels[row.id] == null
                                          ? null
                                          : 'Serial ${serialLabels[row.id]}'),
                                  if (source != null ||
                                      receiptLabels[row.id] != null)
                                    Text(source ?? receiptLabels[row.id]!,
                                        style: muted,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                  Row(children: [
                                    Expanded(
                                        child: Text(next,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: muted)),
                                    Text(ageLabel(row), style: muted)
                                  ]),
                                ])))));
    });
  }

  Widget moreMenu() => PopupMenuButton<String>(
        tooltip: 'More RMA views',
        onSelected: (value) => setState(() {
          origin = value;
          filter = 'All';
        }),
        itemBuilder: (_) => [
          const PopupMenuItem(
              value: 'attention', child: Text('Aging & attention')),
          const PopupMenuItem(value: 'reports', child: Text('Reports')),
          if (widget.user.can(PosPermission.manageRecovery))
            const PopupMenuItem(value: 'settings', child: Text('Settings')),
        ],
        child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('More'),
              Icon(Icons.arrow_drop_down),
            ])),
      );

  @override
  Widget build(BuildContext context) {
    final visible = rows
        .where((row) =>
            row.origin == origin &&
            (filter == 'All' || stages[row.id] == filter) &&
            (searchText.trim().isEmpty ||
                ('${searchKeys[row.id]} ${nextActions[row.id]}')
                    .toLowerCase()
                    .contains(searchText.trim().toLowerCase())))
        .toList();
    Widget tab(String value, String label) => Semantics(
          button: true,
          selected: origin == value,
          child: Material(
            color: origin == value
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              key: ValueKey('workspace-$value'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() {
                origin = value;
                filter = 'All';
              }),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(
                    '$label  ${rows.where((row) => row.origin == value).length}',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: origin == value
                            ? FontWeight.w700
                            : FontWeight.w500)),
              ),
            ),
          ),
        );
    Widget action() => FilledButton.icon(
          onPressed: () => create(origin),
          icon: const Icon(Icons.add, size: 18),
          label: Text(
              origin == 'customer' ? 'New Customer RMA' : 'New Supplier RMA'),
        );
    return Scaffold(
        appBar: AppBar(title: const Text('RMA / Warranty'), actions: [
          IconButton(
              tooltip: 'Refresh RMA queue',
              onPressed: refresh,
              icon: const Icon(Icons.refresh))
        ]),
        body: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1500),
                child: ListView(
                    padding: EdgeInsets.symmetric(
                        horizontal:
                            MediaQuery.sizeOf(context).width >= 600 ? 20 : 12,
                        vertical: 8),
                    children: [
                      Text(
                          'Manage customer returns, warranties, and supplier recovery.',
                          style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 8),
                      LayoutBuilder(
                          builder: (context, constraints) =>
                              constraints.maxWidth >= 1000
                                  ? Row(children: [
                                      tab('customer', 'Customer RMAs'),
                                      const SizedBox(width: 8),
                                      tab('inbound', 'Supplier RMAs'),
                                      const SizedBox(width: 8),
                                      moreMenu(),
                                      const Spacer(),
                                      if (origin == 'customer' ||
                                          origin == 'inbound')
                                        action(),
                                    ])
                                  : Wrap(
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      spacing: 8,
                                      runSpacing: 6,
                                      children: [
                                          tab('customer', 'Customer RMAs'),
                                          tab('inbound', 'Supplier RMAs'),
                                          if (origin == 'customer' ||
                                              origin == 'inbound')
                                            action(),
                                          moreMenu(),
                                        ])),
                      const SizedBox(height: 8),
                      if (origin == 'customer' || origin == 'inbound')
                        metricTiles(context),
                      const SizedBox(height: 8),
                      if (error != null)
                        Text(error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      const SizedBox(height: 4),
                      if (origin == 'customer' || origin == 'inbound')
                        SizedBox(
                            height: 44,
                            child: TextField(
                                key: const ValueKey('rma-search'),
                                controller: searchController,
                                decoration: InputDecoration(
                                    hintText:
                                        'Search RMA, receipt, customer, product, serial...',
                                    prefixIcon: const Icon(Icons.search),
                                    filled: true,
                                    fillColor:
                                        Theme.of(context).colorScheme.surface,
                                    contentPadding:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide.none)),
                                onChanged: (value) =>
                                    setState(() => searchText = value))),
                      const SizedBox(height: 6),
                      if (origin == 'customer' || origin == 'inbound')
                        SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(children: [
                              for (final stage in origin == 'customer'
                                  ? const [
                                      'All',
                                      'Awaiting approval',
                                      'Awaiting receipt',
                                      'Awaiting inspection',
                                      'Awaiting resolution',
                                      'Awaiting supplier',
                                      'Ready for handoff',
                                      'Completed',
                                    ]
                                  : const [
                                      'All',
                                      'Ready to send',
                                      'Awaiting supplier',
                                      'Fulfillment pending',
                                      'Resolved',
                                    ])
                                Padding(
                                    padding: const EdgeInsets.only(right: 5),
                                    child: ChoiceChip(
                                        label: Text(switch (stage) {
                                          'Awaiting approval' => 'Approval',
                                          'Awaiting receipt' => 'Receipt',
                                          'Awaiting inspection' => 'Inspection',
                                          'Awaiting resolution' => 'Resolution',
                                          'Awaiting supplier' => 'Supplier',
                                          'Ready for handoff' => 'Handoff',
                                          'Ready to send' => 'Ready to send',
                                          'Fulfillment pending' =>
                                            'Fulfillment',
                                          'Resolved' => 'Completed',
                                          _ => stage,
                                        }),
                                        visualDensity: VisualDensity.compact,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        selected: filter == stage,
                                        onSelected: (_) =>
                                            setState(() => filter = stage))),
                              PopupMenuButton<String>(
                                tooltip: 'More filters',
                                onSelected: (value) =>
                                    setState(() => filter = value),
                                itemBuilder: (_) => (origin == 'customer'
                                        ? const [
                                            'Rejected / Cancelled',
                                            'Legacy'
                                          ]
                                        : const [
                                            'Requested',
                                            'Rejected',
                                            'Cancelled'
                                          ])
                                    .map((value) => PopupMenuItem(
                                        value: value, child: Text(value)))
                                    .toList(),
                                child: const Padding(
                                    padding:
                                        EdgeInsets.symmetric(horizontal: 8),
                                    child: Row(children: [
                                      Text('More filters'),
                                      Icon(Icons.arrow_drop_down)
                                    ])),
                              ),
                            ])),
                      const SizedBox(height: 6),
                      if (origin == 'attention') ...[
                        Text('Customer claims awaiting suppliers',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        for (final row in rows)
                          if (row.origin == 'customer' &&
                              stages[row.id] == 'Awaiting supplier')
                            Card(
                                child: ListTile(
                              title: Text(row.reference),
                              subtitle: Text(
                                  '${summaries[row.id] ?? ''} · ${nextActions[row.id] ?? ''}'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => showCaseDetail(row),
                            )),
                        if (!rows.any((row) =>
                            row.origin == 'customer' &&
                            stages[row.id] == 'Awaiting supplier'))
                          const Card(
                              child: Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Text(
                                      'No customer claims are awaiting suppliers.'))),
                        const SizedBox(height: 12),
                        const Text(
                            'Supplier overdue tracking is unavailable until an SLA is configured.'),
                      ],
                      if (origin == 'reports') ...[
                        Text('RMA overview',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final metric in <(String, int)>[
                            (
                              'Customer claims',
                              rows
                                  .where((row) => row.origin == 'customer')
                                  .length
                            ),
                            (
                              'Supplier claims',
                              rows
                                  .where((row) => row.origin == 'inbound')
                                  .length
                            ),
                            (
                              'Completed',
                              rows
                                  .where((row) => stages[row.id] == 'Completed')
                                  .length
                            ),
                          ])
                            Card(
                                child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text('${metric.$1}: ${metric.$2}'))),
                        ]),
                      ],
                      if (origin == 'settings') ...[
                        Text('RMA settings',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        const Text(
                            'Supplier overdue tracking requires an SLA. No RMA-specific settings are configured.'),
                      ],
                      if (visible.isEmpty &&
                          (origin == 'customer' || origin == 'inbound'))
                        Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      rows
                                              .where(
                                                  (row) => row.origin == origin)
                                              .isEmpty
                                          ? origin == 'customer'
                                              ? 'No Customer RMAs found'
                                              : 'No Supplier RMAs found'
                                          : origin == 'customer'
                                              ? 'No Customer RMAs found'
                                              : 'No Supplier RMAs found',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  const SizedBox(height: 6),
                                  Text(rows
                                          .where((row) => row.origin == origin)
                                          .isEmpty
                                      ? origin == 'customer'
                                          ? 'Customer returns and warranty claims will appear here.'
                                          : 'Supplier claims from receiving or customer recovery will appear here.'
                                      : 'Try changing the search or filters.'),
                                ])),
                      for (final row in visible) queueRow(context, row),
                    ]))));
  }
}
