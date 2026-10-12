import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../data/database.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/customer_credit_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/utils/money.dart';
import '../../core/models/quantity.dart';

class ContactsScreen extends StatefulWidget {
  final DirectoryRepository repository;
  final ActiveUser user;
  const ContactsScreen(
      {super.key, required this.repository, required this.user});
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  bool suppliers = false;
  String search = '';
  Future<void> edit({Customer? customer, Supplier? supplier}) async {
    final name = TextEditingController(text: customer?.name ?? supplier?.name);
    final phone =
        TextEditingController(text: customer?.phone ?? supplier?.phone);
    final address =
        TextEditingController(text: customer?.address ?? supplier?.address);
    final notes =
        TextEditingController(text: customer?.notes ?? supplier?.notes);
    final contact = TextEditingController(text: supplier?.contact);
    var active = customer?.isActive ?? supplier?.isActive ?? true;
    String? error;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text(customer == null && supplier == null
                ? 'Add ${suppliers ? 'supplier' : 'customer'}'
                : 'Edit ${suppliers ? 'supplier' : 'customer'}'),
            content: SizedBox(
                width: 380,
                child: ListView(shrinkWrap: true, children: [
                  TextField(
                      controller: name,
                      autofocus: true,
                      decoration:
                          InputDecoration(labelText: 'Name', errorText: error)),
                  if (suppliers)
                    TextField(
                        controller: contact,
                        decoration: const InputDecoration(
                            labelText: 'Contact person (optional)')),
                  TextField(
                      controller: phone,
                      keyboardType: TextInputType.phone,
                      decoration:
                          const InputDecoration(labelText: 'Phone (optional)')),
                  TextField(
                      controller: address,
                      decoration: const InputDecoration(
                          labelText: 'Address (optional)')),
                  TextField(
                      controller: notes,
                      decoration:
                          const InputDecoration(labelText: 'Notes (optional)')),
                  if (customer != null || supplier != null)
                    SwitchListTile(
                        title: const Text('Active'),
                        value: active,
                        onChanged: (value) => update(() => active = value)),
                ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () async {
                    if (name.text.trim().isEmpty) {
                      update(() => error = 'Name is required');
                      return;
                    }
                    try {
                      if (suppliers) {
                        await widget.repository.saveSupplier(widget.user,
                            id: supplier?.id,
                            name: name.text,
                            contact: contact.text,
                            phone: phone.text,
                            address: address.text,
                            notes: notes.text,
                            active: active);
                      } else {
                        await widget.repository.saveCustomer(widget.user,
                            id: customer?.id,
                            name: name.text,
                            phone: phone.text,
                            address: address.text,
                            notes: notes.text,
                            active: active);
                      }
                      if (context.mounted) {
                        Navigator.pop(context);
                      }
                      if (mounted) {
                        setState(() {});
                      }
                    } catch (failure) {
                      update(() => error = safeMessage(failure));
                    }
                  },
                  child: const Text('Save')),
            ],
          ),
        ),
      );
    } finally {
      // Let the reverse route transition finish before disposing field controllers.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      name.dispose();
      phone.dispose();
      address.dispose();
      notes.dispose();
      contact.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Customers & suppliers')),
        body: Column(children: [
          if (widget.user.can(PosPermission.manageContacts))
            SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Customers')),
                  ButtonSegment(value: true, label: Text('Suppliers')),
                ],
                selected: {
                  suppliers
                },
                onSelectionChanged: (value) => setState(() {
                      suppliers = value.first;
                      search = '';
                    })),
          Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    labelText:
                        'Search ${suppliers ? 'suppliers' : 'customers'}'),
                onChanged: (value) =>
                    setState(() => search = value.toLowerCase().trim()),
              )),
          Expanded(
              child: FutureBuilder(
            future: suppliers
                ? widget.repository.suppliers()
                : widget.repository.customers(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text(safeMessage(snapshot.error!)));
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = snapshot.data!;
              final filtered = rows.where((row) {
                final name =
                    row is Customer ? row.name : (row as Supplier).name;
                return name.toLowerCase().contains(search);
              }).toList();
              if (filtered.isEmpty) {
                return Center(
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Card(
                            child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                          search.isEmpty
                                              ? 'No ${suppliers ? 'suppliers' : 'customers'} yet'
                                              : 'No matching records',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium),
                                      const SizedBox(height: 8),
                                      Text(search.isEmpty
                                          ? suppliers
                                              ? 'Add suppliers to record stock receiving and supplier RMA.'
                                              : 'Add customers to track purchases, credit, RMA, and layaways.'
                                          : 'Try a different name.'),
                                      if (search.isEmpty &&
                                          widget.user.can(
                                              PosPermission.manageContacts))
                                        TextButton.icon(
                                            onPressed: () => edit(),
                                            icon: const Icon(Icons.add),
                                            label: Text(
                                                'Add ${suppliers ? 'supplier' : 'customer'}')),
                                    ])))));
              }
              return ListView(padding: const EdgeInsets.all(8), children: [
                for (final row in filtered)
                  Card(
                      child: ListTile(
                    title: Text(
                        row is Customer ? row.name : (row as Supplier).name),
                    subtitle: Text(row is Customer
                        ? '${row.phone ?? 'No phone'}${row.isActive ? '' : ' · Inactive'}'
                        : '${(row as Supplier).phone ?? 'No phone'}${row.isActive ? '' : ' · Inactive'}'),
                    onTap: () => row is Customer
                        ? Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                                builder: (_) => CustomerDetailsScreen(
                                    customer: row,
                                    repository: CustomerCreditRepository(
                                        widget.repository.db),
                                    user: widget.user)))
                        : Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                                builder: (_) => SupplierDetailsScreen(
                                    supplier: row as Supplier,
                                    repository: StockReceivingRepository(
                                        widget.repository.db)))),
                    trailing: widget.user.can(PosPermission.manageContacts)
                        ? IconButton(
                            tooltip: 'Edit',
                            icon: const Icon(Icons.edit),
                            onPressed: () => edit(
                                customer: row is Customer ? row : null,
                                supplier: row is Supplier ? row : null))
                        : null,
                  ))
              ]);
            },
          )),
        ]),
        floatingActionButton: widget.user.can(PosPermission.manageContacts)
            ? FloatingActionButton.extended(
                heroTag: 'contacts-add',
                onPressed: () => edit(),
                icon: const Icon(Icons.add),
                label: Text('Add ${suppliers ? 'supplier' : 'customer'}'),
              )
            : null,
      );
}

