import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/daos/rma_lifecycle_repository.dart';
import '../../data/daos/rma_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';
import 'rma_action_panel.dart';

class RmaDetailPage extends StatefulWidget {
  final RmaCase row;
  final RmaRepository repository;
  final ActiveUser user;
  final Future<void> Function() onAction;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onRelease;
  final Future<void> Function() onSendToSupplier;
  final Future<void> Function() onDisposition;
  final Future<void> Function() onSupplierDisposition;
  final Future<void> Function(RmaCase) onOpenRelated;

  const RmaDetailPage(
      {super.key,
      required this.row,
      required this.repository,
      required this.user,
      required this.onAction,
      required this.onRefresh,
      required this.onRelease,
      required this.onSendToSupplier,
      required this.onDisposition,
      required this.onSupplierDisposition,
      required this.onOpenRelated});

  @override
  State<RmaDetailPage> createState() => _RmaDetailPageState();
}

class _RmaDetailPageState extends State<RmaDetailPage> {
  late Future<_Detail> detail = _load();

  Future<_Detail> _load() async {
    final db = widget.repository.db;
    final row = (await db.select(db.rmaCases).get())
        .firstWhere((e) => e.id == widget.row.id);
    final lifecycle = RmaLifecycleRepository(db);
    final facts = await lifecycle.history(row.id);
    final action = await lifecycle.nextAction(row.id);
    final customer = (await db.select(db.customers).get())
        .where((e) => e.id == row.customerId)
        .firstOrNull;
    final supplier = (await db.select(db.suppliers).get())
        .where((e) => e.id == row.supplierId)
        .firstOrNull;
    final saleItem = (await db.select(db.saleItems).get())
        .where((e) => e.id == row.saleItemId)
        .firstOrNull;
    final receivingItem = (await db.select(db.stockReceivingItems).get())
        .where((e) => e.id == row.receivingItemId)
        .firstOrNull;
    final product = (await db.select(db.products).get())
        .where((e) => e.id == (saleItem?.productId ?? receivingItem?.productId))
        .firstOrNull;
    final serials = await db.select(db.serialUnits).get();
    final serial = serials.where((e) => e.id == row.serialUnitId).firstOrNull;
    final reservedId = facts
        .where((e) => e.action == 'replacement_reserved')
        .lastOrNull
        ?.serialUnitId;
    final reservedSerial =
        serials.where((e) => e.id == reservedId).firstOrNull?.serialNumber;
    final receiving = (await db.select(db.stockReceivings).get())
        .where((e) => e.id == row.receivingId)
        .firstOrNull;
    final sale = (await db.select(db.sales).get())
        .where((e) => e.id == row.saleId)
        .firstOrNull;
    final relatedId = facts
        .where((e) =>
            e.action == 'supplier_requested' ||
            e.action == 'supplier_created' ||
            e.action == 'supplier_claim_opened')
        .firstOrNull
        ?.relatedCaseId;
    final relatedCase = (await db.select(db.rmaCases).get())
        .where((e) => e.id == relatedId)
        .firstOrNull;
    final relatedFacts = relatedCase == null
        ? <RmaLifecycleEvent>[]
        : await lifecycle.history(relatedCase.id);
    final handoffId =
        facts.where((e) => e.action == 'handoff').lastOrNull?.serialUnitId;
    final supplierReplacementId =
        (row.origin == 'inbound' ? facts : relatedFacts)
            .where((e) =>
                e.action == 'supplier_fulfilled' && e.outcome == 'replacement')
            .lastOrNull
            ?.serialUnitId;
    final warrantySerialId =
        row.origin == 'customer' ? handoffId : supplierReplacementId;
    final warranty = warrantySerialId == null
        ? null
        : (await db.select(db.serialWarrantySnapshots).get())
            .where((w) => w.serialUnitId == warrantySerialId)
            .lastOrNull;
    final actorNames = {
      for (final user in await db.select(db.users).get()) user.id: user.name,
    };
    final linkedSupplier = relatedCase == null
        ? null
        : (await db.select(db.suppliers).get())
            .where((e) => e.id == relatedCase.supplierId)
            .firstOrNull;
    return _Detail(
        row,
        facts,
        action,
        row.origin == 'customer'
            ? customer?.name ?? 'Walk-in customer'
            : supplier?.name ?? 'Unknown supplier',
        saleItem?.productName ?? product?.name ?? 'Item',
        serial?.serialNumber,
        sale?.birInvoiceNumber == null ? null : '#${sale!.birInvoiceNumber}',
        reservedSerial,
        receiving?.externalReference,
        receivingItem?.unitCostCents,
        relatedCase,
        relatedFacts,
        serials.where((s) => s.id == handoffId).firstOrNull?.serialNumber,
        serials
            .where((s) => s.id == supplierReplacementId)
            .firstOrNull
            ?.serialNumber,
        warranty,
        actorNames,
        row.origin == 'inbound' ? supplier?.name : linkedSupplier?.name);
  }

