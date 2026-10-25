import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../core/models/active_user.dart';
import '../../data/database.dart';
import '../../data/daos/supplier_payables_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/app_workspace.dart';
import 'supplier_statement_pdf.dart';

class SupplierStatementDialog extends StatefulWidget {
  const SupplierStatementDialog({super.key, required this.supplier,
      required this.repository, required this.user});
  final Supplier supplier;
  final SupplierPayablesRepository repository;
  final ActiveUser user;

  @override
  State<SupplierStatementDialog> createState() => _SupplierStatementDialogState();
}

class _SupplierStatementDialogState extends State<SupplierStatementDialog> {
  String period = 'This month';
  DateTimeRange? custom;
  int page = 0;
  bool printing = false;
  String? error;
  late Future<SupplierStatementPage> data = _load();

  DateTimeRange get range {
    final today = DateTime.now();
    if (period == 'Custom' && custom != null) return custom!;
    if (period == 'Last month') {
      return DateTimeRange(start: DateTime(today.year, today.month - 1),
          end: DateTime(today.year, today.month)
              .subtract(const Duration(days: 1)));
    }
    if (period == 'This year') {
      return DateTimeRange(start: DateTime(today.year), end: today);
    }
    return DateTimeRange(start: DateTime(today.year, today.month), end: today);
  }

  DateTime get exclusiveEnd =>
      DateTime(range.end.year, range.end.month, range.end.day + 1);
  Future<SupplierStatementPage> _load() => widget.repository.statementPage(
      widget.supplier.id, range.start, exclusiveEnd, page: page);

  Future<void> choosePeriod(String value) async {
    if (value == 'Custom') {
      final selected = await showDateRangePicker(context: context,
          firstDate: DateTime(2000), lastDate: DateTime.now(),
          initialDateRange: custom);
      if (selected == null) return;
      custom = selected;
    }
    setState(() { period = value; page = 0; data = _load(); });
  }

  Future<void> printStatement() async {
    if (!widget.user.can(PosPermission.manageExpenseFunds)) return;
    setState(() { printing = true; error = null; });
    try {
      final bytes = await SupplierStatementPdf(widget.repository.db)
          .render(widget.supplier.id, range.start, exclusiveEnd);
      await Printing.layoutPdf(onLayout: (_) async => bytes,
          name: 'Supplier Statement - ${widget.supplier.name}');
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      if (mounted) setState(() => printing = false);
    }
  }

  Widget metric(String label, int cents) => SizedBox(width: 150,
      child: Card(child: Padding(padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [Text(label, style: Theme.of(context).textTheme.labelMedium),
                Text(formatPeso(cents),
                    style: Theme.of(context).textTheme.titleMedium)]))));

  @override
  Widget build(BuildContext context) =>
      !widget.user.can(PosPermission.manageExpenseFunds)
          ? const Dialog(child: Padding(padding: EdgeInsets.all(24),
              child: Text('Supplier statement access required.')))
          : Dialog(child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980, maxHeight: 720),
              child: Padding(padding: const EdgeInsets.all(20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [Text('Supplier Statement',
                                style: Theme.of(context).textTheme.headlineSmall),
                              Text(widget.supplier.name)])),
                          IconButton(onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close))]),
                        const SizedBox(height: 12),
                        DropdownButton<String>(value: period,
                            items: [for (final value in const [
                              'This month', 'Last month', 'This year', 'Custom'])
                              DropdownMenuItem(value: value, child: Text(value))],
                            onChanged: (value) {
                              if (value != null) {
                                choosePeriod(value);
                              }
                            }),
                        Text('${MaterialLocalizations.of(context).formatMediumDate(range.start)} – '
                            '${MaterialLocalizations.of(context).formatMediumDate(range.end)}'),
                        if (error != null) Text(error!, style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                        const SizedBox(height: 12),
                        Expanded(child: FutureBuilder<SupplierStatementPage>(
                            future: data, builder: (context, snapshot) {
                              if (snapshot.hasError) {
                                return Center(child: Text(safeMessage(snapshot.error!)));
                              }
                              if (!snapshot.hasData) {
                                return const Center(child: CircularProgressIndicator());
                              }
                              final result = snapshot.data!;
                              final summary = result.summary;
                              return Column(children: [
                                Wrap(spacing: 8, runSpacing: 8, children: [
                                  metric('Opening', summary.openingCents),
                                  metric('Purchases', summary.chargesCents),
                                  metric('Supplier credits', summary.creditsCents),
                                  metric('Payments', summary.paymentsCents),
                                  metric('Closing', summary.closingCents),
                                ]),
                                if (summary.unappliedCreditCents > 0)
                                  Align(alignment: Alignment.centerLeft,
                                      child: Text('Current unapplied supplier credit: '
                                          '${formatPeso(summary.unappliedCreditCents)}')),
                                if (summary.legacyCount > 0)
                                  Align(alignment: Alignment.centerLeft,
                                      child: Text('${summary.legacyCount} legacy Receiving records '
                                          'have unknown settlement and are excluded from collectible balances.')),
                                const SizedBox(height: 8),
                                Expanded(child: AppPagedListPanel(
                                    title: 'Statement activity',
                                    total: summary.count,
                                    count: result.lines.length,
                                    page: page,
                                    emptyTitle: 'No activity in this period',
                                    onPrevious: () => setState(() {
                                      page--; data = _load();
                                    }),
                                    onNext: () => setState(() {
                                      page++; data = _load();
                                    }),
                                    itemBuilder: (context, index) {
                                      final line = result.lines[index];
                                      return ListTile(
                                        title: Text('${line.reference} · ${line.type}'),
                                        subtitle: Text('${MaterialLocalizations.of(context).formatMediumDate(line.date)} · '
                                            'Charge ${formatPeso(line.purchaseCents)} · '
                                            'Payment/Credit ${formatPeso(line.settlementCents)}'),
                                        trailing: Text(formatPeso(line.balanceCents)),
                                      );
                                    })),
                              ]);
                            })),
                        const SizedBox(height: 12),
                        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          TextButton(onPressed: () => Navigator.pop(context),
                              child: const Text('Close')),
                          const SizedBox(width: 8),
                          FilledButton.icon(onPressed: printing ? null : printStatement,
                              icon: const Icon(Icons.print_outlined),
                              label: Text(printing ? 'Preparing…' : 'Print statement')),
                        ]),
                      ]))));
}
