import 'package:flutter/material.dart';
import '../../core/services/sales_service.dart';
import '../../data/daos/sales_repository.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/utils/money.dart';
import '../../core/models/quantity.dart';

class ReportsScreen extends StatefulWidget {
  final SalesService sales;
  final bool active;
  const ReportsScreen({super.key, required this.sales, this.active = true});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  DateTime date = DateTime.now();
  DailyReport? report;
  String? error;
  @override
  void initState() {
    super.initState();
    if (widget.active) refresh();
  }

  @override
  void didUpdateWidget(covariant ReportsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) refresh();
  }

  Future<void> refresh() async {
    try {
      final result = await widget.sales.report(date);
      if (mounted) {
        setState(() {
          report = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  Future<void> chooseDate() async {
    final picked = await showDatePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime.now().add(const Duration(days: 1)),
        initialDate: date);
    if (picked != null) {
      setState(() => date = picked);
      await refresh();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Reports'), actions: [
        IconButton(
            tooltip: 'Refresh report',
            onPressed: refresh,
            icon: const Icon(Icons.refresh))
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (error != null)
          Text(error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                  tooltip: 'Previous day',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () {
                    setState(
                        () => date = date.subtract(const Duration(days: 1)));
                    refresh();
                  }),
              OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today),
                  onPressed: chooseDate,
                  label: Text('${date.year}-${date.month}-${date.day}')),
              IconButton(
                  tooltip: 'Next day',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: date.isBefore(
                          DateTime.now().subtract(const Duration(days: 1)))
                      ? () {
                          setState(
                              () => date = date.add(const Duration(days: 1)));
                          refresh();
                        }
                      : null),
            ]),
        if (report != null) ...[
          LayoutBuilder(
              builder: (context, constraints) =>
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    _metric('Gross sales', formatPeso(report!.grossCents),
                        constraints.maxWidth),
                    _metric('Net sales', formatPeso(report!.netCents),
                        constraints.maxWidth),
                    _metric('Transactions', '${report!.completedCount}',
                        constraints.maxWidth),
                    _metric('Reversals', formatPeso(report!.reversalCents),
                        constraints.maxWidth),
                  ])),
          const Divider(),
          Text('Cash breakdown', style: Theme.of(context).textTheme.titleLarge),
          ...report!.paymentBreakdown.entries.map((entry) => ListTile(
              title: Text(entry.key), trailing: Text(formatPeso(entry.value)))),
          const Divider(),
          Text('Low stock', style: Theme.of(context).textTheme.titleLarge),
          if (report!.lowStockDetails.isEmpty)
            const Text('No low stock items.'),
          ...report!.lowStockDetails.map((entry) => ListTile(
              title: Text(entry.$1),
              trailing:
                  Text('${Quantity.format(entry.$2)} ${entry.$3} remaining'))),
        ]
      ]));

  Widget _metric(String label, String value, double width) => SizedBox(
      width: width >= 800
          ? (width - 36) / 4
          : width >= 480
              ? (width - 12) / 2
              : width,
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Text(value,
                        style: Theme.of(context).textTheme.headlineSmall),
                  ]))));
}