  void reload() => setState(() {
        detail = _load();
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
        appBar: AppBar(
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
            title: Text(widget.row.origin == 'customer'
                ? 'Customer RMA'
                : 'Supplier RMA'),
            actions: [
              IconButton(onPressed: reload, icon: const Icon(Icons.refresh))
            ]),
        body: FutureBuilder<_Detail>(
            future: detail,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text('${snapshot.error}'));
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final info = snapshot.data!;
              final row = info.row;
              final theme = Theme.of(context);
              final facts = info.facts;
              final actions = facts.map((e) => e.action).toSet();
              final intent =
                  facts.where((e) => e.action == 'intent').firstOrNull;
              final receipt =
                  facts.where((e) => e.action == 'received').lastOrNull;
              final inspection =
                  facts.where((e) => e.action == 'inspected').lastOrNull;
              final reservation = facts
                  .where((e) => e.action == 'replacement_reserved')
                  .lastOrNull;
              final handoff =
                  facts.where((e) => e.action == 'handoff').lastOrNull;
              final custody = facts
                  .where((e) => e.action.startsWith('custody_'))
                  .lastOrNull;
              final supplierFacts =
                  row.origin == 'inbound' ? facts : info.relatedFacts;
              final supplierDecision = supplierFacts
                  .where((e) => e.action == 'supplier_decision')
                  .lastOrNull;
              final supplierFulfillment = supplierFacts
                  .where((e) => e.action == 'supplier_fulfilled')
                  .lastOrNull;
              final progress = <(String, bool)>[
                ('Request', actions.contains('requested')),
                ('Approval', actions.contains('approved')),
                ('Receive', receipt != null),
                ('Inspect', inspection != null),
                ('Resolution', intent != null),
                ('Complete', actions.contains('completed')),
              ];
              final titleStyle = theme.textTheme.titleMedium;
              final content = <Widget>[
                _sectionCard(
                    context,
                    row.origin == 'customer'
                        ? 'Claim details'
                        : 'Supplier claim details',
                    [
                      _metaRow(
                          context,
                          row.origin == 'customer' ? 'Customer' : 'Supplier',
                          info.party),
                      _metaRow(
                          context,
                          'Source',
                          row.origin == 'customer'
                              ? info.receipt == null
                                  ? 'Customer return'
                                  : 'Receipt ${info.receipt}'
                              : info.relatedCase == null
                                  ? 'Inventory / Receiving'
                                  : 'Customer RMA'),
                      if (row.origin == 'inbound' && info.relatedCase != null)
                        _metaRow(
                            context, 'Linked RMA', info.relatedCase!.reference),
                      _metaRow(context, 'Reported issue', row.issueDescription),
                      if (row.origin == 'inbound') ...[
                        if (info.receivingReference != null)
                          _metaRow(
                              context, 'Receiving', info.receivingReference!),
                        if (info.purchaseCostCents != null)
                          _metaRow(context, 'Purchase cost',
                              formatPeso(info.purchaseCostCents!)),
                      ],
                    ]),
                if (row.origin == 'inbound' &&
                    {'repair', 'no_fault'}
                        .contains(supplierFulfillment?.outcome) &&
                    !actions.contains('supplier_disposition') &&
                    (info.relatedCase == null ||
                        info.relatedFacts.any((e) => e.action == 'completed')))
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Returned business item',
                                    style: titleStyle),
                                const Text(
                                    'The supplier return is complete. Record whether the original item is held, scrapped, or restocked.'),
                                FilledButton(
                                    onPressed: () async {
                                      await widget.onSupplierDisposition();
                                      reload();
                                    },
                                    child: const Text(
                                        'Record returned-item disposition')),
                              ]))),
                if (row.origin == 'customer' && intent != null)
                  _sectionCard(context, 'Customer fulfillment', [
                    _metaRow(context, 'Outcome', _label(intent.outcome)),
                    _metaRow(context, 'Status',
                        _operationalStatus(info, intent, actions)),
                    if (intent.outcome == 'refund')
                      _metaRow(
                          context,
                          'Refund',
                          '${formatPeso(intent.amountCents ?? 0)} · ${_label(intent.method)} · '
                              '${actions.contains('refund_executed') ? 'Completed' : 'Pending'}'),
                    if (intent.outcome == 'replacement')
                      _metaRow(context, 'Replacement serial',
                          info.reservedSerial ?? '—'),
                    if (info.finalSerial != null)
                      _metaRow(
                          context, 'Final customer serial', info.finalSerial!),
                    _metaRow(
                        context,
                        'Warranty',
                        handoff == null
                            ? '—'
                            : _warrantyLabel(info.warranty, context)),
                  ]),
                if (row.origin == 'customer' && info.relatedCase != null)
                  _sectionCard(context, 'Supplier recovery', [
                    Row(children: [
                      Expanded(
                          child: Text(info.relatedCase!.reference,
                              style: theme.textTheme.titleSmall)),
                      Text(_supplierStage(info.relatedFacts),
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: theme.colorScheme.primary)),
                    ]),
                    const SizedBox(height: 6),
                    _metaRow(context, 'Supplier',
                        info.supplierName ?? 'Legacy / unknown'),
                    _metaRow(context, 'Item', info.product),
                    if (info.serial != null)
                      _metaRow(context, 'Serial', info.serial!),
                    _metaRow(
                        context,
                        'Custody',
                        _custodyLabel(custody?.action,
                            received: receipt != null)),
                    if (supplierDecision != null)
                      _metaRow(context, 'Decision',
                          _label(supplierDecision.outcome)),
                    if (supplierFulfillment != null)
                      _metaRow(context, 'Fulfillment',
                          _label(supplierFulfillment.outcome)),
                    if (info.supplierReplacementSerial != null)
                      _metaRow(context, 'New serial',
                          info.supplierReplacementSerial!),
                    Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                            onPressed: () =>
                                widget.onOpenRelated(info.relatedCase!),
                            icon: const Icon(Icons.open_in_new, size: 18),
                            label: const Text('View Supplier RMA'))),
                  ]),
                if (row.origin == 'customer' &&
                    info.relatedCase == null &&
                    intent != null)
                  _sectionCard(context, 'Supplier recovery', [
                    Text('None',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ]),
                if (row.origin == 'customer' &&
                    {'restock', 'scrap'}.contains(intent?.disposition) &&
                    !actions.contains('disposition_executed') &&
                    info.action != 'Execute physical disposition')
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Returned item · disposition',
                                    style: titleStyle),
                                Text('Pending: ${_label(intent?.disposition)}'),
                                FilledButton(
                                    onPressed: () async {
                                      await widget.onDisposition();
                                      reload();
                                    },
                                    child: const Text(
                                        'Execute physical disposition')),
                              ]))),
                Card(
                    key: const ValueKey('rma-item-card'),
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  row.origin == 'customer'
                                      ? 'Returned item'
                                      : 'Source / item',
                                  style: titleStyle),
                              const SizedBox(height: 8),
                              Text(info.product,
                                  style: theme.textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w600)),
                              if (row.origin == 'inbound') ...[
                                const SizedBox(height: 8),
                                _metaRow(
                                    context,
                                    'Source',
                                    info.relatedCase == null
                                        ? 'Inventory / Receiving'
                                        : 'Customer RMA'),
                                if (info.relatedCase != null)
                                  _metaRow(context, 'Linked RMA',
                                      info.relatedCase!.reference),
                                _metaRow(context, 'Supplier', info.party),
                                if (info.receivingReference != null)
                                  _metaRow(context, 'Receiving',
                                      info.receivingReference!),
                              ],
                              _subheading(context, 'Identity'),
                              if (info.serial != null)
                                _metaRow(
                                    context, 'Original serial', info.serial!),
                              _metaRow(
                                  context,
                                  'Returned serial',
                                  row.origin == 'customer'
                                      ? receipt?.returnedSerial ?? '—'
                                      : supplierFulfillment?.returnedSerial ??
                                          '—'),
                              _metaRow(context, 'Quantity',
                                  Quantity.format(row.quantityMilli)),
                              if (inspection != null) ...[
                                const Divider(height: 16),
                                _subheading(context, 'Inspection'),
                                _metaRow(context, 'Condition',
                                    _label(inspection.condition)),
                                _metaRow(
                                    context,
                                    'Fault reproduced',
                                    inspection.faultReproduced == null
                                        ? 'Not tested'
                                        : inspection.faultReproduced!
                                            ? 'Yes'
                                            : 'No'),
                                _metaRow(context, 'Finding',
                                    inspection.finding ?? '—'),
                              ],
                              const Divider(height: 16),
                              _subheading(context, 'Custody'),
                              _metaRow(
                                  context,
                                  'Current custody',
                                  row.origin == 'inbound'
                                      ? _supplierCustodyLabel(actions)
                                      : _custodyLabel(custody?.action,
                                          received: receipt != null)),
                              if (row.origin == 'customer')
                                _metaRow(
                                    context,
                                    'Disposition',
                                    intent == null
                                        ? 'Pending'
                                        : _label(intent.disposition)),
                              if (row.origin == 'customer' &&
                                  receipt != null &&
                                  handoff == null)
                                Text('Not sellable inventory',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme
                                            .colorScheme.onSurfaceVariant)),
                              if (reservation != null &&
                                  handoff == null &&
                                  info.action == 'Hand replacement to customer')
                                TextButton(
                                    onPressed: () async {
                                      final confirmed = await showDialog<bool>(
                                          context: context,
                                          builder: (dialogContext) =>
                                              AlertDialog(
                                                title: const Text(
                                                    'Release reservation?'),
                                                content: Text(
                                                    'Serial ${info.reservedSerial ?? ''} will become available again.'),
                                                actions: [
                                                  TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                              dialogContext,
                                                              false),
                                                      child:
                                                          const Text('Keep')),
                                                  FilledButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                              dialogContext,
                                                              true),
                                                      child: const Text(
                                                          'Release')),
                                                ],
                                              ));
                                      if (confirmed != true) return;
                                      await widget.onRelease();
                                      reload();
                                    },
                                    child: const Text(
                                        'Release / change replacement')),
                            ]))),
                if (row.origin == 'inbound')
                  _sectionCard(context, 'Supplier decision', [
                    _metaRow(
                        context,
                        'Status',
                        supplierDecision == null
                            ? actions.contains('supplier_requested')
                                ? 'Awaiting decision'
                                : 'Ready to send'
                            : 'Recorded'),
                    if (supplierDecision != null) ...[
                      _metaRow(context, 'Decision',
                          _label(supplierDecision.outcome)),
                      _metaRow(context, 'Recorded',
                          _eventTime(context, supplierDecision.createdAt)),
                      if (supplierDecision.note?.isNotEmpty == true)
                        _metaRow(context, 'Notes', supplierDecision.note!),
                    ],
                  ]),
                if (row.origin == 'inbound')
                  _sectionCard(context, 'Fulfillment', [
                    _metaRow(context, 'Status',
                        supplierFulfillment == null ? 'Pending' : 'Received'),
                    if (supplierFulfillment != null) ...[
                      _metaRow(context, 'Fulfillment',
                          _label(supplierFulfillment.outcome)),
                      _metaRow(context, 'Received',
                          _eventTime(context, supplierFulfillment.createdAt)),
                      if (supplierFulfillment.returnedSerial != null)
                        _metaRow(context, 'Returned serial',
                            supplierFulfillment.returnedSerial!),
                      if (supplierFulfillment.condition != null)
                        _metaRow(context, 'Condition',
                            _label(supplierFulfillment.condition)),
                      if (info.supplierReplacementSerial != null)
                        _metaRow(context, 'New serial',
                            info.supplierReplacementSerial!),
                      if (supplierFulfillment.amountCents != null)
                        _metaRow(context, 'Credit',
                            formatPeso(supplierFulfillment.amountCents!)),
                      if (supplierFulfillment.outcome == 'replacement')
                        _metaRow(
                            context,
                            'Destination',
                            info.relatedCase == null ||
                                    info.relatedFacts
                                        .any((e) => e.action == 'completed')
                                ? 'Store recovery inventory'
                                : 'Held for customer'),
                    ],
                    _metaRow(context, 'Warranty',
                        _warrantyLabel(info.warranty, context)),
                  ]),
                if (row.origin == 'inbound' && info.relatedCase != null)
                  _sectionCard(context, 'Customer impact', [
                    Text(info.relatedCase!.reference,
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    _metaRow(
                        context,
                        'Status',
                        info.relatedFacts.any((e) => e.action == 'completed')
                            ? 'Customer completed'
                            : 'Waiting for supplier recovery'),
                    Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                            onPressed: () =>
                                widget.onOpenRelated(info.relatedCase!),
                            icon: const Icon(Icons.open_in_new, size: 18),
                            label: const Text('View Customer RMA'))),
                  ]),
                Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                            color: theme.colorScheme.outlineVariant)),
                    child: ExpansionTile(
                        title: const Text('Activity & custody history'),
                        subtitle: Text(
                            '${facts.length} ${facts.length == 1 ? 'event' : 'events'}'),
                        childrenPadding:
                            const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        children: [
                          if (facts.isEmpty)
                            const Padding(
                                padding: EdgeInsets.all(8),
                                child: Text(
                                    'Detailed physical history is unavailable.')),
                          for (final event in facts.reversed)
                            _timelineEvent(
                                context,
                                event,
                                info.actorNames[event.actorId] ?? 'Staff',
                                info.warranty?.sourceEventId == event.id
                                    ? _warrantyLabel(info.warranty, context)
                                    : null),
                        ])),
              ];
              // Keep the physical item directly below the claim on both
              // desktop and narrow layouts; fulfillment follows the item.
              final itemIndex = content.indexWhere(
                  (widget) => widget.key == const ValueKey('rma-item-card'));
              if (itemIndex > 1) {
                content.insert(1, content.removeAt(itemIndex));
              }
              final actionPanel = RmaActionPanel(
                key: ValueKey('${row.id}:${info.action}:${facts.length}'),
                row: row,
                repository: widget.repository,
                user: widget.user,
                action: info.action,
                events: facts,
                product: info.product,
                originalSerial: info.serial,
                supplierName: info.supplierName,
                relatedCase: info.relatedCase,
                onSaved: () async {
                  await widget.onRefresh();
                  reload();
                },
                onOtherAction: widget.onAction,
                onOpenRelated: widget.onOpenRelated,
              );
              final header = Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 12,
                            runSpacing: 4,
                            children: [
                              Text(row.reference,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w600)),
                              _statusChip(context,
                                  _operationalStatus(info, intent, actions)),
                            ]),
                        const SizedBox(height: 4),
                        Text(info.party,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w500)),
                        Text(
                            [
                              info.product,
                              if (info.serial != null) 'Serial ${info.serial}',
                              if (info.receipt != null)
                                'Receipt ${info.receipt}',
                              if (row.origin == 'inbound' &&
                                  info.relatedCase != null)
                                'Linked ${info.relatedCase!.reference}',
                            ].join(' · '),
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 12),
                        _progressStrip(
                            context,
                            row.origin == 'customer'
                                ? progress
                                : <(String, bool)>[
                                    (
                                      'Claim',
                                      actions.contains('supplier_intake') ||
                                          actions
                                              .contains('supplier_created') ||
                                          actions.contains('supplier_requested')
                                    ),
                                    (
                                      'Send',
                                      actions.contains('supplier_requested')
                                    ),
                                    (
                                      'Review',
                                      actions.contains('supplier_decision')
                                    ),
                                    (
                                      'Outcome',
                                      actions.contains('supplier_decision')
                                    ),
                                    (
                                      'Fulfill',
                                      actions.contains('supplier_fulfilled')
                                    ),
                                    ('Complete', actions.contains('completed')),
                                  ]),
                      ]));
              return LayoutBuilder(builder: (context, constraints) {
                final wide = constraints.maxWidth >= 850;
                final details = Theme(
                    data: theme.copyWith(
                        cardTheme: CardThemeData(
                            elevation: 0,
                            color: theme.colorScheme.surface,
                            margin: const EdgeInsets.only(bottom: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                    color: theme.colorScheme.outlineVariant)))),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: content));
                if (!wide) {
                  return SingleChildScrollView(
                      child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [header, actionPanel, details])));
                }
                return Column(children: [
                  header,
                  Expanded(
                      child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                          child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                    flex: 66,
                                    child:
                                        SingleChildScrollView(child: details)),
                                const SizedBox(width: 16),
                                Expanded(
                                    flex: 34,
                                    child: SingleChildScrollView(
                                        child: actionPanel)),
                              ]))),
                ]);
              });
            }),
      );
}

