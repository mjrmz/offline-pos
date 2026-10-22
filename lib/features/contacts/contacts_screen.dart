import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../data/database.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/customer_credit_repository.dart';
import '../../data/daos/sale_return_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../core/services/sales_service.dart';
import '../../hardware/printer/receipt_service.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/utils/money.dart';
import '../../shared/widgets/app_workspace.dart';
import 'customer_profile_screen.dart';
import 'customer_profile_ui.dart';
import 'supplier_profile_drawer.dart';
import '../../shared/widgets/record_details_drawer.dart';

class ContactsScreen extends StatefulWidget {
  final DirectoryRepository repository;
  final ActiveUser user;
  final SalesService? sales;
  final PosRepository? pos;
  final ReceiptService? receipts;
  const ContactsScreen(
      {super.key,
      required this.repository,
      required this.user,
      this.sales,
      this.pos,
      this.receipts});
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  bool suppliers = false;
  String search = '';
  int page = 0;
  Future<void> _openCustomer(Customer row) => showRecordDetailsDrawer<void>(
          context: context,
          builder: (context) => Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                  width: (MediaQuery.sizeOf(context).width * .58)
                      .clamp(0, 880)
                      .toDouble(),
                  height: double.infinity,
                  child: CustomerProfileScreen(
                      customer: row,
                      repository:
                          CustomerCreditRepository(widget.repository.db),
                      user: widget.user,
                      sales: widget.sales,
                      pos: widget.pos,
                      receipts: widget.receipts,
                      onEdit: () => edit(customer: row))))).then((_) {
        if (mounted) setState(() {});
      });

  Future<void> _openSupplier(Supplier row) => showRecordDetailsDrawer<void>(
              context: context,
              builder: (context) => Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                      width: MediaQuery.sizeOf(context)
                          .width
                          .clamp(0, 800)
                          .toDouble(),
                      height: double.infinity,
                      child: SupplierProfileDrawer(
                          supplier: row,
                          user: widget.user,
                          onEdit: () => edit(supplier: row),
                          repository:
                              StockReceivingRepository(widget.repository.db)))))
          .then((_) {
        if (mounted) setState(() {});
      });
  String _customerSubtitle(Customer row, CustomerSummary? summary) {
    if (summary == null) return row.phone ?? 'No phone';
    final last = summary.lastPurchase == null
        ? 'No purchases'
        : MaterialLocalizations.of(context)
            .formatMediumDate(summary.lastPurchase!);
    return '${row.phone ?? 'No phone'}\n'
        '${summary.purchases} ${summary.purchases == 1 ? 'purchase' : 'purchases'} · Last $last · ${summary.points} pts'
        '${summary.creditCents == 0 || !widget.user.can(PosPermission.customerCredit) ? '' : ' · ${formatPeso(summary.creditCents)} credit'}';
  }

  Future<List<Object>> _loadPage() async {
    if (suppliers) {
      final total = await widget.repository.countSuppliers(search);
      final rows = await widget.repository.supplierPage(search, page);
      final now = DateTime.now();
      final summaries = await widget.repository.supplierSummaries(rows,
          DateTime(now.year, now.month), DateTime(now.year, now.month + 1));
      return [total, rows, summaries];
    }
    final total = await widget.repository.countCustomers(search);
    final rows = await widget.repository.customerPage(search, page);
    final summaries = await widget.repository
        .customerSummaries(ids: rows.map((row) => row.id).toList());
    return [total, rows, summaries];
  }

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
          body: Column(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: AppPageHeader(
                title: 'Customers & Suppliers',
                subtitle:
                    'Manage customer relationships, supplier records, purchasing history, and account activity.',
                action: widget.user.can(PosPermission.manageContacts)
                    ? FilledButton.icon(
                        onPressed: () => edit(),
                        icon: const Icon(Icons.add),
                        label:
                            Text('Add ${suppliers ? 'supplier' : 'customer'}'))
                    : null)),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: AppWorkspaceTabs(
                labels: const ['Customers', 'Suppliers'],
                selectedIndex: suppliers ? 1 : 0,
                onSelected: (index) => setState(() {
                      suppliers = index == 1;
                      search = '';
                      page = 0;
                    }))),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: AppSearchField(
                key: ValueKey(suppliers),
                hintText: suppliers
                    ? 'Search supplier or contact...'
                    : 'Search customer or phone...',
                onChanged: (value) => setState(() {
                      search = value.toLowerCase().trim();
                      page = 0;
                    }))),
        Expanded(
            child: FutureBuilder<List<Object>>(
                key: ValueKey('$suppliers:$search:$page'),
                future: _loadPage(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text(safeMessage(snapshot.error!)));
                  }
                  final data = snapshot.data;
                  final total = data == null ? 0 : data[0] as int;
                  final rows =
                      data == null ? <dynamic>[] : data[1] as List<dynamic>;
                  final summaries = data == null || suppliers
                      ? <String, CustomerSummary>{}
                      : data[2] as Map<String, CustomerSummary>;
                  final supplierSummaries = data == null || !suppliers
                      ? <String, SupplierListSummary>{}
                      : data[2] as Map<String, SupplierListSummary>;
                  return Padding(
                      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                      child: AppPagedListPanel(
                          title: suppliers ? 'Suppliers' : 'Customers',
                          total: total,
                          count: rows.length,
                          loading: data == null,
                          page: page,
                          onPrevious: () => setState(() => page--),
                          onNext: () => setState(() => page++),
                          emptyTitle:
                              'No ${suppliers ? 'suppliers' : 'customers'} found.',
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            if (row is Customer) {
                              final summary = summaries[row.id];
                              return AppEntityRow(
                                  title: row.name,
                                  subtitle: _customerSubtitle(row, summary),
                                  amount: summary == null
                                      ? null
                                      : formatPeso(summary.lifetimeCents),
                                  status: summary == null
                                      ? null
                                      : AppSemanticStatusBadge(
                                          label: summary.group),
                                  onTap: () => _openCustomer(row));
                            }
                            final supplier = row as Supplier;
                            final summary = supplierSummaries[supplier.id];
                            String dateOrNone(DateTime? date) => date == null
                                ? 'None'
                                : MaterialLocalizations.of(context)
                                    .formatMediumDate(date);
                            return AppEntityRow(
                                title: supplier.name,
                                subtitle:
                                    '${supplier.contact ?? supplier.phone ?? 'No contact'}\n'
                                    'Last receiving ${dateOrNone(summary?.lastReceiving)} · Last PO ${dateOrNone(summary?.lastOrder)}',
                                amount: summary == null ||
                                        !widget.user.can(PosPermission.reports)
                                    ? null
                                    : '${formatPeso(summary.purchasedCents)} this month',
                                status: AppSemanticStatusBadge(
                                    label: supplier.isActive
                                        ? 'Active'
                                        : 'Inactive'),
                                onTap: () => _openSupplier(supplier));
                          }));
                })),
      ]));
}

