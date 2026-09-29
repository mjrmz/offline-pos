import 'package:flutter/material.dart';
import '../../core/models/active_user.dart';
import '../../core/services/sales_service.dart';
import '../../data/daos/sales_repository.dart';
import '../../shared/utils/safe_message.dart';
import '../pos_checkout/checkout_screen.dart';

class SalesHistoryScreen extends StatefulWidget {
  final SalesService sales;
  final ActiveUser user;
  final bool active;
  const SalesHistoryScreen(
      {super.key, required this.sales, required this.user, this.active = true});
  @override
  State<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends State<SalesHistoryScreen> {
  List<SaleSummary> rows = [];
  String? error;
  @override
  void initState() {
    super.initState();
    if (widget.active) refresh();
  }

  @override
  void didUpdateWidget(covariant SalesHistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) refresh();
  }

  Future<void> refresh() async {
    try {
      final result = await widget.sales.history();
      if (mounted) {
        setState(() {
          rows = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  Future<void> open(String saleId) async {
    try {
      final detail = await widget.sales.detail(saleId);
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                  title: Text('Sale ${detail.summary.sale.id}'),
                  content: SizedBox(
                      width: 500,
                      child: ListView(shrinkWrap: true, children: [
                        Text('Cashier: ${detail.summary.cashierName}'),
                        Text('Date: ${detail.summary.sale.createdAt}'),
                        Text('Status: ${detail.summary.sale.status}'),
                        Text('Payment: ${detail.summary.paymentMethod}'),
                        Text('Total: ${money(detail.summary.sale.totalCents)}'),
                        for (var i = 0; i < detail.items.length; i++)
                          Text(
                              '${detail.productNames[i]} × ${detail.items[i].quantity} @ ${money(detail.items[i].unitPriceCents)} = ${money(detail.items[i].lineTotalCents)}'),
                        if (detail.reversal != null)
                          Text(
                              '${detail.reversal!.kind} by user ${detail.reversal!.actorId} at ${detail.reversal!.createdAt}'),
                        if (detail.reversal != null)
                          Text(detail.reversal!.stockRestored
                              ? 'Stock restored to sellable inventory'
                              : 'Stock not returned to sellable inventory'),
                      ])),
                  actions: [
                    if (widget.user.can(PosPermission.reverseSale) &&
                        detail.summary.sale.status == 'completed') ...[
                      TextButton(
                          onPressed: () async {
                            Navigator.pop(context);
                            await reverse(saleId, false);
                          },
                          child: const Text('Void')),
                      TextButton(
                          onPressed: () async {
                            Navigator.pop(context);
                            await reverse(saleId, true);
                          },
                          child: const Text('Record full refund')),
                    ],
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close')),
                  ]));
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  Future<void> reverse(String saleId, bool refund) async {
    final decision = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(refund ? 'Record full refund' : 'Void sale'),
                content: Text(refund
                    ? 'Return items to sellable stock?'
                    : 'Void this sale and restore all sold stock?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  if (refund)
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('No')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(refund ? 'Yes' : 'Confirm'))
                ]));
    if (decision == null) return;
    try {
      if (refund) {
        await widget.sales.refundSale(saleId, returnToSellableStock: decision);
      } else {
        await widget.sales.voidSale(saleId);
      }
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Sales history'), actions: [
        IconButton(onPressed: refresh, icon: const Icon(Icons.refresh))
      ]),
      body: ListView(children: [
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        ...rows.map((row) => ListTile(
            title: Text('${row.sale.id} · ${money(row.sale.totalCents)}'),
            subtitle: Text(
                '${row.sale.createdAt} · ${row.cashierName} · ${row.sale.status} · ${row.paymentMethod}'),
            onTap: () => open(row.sale.id)))
      ]));
}