String _label(String? raw) => raw == 'replacement'
    ? 'Replace now'
    : raw == null
        ? 'Not recorded'
        : raw
            .split('_')
            .map((word) => word.isEmpty
                ? word
                : '${word[0].toUpperCase()}${word.substring(1)}')
            .join(' ');

String _eventLabel(RmaLifecycleEvent event) => switch (event.action) {
      'requested' => 'RMA requested',
      'approved' => 'RMA approved',
      'rejected' => 'Request rejected',
      'cancelled' => 'Request cancelled',
      'received' => 'Item received',
      'inspected' => 'Inspection completed',
      'intent' => 'Resolution authorized',
      'refund_executed' => 'Refund completed',
      'replacement_reserved' => 'Replacement reserved',
      'replacement_released' => 'Replacement released',
      'handoff' => 'Customer handoff confirmed',
      'completed' => 'RMA completed',
      'supplier_created' => 'Supplier RMA created',
      'supplier_requested' => 'Item sent to supplier',
      'supplier_decision' => 'Supplier decision recorded',
      'supplier_fulfilled' => switch (event.outcome) {
          'repair' => 'Repaired original received',
          'no_fault' => 'Original returned, no fault found',
          'replacement' => 'Supplier replacement received',
          'credit' => 'Supplier credit received',
          'rejected' => 'Rejected original returned',
          _ => 'Supplier fulfillment recorded',
        },
      'supplier_disposition' => 'Returned item disposition recorded',
      'custody_store' => 'Store took custody',
      'custody_supplier' => 'Supplier took custody',
      'custody_customer' => 'Customer took custody',
      _ => _label(event.action),
    };

