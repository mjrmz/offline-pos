import 'package:flutter/material.dart';
import '../../core/models/cart.dart';
import '../../core/models/product.dart';
import '../../core/services/sale_service.dart';
import '../../data/daos/pos_repository.dart';

String money(int cents) =>
    '₱${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
int parseMoney(String value) {
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value.trim())) {
    throw const FormatException(
        'Enter a valid amount (up to 2 decimal places)');
  }
  final parts = value.trim().split('.');
  return int.parse(parts[0]) * 100 +
      (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
}

class CheckoutScreen extends StatefulWidget {
  final PosRepository repository;
  const CheckoutScreen({super.key, required this.repository});
  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final cart = Cart();
  final barcodeController = TextEditingController();
  final cashController = TextEditingController();
  late final SaleService sales = SaleService(widget.repository);
  List<PosProduct> products = [];
  String? message;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    barcodeController.dispose();
    cashController.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final rows = await widget.repository.products();
      if (mounted) setState(() => products = rows);
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> lookup() async {
    try {
      final product =
          await widget.repository.barcode(barcodeController.text.trim());
      if (product == null) throw StateError('Barcode not found');
      setState(() {
        cart.add(product);
        message = null;
        barcodeController.clear();
      });
    } catch (e) {
      setState(() => message = '$e');
    }
  }

  Future<void> checkout() async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result =
          await sales.checkout(cart, parseMoney(cashController.text));
      if (mounted) {
        setState(() {
          message =
              'Sale ${result.saleId} complete. Change: ${money(result.changeCents)}';
          cashController.clear();
        });
      }
      await refresh();
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    int? change;
    try {
      change = parseMoney(cashController.text) - cart.totalCents;
    } catch (_) {}
    return Scaffold(
      appBar: AppBar(title: const Text('POS Checkout'), actions: [
        TextButton(
            onPressed: busy
                ? null
                : () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            ProductScreen(repository: widget.repository)));
                    await refresh();
                  },
            child: const Text('Products & categories'))
      ]),
      body: AbsorbPointer(
          absorbing: busy,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            if (message != null)
              Text(message!,
                  style: TextStyle(
                      color: message!.startsWith('Sale ')
                          ? Colors.green
                          : Colors.red)),
            TextField(
                controller: barcodeController,
                decoration: InputDecoration(
                    labelText: 'Type barcode',
                    suffixIcon: IconButton(
                        onPressed: lookup, icon: const Icon(Icons.search))),
                onSubmitted: (_) => lookup()),
            const SizedBox(height: 12),
            const Text('Select product'),
            ...products.where((p) => p.isActive).map((p) => ListTile(
                title: Text(p.name),
                subtitle: Text(money(p.priceCents)),
                trailing: IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () => setState(() {
                          cart.add(p);
                          message = null;
                        })))),
            const Divider(),
            const Text('Cart'),
            ...cart.lines.map((line) => ListTile(
                title: Text(line.product.name),
                subtitle: Text(
                    '${money(line.product.priceCents)} × ${line.quantity} = ${money(line.totalCents)}'),
                trailing: SizedBox(
                    width: 135,
                    child: Row(children: [
                      SizedBox(
                          width: 65,
                          child: TextFormField(
                              key: ValueKey(
                                  'quantity-${line.product.id}-${line.quantity}'),
                              initialValue: '${line.quantity}',
                              keyboardType: TextInputType.number,
                              onFieldSubmitted: (value) {
                                final quantity = int.tryParse(value);
                                if (quantity == null) {
                                  setState(() => message = 'Invalid quantity');
                                  return;
                                }
                                try {
                                  setState(() => cart.setQuantity(
                                      line.product.id, quantity));
                                } catch (e) {
                                  setState(() => message = '$e');
                                }
                              })),
                      IconButton(
                          onPressed: () =>
                              setState(() => cart.remove(line.product.id)),
                          icon: const Icon(Icons.delete))
                    ])))),
            Text('Subtotal: ${money(cart.subtotalCents)}'),
            Text('Total: ${money(cart.totalCents)}'),
            const Text('Payment: Cash'),
            TextField(
                controller: cashController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Cash received'),
                onChanged: (_) => setState(() {})),
            if (change != null && change >= 0) Text('Change: ${money(change)}'),
            FilledButton(
                onPressed: busy || cart.isEmpty ? null : checkout,
                child: Text(busy ? 'Completing…' : 'Complete sale')),
          ])),
    );
  }
}

