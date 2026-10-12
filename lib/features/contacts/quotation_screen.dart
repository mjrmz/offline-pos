import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/product.dart';
import '../../core/models/quantity.dart';
import '../../data/database.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/quotation_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/expiry_date_field.dart';
import '../../shared/widgets/transaction_picker.dart';

class QuotationScreen extends StatefulWidget {
  final QuotationRepository repository;
  final DirectoryRepository directory;
  final PosRepository products;
  final ActiveUser user;
  const QuotationScreen(
      {super.key,
      required this.repository,
      required this.directory,
      required this.products,
      required this.user});
  @override
  State<QuotationScreen> createState() => _QuotationScreenState();
}

class _QuotationScreenState extends State<QuotationScreen> {
  List<Quotation> rows = [];
  List<PosProduct> products = [];
  List<Customer> customers = [];
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
      final quotes = await widget.repository.history();
      final catalog = await widget.products.products();
      final directory = await widget.directory.customers();
      if (mounted) {
        setState(() {
          rows = quotes;
          products = catalog.where((p) => p.isActive).toList();
          customers = directory.where((c) => c.isActive).toList();
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  Future<void> create() async {
    final quantity = TextEditingController(text: '1');
    final notes = TextEditingController();
    final lines = <QuoteLineRequest>[];
    String? productId;
    String? customerId;
    DateTime? validUntil;
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
                              title: const Text('New quotation'),
                              trailing: IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () => Navigator.pop(context))),
                          const Divider(height: 1),
                          Expanded(
                              child: ListView(
                                  padding: const EdgeInsets.all(24),
                                  children: [
                                Text('Customer and validity',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
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
                                if (customerId == null)
                                  const Padding(
                                      padding: EdgeInsets.only(top: 8),
                                      child: Text('Walk-in customer')),
                                if (customerId != null)
                                  TextButton(
                                      onPressed: () =>
                                          update(() => customerId = null),
                                      child: const Text('Use walk-in')),
                                const SizedBox(height: 12),
                                const Text('Valid until (optional)'),
                                ExpiryDateField(
                                    value: validUntil,
                                    onChanged: (date) =>
                                        update(() => validUntil = date)),
                                const Divider(height: 36),
                                Text('Items',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const SizedBox(height: 12),
                                TransactionProductPicker(
                                    products: products,
                                    onSelected: (p) => update(() {
                                          productId = p.id;
                                          validation = null;
                                        })),
                                if (productId != null)
                                  Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                          'Selected: ${products.firstWhere((p) => p.id == productId).name} · ${formatPeso(products.firstWhere((p) => p.id == productId).priceCents)} / ${products.firstWhere((p) => p.id == productId).business.unit.label}')),
                                const SizedBox(height: 12),
                                Row(children: [
                                  Expanded(
                                      child: TextField(
                                    controller: quantity,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    decoration: const InputDecoration(
                                        labelText: 'Quantity',
                                        border: OutlineInputBorder()),
                                    onSubmitted: (_) {},
                                  )),
                                  const SizedBox(width: 12),
                                  FilledButton.tonal(
                                      onPressed: () {
                                        final product = products
                                            .where((p) => p.id == productId)
                                            .firstOrNull;
                                        final milli = product == null
                                            ? null
                                            : Quantity.tryParse(quantity.text,
                                                fractional: product
                                                    .business.fractional);
                                        if (product == null ||
                                            milli == null ||
                                            milli <= 0 ||
                                            lines.any((l) =>
                                                l.productId == product.id)) {
                                          update(() => validation = product ==
                                                  null
                                              ? 'Select a product first.'
                                              : milli == null || milli <= 0
                                                  ? 'Quantity must be greater than zero.'
                                                  : 'This product is already in the quotation.');
                                          return;
                                        }
                                        update(() {
                                          lines.add(QuoteLineRequest(
                                              product.id, milli));
                                          productId = null;
                                          validation = null;
                                        });
                                      },
                                      child: const Text('Add item'))
                                ]),
                                if (validation != null)
                                  Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(validation!,
                                          style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .error))),
                                const SizedBox(height: 16),
                                if (lines.isEmpty)
                                  const Card(
                                      child: Padding(
                                          padding: EdgeInsets.all(24),
                                          child: Text(
                                              'Add a product to build the quotation.'))),
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
                                                        'Remove quotation item',
                                                    icon:
                                                        const Icon(Icons.close),
                                                    onPressed: () => update(
                                                        () =>
                                                            lines.remove(line)))
                                              ]))),
                                const Text(
                                    'Stock is checked again when the quotation is converted to a sale.'),
                                const Divider(height: 36),
                                TextField(
                                    controller: notes,
                                    maxLines: 2,
                                    decoration: const InputDecoration(
                                        labelText: 'Notes (optional)',
                                        border: OutlineInputBorder())),
                                const SizedBox(height: 16),
                                TransactionTotal(
                                    'Subtotal',
                                    lines.fold(
                                        0,
                                        (sum, line) =>
                                            sum +
                                            Quantity.lineCents(
                                                products
                                                    .firstWhere((p) =>
                                                        p.id == line.productId)
                                                    .priceCents,
                                                line.quantityMilli))),
                                TransactionTotal(
                                    'Total',
                                    lines.fold(
                                        0,
                                        (sum, line) =>
                                            sum +
                                            Quantity.lineCents(
                                                products
                                                    .firstWhere((p) =>
                                                        p.id == line.productId)
                                                    .priceCents,
                                                line.quantityMilli)),
                                    strong: true),
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
                                        onPressed: lines.isEmpty
                                            ? null
                                            : () =>
                                                Navigator.pop(context, true),
                                        child: const Text('Save quotation'))
                                  ])),
                        ])),
                  )));
      if (confirmed != true) return;
      await widget.repository.create(widget.user, lines,
          customerId: customerId, notes: notes.text, validUntil: validUntil);
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      quantity.dispose();
      notes.dispose();
    }
  }

  Future<void> convert(Quotation quote) async {
    final amount = TextEditingController();
    final serialSelections = <String, Set<String>>{};
    final batchSelections = <String, String>{};
    try {
      final items = await widget.repository.items(quote.id);
      final serialOptions = <String, List<SerialUnit>>{};
      final batchOptions = <String, List<ProductLot>>{};
      for (final item in items) {
        final product =
            products.where((p) => p.id == item.productId).firstOrNull;
        if (product?.serialTracking == true) {
          serialOptions[item.productId] =
              await widget.products.availableSerials(item.productId);
        }
        if (product?.business.batch == true) {
          batchOptions[item.productId] =
              await widget.products.batches(item.productId);
        }
      }
      if (!mounted) return;
      final total = items.fold<int>(0, (sum, i) => sum + i.lineTotalCents);
      amount.text = (total / 100).toStringAsFixed(2);
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: Text('Convert ${quote.reference}'),
                    content: SizedBox(
                        width: 420,
                        height: 350,
                        child: ListView(children: [
                          Text('Quoted total: ${formatPeso(total)}'),
                          TextField(
                              controller: amount,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                  labelText: 'Cash received (pesos)')),
                          for (final item in items) ...[
                            Text(products
                                    .where((p) => p.id == item.productId)
                                    .firstOrNull
                                    ?.name ??
                                'Product'),
                            if (batchOptions[item.productId] != null)
                              DropdownButtonFormField<String>(
                                  decoration:
                                      const InputDecoration(labelText: 'Batch'),
                                  items: [
                                    for (final batch
                                        in batchOptions[item.productId]!)
                                      DropdownMenuItem(
                                          value: batch.id,
                                          child: Text(batch.batchNumber))
                                  ],
                                  onChanged: (value) => update(() {
                                        if (value != null) {
                                          batchSelections[item.productId] =
                                              value;
                                        }
                                      })),
                            for (final serial
                                in serialOptions[item.productId] ??
                                    <SerialUnit>[])
                              CheckboxListTile(
                                  title: Text(serial.serialNumber),
                                  value: serialSelections[item.productId]
                                          ?.contains(serial.id) ??
                                      false,
                                  onChanged: (value) => update(() {
                                        final selected =
                                            serialSelections.putIfAbsent(
                                                item.productId,
                                                () => <String>{});
                                        if (value == true) {
                                          selected.add(serial.id);
                                        } else {
                                          selected.remove(serial.id);
                                        }
                                      })),
                          ],
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Complete sale'))
                    ],
                  )));
      if (confirmed != true) return;
      final cents = tryParsePeso(amount.text);
      if (cents == null || cents < total) {
        throw StateError('Cash received is below quoted total');
      }
      await widget.repository.convertCash(widget.user, quote.id, cents,
          serialIds: serialSelections
              .map((key, value) => MapEntry(key, value.toList())),
          batchIds: batchSelections);
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      amount.dispose();
    }
  }

  Future<void> showQuote(Quotation quote) async {
    final items = await widget.repository.items(quote.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760, maxHeight: 700),
              child: Column(children: [
                ListTile(
                    title: Text('Quotation ${quote.reference}'),
                    trailing: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context))),
                Expanded(
                    child:
                        ListView(padding: const EdgeInsets.all(24), children: [
                  Text(
                      'Status: ${quote.status == 'open' && quote.validUntil != null && quote.validUntil!.isBefore(DateTime.now()) ? 'Expired' : quote.status[0].toUpperCase() + quote.status.substring(1)}'),
                  Text(
                      'Customer: ${customers.where((c) => c.id == quote.customerId).firstOrNull?.name ?? 'Walk-in'}'),
                  Text(
                      'Created: ${MaterialLocalizations.of(context).formatMediumDate(quote.createdAt)}'),
                  Text(
                      'Valid until: ${quote.validUntil == null ? 'No expiry' : MaterialLocalizations.of(context).formatMediumDate(quote.validUntil!)}'),
                  const Divider(height: 32),
                  Text('Items', style: Theme.of(context).textTheme.titleMedium),
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
                  TransactionTotal('Total',
                      items.fold(0, (sum, item) => sum + item.lineTotalCents),
                      strong: true),
                  if (quote.notes?.isNotEmpty == true) ...[
                    const SizedBox(height: 16),
                    Text('Notes: ${quote.notes}')
                  ],
                  const SizedBox(height: 16),
                  const Text(
                      'Stock is checked again when this quotation is converted to a sale.'),
                ])),
                if (quote.status == 'open' &&
                    (quote.validUntil == null ||
                        !quote.validUntil!.isBefore(DateTime.now())))
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: FilledButton(
                          onPressed: () {
                            Navigator.pop(context);
                            convert(quote);
                          },
                          child: const Text('Convert to sale'))),
              ]))),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Quotations'), actions: [
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
                label: const Text('New quotation'))),
        const SizedBox(height: 16),
        TextField(
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Search quote or customer',
                border: OutlineInputBorder()),
            onChanged: (value) => setState(() => query = value.toLowerCase())),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          for (final status in ['all', 'open', 'expired', 'converted'])
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
                      'No quotations yet. Create a quote to give customers a priced offer before checkout.'))),
        for (final row in rows)
          if (filter == 'all' ||
              filter == row.status ||
              filter == 'expired' &&
                  row.status == 'open' &&
                  row.validUntil != null &&
                  row.validUntil!.isBefore(DateTime.now()))
            if ('${row.reference} ${customers.where((c) => c.id == row.customerId).firstOrNull?.name ?? 'Walk-in'}'
                .toLowerCase()
                .contains(query))
              ListTile(
                  onTap: () => showQuote(row),
                  title: Text(
                      'Quote ${row.reference} · ${customers.where((c) => c.id == row.customerId).firstOrNull?.name ?? 'Walk-in'}'),
                  subtitle: Text(
                      '${MaterialLocalizations.of(context).formatMediumDate(row.createdAt)}${row.validUntil == null ? '' : ' · Valid until ${MaterialLocalizations.of(context).formatMediumDate(row.validUntil!)}'}'),
                  trailing: Chip(
                      label: Text(row.status == 'open' &&
                              row.validUntil != null &&
                              row.validUntil!.isBefore(DateTime.now())
                          ? 'Expired'
                          : row.status[0].toUpperCase() +
                              row.status.substring(1)))),
      ]));
}