String _supplierStage(List<RmaLifecycleEvent> facts) {
  final actions = facts.map((e) => e.action).toSet();
  if (actions.contains('completed')) {
    return 'Complete';
  }
  if (actions.contains('supplier_fulfilled')) {
    return 'Returned item disposition pending';
  }
  if (actions.contains('supplier_decision')) {
    return 'Awaiting fulfillment';
  }
  if (actions.contains('supplier_requested')) {
    return 'Awaiting supplier decision';
  }
  if (actions.contains('supplier_created') ||
      actions.contains('supplier_intake')) {
    return 'Ready to send';
  }
  return 'Legacy / unknown';
}

String _warrantyLabel(SerialWarrantySnapshot? warranty, BuildContext context) {
  if (warranty == null || warranty.source == 'legacy_unknown') {
    return 'Legacy / unknown';
  }
  if (warranty.treatment == 'unknown') {
    return 'Unknown / not provided';
  }
  if (warranty.treatment == 'none') {
    return 'No warranty';
  }
  final end = warranty.endAt;
  return '${_label(warranty.treatment)}${end == null ? '' : ' until ${MaterialLocalizations.of(context).formatMediumDate(end)}'}';
}

String _eventTime(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final locale = MaterialLocalizations.of(context);
  return '${locale.formatMediumDate(local)} · '
      '${TimeOfDay.fromDateTime(local).format(context)}';
}