class ProductScreen extends StatefulWidget {
  final PosRepository repository;
  const ProductScreen({super.key, required this.repository});
  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  List<PosProduct> products = [];
  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final rows = await widget.repository.products();
    if (mounted) setState(() => products = rows);
  }

  Future<void> edit([PosProduct? product]) async {
    final name = TextEditingController(text: product?.name);
    final sku = TextEditingController(text: product?.sku);
    final barcode = TextEditingController(text: product?.barcode);
    final price = TextEditingController(
        text: product == null
            ? ''
            : '${product.priceCents ~/ 100}.${(product.priceCents % 100).toString().padLeft(2, '0')}');
    final cost = TextEditingController(
        text: product == null
            ? '0'
            : '${product.costCents ~/ 100}.${(product.costCents % 100).toString().padLeft(2, '0')}');
    final stock = TextEditingController(text: '0');
    final categories = await widget.repository.categories();
    String? categoryId = product?.categoryId;
    bool active = product?.isActive ?? true;
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: Text(
                        product == null ? 'Create product' : 'Edit product'),
                    content: SizedBox(
                        width: 400,
                        child: ListView(shrinkWrap: true, children: [
                          TextField(
                              controller: name,
                              decoration:
                                  const InputDecoration(labelText: 'Name')),
                          TextField(
                              controller: sku,
                              decoration:
                                  const InputDecoration(labelText: 'SKU')),
                          TextField(
                              controller: barcode,
                              decoration:
                                  const InputDecoration(labelText: 'Barcode')),
                          TextField(
                              controller: price,
                              decoration: const InputDecoration(
                                  labelText: 'Price (pesos)'),
                              keyboardType: TextInputType.number),
                          TextField(
                              controller: cost,
                              decoration: const InputDecoration(
                                  labelText: 'Cost (pesos)'),
                              keyboardType: TextInputType.number),
                          if (product == null)
                            TextField(
                                controller: stock,
                                decoration: const InputDecoration(
                                    labelText: 'Starting stock'),
                                keyboardType: TextInputType.number),
                          DropdownButtonFormField<String?>(
                              initialValue: categoryId,
                              decoration:
                                  const InputDecoration(labelText: 'Category'),
                              items: [
                                const DropdownMenuItem<String?>(
                                    value: null, child: Text('None')),
                                ...categories.map((c) =>
                                    DropdownMenuItem<String?>(
                                        value: c.id, child: Text(c.name)))
                              ],
                              onChanged: (v) => update(() => categoryId = v)),
                          SwitchListTile(
                              title: const Text('Active'),
                              value: active,
                              onChanged: (v) => update(() => active = v)),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () async {
                            try {
                              await widget.repository.saveProduct(
                                  id: product?.id,
                                  name: name.text,
                                  sku: sku.text,
                                  barcode: barcode.text,
                                  categoryId: categoryId,
                                  priceCents: parseMoney(price.text),
                                  costCents: parseMoney(cost.text),
                                  startingStock: int.parse(stock.text),
                                  isActive: active);
                              if (context.mounted) Navigator.pop(context);
                              await refresh();
                            } catch (e) {
                              if (mounted) setState(() => error = '$e');
                            }
                          },
                          child: const Text('Save'))
                    ])));
    name.dispose();
    sku.dispose();
    barcode.dispose();
    price.dispose();
    cost.dispose();
    stock.dispose();
  }

  Future<void> addCategory() async {
    final name = TextEditingController();
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Add category'),
                content: TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Name')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        try {
                          await widget.repository.addCategory(name.text);
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (mounted) setState(() => error = '$e');
                        }
                      },
                      child: const Text('Save'))
                ]));
    name.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Products & categories')),
        body: ListView(children: [
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          Wrap(spacing: 8, children: [
            FilledButton(
                onPressed: () => edit(), child: const Text('Add product')),
            OutlinedButton(
                onPressed: addCategory, child: const Text('Add category')),
          ]),
          ...products.map((p) => FutureBuilder<int>(
                future: widget.repository.stock(p.id),
                builder: (context, snapshot) => ListTile(
                  title: Text(p.name),
                  subtitle: Text(
                      '${money(p.priceCents)} · Stock: ${snapshot.data ?? '…'}${p.isActive ? '' : ' · Inactive'}'),
                  trailing: IconButton(
                      icon: const Icon(Icons.edit), onPressed: () => edit(p)),
                ),
              )),
        ]),
      );
}