class SupplierDetailsScreen extends StatelessWidget {
  final Supplier supplier;
  final StockReceivingRepository repository;
  const SupplierDetailsScreen(
      {super.key, required this.supplier, required this.repository});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(supplier.name)),
        body: FutureBuilder(
          future: repository.history(supplierId: supplier.id),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text(safeMessage(snapshot.error!)));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final rows = snapshot.data!;
            return ListView(padding: const EdgeInsets.all(16), children: [
              Text(supplier.contact ?? ''),
              Text(supplier.phone ?? ''),
              Text(supplier.address ?? ''),
              Text(supplier.notes ?? ''),
              const Divider(),
              const Text('Receiving history'),
              if (rows.isEmpty) const Text('No deliveries recorded yet'),
              for (final row in rows)
                FutureBuilder(
                  future: repository.items(row.id),
                  builder: (context, items) => ListTile(
                    onTap: items.hasData
                        ? () async {
                            final details = <Widget>[];
                            for (final item in items.data!) {
                              final product = await (repository.db
                                      .select(repository.db.products)
                                    ..where((p) => p.id.equals(item.productId)))
                                  .getSingleOrNull();
                              final serials =
                                  await repository.serialsForItem(item.id);
                              details.add(ListTile(
                                title: Text(product?.name ?? 'Product'),
                                subtitle: Text(
                                    '${Quantity.format(item.quantityMilli)} · ${formatPeso(item.unitCostCents)} / unit${item.batchNumber == null ? '' : ' · ${item.batchNumber}'}${serials.isEmpty ? '' : '\nSerials: ${serials.map((s) => s.serialNumber).join(', ')}'}'),
                              ));
                            }
                            if (!context.mounted) return;
                            await showDialog<void>(
                                context: context,
                                builder: (context) => AlertDialog(
                                      title: Text(
                                          row.externalReference ?? 'Delivery'),
                                      content: SizedBox(
                                          width: 450,
                                          child: ListView(
                                              shrinkWrap: true,
                                              children: details)),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            child: const Text('Close'))
                                      ],
                                    ));
                          }
                        : null,
                    title: Text(row.externalReference ?? 'Delivery'),
                    subtitle: Text(MaterialLocalizations.of(context)
                        .formatMediumDate(row.receivedAt)),
                    trailing: Text(
                        items.hasData ? '${items.data!.length} items' : '…'),
                  ),
                ),
            ]);
          },
        ),
      );
}