String _eventDetail(RmaLifecycleEvent event) => switch (event.action) {
      'received' when event.expectedSerial != null =>
        ' · Serial ${event.returnedSerial == event.expectedSerial ? 'verified' : 'mismatch: expected ${event.expectedSerial}, returned ${event.returnedSerial}'}',
      'inspected' => ' · Condition: ${_label(event.condition)}'
          ' · Fault reproduced: ${event.faultReproduced == null ? 'Not tested' : event.faultReproduced! ? 'Yes' : 'No'}'
          '${event.finding?.isNotEmpty == true ? ' · ${event.finding}' : ''}',
      'intent' => ' · ${_label(event.outcome)} / ${_label(event.disposition)}',
      'replacement_reserved' => ' · Exact serial reserved',
      'handoff' => ' · Recipient ${event.recipient ?? 'recorded'}',
      'supplier_requested' => event.finding?.isNotEmpty == true
          ? ' · Reference ${event.finding}'
          : '',
      'supplier_decision' => ' · ${_label(event.outcome)}',
      'supplier_fulfilled' =>
        '${event.returnedSerial == null ? '' : ' · Serial ${event.returnedSerial}'}'
            '${event.condition == null ? '' : ' · ${_label(event.condition)}'}'
            '${event.amountCents == null ? '' : ' · ${formatPeso(event.amountCents!)}'}',
      _ => '',
    };

