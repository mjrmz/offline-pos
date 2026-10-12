import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/product.dart';
import '../../core/models/quantity.dart';
import '../../data/database.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/layaway_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/transaction_picker.dart';

class LayawayScreen extends StatefulWidget {
  final LayawayRepository repository;
  final DirectoryRepository directory;
  final PosRepository products;
  final ActiveUser user;
  const LayawayScreen(
      {super.key,
      required this.repository,
      required this.directory,
      required this.products,
      required this.user});
  @override
  State<LayawayScreen> createState() => _LayawayScreenState();
}

class _LayawayScreenState extends State<LayawayScreen> {
  List<Layaway> rows = [];
  List<Customer> customers = [];
  List<PosProduct> products = [];
  String? error;
  String query = '';
  String filter = 'all';
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final next = await widget.repository.history();
      final directory = await widget.directory.customers();
      final catalog = await widget.products.products();
      if (mounted) {
        setState(() {
          rows = next;
          customers = directory.where((c) => c.isActive).toList();
          products = catalog.where((p) => p.isActive).toList();
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  Future<void> create() async {
    final quantity = TextEditingController(text: '1');
    final deposit = TextEditingController();
    String? customerId;
    String? productId;
    String method = 'cash';
    List<SerialUnit> serials = [];
    final selectedSerials = <String>{};
    int? physicalMilli;
    int? reservedMilli;
    final lines = <LayawayLineRequest>[];
    String? validation;
    final mobile = MediaQuery.sizeOf(context).width < 700;
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => Dialog(
                    insetPadding: EdgeInsets.all(mobile ? 0 : 24),
                    child: SizedBox(
                        width: mobile ? double.infinity : 900,
                        height: mobile
                            ? double.infinity
                            : MediaQuery.sizeOf(context).height * .88,
                        child: Column(children: [
                          ListTile(
                              title: const Text('New layaway'),
                              trailing: IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () => Navigator.pop(context))),
                          const Divider(height: 1),
                          Expanded(
                              child: ListView(
                                  padding: const EdgeInsets.all(24),
                                  children: [
                                Text('Customer',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const Text(
                                    'A customer is required to track payments and reserved stock.'),
                                const SizedBox(height: 12),
                                TransactionCustomerPicker(
                                    customers: customers,
                                    onSelected: (c) =>
                                        update(() => customerId = c.id)),
                                if (widget.user
                                    .can(PosPermission.manageContacts))
                                  TextButton.icon(
                                      onPressed: () async {
                                        final added =
                                            await quickAddTransactionCustomer(
                                                context,
                                                widget.directory,
                                                widget.user);
                                        if (added != null && context.mounted) {
                                          update(() {
                                            customers.add(added);
                                            customerId = added.id;
                                          });
                                        }
                                      },
                                      icon: const Icon(Icons.person_add),
                                      label: const Text('Add customer')),
                                if (customerId != null)
                                  Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                          'Selected: ${customers.firstWhere((c) => c.id == customerId).name}')),
                                const Divider(height: 36),
                                Text('Reserved items',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const SizedBox(height: 12),
                                TransactionProductPicker(
                                    products: products,
                                    onSelected: (p) async {
                                      productId = p.id;
                                      final stock = await widget.products
                                          .stockMilli(p.id);
                                      final reserved = await widget.products
                                          .reservedStockMilli(p.id);
                                      final available = p.serialTracking
                                          ? await widget.products
                                              .availableSerials(p.id)
                                          : <SerialUnit>[];
                                      if (context.mounted) {
                                        update(() {
                                          physicalMilli = stock;
                                          reservedMilli = reserved;
                                          serials = available;
                                          selectedSerials.clear();
                                          validation = null;
                                        });
                                      }
                                    }),
                                if (productId != null)
                                  Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                          'Selected: ${products.firstWhere((p) => p.id == productId).name} · ${formatPeso(products.firstWhere((p) => p.id == productId).priceCents)} / ${products.firstWhere((p) => p.id == productId).business.unit.label}')),
                                const SizedBox(height: 12),
                                TextField(
                                    controller: quantity,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    decoration: const InputDecoration(
                                        labelText: 'Quantity',
                                        border: OutlineInputBorder()),
                                    onChanged: (_) => update(() {})),
                                if (physicalMilli != null &&
                                    reservedMilli != null &&
                                    productId != null)
                                  Builder(builder: (context) {
                                    final p = products
                                        .firstWhere((p) => p.id == productId);
                                    final selected = Quantity.tryParse(
                                            quantity.text,
                                            fractional:
                                                p.business.fractional) ??
                                        0;
                                    final available =
                                        physicalMilli! - reservedMilli!;
                                    return Card(
                                        child: Padding(
                                            padding: const EdgeInsets.all(12),
                                            child: Column(children: [
                                              Text('Stock for ${p.name}',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleSmall),
                                              Text(
                                                  'Physical: ${Quantity.format(physicalMilli!)} ${p.business.unit.label}'),
                                              Text(
                                                  'Already reserved: ${Quantity.format(reservedMilli!)} ${p.business.unit.label}'),
                                              Text(
                                                  'Available to reserve: ${Quantity.format(available)} ${p.business.unit.label}'),
                                              Text(
                                                  'This layaway: ${Quantity.format(selected)} ${p.business.unit.label}'),
                                              Text(
                                                  'Available after: ${Quantity.format(available - selected)} ${p.business.unit.label}'),
                                            ])));
                                  }),
                                for (final serial in serials)
                                  CheckboxListTile(
                                      title: Text(serial.serialNumber),
                                      value:
                                          selectedSerials.contains(serial.id),
                                      onChanged: (value) => update(() {
                                            if (value == true) {
                                              selectedSerials.add(serial.id);
                                            } else {
                                              selectedSerials.remove(serial.id);
                                            }
                                          })),
                                Align(
                                    alignment: Alignment.centerLeft,
                                    child: FilledButton.tonal(
                                        onPressed: () {
                                          final p = products
                                              .where((p) => p.id == productId)
                                              .firstOrNull;
                                          final milli = p == null
                                              ? null
                                              : Quantity.tryParse(quantity.text,
                                                  fractional:
                                                      p.business.fractional);
                                          if (p == null ||
                                              milli == null ||
                                              milli <= 0 ||
                                              lines.any(
                                                  (l) => l.productId == p.id) ||
                                              (physicalMilli != null &&
                                                  reservedMilli != null &&
                                                  milli >
                                                      physicalMilli! -
                                                          reservedMilli!)) {
                                            update(() => validation = p == null
                                                ? 'Select a product first.'
                                                : milli == null || milli <= 0
                                                    ? 'Quantity must be greater than zero.'
                                                    : lines.any((l) =>
                                                            l.productId == p.id)
                                                        ? 'This product is already in the layaway.'
                                                        : 'Only ${Quantity.format(physicalMilli! - reservedMilli!)} ${p.business.unit.label} are available to reserve.');
                                            return;
                                          }
                                          update(() {
                                            lines.add(LayawayLineRequest(
                                                p.id, milli,
                                                serialIds:
                                                    selectedSerials.toList()));
                                            validation = null;
                                            productId = null;
                                            physicalMilli = null;
                                            reservedMilli = null;
                                            serials = [];
                                          });
                                        },
                                        child: const Text('Add item'))),
                                if (validation != null)
                                  Text(validation!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error)),
                                for (final line in lines)
                                  Card(
                                      child: ListTile(
                                          title: Text(products
                                              .firstWhere(
                                                  (p) => p.id == line.productId)
                                              .name),
                                          subtitle: Text(
                                              '${Quantity.format(line.quantityMilli)} ${products.firstWhere((p) => p.id == line.productId).business.unit.label} × ${formatPeso(products.firstWhere((p) => p.id == line.productId).priceCents)}'),
                                          trailing: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(formatPeso(
                                                    Quantity.lineCents(
                                                        products
                                                            .firstWhere((p) =>
                                                                p.id ==
                                                                line.productId)
                                                            .priceCents,
                                                        line.quantityMilli))),
                                                IconButton(
                                                    tooltip:
                                                        'Remove layaway item',
                                                    icon:
                                                        const Icon(Icons.close),
                                                    onPressed: () => update(
                                                        () =>
                                                            lines.remove(line)))
                                              ]))),
                                const Divider(height: 36),
                                Text('Payment',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const SizedBox(height: 12),
                                TextField(
                                    controller: deposit,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    decoration: const InputDecoration(
                                        labelText: 'Deposit (pesos)',
                                        border: OutlineInputBorder()),
                                    onChanged: (_) => update(() {})),
                                const SizedBox(height: 12),
                                DropdownButtonFormField<String>(
                                    initialValue: method,
                                    decoration: const InputDecoration(
                                        labelText: 'Deposit method'),
                                    items: const [
                                      DropdownMenuItem(
                                          value: 'cash', child: Text('Cash')),
                                      DropdownMenuItem(
                                          value: 'gcash',
                                          child: Text('Confirmed GCash'))
                                    ],
                                    onChanged: (value) =>
                                        update(() => method = value ?? method)),
                                if (method == 'cash')
                                  FutureBuilder<List<CashSession>>(
                                      future: widget.repository.db
                                          .select(
                                              widget.repository.db.cashSessions)
                                          .get(),
                                      builder: (context, snapshot) => snapshot
                                                  .hasData &&
                                              !snapshot.data!.any((session) =>
                                                  session.closedAt == null)
                                          ? Text(
                                              'Open a shift before accepting a cash deposit.',
                                              style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .error))
                                          : const SizedBox.shrink()),
                                Builder(builder: (context) {
                                  final total = lines.fold<int>(
                                      0,
                                      (sum, line) =>
                                          sum +
                                          Quantity.lineCents(
                                              products
                                                  .firstWhere((p) =>
                                                      p.id == line.productId)
                                                  .priceCents,
                                              line.quantityMilli));
                                  final paid = tryParsePeso(deposit.text) ?? 0;
                                  return Column(children: [
                                    TransactionTotal('Order total', total),
                                    TransactionTotal('Deposit', paid),
                                    TransactionTotal('Remaining balance',
                                        (total - paid).clamp(0, total),
                                        strong: true),
                                    if (paid > total)
                                      const Text('Deposit cannot exceed total.')
                                  ]);
                                }),
                              ])),
                          Padding(
                              padding: const EdgeInsets.all(16),
                              child: Wrap(
                                  alignment: WrapAlignment.end,
                                  spacing: 12,
                                  runSpacing: 8,
                                  children: [
                                    TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('Cancel')),
                                    FilledButton(
                                        onPressed: customerId == null ||
                                                lines.isEmpty ||
                                                (tryParsePeso(deposit.text) ??
                                                        0) <=
                                                    0 ||
                                                (tryParsePeso(deposit.text) ??
                                                        0) >
                                                    lines.fold<int>(
                                                        0,
                                                        (sum, line) =>
                                                            sum +
                                                            Quantity.lineCents(
                                                                products
                                                                    .firstWhere((p) =>
                                                                        p.id ==
                                                                        line
                                                                            .productId)
                                                                    .priceCents,
                                                                line
                                                                    .quantityMilli))
                                            ? null
                                            : () =>
                                                Navigator.pop(context, true),
                                        child: const Text('Create layaway'))
                                  ])),
                        ])),
                  )));
      if (confirmed != true) return;
      final cents = tryParsePeso(deposit.text);
      if (customerId == null || lines.isEmpty || cents == null || cents <= 0) {
        throw StateError('Select customer, product, quantity and deposit');
      }
      await widget.repository
          .create(widget.user, customerId!, lines, cents, method);
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      quantity.dispose();
      deposit.dispose();
    }
  }

  Future<void> pay(Layaway row) async {
    final amount = TextEditingController();
    String method = 'cash';
    try {
      final due = await widget.repository.balance(row.id);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: Text('Payment for ${row.reference}'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('Balance: ${formatPeso(due)}'),
                      TextField(
                          controller: amount,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Amount (pesos)'),
                          onChanged: (_) => update(() {})),
                      TransactionTotal(
                          'After payment',
                          (due - (tryParsePeso(amount.text) ?? 0))
                              .clamp(0, due),
                          strong: true),
                      DropdownButtonFormField<String>(
                          initialValue: method,
                          items: const [
                            DropdownMenuItem(
                                value: 'cash', child: Text('Cash')),
                            DropdownMenuItem(
                                value: 'gcash', child: Text('Confirmed GCash'))
                          ],
                          onChanged: (value) =>
                              update(() => method = value ?? method)),
                      if (method == 'cash')
                        FutureBuilder<List<CashSession>>(
                            future: widget.repository.db
                                .select(widget.repository.db.cashSessions)
                                .get(),
                            builder: (context, snapshot) => snapshot.hasData &&
                                    !snapshot.data!.any(
                                        (session) => session.closedAt == null)
                                ? Text('Open a shift before accepting cash.',
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error))
                                : const SizedBox.shrink()),
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: (tryParsePeso(amount.text) ?? 0) <= 0 ||
                                  (tryParsePeso(amount.text) ?? 0) > due
                              ? null
                              : () => Navigator.pop(context, true),
                          child: const Text('Record payment'))
                    ],
                  )));
      if (confirmed != true) return;
      final cents = tryParsePeso(amount.text);
      if (cents == null) throw StateError('Enter a valid payment');
      await widget.repository.payment(widget.user, row.id, cents, method);
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      amount.dispose();
    }
  }

  Future<void> closeLayaway(Layaway row, bool complete) async {
    try {
      final due = await widget.repository.balance(row.id);
      final items = await widget.repository.items(row.id);
      final batches = <String, List<ProductLot>>{};
      final selected = <String, String>{};
      if (complete) {
        for (final item in items) {
          final product =
              products.where((p) => p.id == item.productId).firstOrNull;
          if (product?.business.batch == true) {
            batches[item.productId] =
                await widget.products.batches(item.productId);
          }
        }
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: Text(complete
                        ? 'Complete ${row.reference}'
                        : 'Cancel ${row.reference}'),
                    content: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                          'Customer: ${customers.where((c) => c.id == row.customerId).firstOrNull?.name ?? 'Customer'}'),
                      for (final item in items)
                        Text(
                            '${products.where((p) => p.id == item.productId).firstOrNull?.name ?? 'Product'} · ${Quantity.format(item.quantityMilli)} ${item.unitSnapshot}'),
                      TransactionTotal('Total', row.totalCents),
                      TransactionTotal('Paid', row.totalCents - due),
                      TransactionTotal('Remaining', due, strong: true),
                      Text(complete
                          ? 'Collect final cash of ${formatPeso(due)} now. The full sale and stock deduction occur once.'
                          : 'Release reserved stock. Payments become a customer refund obligation.'),
                      for (final item in items)
                        if (batches[item.productId] != null)
                          DropdownButtonFormField<String>(
                              decoration:
                                  const InputDecoration(labelText: 'Batch'),
                              items: [
                                for (final batch in batches[item.productId]!)
                                  DropdownMenuItem(
                                      value: batch.id,
                                      child: Text(batch.batchNumber))
                              ],
                              onChanged: (value) => update(() {
                                    if (value != null) {
                                      selected[item.productId] = value;
                                    }
                                  })),
                    ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Back')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(
                              complete ? 'Complete sale' : 'Cancel layaway'))
                    ],
                  )));
      if (confirmed != true) return;
      if (complete) {
        await widget.repository
            .complete(widget.user, row.id, batchIds: selected);
      } else {
        await widget.repository.cancel(widget.user, row.id);
      }
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  Future<void> showLayaway(Layaway row) async {
    final items = await widget.repository.items(row.id);
    final payments = await widget.repository.payments(row.id);
    final due = await widget.repository.balance(row.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760, maxHeight: 700),
              child: Column(children: [
                ListTile(
                    title: Text('Layaway ${row.reference}'),
                    trailing: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context))),
                Expanded(
                    child:
                        ListView(padding: const EdgeInsets.all(24), children: [
                  Chip(
                      label: Text(row.status[0].toUpperCase() +
                          row.status.substring(1))),
                  Text(
                      'Customer: ${customers.where((c) => c.id == row.customerId).firstOrNull?.name ?? 'Customer'}'),
                  Text(
                      'Created: ${MaterialLocalizations.of(context).formatMediumDate(row.createdAt)}'),
                  const Divider(height: 32),
                  Text('Reserved items',
                      style: Theme.of(context).textTheme.titleMedium),
                  for (final item in items)
                    ListTile(
                        title: Text(products
                                .where((p) => p.id == item.productId)
                                .firstOrNull
                                ?.name ??
                            'Product'),
                        subtitle: Text(
                            '${Quantity.format(item.quantityMilli)} ${item.unitSnapshot} × ${formatPeso(item.unitPriceCents)}'),
                        trailing: Text(formatPeso(item.lineTotalCents))),
                  const Divider(),
                  TransactionTotal('Total', row.totalCents),
                  TransactionTotal('Paid', row.totalCents - due),
                  TransactionTotal('Remaining balance', due, strong: true),
                  const Divider(height: 32),
                  Text('Payment history',
                      style: Theme.of(context).textTheme.titleMedium),
                  for (final payment in payments)
                    ListTile(
                        title: Text(payment.method == 'cash'
                            ? 'Cash payment'
                            : 'GCash payment'),
                        subtitle: Text(MaterialLocalizations.of(context)
                            .formatMediumDate(payment.createdAt)),
                        trailing: Text(formatPeso(payment.amountCents))),
                ])),
                if (row.status == 'active')
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(spacing: 8, children: [
                        if (due > 0)
                          TextButton(
                              onPressed: () {
                                Navigator.pop(context);
                                pay(row);
                              },
                              child: const Text('Record payment')),
                        TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              closeLayaway(row, true);
                            },
                            child: const Text('Complete layaway')),
                        TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              closeLayaway(row, false);
                            },
                            child: const Text('Cancel layaway')),
                      ])),
              ]))),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Layaway'), actions: [
        IconButton(onPressed: refresh, icon: const Icon(Icons.refresh))
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (error != null)
          Text(error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
                onPressed: create,
                icon: const Icon(Icons.add),
                label: const Text('New layaway'))),
        const SizedBox(height: 16),
        TextField(
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Search customer or layaway reference',
                border: OutlineInputBorder()),
            onChanged: (value) => setState(() => query = value.toLowerCase())),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          for (final status in ['all', 'active', 'completed', 'cancelled'])
            FilterChip(
                label: Text(status[0].toUpperCase() + status.substring(1)),
                selected: filter == status,
                onSelected: (_) => setState(() => filter = status)),
        ]),
        if (rows.isEmpty)
          const Card(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'No layaways yet. Reserve stock for a customer and record a deposit to begin.'))),
        for (final row in rows)
          if (filter == 'all' || filter == row.status)
            if ('${row.reference} ${customers.where((c) => c.id == row.customerId).firstOrNull?.name ?? ''}'
                .toLowerCase()
                .contains(query))
              FutureBuilder<int>(
                  future: widget.repository.balance(row.id),
                  builder: (context, snapshot) => ListTile(
                      onTap: () => showLayaway(row),
                      title: Text(
                          'Layaway ${row.reference} · ${customers.where((c) => c.id == row.customerId).firstOrNull?.name ?? 'Customer'}'),
                      subtitle: Text(
                          '${MaterialLocalizations.of(context).formatMediumDate(row.createdAt)} · Total ${formatPeso(row.totalCents)} · Paid ${snapshot.hasData ? formatPeso(row.totalCents - snapshot.data!) : '…'} · Balance ${snapshot.hasData ? formatPeso(snapshot.data!) : '…'}'),
                      trailing: Chip(
                          label: Text(row.status[0].toUpperCase() +
                              row.status.substring(1))))),
      ]));
}