class CustomerDetailsScreen extends StatefulWidget {
  final Customer customer;
  final CustomerCreditRepository repository;
  final ActiveUser user;
  const CustomerDetailsScreen(
      {super.key,
      required this.customer,
      required this.repository,
      required this.user});
  @override
  State<CustomerDetailsScreen> createState() => _CustomerDetailsScreenState();
}

class _CustomerDetailsScreenState extends State<CustomerDetailsScreen> {
  Future<void> settleRefund(CustomerRefundObligation obligation) async {
    final due = obligation.amountCents - obligation.settledCents;
    final amount = TextEditingController(text: (due / 100).toStringAsFixed(2));
    final note = TextEditingController();
    String method = 'cash';
    int? confirmedCents;
    try {
      confirmedCents = await showDialog<int>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: const Text('Settle customer refund'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('Refund due: ${formatPeso(due)}'),
                      TextField(
                          controller: amount,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Amount returned (pesos)')),
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
                      TextField(
                          controller: note,
                          decoration: const InputDecoration(
                              labelText: 'Note / reference (optional)')),
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () {
                            final cents = tryParsePeso(amount.text);
                            if (cents == null || cents <= 0 || cents > due) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Enter an amount within the refund due')));
                              return;
                            }
                            Navigator.pop(context, cents);
                          },
                          child: const Text('Confirm returned')),
                    ],
                  )));
      if (confirmedCents == null) return;
      try {
        await widget.repository.settleRefund(
            widget.user, obligation.id, confirmedCents, method,
            note: note.text);
        if (mounted) setState(() {});
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(safeMessage(error))));
        }
      }
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      amount.dispose();
      note.dispose();
    }
  }

  Future<void> recordPayment() async {
    final amount = TextEditingController();
    final note = TextEditingController();
    String method = 'cash';
    String? error;
    var saving = false;
    try {
      await showDialog<void>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: const Text('Record utang payment'),
                    content: SizedBox(
                        width: 350,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          TextField(
                              controller: amount,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: InputDecoration(
                                  labelText: 'Amount (pesos)',
                                  errorText: error)),
                          DropdownButtonFormField<String>(
                              initialValue: method,
                              decoration: const InputDecoration(
                                  labelText: 'Payment method'),
                              items: const [
                                DropdownMenuItem(
                                    value: 'cash', child: Text('Cash')),
                                DropdownMenuItem(
                                    value: 'gcash',
                                    child: Text('Confirmed GCash'))
                              ],
                              onChanged: (value) =>
                                  update(() => method = value ?? method)),
                          TextField(
                              controller: note,
                              decoration: const InputDecoration(
                                  labelText: 'Note (optional)')),
                        ])),
                    actions: [
                      TextButton(
                          onPressed:
                              saving ? null : () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: saving
                              ? null
                              : () async {
                                  final cents = tryParsePeso(amount.text);
                                  if (cents == null || cents <= 0) {
                                    update(() =>
                                        error = 'Enter a positive peso amount');
                                    return;
                                  }
                                  update(() => saving = true);
                                  try {
                                    await widget.repository.payment(widget.user,
                                        widget.customer.id, cents, method,
                                        note: note.text);
                                    if (context.mounted) Navigator.pop(context);
                                    if (mounted) setState(() {});
                                  } catch (failure) {
                                    update(() {
                                      error = safeMessage(failure);
                                      saving = false;
                                    });
                                  }
                                },
                          child: const Text('Record')),
                    ],
                  )));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      amount.dispose();
      note.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.customer.name)),
        body: FutureBuilder(
          future: Future.wait<Object>([
            widget.repository.balance(widget.customer.id),
            widget.repository.entries(widget.customer.id),
            widget.repository.purchases(widget.customer.id),
            widget.repository.refundObligations(widget.customer.id),
          ]),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text(safeMessage(snapshot.error!)));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final balance = snapshot.data![0] as int;
            final entries = snapshot.data![1] as List<CustomerCreditEntry>;
            final purchases = snapshot.data![2] as List<Sale>;
            final refunds = snapshot.data![3] as List<CustomerRefundObligation>;
            return ListView(padding: const EdgeInsets.all(16), children: [
              if (widget.customer.phone != null)
                Text('Phone: ${widget.customer.phone}'),
              if (widget.customer.address != null)
                Text('Address: ${widget.customer.address}'),
              if (widget.customer.notes != null)
                Text('Notes: ${widget.customer.notes}'),
              Text('Outstanding utang: ${formatPeso(balance)}'),
              if (balance > 0)
                FilledButton(
                    onPressed: recordPayment,
                    child: const Text('Record payment')),
              if (refunds.isNotEmpty) ...[
                const Divider(),
                const Text('Customer refunds due'),
                for (final obligation in refunds)
                  ListTile(
                    title: Text(obligation.saleId == null
                        ? 'Layaway ${obligation.layawayId?.substring(0, 8) ?? ''}'
                        : 'Sale ${obligation.saleId!.substring(0, 8)}'),
                    subtitle: Text(
                        '${formatPeso(obligation.settledCents)} returned of ${formatPeso(obligation.amountCents)}'),
                    trailing:
                        obligation.settledCents < obligation.amountCents &&
                                widget.user.can(PosPermission.customerCredit)
                            ? FilledButton(
                                onPressed: () => settleRefund(obligation),
                                child: const Text('Return balance'))
                            : null,
                  ),
              ],
              const Divider(),
              const Text('Purchases'),
              if (purchases.isEmpty) const Text('No purchases linked yet'),
              for (final sale in purchases)
                ListTile(
                    title: Text(
                        'Sale ${sale.birInvoiceNumber == null ? sale.id.substring(0, 8) : '#${sale.birInvoiceNumber}'}'),
                    subtitle: Text(MaterialLocalizations.of(context)
                        .formatMediumDate(sale.createdAt)),
                    trailing: Text(formatPeso(sale.totalCents))),
              const Divider(),
              const Text('Utang history'),
              if (entries.isEmpty) const Text('No credit transactions yet'),
              for (final entry in entries)
                ListTile(
                    title: Text(entry.kind == 'credit_sale'
                        ? 'Credit sale'
                        : entry.kind == 'payment'
                            ? 'Payment'
                            : 'Sale reversal'),
                    subtitle: Text(
                        '${MaterialLocalizations.of(context).formatMediumDate(entry.createdAt)}${entry.paymentMethod == null ? '' : ' · ${entry.paymentMethod == 'gcash' ? 'Confirmed GCash' : 'Cash'}'}${entry.note == null ? '' : ' · ${entry.note}'}'),
                    trailing: Text(
                        '${entry.amountCents >= 0 ? '+' : ''}${formatPeso(entry.amountCents)}')),
            ]);
          },
        ),
      );
}