class _Detail {
  final RmaCase row;
  final List<RmaLifecycleEvent> facts;
  final String action;
  final String party;
  final String product;
  final String? serial;
  final String? receipt;
  final String? reservedSerial;
  final String? receivingReference;
  final int? purchaseCostCents;
  final RmaCase? relatedCase;
  final List<RmaLifecycleEvent> relatedFacts;
  final String? finalSerial;
  final String? supplierReplacementSerial;
  final SerialWarrantySnapshot? warranty;
  final Map<String, String> actorNames;
  final String? supplierName;
  const _Detail(
      this.row,
      this.facts,
      this.action,
      this.party,
      this.product,
      this.serial,
      this.receipt,
      this.reservedSerial,
      this.receivingReference,
      this.purchaseCostCents,
      this.relatedCase,
      this.relatedFacts,
      this.finalSerial,
      this.supplierReplacementSerial,
      this.warranty,
      this.actorNames,
      this.supplierName);
}

Widget _progressStrip(BuildContext context, List<(String, bool)> steps) {
  final theme = Theme.of(context);
  final current = steps.indexWhere((step) => !step.$2);
  final activeIndex = current < 0 ? steps.length - 1 : current;
  return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        for (var index = 0; index < steps.length; index++)
          Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(
                  child: Container(
                      height: 1,
                      color: index == 0
                          ? Colors.transparent
                          : steps[index - 1].$2
                              ? theme.colorScheme.primary
                                  .withValues(alpha: 0.45)
                              : theme.colorScheme.outlineVariant)),
              Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: steps[index].$2
                          ? theme.colorScheme.primary
                          : index == activeIndex
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surface,
                      border: Border.all(
                          color: index <= activeIndex
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          width: index == activeIndex ? 2 : 1)),
                  child: steps[index].$2
                      ? Icon(Icons.check,
                          size: 13, color: theme.colorScheme.onPrimary)
                      : index == activeIndex
                          ? Center(
                              child: Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: theme.colorScheme.primary)))
                          : null),
              Expanded(
                  child: Container(
                      height: 1,
                      color: index == steps.length - 1
                          ? Colors.transparent
                          : steps[index].$2
                              ? theme.colorScheme.primary
                                  .withValues(alpha: 0.45)
                              : theme.colorScheme.outlineVariant)),
            ]),
            const SizedBox(height: 3),
            Text(steps[index].$1,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: index == activeIndex
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: index <= activeIndex
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant)),
          ])),
      ]));
}

