import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../core/models/active_user.dart';
import '../../data/daos/receivables_reporting_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/app_workspace.dart';
import 'customer_statement_pdf.dart';

class CustomerStatementDialog extends StatefulWidget {
  const CustomerStatementDialog(
      {super.key,
      required this.customer,
      required this.repository,
      required this.user});
  final Customer customer;
  final ReceivablesReportingRepository repository;
  final ActiveUser user;
  @override
  State<CustomerStatementDialog> createState() =>
      _CustomerStatementDialogState();
}

class _CustomerStatementDialogState extends State<CustomerStatementDialog> {
  String period = 'This month';
  DateTimeRange? custom;
  int page = 0;
  bool printing = false;
  String? error;
  late Future<StatementPage> data = _load();

  DateTimeRange get range {
    final today = DateTime.now();
    if (period == 'Custom' && custom != null) return custom!;
    if (period == 'Last month') {
      return DateTimeRange(
          start: DateTime(today.year, today.month - 1, 1),
          end: DateTime(today.year, today.month, 1)
              .subtract(const Duration(days: 1)));
    }
    if (period == 'This year') {
      return DateTimeRange(start: DateTime(today.year, 1, 1), end: today);
    }
    return DateTimeRange(
        start: DateTime(today.year, today.month, 1), end: today);
  }

  DateTime get exclusiveEnd =>
      DateTime(range.end.year, range.end.month, range.end.day + 1);
  Future<StatementPage> _load() => widget.repository
      .statementPage(widget.customer.id, range.start, exclusiveEnd, page: page);
  void refresh() => setState(() {
        page = 0;
        data = _load();
      });

  Future<void> choosePeriod(String value) async {
    if (value == 'Custom') {
      final selected = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2000),
          lastDate: DateTime.now().add(const Duration(days: 365)),
          initialDateRange: custom);
      if (selected == null) return;
      custom = selected;
    }
    period = value;
    refresh();
  }

  Future<void> printStatement() async {
    if (!widget.user.can(PosPermission.customerCredit)) return;
    setState(() {
      printing = true;
      error = null;
    });
    try {
      final bytes = await CustomerStatementPdf(widget.repository.db)
          .render(widget.customer.id, range.start, exclusiveEnd);
      await Printing.layoutPdf(
          onLayout: (_) async => bytes,
          name: 'Customer Statement - ${widget.customer.name}');
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      if (mounted) setState(() => printing = false);
    }
  }

  @override
  Widget build(BuildContext context) => !widget.user
          .can(PosPermission.customerCredit)
      ? const Dialog(
          child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Customer credit access required.')))
      : Dialog(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980, maxHeight: 720),
              child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text('Customer Statement',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall),
                                Text(widget.customer.name)
                              ])),
                          IconButton(
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close))
                        ]),
                        const SizedBox(height: 12),
                        DropdownButton<String>(
                            value: period,
                            items: [
                              for (final value in [
                                'This month',
                                'Last month',
                                'This year',
                                'Custom'
                              ])
                                DropdownMenuItem(
                                    value: value, child: Text(value))
                            ],
                            onChanged: (value) {
                              if (value != null) choosePeriod(value);
                            }),
                        Text(
                            '${MaterialLocalizations.of(context).formatMediumDate(range.start)} – ${MaterialLocalizations.of(context).formatMediumDate(range.end)}'),
                        if (error != null)
                          Text(error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                        const SizedBox(height: 12),
                        Expanded(
                            child: FutureBuilder<StatementPage>(
                                future: data,
                                builder: (context, snapshot) {
                                  if (snapshot.hasError) {
                                    return Center(
                                        child:
                                            Text(safeMessage(snapshot.error!)));
                                  }
                                  if (!snapshot.hasData) {
                                    return const Center(
                                        child: CircularProgressIndicator());
                                  }
                                  final result = snapshot.data!,
                                      s = result.summary;
                                  return Column(children: [
                                    Wrap(spacing: 12, runSpacing: 8, children: [
                                      _metric('Opening', s.openingCents),
                                      _metric('New credit', s.chargesCents),
                                      _metric('Payments', s.paymentsCents),
                                      _metric(
                                          'Adjustments', s.adjustmentsCents),
                                      _metric(
                                          'Closing balance', s.closingCents),
                                    ]),
                                    const SizedBox(height: 12),
                                    Expanded(
                                        child: AppPagedListPanel(
                                            title: 'Statement activity',
                                            total: s.count,
                                            count: result.lines.length,
                                            page: page,
                                            emptyTitle:
                                                'No activity in this period',
                                            emptyMessage:
                                                'Choose another period to review credit activity.',
                                            onPrevious: () => setState(() {
                                                  page--;
                                                  data = _load();
                                                }),
                                            onNext: () => setState(() {
                                                  page++;
                                                  data = _load();
                                                }),
                                            itemBuilder: (context, index) {
                                              final line = result.lines[index];
                                              return ListTile(
                                                  title: Text(
                                                      '${line.reference} • ${line.description}'),
                                                  subtitle: Text(
                                                      MaterialLocalizations.of(
                                                              context)
                                                          .formatMediumDate(
                                                              line.date)),
                                                  trailing: Text(
                                                      '${line.chargeCents == 0 ? '' : 'Charge ${formatPeso(line.chargeCents)}  '}${line.paymentCreditCents == 0 ? '' : 'Credit ${formatPeso(line.paymentCreditCents)}  '}Balance ${formatPeso(line.balanceCents)}'));
                                            })),
                                  ]);
                                })),
                        const SizedBox(height: 12),
                        Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('Close')),
                              const SizedBox(width: 8),
                              FilledButton.icon(
                                  onPressed: printing ? null : printStatement,
                                  icon: const Icon(Icons.print_outlined),
                                  label: Text(printing
                                      ? 'Preparing…'
                                      : 'Print statement')),
                            ]),
                      ]))));

  Widget _metric(String label, int cents) => SizedBox(
      width: 150,
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.labelMedium),
                    Text(formatPeso(cents),
                        style: Theme.of(context).textTheme.titleMedium),
                  ]))));
}
