import 'package:flutter/material.dart';
import '../../core/services/sales_service.dart';
import '../../data/daos/sales_repository.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/utils/money.dart';

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
        IconButton(onPressed: refresh, icon: const Icon(Icons.refresh))
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        OutlinedButton(
            onPressed: chooseDate,
            child: Text('Date: ${date.year}-${date.month}-${date.day}')),
        if (report != null) ...[
          Text('Completed sales: ${report!.completedCount}'),
          Text('Gross sales: ${formatPeso(report!.grossCents)}'),
          Text('Reversed sales: ${formatPeso(report!.reversalCents)}'),
          Text('Net sales: ${formatPeso(report!.netCents)}'),
          const Divider(),
          const Text('Cash breakdown'),
          ...report!.paymentBreakdown.entries
              .map((entry) => Text('${entry.key}: ${formatPeso(entry.value)}')),
          const Divider(),
          const Text('Low stock'),
          ...report!.lowStock
              .map((entry) => Text('${entry.$1}: ${entry.$2} remaining')),
        ]
      ]));
}