String _operationalStatus(
    _Detail info, RmaLifecycleEvent? intent, Set<String> actions) {
  if (actions.contains('completed')) return 'Completed';
  if (info.row.origin == 'inbound') {
    return switch (info.action) {
      'Send to supplier' => 'Ready to send',
      'Record supplier decision' => 'Awaiting supplier',
      'Record supplier fulfillment' => 'Fulfillment pending',
      'Resolve rejected item' => 'Returned item disposition',
      'Supplier fulfilled' => 'Fulfillment received',
      _ => info.action,
    };
  }
  if (intent?.outcome == 'refund' && !actions.contains('refund_executed')) {
    return 'Refund pending';
  }
  if (intent?.outcome == 'replacement' &&
      actions.contains('replacement_reserved') &&
      !actions.contains('handoff')) {
    return 'Replacement reserved';
  }
  return switch (info.action) {
    'Approve claim' => 'Awaiting approval',
    'Receive returned item' => 'Awaiting receipt',
    'Inspect returned item' => 'Awaiting inspection',
    'Choose resolution' => 'Awaiting resolution',
    'Waiting on supplier' => 'Awaiting supplier',
    'Hand replacement to customer' ||
    'Hand supplier replacement to customer' ||
    'Hand repaired item to customer' ||
    'Hand returned item to customer' ||
    'Hand item to customer' =>
      'Ready for handoff',
    _ => info.action,
  };
}

