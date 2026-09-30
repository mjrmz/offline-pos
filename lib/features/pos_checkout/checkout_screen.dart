import 'package:flutter/material.dart';
import '../../core/models/cart.dart';
import '../../core/models/active_user.dart';
import '../../core/models/product.dart';
import '../../core/services/sale_service.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/catalog_service.dart';
import '../../shared/utils/safe_message.dart';
import '../../data/daos/pos_repository.dart';
import '../../hardware/printer/receipt_service.dart';
import '../../hardware/barcode/camera_scanner.dart';
import 'dart:io';

String money(int cents) =>
    '\u20B1${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
int? tryParseMoney(String value) {
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value.trim())) return null;
  final parts = value.trim().split('.');
  final pesos = int.tryParse(parts[0]);
  final fraction =
      parts.length == 1 ? 0 : int.tryParse(parts[1].padRight(2, '0'));
  if (pesos == null ||
      fraction == null ||
      pesos > (0x7fffffffffffffff - fraction) ~/ 100) {
    return null;
  }
  return pesos * 100 + fraction;
}

String? cashValidationMessage(String value, int totalCents) {
  if (value.trim().isEmpty) return 'Enter cash received';
  final cents = tryParseMoney(value);
  if (cents == null) return 'Enter a valid amount (up to 2 decimal places)';
  if (cents <= 0) return 'Cash received must be greater than zero';
  if (cents < totalCents) return 'Cash received is below the total';
  return null;
}

String? quantityValidationMessage(String value) {
  final quantity = int.tryParse(value.trim());
  if (quantity == null || quantity <= 0) {
    return 'Quantity must be a positive whole number';
  }
  return null;
}

class CheckoutScreen extends StatefulWidget {
  final PosRepository repository;
  final ActiveUser user;
  final AuthService auth;
  final ReceiptService? receipts;
  final CameraBarcodeScanner? camera;
  const CheckoutScreen(
      {super.key,
      required this.repository,
      required this.user,
      required this.auth,
      this.receipts,
      this.camera});
  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final cart = Cart();
  final barcodeController = TextEditingController();
  final cashController = TextEditingController();
  final barcodeFocus = FocusNode();
  final listController = ScrollController();
  late final SaleService sales = SaleService(widget.repository, widget.auth);
  List<PosProduct> products = [];
  String? message;
  bool busy = false;
  String? lastSaleId;
  @override
  void initState() {
    super.initState();
    refresh();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) barcodeFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    barcodeController.dispose();
    cashController.dispose();
    barcodeFocus.dispose();
    listController.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final rows = await widget.repository.products();
      if (mounted) setState(() => products = rows);
    } catch (e) {
      if (mounted) setState(() => message = safeMessage(e));
    }
  }

  Future<void> lookup([String? code]) async {
    try {
      final product = await widget.repository
          .barcode((code ?? barcodeController.text).trim());
      if (product == null) throw StateError('Barcode not found');
      setState(() {
        cart.add(product);
        message = null;
        barcodeController.clear();
      });
      barcodeFocus.requestFocus();
    } catch (e) {
      setState(() => message = safeMessage(e));
    }
  }

  Future<void> scanCamera() async {
    final result =
        await (widget.camera ?? MobileCameraBarcodeScanner()).scan(context);
    if (!mounted) return;
    switch (result.status) {
      case CameraScanStatus.found:
        await lookup(result.barcode);
        break;
      case CameraScanStatus.denied:
        setState(() =>
            message = 'Camera permission denied. Type the barcode instead.');
        break;
      case CameraScanStatus.unavailable:
        setState(
            () => message = 'Camera unavailable. Type the barcode instead.');
        break;
      case CameraScanStatus.cancelled:
        break;
    }
  }

  Future<void> checkout() async {
    if (busy) return;
    final validation =
        cashValidationMessage(cashController.text, cart.totalCents);
    if (cart.isEmpty || cart.totalCents <= 0 || validation != null) {
      setState(
          () => message = validation ?? 'Add a product with a positive total');
      return;
    }
    final cashCents = tryParseMoney(cashController.text)!;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result = await sales.checkout(cart, cashCents);
      lastSaleId = result.saleId;
      final completionMessage = result.protectionWarning
          ? 'Sale ${result.saleId} committed, but compliance finalization is pending. Stop BIR checkout and restart for recovery.'
          : 'Sale ${result.saleId} complete. Change: ${money(result.changeCents)}';
      if (mounted) {
        setState(() {
          message = completionMessage;
          cashController.clear();
        });
        barcodeFocus.requestFocus();
        if (listController.hasClients) listController.jumpTo(0);
      }
      final hardware =
          await widget.receipts?.afterCommittedCashSale(result.saleId);
      if (mounted && hardware != null) {
        setState(() => message = '$completionMessage'
            '${hardware.printerAttempted && !hardware.printed ? ' Receipt could not be printed.' : ''}'
            '${hardware.drawerAttempted && !hardware.drawerOpened ? ' Cash drawer could not be opened.' : ''}');
      }
      await refresh();
    } catch (e) {
      if (mounted) setState(() => message = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cashCents = tryParseMoney(cashController.text);
    final cashError = cart.isEmpty
        ? null
        : cashValidationMessage(cashController.text, cart.totalCents);
    final change = cashError == null && cashCents != null
        ? cashCents - cart.totalCents
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('POS Checkout'), actions: [
        if (widget.user.can(PosPermission.manageCatalog))
          TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => ProductScreen(
                              repository: widget.repository,
                              auth: widget.auth)));
                      await refresh();
                    },
              child: const Text('Products & categories'))
      ]),
      body: AbsorbPointer(
          absorbing: busy,
          child: ListView(
              controller: listController,
              padding: const EdgeInsets.all(16),
              children: [
                if (message != null)
                  Text(message!,
                      style: TextStyle(
                          color: message!.startsWith('Sale ')
                              ? Colors.green
                              : Colors.red)),
                if (lastSaleId != null)
                  TextButton(
                      onPressed: () async {
                        final ok =
                            await widget.receipts?.reprint(lastSaleId!) ??
                                false;
                        if (mounted) {
                          setState(() => message = ok
                              ? 'Receipt reprinted for sale $lastSaleId.'
                              : 'Receipt could not be printed. Check printer settings and connection.');
                        }
                      },
                      child: const Text('Reprint')),
                TextField(
                    controller: barcodeController,
                    focusNode: barcodeFocus,
                    decoration: InputDecoration(
                        labelText: 'Type barcode',
                        suffixIcon:
                            Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                              onPressed: () => lookup(),
                              icon: const Icon(Icons.search)),
                          if (Platform.isAndroid || Platform.isIOS)
                            IconButton(
                                onPressed: scanCamera,
                                icon: const Icon(Icons.camera_alt)),
                        ])),
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
                        '${money(line.product.priceCents)} \u00D7 ${line.quantity} = ${money(line.totalCents)}'),
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
                                    final validation =
                                        quantityValidationMessage(value);
                                    if (validation != null) {
                                      setState(() => message = validation);
                                      return;
                                    }
                                    final quantity = int.tryParse(value.trim());
                                    setState(() {
                                      cart.setQuantity(
                                          line.product.id, quantity!);
                                      message = null;
                                    });
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
                    decoration: InputDecoration(
                        labelText: 'Cash received', errorText: cashError),
                    onChanged: (_) => setState(() {})),
                if (change != null && change >= 0)
                  Text('Change: ${money(change)}'),
                FilledButton(
                    onPressed: busy ||
                            cart.isEmpty ||
                            cart.totalCents <= 0 ||
                            cashError != null
                        ? null
                        : checkout,
                    child: Text(busy ? 'Completing\u2026' : 'Complete sale')),
              ])),
    );
  }
}