class CustomerDetailsScreen extends StatefulWidget {
  final Customer customer;
  final CustomerCreditRepository repository;
  final ActiveUser user;
  final bool embedded;
  const CustomerDetailsScreen(
      {super.key,
      required this.customer,
      required this.repository,
      required this.user,
      this.embedded = false});
  @override
  State<CustomerDetailsScreen> createState() => _CustomerDetailsScreenState();
}

class _CustomerDetailsScreenState extends State<CustomerDetailsScreen> {
  int creditPage = 0;

  @override
  void didUpdateWidget(covariant CustomerDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.customer.id != widget.customer.id) creditPage = 0;
  }

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
                    title: const Text('Record credit payment'),
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
  Widget build(BuildContext context) {
    final content = FutureBuilder(
      future: Future.wait<Object>([
        widget.repository.balance(widget.customer.id),
        widget.embedded
            ? widget.repository.entriesPage(widget.customer.id, creditPage)
            : widget.repository.entries(widget.customer.id),
        widget.embedded
            ? Future.value(<Sale>[])
            : widget.repository.purchases(widget.customer.id),
        widget.repository.refundObligations(widget.customer.id),
        widget.embedded
            ? Future.value(<CommercialReturn>[])
            : SaleReturnRepository(widget.repository.db)
                .forCustomer(widget.customer.id),
        widget.repository.activitySummary(widget.customer.id),
      ]),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text(safeMessage(snapshot.error!)));
        }
        if (snapshot.connectionState != ConnectionState.done ||
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final balance = snapshot.data![0] as int;
        final entries = snapshot.data![1] as List<CustomerCreditEntry>;
        final purchases = snapshot.data![2] as List<Sale>;
        final refunds = snapshot.data![3] as List<CustomerRefundObligation>;
        final returns = snapshot.data![4] as List<CommercialReturn>;
        final activity = snapshot.data![5] as CustomerCreditActivitySummary;
        if (widget.embedded) {
          return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                CustomerProfileKpis([
                  ('Outstanding credit', formatPeso(balance)),
                  ('Credit purchases', '${activity.creditSales}'),
                  ('Payments', '${activity.payments}'),
                  (
                    'Last credit activity',
                    activity.lastActivity == null
                        ? '—'
                        : MaterialLocalizations.of(context)
                            .formatMediumDate(activity.lastActivity!)
                  ),
                ]),
                if (balance > 0) ...[
                  const SizedBox(height: 10),
                  Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton(
                          onPressed: recordPayment,
                          child: const Text('Record payment'))),
                ],
                if (refunds.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  CustomerProfilePanel(
                      title: 'Customer refunds due',
                      count: refunds.length,
                      child: Column(children: [
                        for (final obligation in refunds)
                          ListTile(
                              title: Text(obligation.saleId == null
                                  ? 'Layaway refund'
                                  : 'Sale refund'),
                              subtitle: Text(
                                  '${formatPeso(obligation.settledCents)} returned of ${formatPeso(obligation.amountCents)}'),
                              trailing: obligation.settledCents <
                                      obligation.amountCents
                                  ? TextButton(
                                      onPressed: () => settleRefund(obligation),
                                      child: const Text('Return balance'))
                                  : null),
                      ])),
                ],
                const SizedBox(height: 20),
                Expanded(
                    child: FutureBuilder<Map<String, String>>(
                        future: widget.repository.saleReferences(entries),
                        builder: (context, referenceSnapshot) {
                          if (referenceSnapshot.hasError) {
                            return Center(
                                child: Text(
                                    safeMessage(referenceSnapshot.error!)));
                          }
                          if (referenceSnapshot.connectionState !=
                                  ConnectionState.done ||
                              !referenceSnapshot.hasData) {
                            return const Center(
                                child: CircularProgressIndicator());
                          }
                          final references = referenceSnapshot.data!;
                          return AppPagedListPanel(
                              title: 'Credit activity',
                              total: activity.total,
                              count: entries.length,
                              page: creditPage,
                              emptyTitle: 'No credit activity',
                              emptyMessage:
                                  'Credit sales and related activity will appear here.',
                              onPrevious: () => setState(() => creditPage--),
                              onNext: () => setState(() => creditPage++),
                              itemBuilder: (context, index) {
                                final entry = entries[index];
                                return Card(
                                    margin: EdgeInsets.zero,
                                    child: ListTile(
                                        dense: true,
                                        title: Text(entry.kind == 'credit_sale'
                                            ? 'Credit sale'
                                            : entry.kind == 'payment'
                                                ? 'Payment'
                                                : 'Sale reversal'),
                                        subtitle: Text(
                                            '${MaterialLocalizations.of(context).formatMediumDate(entry.createdAt)}${entry.saleId == null ? '' : ' · ${references[entry.saleId] ?? 'Sale ${entry.saleId!.substring(0, 8)}'}'}${entry.paymentMethod == null ? '' : ' · ${entry.paymentMethod == 'gcash' ? 'Confirmed GCash' : 'Cash'}'}${entry.note == null ? '' : ' · ${entry.note}'}'),
                                        trailing: Text(
                                            '${entry.amountCents >= 0 ? '+' : ''}${formatPeso(entry.amountCents)}')));
                              });
                        }))
              ]));
        }
        return ListView(padding: const EdgeInsets.all(16), children: [
          if (!widget.embedded && widget.customer.phone != null)
            Text('Phone: ${widget.customer.phone}'),
          if (!widget.embedded && widget.customer.address != null)
            Text('Address: ${widget.customer.address}'),
          if (!widget.embedded && widget.customer.notes != null)
            Text('Notes: ${widget.customer.notes}'),
          CustomerProfileKpis([
            ('Outstanding credit', formatPeso(balance)),
            (
              'Credit purchases',
              '${entries.where((e) => e.kind == 'credit_sale').length}'
            ),
            ('Payments', '${entries.where((e) => e.kind == 'payment').length}'),
            (
              'Last credit activity',
              entries.isEmpty
                  ? '—'
                  : MaterialLocalizations.of(context)
                      .formatMediumDate(entries.last.createdAt)
            ),
          ]),
          if (balance > 0 && widget.user.can(PosPermission.customerCredit))
            FilledButton(
                onPressed: recordPayment, child: const Text('Record payment')),
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
                trailing: obligation.settledCents < obligation.amountCents &&
                        widget.user.can(PosPermission.customerCredit)
                    ? FilledButton(
                        onPressed: () => settleRefund(obligation),
                        child: const Text('Return balance'))
                    : null,
              ),
          ],
          if (!widget.embedded) ...[
            const Divider(),
            const Text('Purchases'),
            if (purchases.isEmpty) const Text('No purchases linked yet'),
            for (final sale in purchases)
              Column(children: [
                ListTile(
                    title: Text(
                        'Sale ${sale.receiptNumber ?? (sale.birInvoiceNumber == null ? 'Legacy sale' : '#${sale.birInvoiceNumber}')}'),
                    subtitle: Text(MaterialLocalizations.of(context)
                        .formatMediumDate(sale.createdAt)),
                    trailing: Text(formatPeso(sale.totalCents))),
                for (final row in returns.where((r) => r.saleId == sale.id))
                  ListTile(
                      contentPadding: const EdgeInsets.only(left: 28),
                      title: Text(
                          '${row.reference} Â· ${row.kind == 'exchange' ? 'Exchange' : 'Return'}'),
                      subtitle: Text(MaterialLocalizations.of(context)
                          .formatMediumDate(row.createdAt)),
                      trailing: Text(row.cashEffectCents < 0
                          ? '${formatPeso(-row.cashEffectCents)} refunded'
                          : row.cashEffectCents > 0
                              ? '${formatPeso(row.cashEffectCents)} paid'
                              : 'No cash movement'))
              ]),
          ],
          const SizedBox(height: 20),
          CustomerProfilePanel(
              title: 'Credit activity',
              count: entries.length,
              child: entries.isEmpty
                  ? const CustomerProfileEmpty('No credit activity',
                      'Credit sales and related activity will appear here.')
                  : Column(children: [
                      for (final entry in entries.reversed)
                        ListTile(
                            title: Text(entry.kind == 'credit_sale'
                                ? 'Credit sale'
                                : entry.kind == 'payment'
                                    ? 'Payment'
                                    : 'Sale reversal'),
                            subtitle: Text(
                                '${MaterialLocalizations.of(context).formatMediumDate(entry.createdAt)}${entry.paymentMethod == null ? '' : ' Â· ${entry.paymentMethod == 'gcash' ? 'Confirmed GCash' : 'Cash'}'}${entry.note == null ? '' : ' Â· ${entry.note}'}'),
                            trailing: Text(
                                '${entry.amountCents >= 0 ? '+' : ''}${formatPeso(entry.amountCents)}')),
                    ])),
        ]);
      },
    );
    return widget.embedded
        ? content
        : Scaffold(
            appBar: AppBar(title: Text(widget.customer.name)), body: content);
  }
}