Widget _statusChip(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  return Chip(
      key: const ValueKey('rma-status-chip'),
      visualDensity: VisualDensity.compact,
      side: BorderSide.none,
      backgroundColor: status == 'Completed'
          ? scheme.secondaryContainer
          : scheme.primaryContainer,
      labelStyle: TextStyle(
          color: status == 'Completed'
              ? scheme.onSecondaryContainer
              : scheme.onPrimaryContainer,
          fontWeight: FontWeight.w600),
      label: Text(status));
}

Widget _sectionCard(BuildContext context, String title, List<Widget> children) {
  final theme = Theme.of(context);
  return Card(
      elevation: 0,
      color: theme.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: theme.colorScheme.outlineVariant)),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            ...children,
          ])));
}

Widget _metaRow(BuildContext context, String label, String value) {
  final theme = Theme.of(context);
  return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: LayoutBuilder(builder: (context, constraints) {
        final labelWidth = constraints.maxWidth < 430 ? 112.0 : 145.0;
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: labelWidth,
              child: Text(label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
          const SizedBox(width: 8),
          Expanded(
              child: Text(value,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500))),
        ]);
      }));
}

Widget _subheading(BuildContext context, String label) {
  final theme = Theme.of(context);
  return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 7),
      child: Text(label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6)));
}

String _custodyLabel(String? action, {required bool received}) =>
    switch (action) {
      'custody_store' => 'Received by store',
      'custody_supplier' => 'With supplier',
      'custody_customer' => 'With customer',
      _ => received ? 'Held by store' : 'With customer',
    };

String _supplierCustodyLabel(Set<String> actions) {
  if (actions.contains('supplier_fulfilled')) return 'Received by store';
  if (actions.contains('supplier_requested')) return 'With supplier';
  return 'Held by store';
}

Widget _timelineEvent(BuildContext context, RmaLifecycleEvent event,
    String actor, String? warranty) {
  final theme = Theme.of(context);
  final detail = _eventDetail(event).replaceFirst(RegExp(r'^ · '), '');
  return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(children: [
          Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                  shape: BoxShape.circle, color: theme.colorScheme.primary)),
          Container(
              width: 1, height: 48, color: theme.colorScheme.outlineVariant),
        ]),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_eventTime(context, event.createdAt),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(_eventLabel(event),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          Text(actor, style: theme.textTheme.bodySmall),
          if (detail.isNotEmpty) Text(detail, style: theme.textTheme.bodySmall),
          if (warranty != null)
            Text('Warranty: $warranty', style: theme.textTheme.bodySmall),
          if (event.note?.isNotEmpty == true)
            Text(event.note!, style: theme.textTheme.bodySmall),
        ])),
      ]));
}