class ProductScreen extends StatefulWidget {
  final PosRepository repository;
  final AuthService auth;
  const ProductScreen(
      {super.key, required this.repository, required this.auth});
  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  late final catalog = CatalogService(widget.repository, widget.auth);
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
    final threshold =
        TextEditingController(text: '${product?.lowStockThreshold ?? 5}');
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
                          TextField(
                              controller: threshold,
                              decoration: const InputDecoration(
                                  labelText: 'Low-stock threshold'),
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
                              final priceCents = tryParseMoney(price.text);
                              final costCents = tryParseMoney(cost.text);
                              final startingStock =
                                  int.tryParse(stock.text.trim());
                              final lowStockThreshold =
                                  int.tryParse(threshold.text.trim());
                              if (priceCents == null ||
                                  costCents == null ||
                                  startingStock == null ||
                                  lowStockThreshold == null ||
                                  lowStockThreshold < 0) {
                                throw StateError(
                                    'Enter valid price, cost, and starting stock');
                              }
                              await catalog.saveProduct(
                                  id: product?.id,
                                  name: name.text,
                                  sku: sku.text,
                                  barcode: barcode.text,
                                  categoryId: categoryId,
                                  priceCents: priceCents,
                                  costCents: costCents,
                                  startingStock: startingStock,
                                  lowStockThreshold: lowStockThreshold,
                                  isActive: active);
                              if (context.mounted) Navigator.pop(context);
                              await refresh();
                            } catch (e) {
                              if (mounted) {
                                setState(() => error = safeMessage(e));
                              }
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
    threshold.dispose();
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
                          await catalog.addCategory(name.text);
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (mounted) setState(() => error = safeMessage(e));
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
                      '${money(p.priceCents)} \u00B7 Stock: ${snapshot.data ?? '\u2026'}${p.isActive ? '' : ' \u00B7 Inactive'}'),
                  trailing: IconButton(
                      icon: const Icon(Icons.edit), onPressed: () => edit(p)),
                ),
              )),
        ]),
      );
}
