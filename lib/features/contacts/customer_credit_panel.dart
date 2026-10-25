import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../data/daos/customer_credit_repository.dart';
import '../../data/daos/receivables_reporting_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/app_workspace.dart';
import 'customer_statement_dialog.dart';

class CustomerCreditPanel extends StatefulWidget {
  const CustomerCreditPanel(
      {super.key,
      required this.customer,
      required this.repository,
      required this.user});
  final Customer customer;
  final CustomerCreditRepository repository;
  final ActiveUser user;
  @override
  State<CustomerCreditPanel> createState() => _CustomerCreditPanelState();
}

class _CustomerCreditPanelState extends State<CustomerCreditPanel> {
  late Future<CustomerCreditSnapshot> data =
      widget.repository.snapshot(widget.customer.id);
  late Future<CustomerAging> agingData = reporting.aging(widget.customer.id);
  ReceivablesReportingRepository get reporting =>
      ReceivablesReportingRepository(widget.repository.db);
  int salesPage = 0, ledgerPage = 0;
  int revision = 0;
  void reload() => setState(() {
        revision++;
        data = widget.repository.snapshot(widget.customer.id);
        agingData = reporting.aging(widget.customer.id);
      });

  @override
  void didUpdateWidget(covariant CustomerCreditPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.customer.id != widget.customer.id ||
        oldWidget.repository != widget.repository) {
      salesPage = 0;
      ledgerPage = 0;
      revision++;
      data = widget.repository.snapshot(widget.customer.id);
      agingData = reporting.aging(widget.customer.id);
    }
  }

  Future<void> editLimit(CustomerCreditSnapshot state) async {
    final controller = TextEditingController(
        text: state.creditLimitCents == null
            ? ''
            : (state.creditLimitCents! / 100).toStringAsFixed(2));
    String? error;
    try {
      await showDialog<void>(
          context: context,
          builder: (dialog) => StatefulBuilder(
              builder: (dialog, update) => AlertDialog(
                    title: const Text('Credit limit'),
                    content: TextField(
                        controller: controller,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: InputDecoration(
                            labelText: 'Limit in pesos (blank for none)',
                            errorText: error)),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialog),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () async {
                            final raw = controller.text.trim();
                            final cents =
                                raw.isEmpty ? null : tryParsePeso(raw);
                            if (raw.isNotEmpty && cents == null) {
                              update(() => error = 'Enter a valid peso amount');
                              return;
                            }
                            try {
                              await widget.repository.setCreditLimit(
                                  widget.user, widget.customer.id, cents);
                              if (dialog.mounted) Navigator.pop(dialog);
                              reload();
                            } catch (e) {
                              update(() => error = safeMessage(e));
                            }
                          },
                          child: const Text('Save'))
                    ],
                  )));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      controller.dispose();
    }
  }

  Future<void> recordPayment(CustomerCreditSnapshot state) async {
    final amount = TextEditingController();
    final note = TextEditingController();
    String method = 'cash';
    String? saleId;
    String? error;
    bool saving = false;
    try {
      await showDialog<void>(
          context: context,
          builder: (dialog) => StatefulBuilder(
              builder: (dialog, update) => AlertDialog(
                    title: const Text('Record customer payment'),
                    content: SizedBox(
                        width: 420,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(
                                  'Outstanding: ${formatPeso(state.outstandingCents)}'),
                              TextField(
                                  controller: amount,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                  decoration: InputDecoration(
                                      labelText: 'Amount received',
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
                                  onChanged: saving
                                      ? null
                                      : (v) =>
                                          update(() => method = v ?? method)),
                              DropdownButtonFormField<String>(
                                  initialValue: saleId,
                                  decoration: const InputDecoration(
                                      labelText: 'Allocation'),
                                  items: [
                                    const DropdownMenuItem(
                                        value: null,
                                        child: Text(
                                            'Automatic — oldest balance first')),
                                    for (final sale in state.sales
                                        .where((s) => s.remainingCents > 0))
                                      DropdownMenuItem(
                                          value: sale.sale.id,
                                          child: Text(
                                              '${sale.reference} — ${formatPeso(sale.remainingCents)}'))
                                  ],
                                  onChanged: saving
                                      ? null
                                      : (v) => update(() => saleId = v)),
                              TextField(
                                  controller: note,
                                  decoration: const InputDecoration(
                                      labelText: 'Notes (optional)')),
                            ]))),
                    actions: [
                      TextButton(
                          onPressed:
                              saving ? null : () => Navigator.pop(dialog),
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
                                  update(() {
                                    saving = true;
                                    error = null;
                                  });
                                  try {
                                    await widget.repository.payment(widget.user,
                                        widget.customer.id, cents, method,
                                        note: note.text, saleId: saleId);
                                    if (dialog.mounted) Navigator.pop(dialog);
                                    reload();
                                  } catch (e) {
                                    update(() {
                                      error = safeMessage(e);
                                      saving = false;
                                    });
                                  }
                                },
                          child: Text(saving ? 'Posting…' : 'Record payment'))
                    ],
                  )));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      amount.dispose();
      note.dispose();
    }
  }

  Future<void> viewStatement() async {
    if (!widget.user.can(PosPermission.customerCredit)) return;
    await showDialog<void>(
        context: context,
        builder: (_) => CustomerStatementDialog(
            customer: widget.customer,
            repository: reporting,
            user: widget.user));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CustomerCreditSnapshot>(
      key: ValueKey(revision),
      future: data,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text(safeMessage(snapshot.error!)));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final state = snapshot.data!;
        final open = state.sales.where((s) => s.remainingCents > 0).toList();
        final sales = open.skip(salesPage * 50).take(50).toList();
        final ledger =
            state.ledger.reversed.skip(ledgerPage * 50).take(50).toList();
        return ListView(padding: const EdgeInsets.all(20), children: [
          Text('Customer Credit / Receivables',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, children: [
            _metric(context, 'Outstanding balance',
                formatPeso(state.outstandingCents)),
            _metric(
                context,
                'Credit limit',
                state.creditLimitCents == null
                    ? 'No limit set'
                    : formatPeso(state.creditLimitCents!)),
            _metric(
                context,
                'Available credit',
                state.availableCents == null
                    ? '—'
                    : formatPeso(state.availableCents!)),
            _metric(context, 'Open credit sales', '${state.openSales}'),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            if (state.outstandingCents > 0 &&
                widget.user.can(PosPermission.customerCredit))
              FilledButton.icon(
                  onPressed: () => recordPayment(state),
                  icon: const Icon(Icons.payments_outlined),
                  label: const Text('Record payment')),
            if (widget.user.can(PosPermission.manageContacts))
              OutlinedButton(
                  onPressed: () => editLimit(state),
                  child: const Text('Set credit limit')),
            if (widget.user.can(PosPermission.customerCredit))
              OutlinedButton.icon(
                  onPressed: viewStatement,
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Customer Statement')),
          ]),
          const SizedBox(height: 16),
          Text('Aging', style: Theme.of(context).textTheme.titleMedium),
          const Text('Aging is based on credit sale date.'),
          FutureBuilder<CustomerAging>(
              future: agingData,
              builder: (context, aged) {
                if (aged.hasError) return Text(safeMessage(aged.error!));
                if (!aged.hasData) return const LinearProgressIndicator();
                return Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final label in CustomerAging.labels)
                    _metric(context, label,
                        formatPeso(aged.data!.buckets[label] ?? 0)),
                ]);
              }),
          const SizedBox(height: 20),
          SizedBox(
              height: 320,
              child: AppPagedListPanel(
                  title: 'Open credit sales',
                  total: open.length,
                  count: sales.length,
                  page: salesPage,
                  emptyTitle: 'No open credit sales',
                  emptyMessage: 'Outstanding credit sales appear here.',
                  onPrevious: () => setState(() => salesPage--),
                  onNext: () => setState(() => salesPage++),
                  itemBuilder: (context, i) {
                    final sale = sales[i];
                    return ListTile(
                        title: Text(sale.reference),
                        subtitle: Text(
                            '${MaterialLocalizations.of(context).formatMediumDate(sale.sale.createdAt)} • ${sale.status} • Age ${DateTime.now().difference(DateTime(sale.sale.createdAt.year, sale.sale.createdAt.month, sale.sale.createdAt.day)).inDays.clamp(0, 999999)} days'),
                        trailing: Text(
                            'Original ${formatPeso(sale.originalCents)}  Paid ${formatPeso(sale.paidCents)}  Balance ${formatPeso(sale.remainingCents)}'));
                  })),
          const SizedBox(height: 20),
          SizedBox(
              height: 320,
              child: AppPagedListPanel(
                  title: 'Credit activity',
                  total: state.ledger.length,
                  count: ledger.length,
                  page: ledgerPage,
                  emptyTitle: 'No credit activity',
                  emptyMessage: 'Credit sales and payments appear here.',
                  onPrevious: () => setState(() => ledgerPage--),
                  onNext: () => setState(() => ledgerPage++),
                  itemBuilder: (context, i) {
                    final line = ledger[i], e = line.entry;
                    final label = e.kind == 'credit_sale'
                        ? 'Credit sale'
                        : e.kind == 'payment'
                            ? 'Payment'
                            : 'Credit adjustment';
                    return ListTile(
                        title: Text('${line.reference} • $label'),
                        subtitle: Text(MaterialLocalizations.of(context)
                            .formatMediumDate(e.createdAt)),
                        trailing: Text(
                            '${e.amountCents >= 0 ? 'Charge ${formatPeso(e.amountCents)}' : 'Credit ${formatPeso(-e.amountCents)}'}  Balance ${formatPeso(line.runningCents)}'));
                  })),
        ]);
      });

  Widget _metric(BuildContext context, String label, String value) => SizedBox(
      width: 190,
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(height: 6),
                    Text(value, style: Theme.of(context).textTheme.titleMedium),
                  ]))));
}
