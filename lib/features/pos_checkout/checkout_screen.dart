import 'package:flutter/material.dart';
import 'package:drift/drift.dart' show TableUpdateQuery;
import '../../core/models/cart.dart';
import '../../core/models/active_user.dart';
import '../../core/models/product.dart';
import '../../core/models/business_product.dart';
import '../../core/models/business_feature.dart';
import '../../core/models/quantity.dart';
import '../../core/models/sale_line_format.dart';
import '../../data/daos/business_feature_repository.dart';
import '../../core/services/sale_service.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/catalog_service.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/utils/money.dart';
import '../../shared/widgets/expiry_date_field.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../../data/database.dart';
import '../inventory/inventory_overview.dart' show inventoryMovementLabel;
import '../../hardware/printer/receipt_service.dart';
import '../../hardware/barcode/camera_scanner.dart';
import 'dart:io';
import 'dart:async';

String money(int cents) => formatPeso(cents);
int? tryParseMoney(String value) => tryParsePeso(value);
Future<void> waitForDialogExit() =>
    Future<void>.delayed(const Duration(milliseconds: 300));
String formatPesoInput(int cents) =>
    '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';

DateTime? parseOptionalDate(String value) {
  final input = value.trim();
  if (input.isEmpty) return null;
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(input)) {
    throw FormatException('Use YYYY-MM-DD for expiry');
  }
  final date = DateTime.tryParse(input);
  if (date == null ||
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}' !=
          input) {
    throw FormatException('Invalid expiry date');
  }
  return date;
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
  State<CheckoutScreen> createState() => CheckoutScreenState();
}

class CheckoutScreenState extends State<CheckoutScreen> {
  bool get hasActiveCart => !cart.isEmpty || busy;
  StreamSubscription<dynamic>? _catalogChanges;
  int _catalogRevision = 0;
  final cart = Cart();
  final barcodeController = TextEditingController();
  final cashController = TextEditingController();
  final barcodeFocus = FocusNode();
  final listController = ScrollController();
  late final SaleService sales = SaleService(widget.repository, widget.auth);
  List<PosProduct> products = [];
  List<Category> categories = [];
  Map<String, int> stockMilli = {};
  final Map<String, String> serialLabels = {};
  final Map<String, String> batchLabels = {};
  String? categoryId;
  bool mobileCartOpen = false;
  List<Customer> customers = [];
  bool credit = false;
  String? customerId;
  String? message;
  bool busy = false;
  bool scanning = false;
  int quantityEditRevision = 0;
  bool pricingPending = false;
  int pricingRevision = 0;
  String catalogQuery = '';
  String? lastSaleId;
  String? saleReference;
  String? scanError;
  @override
  void initState() {
    super.initState();
    final db = widget.repository.db;
    _catalogChanges = db
        .tableUpdates(TableUpdateQuery.onAllTables([
          db.products,
          db.categories,
          db.inventory,
          db.inventoryLayers,
          db.productBusinessConfigurations,
          db.layaways,
          db.layawayItems,
        ]))
        .listen((_) => refresh());
    refresh();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) barcodeFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _catalogChanges?.cancel();
    barcodeController.dispose();
    cashController.dispose();
    barcodeFocus.dispose();
    listController.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    final revision = ++_catalogRevision;
    try {
      final rows = await widget.repository.products();
      final categoryRows = await widget.repository.categories();
      final levels = await widget.repository.stockLevels();
      final customerRows = await widget.repository.db
          .select(widget.repository.db.customers)
          .get();
      if (mounted && revision == _catalogRevision) {
        setState(() {
          products = rows;
          categories = categoryRows;
          stockMilli = {
            for (final entry in levels.entries)
              entry.key: entry.value.$1 - entry.value.$2,
          };
          customers = customerRows.where((c) => c.isActive).toList();
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = safeMessage(e));
    }
  }

  Future<void> _refreshLayerPrices() async {
    final revision = ++pricingRevision;
    final lines = cart.lines
        .where((line) => line.product.pricingPolicy == 'layer')
        .toList();
    if (lines.isEmpty) {
      if (mounted) setState(() => pricingPending = false);
      return;
    }
    setState(() => pricingPending = true);
    try {
      final prices = await Future.wait(lines.map((line) => widget.repository
          .quoteLayerPrice(line.product.id, line.quantityMilli,
              batchId: line.batchId,
              serialIds: line.serialIds,
              extraCents: line.extraCents)));
      if (!mounted || revision != pricingRevision) return;
      setState(() {
        for (var i = 0; i < lines.length; i++) {
          lines[i].pricedTotalCents = prices[i];
        }
        pricingPending = false;
      });
    } catch (error) {
      if (!mounted || revision != pricingRevision) return;
      setState(() {
        pricingPending = true;
        message = safeMessage(error);
      });
    }
  }

  Future<void> lookup([String? code]) async {
    final value = (code ?? barcodeController.text).trim();
    if (value.isEmpty || scanning) return;
    scanning = true;
    try {
      var product = await widget.repository.barcode(value);
      String? scannedSerialId;
      if (product == null) {
        final serial =
            await (widget.repository.db.select(widget.repository.db.serialUnits)
                  ..where((row) => row.serialNumber.equals(value)))
                .getSingleOrNull();
        if (serial != null) {
          if (serial.status != 'available') {
            throw StateError('Serial number is not available for sale');
          }
          product = products.where((p) => p.id == serial.productId).firstOrNull;
          scannedSerialId = serial.id;
        }
      }
      if (product == null) {
        throw StateError('Barcode or serial number not found');
      }
      if (!product.business.madeToOrder && (stockMilli[product.id] ?? 0) <= 0) {
        throw StateError('Out of stock');
      }
      await addToCart(product, scannedSerialId: scannedSerialId);
      if (!mounted) return;
      setState(() {
        barcodeController.clear();
        scanError = null;
      });
      barcodeFocus.requestFocus();
    } catch (e) {
      if (mounted && (code != null || barcodeController.text.trim() == value)) {
        setState(() => scanError = safeMessage(e));
      }
    } finally {
      scanning = false;
    }
  }

  Future<void> addToCart(PosProduct product, {String? scannedSerialId}) async {
    final config = product.business;
    final special = config.weight ||
        config.refill ||
        config.tank ||
        config.batch ||
        product.serialTracking ||
        config.madeToOrder ||
        config.unit != SaleUnit.piece;
    if (!special) {
      final nextQuantity = (cart.lines
                  .where((line) => line.product.id == product.id)
                  .firstOrNull
                  ?.quantityMilli ??
              0) +
          Quantity.scale;
      final available = stockMilli[product.id];
      if (available != null && nextQuantity > available) {
        setState(() => message =
            'Only ${Quantity.format(available)} ${config.unit.label} available.');
        return;
      }
      setState(() {
        cart.add(product);
        message = null;
      });
      await _refreshLayerPrices();
      return;
    }
    final quantity = TextEditingController(text: '1');
    String mode = config.tank
        ? 'exchange'
        : config.refill
            ? 'refill'
            : config.madeToOrder
                ? 'made_order'
                : 'ordinary';
    final batches = config.batch
        ? await widget.repository.batches(product.id)
        : <ProductLot>[];
    final today = DateTime.now();
    final eligible = batches
        .where((b) =>
            b.quantityMilli > 0 &&
            (b.expiryDate == null ||
                !b.expiryDate!
                    .isBefore(DateTime(today.year, today.month, today.day))))
        .toList();
    eligible.sort((a, b) {
      if (a.expiryDate == null) return b.expiryDate == null ? 0 : 1;
      if (b.expiryDate == null) return -1;
      return a.expiryDate!.compareTo(b.expiryDate!);
    });
    String? batchId = eligible.isEmpty ? null : eligible.first.id;
    final availableSerials = product.serialTracking
        ? await widget.repository.availableSerials(product.id)
        : <SerialUnit>[];
    final selectedSerialIds = <String>{};
    if (scannedSerialId != null) selectedSerialIds.add(scannedSerialId);
    for (final serial in availableSerials) {
      serialLabels[serial.id] = serial.serialNumber;
    }
    for (final batch in eligible) {
      batchLabels[batch.id] = batch.batchNumber;
    }
    if (!mounted) {
      quantity.dispose();
      return;
    }
    final selection = await showDialog<(int, String, String?, List<String>)>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: Text(product.name),
                content: SizedBox(
                    width: 350,
                    child: ListView(shrinkWrap: true, children: [
                      Text(
                          '${money(product.priceCents)} per ${config.unit.label}'),
                      TextField(
                          controller: quantity,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                              labelText: 'Quantity (${config.unit.label})')),
                      if (config.refill) ...[
                        ListTile(
                            title: const Text('Refill'),
                            leading: Icon(mode == 'refill'
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked),
                            onTap: () => update(() => mode = 'refill')),
                        ListTile(
                            title: Text(
                                'Refill + container (+${money(config.containerPriceCents)})'),
                            leading: Icon(mode == 'container'
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked),
                            onTap: () => update(() => mode = 'container')),
                      ],
                      if (config.tank) ...[
                        ListTile(
                            title: const Text('Exchange: empty tank returned'),
                            leading: Icon(mode == 'exchange'
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked),
                            onTap: () => update(() => mode = 'exchange')),
                        ListTile(
                            title: Text(
                                'No empty return: add deposit ${money(config.depositCents)}'),
                            leading: Icon(mode == 'deposit'
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked),
                            onTap: () => update(() => mode = 'deposit')),
                      ],
                      if (config.batch)
                        DropdownButtonFormField<String>(
                            initialValue: batchId,
                            decoration:
                                const InputDecoration(labelText: 'Batch'),
                            items: eligible
                                .map((b) => DropdownMenuItem<String>(
                                      value: b.id,
                                      child: Text(
                                          '${b.batchNumber} · ${Quantity.format(b.quantityMilli)} available'
                                          '${b.expiryDate == null ? '' : ' · expires ${b.expiryDate!.year}-${b.expiryDate!.month.toString().padLeft(2, '0')}-${b.expiryDate!.day.toString().padLeft(2, '0')}'}'),
                                    ))
                                .toList(),
                            onChanged: (v) => update(() => batchId = v)),
                      if (product.serialTracking) ...[
                        Text('${selectedSerialIds.length} serials selected'),
                        for (final serial in availableSerials)
                          CheckboxListTile(
                              title: Text(serial.serialNumber),
                              value: selectedSerialIds.contains(serial.id),
                              onChanged: (value) => update(() {
                                    if (value == true) {
                                      selectedSerialIds.add(serial.id);
                                    } else {
                                      selectedSerialIds.remove(serial.id);
                                    }
                                  })),
                      ],
                      if (config.madeToOrder)
                        const Text(
                            'This sale creates an order to prepare; stock is not deducted.'),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () {
                        final milli = Quantity.tryParse(quantity.text,
                            fractional: config.fractional);
                        if (milli == null ||
                            (config.batch && batchId == null) ||
                            (product.serialTracking &&
                                selectedSerialIds.length !=
                                    milli ~/ Quantity.scale)) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text(
                                  'Enter a valid quantity, batch, and serial selection')));
                          return;
                        }
                        Navigator.pop(context,
                            (milli, mode, batchId, selectedSerialIds.toList()));
                      },
                      child: const Text('Add to cart')),
                ],
              )),
    );
    await waitForDialogExit();
    quantity.dispose();
    if (selection == null || !mounted) return;
    setState(() {
      cart.addSpecial(product, selection.$1,
          mode: selection.$2,
          batchId: selection.$3,
          serialIds: selection.$4,
          extraCents: selection.$2 == 'deposit'
              ? config.depositCents
              : selection.$2 == 'container'
                  ? config.containerPriceCents
                  : 0);
      message = null;
    });
    await _refreshLayerPrices();
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
    if (busy || pricingPending) return;
    final validation = credit
        ? (tryParseMoney(cashController.text) == null ||
                tryParseMoney(cashController.text)! < 0 ||
                tryParseMoney(cashController.text)! >= cart.totalCents
            ? 'Enter cash paid below the sale total'
            : customerId == null
                ? 'Select a customer'
                : null)
        : cashValidationMessage(cashController.text, cart.totalCents);
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
      final result = credit
          ? await sales.checkoutCredit(cart, customerId!, cashCents)
          : await sales.checkout(cart, cashCents);
      lastSaleId = result.saleId;
      final completedSale =
          await (widget.repository.db.select(widget.repository.db.sales)
                ..where((row) => row.id.equals(result.saleId)))
              .getSingle();
      saleReference = 'Receipt #${completedSale.receiptNumber ?? 'Legacy sale'}'
          '${completedSale.birInvoiceNumber == null ? '' : '\nInvoice #${completedSale.birInvoiceNumber}'}';
      final completionMessage = result.protectionWarning
          ? 'Sale committed, but compliance finalization is pending. Stop BIR checkout and restart for recovery.'
          : credit
              ? 'Sale completed · Credit ${money(result.totalCents - cashCents)}'
              : 'Sale completed · Change ${money(result.changeCents)}';
      if (mounted) {
        setState(() {
          message = completionMessage;
          cashController.clear();
          customerId = null;
          credit = false;
        });
        barcodeFocus.requestFocus();
        if (listController.hasClients) listController.jumpTo(0);
      }
      final hardware = await widget.receipts?.afterCommittedCashSale(
          result.saleId,
          openDrawer: !credit || cashCents > 0);
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
    final compact = MediaQuery.sizeOf(context).width < 850;
    return Scaffold(
      body: AbsorbPointer(
        absorbing: busy,
        child: LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth < 850) {
            return mobileCartOpen
                ? _salePanel(context, constraints.maxHeight)
                : _catalogPanel(context, constraints.maxWidth);
          }
          return Row(key: const Key('desktop-pos-two-pane'), children: [
            Expanded(
                flex: 55,
                child: _catalogPanel(context, constraints.maxWidth * .55)),
            const VerticalDivider(width: 1),
            Expanded(
                flex: 45,
                child: Material(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    child: _salePanel(context, constraints.maxHeight))),
          ]);
        }),
      ),
      floatingActionButton: compact && !mobileCartOpen
          ? FloatingActionButton.extended(
              key: const Key('mobile-cart-toggle'),
              onPressed: () => setState(() => mobileCartOpen = !mobileCartOpen),
              icon:
                  Icon(mobileCartOpen ? Icons.storefront : Icons.shopping_cart),
              label: Text(mobileCartOpen
                  ? 'Browse products'
                  : 'Current sale · ${cart.lines.length}'),
            )
          : null,
    );
  }

  Widget _catalogPanel(BuildContext context, double width) {
    final scheme = Theme.of(context).colorScheme;
    final query = catalogQuery;
    final filtered = products.where((p) {
      if (!p.isActive || (categoryId != null && p.categoryId != categoryId)) {
        return false;
      }
      final category =
          categories.where((c) => c.id == p.categoryId).firstOrNull?.name ?? '';
      return query.isEmpty ||
          p.name.toLowerCase().contains(query) ||
          (p.sku?.toLowerCase().contains(query) ?? false) ||
          category.toLowerCase().contains(query);
    }).toList();
    final searchFields = <Widget>[
      TextField(
        key: const Key('product-search'),
        decoration: const InputDecoration(
            labelText: 'Search products',
            hintText: 'Name, SKU, or barcode',
            prefixIcon: Icon(Icons.search)),
        onChanged: (value) =>
            setState(() => catalogQuery = value.toLowerCase().trim()),
      ),
      TextField(
        key: const Key('barcode-serial-input'),
        controller: barcodeController,
        focusNode: barcodeFocus,
        onChanged: (_) {
          if (scanError != null) setState(() => scanError = null);
        },
        decoration: InputDecoration(
            labelText: 'Scan barcode / serial',
            hintText: 'Scan or enter barcode / serial',
            errorText: scanError,
            prefixIcon: const Icon(Icons.qr_code_scanner),
            suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  tooltip: 'Look up barcode or serial',
                  onPressed: () => lookup(),
                  icon: const Icon(Icons.keyboard_return)),
              if (Platform.isAndroid || Platform.isIOS)
                IconButton(
                    tooltip: 'Scan with camera',
                    onPressed: scanCamera,
                    icon: const Icon(Icons.camera_alt)),
            ])),
        onSubmitted: (_) => lookup(),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (message != null) _messageBanner(context),
        if (width >= 640)
          Row(children: [
            Expanded(child: searchFields[0]),
            const SizedBox(width: 12),
            Expanded(child: searchFields[1]),
          ])
        else ...[
          searchFields[0],
          const SizedBox(height: 8),
          searchFields[1],
        ],
        const SizedBox(height: 12),
        SizedBox(
            height: 42,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                      label: const Text('All'),
                      selected: categoryId == null,
                      onSelected: (_) => setState(() => categoryId = null))),
              for (final category in categories)
                Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                        label: Text(category.name),
                        selected: categoryId == category.id,
                        onSelected: (_) =>
                            setState(() => categoryId = category.id))),
            ])),
        const SizedBox(height: 12),
        Row(children: [
          Text('Products', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 8),
          Text('${filtered.length}',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 8),
        Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 340),
                        child: const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.search_off, size: 40),
                              SizedBox(height: 8),
                              Text('No products found'),
                              SizedBox(height: 4),
                              Text(
                                  'Try another product name, SKU, category, barcode, or serial.',
                                  textAlign: TextAlign.center),
                            ])))
                : GridView.builder(
                    key: const Key('product-catalog-grid'),
                    padding: const EdgeInsets.only(bottom: 76),
                    itemCount: filtered.length,
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 220,
                            mainAxisExtent: 166,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12),
                    itemBuilder: (context, index) =>
                        _productCard(context, filtered[index]))),
      ]),
    );
  }

  Widget _messageBanner(BuildContext context) {
    final success = message!.startsWith('Sale ') ||
        message!.startsWith('Receipt reprinted');
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: success ? scheme.primaryContainer : scheme.errorContainer),
      child: Row(children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(message!,
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: success
                      ? scheme.onPrimaryContainer
                      : scheme.onErrorContainer)),
          if (success && saleReference != null)
            Text(saleReference!,
                style:
                    TextStyle(color: scheme.onPrimaryContainer, fontSize: 12)),
        ])),
        if (success && lastSaleId != null)
          TextButton.icon(
              onPressed: () async {
                final ok = await widget.receipts?.reprint(lastSaleId!) ?? false;
                if (mounted) {
                  setState(() => message = ok
                      ? 'Receipt reprinted.'
                      : 'Receipt could not be printed. Check printer settings and connection.');
                }
              },
              icon: const Icon(Icons.print, size: 16),
              label: const Text('Reprint')),
      ]),
    );
  }

  Widget _productCard(BuildContext context, PosProduct product) {
    final scheme = Theme.of(context).colorScheme;
    final available = stockMilli[product.id];
    final made = product.business.madeToOrder;
    final out = !made && available != null && available <= 0;
    final low = !out &&
        !made &&
        available != null &&
        available <= product.lowStockThreshold * Quantity.scale;
    final status = made
        ? 'Made to order'
        : out
            ? 'Out of stock'
            : low
                ? 'Low stock'
                : available == null
                    ? 'Checking stock'
                    : '${Quantity.format(available)}${product.business.weight ? ' ${product.business.unit.label}' : ''} available';
    final specialty = product.serialTracking
        ? 'Serialized'
        : product.business.batch
            ? 'Batch'
            : product.business.weight
                ? 'Weight'
                : null;
    final configurable = product.serialTracking ||
        product.business.batch ||
        product.business.weight ||
        product.business.tank ||
        product.business.refill ||
        product.business.madeToOrder;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: out ? scheme.surfaceContainer : scheme.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: scheme.outlineVariant)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: out
            ? null
            : () async {
                await addToCart(product);
                if (mounted) barcodeFocus.requestFocus();
              },
        child: Tooltip(
            message: product.name,
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(product.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(money(product.priceCents),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.primary)),
                    Text('per ${product.business.unit.label}',
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant)),
                    const Spacer(),
                    if (specialty != null || low || out)
                      Wrap(spacing: 4, children: [
                        if (specialty != null) _cardBadge(context, specialty),
                        if (low) _cardBadge(context, 'Low stock'),
                        if (out) _cardBadge(context, 'Out of stock'),
                      ]),
                    if (!out && !low)
                      Text(status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: out
                                  ? scheme.error
                                  : low
                                      ? scheme.tertiary
                                      : scheme.onSurfaceVariant)),
                    if (product.sku != null)
                      Text('SKU ${product.sku}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant)),
                    if (configurable && !out)
                      Align(
                          alignment: Alignment.centerRight,
                          child: Text('Configure ›',
                              style: TextStyle(
                                  fontSize: 11, color: scheme.primary))),
                  ],
                ))),
      ),
    );
  }

  Widget _cardBadge(BuildContext context, String label) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall));

  Future<void> _chooseCustomer() async {
    String query = '';
    await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => SafeArea(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                          height: MediaQuery.sizeOf(context).height * .6,
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Choose customer',
                                    style:
                                        Theme.of(context).textTheme.titleLarge),
                                const SizedBox(height: 12),
                                TextField(
                                    autofocus: true,
                                    decoration: const InputDecoration(
                                        labelText: 'Search customers',
                                        prefixIcon: Icon(Icons.search)),
                                    onChanged: (value) => update(() =>
                                        query = value.toLowerCase().trim())),
                                Expanded(
                                    child: ListView(children: [
                                  ListTile(
                                      title: const Text('Walk-in customer'),
                                      onTap: () {
                                        setState(() {
                                          customerId = null;
                                          credit = false;
                                          cashController.clear();
                                        });
                                        Navigator.pop(context);
                                      }),
                                  for (final customer in customers.where((c) =>
                                      c.name.toLowerCase().contains(query)))
                                    ListTile(
                                        title: Text(customer.name),
                                        onTap: () {
                                          setState(
                                              () => customerId = customer.id);
                                          Navigator.pop(context);
                                        }),
                                ])),
                              ]))),
                )));
    if (mounted) barcodeFocus.requestFocus();
  }

  Widget _salePanel(BuildContext context, double height) {
    final scheme = Theme.of(context).colorScheme;
    final customer = customers.where((c) => c.id == customerId).firstOrNull;
    final cashCents = tryParseMoney(cashController.text);
    final cashError = credit
        ? cashCents == null || cashCents < 0 || cashCents >= cart.totalCents
            ? 'Enter cash paid below the sale total'
            : customerId == null
                ? 'Select a customer for credit'
                : null
        : cashValidationMessage(cashController.text, cart.totalCents);
    final cartIssue = _cartIssue();
    final ready = !busy &&
        !pricingPending &&
        !cart.isEmpty &&
        cart.totalCents > 0 &&
        cashError == null &&
        cartIssue == null;
    return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              if (MediaQuery.sizeOf(context).width < 850)
                IconButton(
                    tooltip: 'Browse products',
                    onPressed: () => setState(() => mobileCartOpen = false),
                    icon: const Icon(Icons.arrow_back)),
              Icon(Icons.shopping_cart_outlined, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('CURRENT SALE',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700, letterSpacing: .5))),
              Text('${cart.lines.length} items',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('customer-selector'),
              onPressed: _chooseCustomer,
              icon: const Icon(Icons.person_outline),
              label: Row(children: [
                Expanded(
                    child: Text(
                        'Customer  ·  ${customer?.name ?? 'Walk-in customer'}',
                        overflow: TextOverflow.ellipsis)),
                const Text('Change'),
              ]),
            ),
            if (customer != null && !credit)
              Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      'Customer is linked when Credit / Utang is used. Cash sales remain walk-in.',
                      style: Theme.of(context).textTheme.bodySmall)),
            const SizedBox(height: 8),
            Expanded(
                child: cart.isEmpty
                    ? Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.shopping_cart_outlined,
                            size: 32, color: scheme.onSurfaceVariant),
                        const SizedBox(height: 8),
                        Text('No items added',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        const Text(
                            'Scan a barcode or select a product to begin.',
                            textAlign: TextAlign.center),
                      ]))
                    : ListView.builder(
                        key: const Key('current-sale-items'),
                        itemCount: cart.lines.length,
                        itemBuilder: (context, index) =>
                            _cartLine(context, cart.lines[index]))),
            if (!cart.isEmpty) ...[
              if (cartIssue != null)
                Text(cartIssue, style: TextStyle(color: scheme.error)),
              const SizedBox(height: 8),
              ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: height * .43),
                  child: SingleChildScrollView(
                      child: _paymentPanel(context, cashCents, cashError))),
              const SizedBox(height: 8),
            ],
            FilledButton(
              key: const Key('pay-button'),
              onPressed: ready ? checkout : null,
              child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(cart.isEmpty
                      ? 'Add an item to continue'
                      : busy
                          ? 'Completing…'
                          : credit
                              ? 'Complete payment · ${money(cart.totalCents)}'
                              : 'Pay ${money(cart.totalCents)}')),
            ),
          ],
        ));
  }

  String? _cartIssue() {
    for (final line in cart.lines) {
      if (line.product.serialTracking &&
          line.serialIds.length * Quantity.scale != line.quantityMilli) {
        return 'Select a serial for each unit of ${line.product.name}.';
      }
      if (line.product.business.batch && line.batchId == null) {
        return 'Select a batch for ${line.product.name}.';
      }
    }
    return null;
  }

  String? _quantityIssue(CartLine line, int milli) {
    if (milli <= 0) return 'Quantity must be greater than zero.';
    if (!line.product.business.fractional && milli % Quantity.scale != 0) {
      return 'This product requires a whole quantity.';
    }
    if (line.product.serialTracking &&
        milli != line.serialIds.length * Quantity.scale) {
      return 'Select a serial for each unit before changing quantity.';
    }
    final available = stockMilli[line.product.id];
    if (!line.product.business.madeToOrder &&
        available != null &&
        milli > available) {
      return 'Only ${Quantity.format(available)} ${line.product.business.unit.label} available.';
    }
    return null;
  }

  void _changeQuantity(CartLine line, int milli) {
    final issue = _quantityIssue(line, milli);
    if (issue != null) {
      setState(() {
        message = issue;
        quantityEditRevision++;
      });
      return;
    }
    setState(() {
      cart.setQuantityMilli(line.product.id, milli);
      message = null;
    });
    _refreshLayerPrices();
  }

  Widget _cartLine(BuildContext context, CartLine line) {
    final mode = saleModeLabel(line.mode);
    final serials = line.serialIds
        .map((id) => serialLabels[id])
        .whereType<String>()
        .join(', ');
    final batch = line.batchId == null ? null : batchLabels[line.batchId];
    final detail = [
      if (mode.isNotEmpty) mode,
      if (batch != null) 'Batch: $batch',
      if (serials.isNotEmpty) 'Serial: $serials'
    ].join(' · ');
    return Column(children: [
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                    child: Text(line.product.name,
                        style: Theme.of(context).textTheme.titleSmall)),
                IconButton(
                    tooltip: 'Remove ${line.product.name}',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      setState(() => cart.remove(line.product.id));
                      _refreshLayerPrices();
                    },
                    icon: const Icon(Icons.close, size: 18)),
              ]),
              Text(
                  line.product.pricingPolicy == 'layer'
                      ? 'Receiving-layer price · total below'
                      : '${money(line.product.priceCents)} / ${line.product.business.unit.label}',
                  style: Theme.of(context).textTheme.bodySmall),
              if (detail.isNotEmpty)
                Text(detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              Row(children: [
                IconButton(
                    tooltip: 'Decrease ${line.product.name} quantity',
                    visualDensity: VisualDensity.compact,
                    onPressed: line.quantityMilli <= Quantity.scale
                        ? null
                        : () => _changeQuantity(
                            line, line.quantityMilli - Quantity.scale),
                    icon: const Icon(Icons.remove_circle_outline)),
                SizedBox(
                    width: 52,
                    child: TextFormField(
                      key: ValueKey(
                          'quantity-${line.product.id}-${line.quantityMilli}-$quantityEditRevision'),
                      initialValue: Quantity.format(line.quantityMilli),
                      textAlign: TextAlign.center,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(isDense: true),
                      onFieldSubmitted: (value) {
                        final milli = Quantity.tryParse(value,
                            fractional: line.product.business.fractional);
                        if (milli == null) {
                          setState(() {
                            message = 'Enter a valid quantity';
                            quantityEditRevision++;
                          });
                          return;
                        }
                        _changeQuantity(line, milli);
                        barcodeFocus.requestFocus();
                      },
                    )),
                IconButton(
                    tooltip: 'Increase ${line.product.name} quantity',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _changeQuantity(
                        line, line.quantityMilli + Quantity.scale),
                    icon: const Icon(Icons.add_circle_outline)),
                Text(line.product.business.unit.label),
                const Spacer(),
                Text(money(line.totalCents),
                    style: Theme.of(context).textTheme.titleSmall),
              ]),
            ],
          )),
      const Divider(height: 1),
    ]);
  }

  Widget _paymentPanel(
      BuildContext context, int? cashCents, String? cashError) {
    final scheme = Theme.of(context).colorScheme;
    final canCredit =
        customerId != null && widget.user.can(PosPermission.customerCredit);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Divider(),
      _amountRow(context, 'Subtotal', cart.subtotalCents),
      Tooltip(
          message: 'Discounts are not configured for checkout',
          child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.local_offer_outlined),
                  label: const Text('+ Add discount')))),
      const Divider(),
      _amountRow(context, 'TOTAL', cart.totalCents, prominent: true),
      const SizedBox(height: 10),
      Text('Payment method', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      Wrap(spacing: 8, children: [
        ChoiceChip(
            label: const Text('Cash'),
            selected: !credit,
            onSelected: (_) => setState(() {
                  credit = false;
                  cashController.clear();
                })),
        Tooltip(
            message: canCredit
                ? 'Customer credit'
                : 'Select a customer before using credit',
            child: ChoiceChip(
                label: const Text('Credit / Utang'),
                selected: credit,
                onSelected: canCredit
                    ? (_) => setState(() {
                          credit = true;
                          cashController.text = '0';
                        })
                    : null)),
      ]),
      if (!canCredit)
        Text('Select a customer before using credit.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      const SizedBox(height: 8),
      TextField(
        key: const Key('cash-tendered'),
        controller: cashController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
            labelText: credit ? 'Cash paid now (pesos)' : 'Cash tendered',
            errorText: cashError),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (cashError == null && _cartIssue() == null) checkout();
        },
      ),
      if (!credit) ...[
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          for (final (label, cents) in [
            ('Exact', cart.totalCents),
            ('₱100', 10000),
            ('₱500', 50000),
            ('₱1,000', 100000),
          ])
            OutlinedButton(
                onPressed: cents < cart.totalCents
                    ? null
                    : () => setState(
                        () => cashController.text = formatPesoInput(cents)),
                child: Text(label)),
        ]),
        if (cashError == null && cashCents != null)
          _amountRow(context, 'Change', cashCents - cart.totalCents),
      ] else if (cashError == null && cashCents != null) ...[
        _amountRow(context, 'Cash', cashCents),
        _amountRow(context, 'Credit', cart.totalCents - cashCents),
        _amountRow(context, 'Remaining', 0),
      ],
    ]);
  }

  Widget _amountRow(BuildContext context, String label, int amount,
          {bool prominent = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style: prominent
                      ? Theme.of(context).textTheme.titleMedium
                      : null)),
          Text(money(amount),
              style: prominent
                  ? Theme.of(context).textTheme.headlineSmall
                  : Theme.of(context).textTheme.bodyMedium),
        ]),
      );
}

class _OpeningBatchEditor {
  final quantity = TextEditingController();
  final number = TextEditingController();
  DateTime? expiry;
  void dispose() {
    quantity.dispose();
    number.dispose();
  }
}

class ProductScreen extends StatefulWidget {
  final PosRepository repository;
  final AuthService auth;
  final ValueChanged<String>? onReceiveStock;
  final ValueChanged<String>? onCreated;
  final bool createOnOpen;
  final String initialFilter;
  const ProductScreen(
      {super.key,
      required this.repository,
      required this.auth,
      this.onReceiveStock,
      this.onCreated,
      this.createOnOpen = false,
      this.initialFilter = 'All'});
  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  late final catalog = CatalogService(widget.repository, widget.auth);
  List<PosProduct> products = [];
  List<Category> categories = [];
  Map<String, List<InventoryLayer>> activeLayers = {};
  Map<String, (int physical, int reserved)> stockLevels = {};
  String? error;
  String search = '';
  late String filter = widget.initialFilter;
  @override
  void initState() {
    super.initState();
    refresh();
    if (widget.createOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) edit();
      });
    }
  }

  Future<void> refresh() async {
    final rows = await widget.repository.products();
    final categoryRows = await widget.repository.categories();
    final layerRows = await widget.repository.activeLayersByProduct();
    final levels = await widget.repository.stockLevels();
    if (mounted) {
      setState(() {
        products = rows;
        categories = categoryRows;
        activeLayers = layerRows;
        stockLevels = levels;
      });
    }
  }

  String _range(Iterable<int> values, int fallback) {
    final sorted = values.toSet().toList()..sort();
    if (sorted.isEmpty) return '${money(fallback)} (reference)';
    return sorted.length == 1
        ? money(sorted.first)
        : '${money(sorted.first)} – ${money(sorted.last)}';
  }

  Widget _badge(String label) => Builder(
      builder: (context) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8)),
          child: Text(label, style: Theme.of(context).textTheme.labelSmall)));

  String _costRange(PosProduct product) => _range(
      (activeLayers[product.id] ?? []).map((l) => l.unitCostCents),
      product.costCents);

  String _sellingRange(PosProduct product) => product.pricingPolicy == 'layer'
      ? _range(
          (activeLayers[product.id] ?? [])
              .map((l) => l.unitSellingPriceCents ?? product.priceCents),
          product.priceCents)
      : money(product.priceCents);

  Future<void> edit([PosProduct? product]) async {
    var saved = false;
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
    final serialInput = TextEditingController();
    final openingSerials = <String>[];
    String? serialError;
    final threshold =
        TextEditingController(text: '${product?.lowStockThreshold ?? 5}');
    final containerPrice = TextEditingController(
        text: product == null
            ? '0'
            : formatPesoInput(product.business.containerPriceCents));
    final deposit = TextEditingController(
        text: product == null
            ? '0'
            : formatPesoInput(product.business.depositCents));
    final batchNumber = TextEditingController();
    final extraOpeningBatches = <_OpeningBatchEditor>[];
    DateTime? expiryDate;
    final available =
        await BusinessFeatureRepository(widget.repository.db).availability();
    SaleUnit unit = product?.business.unit ?? SaleUnit.piece;
    bool weight = product?.business.weight ?? false;
    bool refill = product?.business.refill ?? false;
    bool tank = product?.business.tank ?? false;
    bool batch = product?.business.batch ?? false;
    bool serialTracking = product?.serialTracking ?? false;
    bool made = product?.business.madeToOrder ?? false;
    String pricingPolicy = product?.pricingPolicy ?? 'current';
    String stockSetup = 'zero';
    final existingStock =
        product == null ? 0 : await widget.repository.stockMilli(product.id);
    final categories = await widget.repository.categories();
    String? categoryId = product?.categoryId;
    bool active = product?.isActive ?? true;
    String? formError;
    bool changed = false;
    Future<void> addOpeningSerials(String value, StateSetter update) async {
      final entries = value
          .split(RegExp(r'[\r\n,]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (entries.isEmpty) {
        update(() => serialError = 'Enter a serial number.');
        return;
      }
      final required = Quantity.tryParse(stock.text, fractional: false);
      if (required != null &&
          required > 0 &&
          openingSerials.length + entries.length > required ~/ Quantity.scale) {
        update(() => serialError =
            'Only ${required ~/ Quantity.scale} serial numbers are required.');
        return;
      }
      final existing = StockReceivingRepository(widget.repository.db);
      for (final entry in entries) {
        if (openingSerials.contains(entry) ||
            entries.where((s) => s == entry).length > 1 ||
            await existing.serialNumberExists(entry)) {
          update(() => serialError = 'Serial $entry already exists.');
          return;
        }
      }
      update(() {
        openingSerials.addAll(entries);
        serialInput.clear();
        serialError = null;
        changed = true;
      });
    }

    for (final controller in [
      name,
      sku,
      barcode,
      price,
      cost,
      stock,
      threshold,
      containerPrice,
      deposit,
      batchNumber
    ]) {
      controller.addListener(() => changed = true);
    }
    Future<bool> confirmClose(BuildContext dialogContext) async {
      if (!changed) return true;
      return await showDialog<bool>(
            context: dialogContext,
            builder: (context) => AlertDialog(
              title: const Text('Discard changes?'),
              content: const Text('Your unsaved product changes will be lost.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Keep editing')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Discard')),
              ],
            ),
          ) ??
          false;
    }

    Future<void> createCategory(
        BuildContext dialogContext, StateSetter update) async {
      final categoryName = TextEditingController();
      String? categoryError;
      Category? duplicate;
      final createdId = await showDialog<String>(
        context: dialogContext,
        builder: (context) => StatefulBuilder(
            builder: (context, setCategoryState) => AlertDialog(
                  title: const Text('New category'),
                  content: SizedBox(
                      width: 360,
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                                controller: categoryName,
                                autofocus: true,
                                decoration:
                                    const InputDecoration(labelText: 'Name *')),
                            if (categoryError != null)
                              Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Text(categoryError!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error))),
                          ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    if (duplicate != null)
                      TextButton(
                          onPressed: () =>
                              Navigator.pop(context, duplicate!.id),
                          child: const Text('Use existing category')),
                    FilledButton(
                        onPressed: () async {
                          final normalized =
                              categoryName.text.trim().toLowerCase();
                          if (normalized.isEmpty) {
                            setCategoryState(
                                () => categoryError = 'Name is required.');
                            return;
                          }
                          final match = categories
                              .where((c) =>
                                  c.name.trim().toLowerCase() == normalized)
                              .firstOrNull;
                          if (match != null) {
                            setCategoryState(() {
                              duplicate = match;
                              categoryError =
                                  'A category with this name already exists.';
                            });
                            return;
                          }
                          try {
                            final id =
                                await catalog.addCategory(categoryName.text);
                            if (context.mounted) Navigator.pop(context, id);
                          } catch (e) {
                            setCategoryState(
                                () => categoryError = safeMessage(e));
                          }
                        },
                        child: const Text('Create & select')),
                  ],
                )),
      );
      await waitForDialogExit();
      categoryName.dispose();
      if (createdId != null) {
        final refreshed = await widget.repository.categories();
        update(() {
          categories
            ..clear()
            ..addAll(refreshed);
          categoryId = createdId;
          changed = true;
        });
        await refresh();
      }
    }

    if (!mounted) return;
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => Dialog(
                insetPadding: const EdgeInsets.all(16),
                child: SizedBox(
                    width: 1080,
                    height: MediaQuery.sizeOf(context).height - 32,
                    child: Column(children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 18, 16, 12),
                        child: Row(children: [
                          const Icon(Icons.inventory_2_outlined),
                          const SizedBox(width: 12),
                          Expanded(
                              child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  product == null
                                      ? 'Create product'
                                      : 'Edit product',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall),
                              const Text(
                                  'Product details, pricing, and stock setup'),
                            ],
                          )),
                          IconButton(
                            tooltip: 'Close editor',
                            onPressed: () async {
                              if (await confirmClose(context) &&
                                  context.mounted) {
                                Navigator.pop(context);
                              }
                            },
                            icon: const Icon(Icons.close),
                          ),
                        ]),
                      ),
                      const Divider(height: 1),
                      Expanded(
                          child: ListView(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 20, 20, 144),
                              children: [
                            if (formError != null)
                              Text(formError!,
                                  style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error)),
                            Wrap(spacing: 16, runSpacing: 16, children: [
                              SizedBox(
                                  width: MediaQuery.sizeOf(context).width < 700
                                      ? MediaQuery.sizeOf(context).width - 80
                                      : 490,
                                  child: Card(
                                      child: Padding(
                                          padding: const EdgeInsets.all(20),
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text('GENERAL',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium),
                                                TextField(
                                                    controller: name,
                                                    decoration:
                                                        const InputDecoration(
                                                            labelText: 'Name')),
                                                const SizedBox(height: 12),
                                                Row(children: [
                                                  Expanded(
                                                      child: TextField(
                                                          controller: sku,
                                                          decoration:
                                                              const InputDecoration(
                                                                  labelText:
                                                                      'SKU'))),
                                                  const SizedBox(width: 12),
                                                  Expanded(
                                                      child: TextField(
                                                          controller: barcode,
                                                          decoration:
                                                              const InputDecoration(
                                                                  labelText:
                                                                      'Barcode')))
                                                ]),
                                                const SizedBox(height: 12),
                                                DropdownButtonFormField<
                                                        String?>(
                                                    key: ValueKey(categoryId),
                                                    initialValue: categoryId,
                                                    decoration:
                                                        const InputDecoration(
                                                            labelText:
                                                                'Category'),
                                                    items: [
                                                      const DropdownMenuItem<
                                                              String?>(
                                                          value: null,
                                                          child: Text('None')),
                                                      ...categories.map((c) =>
                                                          DropdownMenuItem<
                                                                  String?>(
                                                              value: c.id,
                                                              child:
                                                                  Text(c.name)))
                                                    ],
                                                    onChanged: (v) =>
                                                        update(() {
                                                          categoryId = v;
                                                          changed = true;
                                                        })),
                                                Align(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: TextButton.icon(
                                                        onPressed: () =>
                                                            createCategory(
                                                                context,
                                                                update),
                                                        icon: const Icon(
                                                            Icons.add),
                                                        label: const Text(
                                                            'Create new category'))),
                                              ])))),
                              SizedBox(
                                  width: MediaQuery.sizeOf(context).width < 700
                                      ? MediaQuery.sizeOf(context).width - 80
                                      : 490,
                                  child: Card(
                                      child: Padding(
                                          padding: const EdgeInsets.all(20),
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text('PRICING',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium),
                                                TextField(
                                                    controller: price,
                                                    decoration:
                                                        const InputDecoration(
                                                            labelText:
                                                                'Current selling price (pesos)'),
                                                    keyboardType:
                                                        TextInputType.number),
                                                const SizedBox(height: 12),
                                                TextField(
                                                    controller: cost,
                                                    onChanged: (_) =>
                                                        update(() {}),
                                                    decoration: const InputDecoration(
                                                        labelText:
                                                            'Current purchase cost (pesos)',
                                                        helperText:
                                                            'Reference cost for opening stock and future receiving. Actual supplier costs are preserved per stock layer.',
                                                        helperMaxLines: 3),
                                                    keyboardType:
                                                        TextInputType.number),
                                                const SizedBox(height: 20),
                                                DropdownButtonFormField<String>(
                                                    initialValue: pricingPolicy,
                                                    isExpanded: true,
                                                    decoration:
                                                        const InputDecoration(
                                                            labelText:
                                                                'Selling price policy'),
                                                    items: const [
                                                      DropdownMenuItem(
                                                          value: 'current',
                                                          child: Text(
                                                              'Use current product selling price')),
                                                      DropdownMenuItem(
                                                          value: 'layer',
                                                          child: Text(
                                                              'Use receiving-layer selling price')),
                                                    ],
                                                    onChanged: (value) =>
                                                        update(() {
                                                          pricingPolicy =
                                                              value ??
                                                                  'current';
                                                          changed = true;
                                                        })),
                                                const SizedBox(height: 8),
                                                Text(pricingPolicy == 'layer'
                                                    ? 'Each received layer can keep its own selling price. FIFO or selected serial determines the price.'
                                                    : 'Sales use this product price. Received stock keeps its actual purchase cost.'),
                                              ])))),
                            ]),
                            const SizedBox(height: 24),
                            Text('INVENTORY',
                                style: Theme.of(context).textTheme.titleMedium),
                            if (product == null && !made) ...[
                              const SizedBox(height: 12),
                              Text('Stock setup',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const Text(
                                  'Choose how this product\'s inventory should begin.'),
                              const SizedBox(height: 8),
                              for (final choice
                                  in <(String, String, String, IconData)>[
                                (
                                  'zero',
                                  'Create with zero stock',
                                  'Add inventory later.',
                                  Icons.inventory_2_outlined
                                ),
                                (
                                  'opening',
                                  'I already have stock on hand',
                                  'Inventory you already owned before setting up this POS.',
                                  Icons.warehouse_outlined
                                ),
                                if (widget.onReceiveStock != null)
                                  (
                                    'receive',
                                    'Receive stock from a supplier now',
                                    'Record a supplier delivery now.',
                                    Icons.local_shipping_outlined
                                  ),
                              ])
                                Card(
                                  child: ListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    selected: stockSetup == choice.$1,
                                    leading: Icon(stockSetup == choice.$1
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked),
                                    onTap: () => update(() {
                                      stockSetup = choice.$1;
                                      changed = true;
                                    }),
                                    title: Text(choice.$2),
                                    subtitle: Text(choice.$3),
                                    trailing: Icon(choice.$4),
                                  ),
                                ),
                              if (stockSetup == 'opening') ...[
                                const SizedBox(height: 12),
                                const Text('Existing inventory',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w600)),
                              ],
                              if (stockSetup == 'opening' && !batch)
                                TextField(
                                    controller: stock,
                                    decoration: const InputDecoration(
                                        labelText: 'Opening quantity',
                                        helperText:
                                            'Use for inventory you already owned before setting up this POS.'),
                                    keyboardType: TextInputType.number,
                                    onChanged: (_) => update(() {})),
                              if (stockSetup == 'opening' && batch) ...[
                                Text('Existing inventory batches',
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                                TextField(
                                    controller: stock,
                                    decoration: const InputDecoration(
                                        labelText: 'Batch 1 quantity'),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true)),
                                TextField(
                                    controller: batchNumber,
                                    decoration: const InputDecoration(
                                        labelText: 'Batch 1 lot number')),
                                ExpiryDateField(
                                    value: expiryDate,
                                    onChanged: (date) =>
                                        update(() => expiryDate = date)),
                                for (var index = 0;
                                    index < extraOpeningBatches.length;
                                    index++)
                                  Card(
                                      child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Column(children: [
                                            Row(children: [
                                              Expanded(
                                                  child: Text(
                                                      'Batch ${index + 2}')),
                                              IconButton(
                                                  icon: const Icon(Icons.close),
                                                  onPressed: () => update(() {
                                                        extraOpeningBatches
                                                            .removeAt(index)
                                                            .dispose();
                                                        changed = true;
                                                      }))
                                            ]),
                                            TextField(
                                                controller:
                                                    extraOpeningBatches[index]
                                                        .quantity,
                                                decoration:
                                                    const InputDecoration(
                                                        labelText: 'Quantity'),
                                                keyboardType:
                                                    const TextInputType
                                                        .numberWithOptions(
                                                        decimal: true)),
                                            TextField(
                                                controller:
                                                    extraOpeningBatches[index]
                                                        .number,
                                                decoration:
                                                    const InputDecoration(
                                                        labelText:
                                                            'Batch / lot')),
                                            ExpiryDateField(
                                                value:
                                                    extraOpeningBatches[index]
                                                        .expiry,
                                                onChanged: (date) => update(
                                                    () => extraOpeningBatches[
                                                            index]
                                                        .expiry = date)),
                                          ]))),
                                TextButton.icon(
                                    onPressed: () => update(() {
                                          extraOpeningBatches
                                              .add(_OpeningBatchEditor());
                                          changed = true;
                                        }),
                                    icon: const Icon(Icons.add),
                                    label: const Text('Add opening batch')),
                              ],
                              if (stockSetup == 'opening')
                                Text(
                                    'Opening layer cost: ${money(tryParseMoney(cost.text) ?? 0)} per ${unit.label}. Used as the opening cost for this existing stock.'),
                              if (stockSetup == 'opening' &&
                                  serialTracking) ...[
                                Text(
                                    'Serial numbers · ${(Quantity.tryParse(stock.text, fractional: false) ?? 0) ~/ Quantity.scale} required · ${openingSerials.length} entered',
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                                const Text(
                                    'Enter the serial numbers already physically on hand.'),
                                TextField(
                                  controller: serialInput,
                                  decoration: const InputDecoration(
                                      labelText: 'Scan or enter serial number',
                                      hintText: 'Press Enter to add'),
                                  onSubmitted: (value) =>
                                      addOpeningSerials(value, update),
                                ),
                                Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                        onPressed: () => addOpeningSerials(
                                            serialInput.text, update),
                                        child: const Text('Add serial'))),
                                if (serialError != null)
                                  Text(serialError!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error)),
                                for (final serial in openingSerials)
                                  ListTile(
                                    dense: true,
                                    title: Text(serial),
                                    trailing: IconButton(
                                        icon: const Icon(Icons.close, size: 18),
                                        onPressed: () => update(() =>
                                            openingSerials.remove(serial))),
                                  ),
                                if (openingSerials.isNotEmpty)
                                  Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton(
                                          onPressed: () =>
                                              update(openingSerials.clear),
                                          child: const Text('Clear all'))),
                              ],
                            ],
                            const SizedBox(height: 16),
                            TextField(
                                controller: threshold,
                                decoration: const InputDecoration(
                                    labelText: 'Low-stock alert threshold',
                                    helperText:
                                        'Show an alert when available stock reaches this quantity.'),
                                keyboardType: TextInputType.number),
                            const SizedBox(height: 16),
                            ExpansionTile(
                                title: Row(children: [
                                  const Expanded(
                                      child: Text('Unit & selling method')),
                                  Text(
                                      '${unit.label}${weight ? ' · Weight' : ''}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ]),
                                children: [
                                  if (available[
                                          BusinessFeature.weightBasedPricing] ==
                                      true)
                                    SwitchListTile(
                                        title: const Text('Sold by weight'),
                                        value: weight,
                                        onChanged: (v) => update(() {
                                              changed = true;
                                              weight = v;
                                              if (v) {
                                                unit = SaleUnit.kilogram;
                                                refill = false;
                                                tank = false;
                                              }
                                            })),
                                  if (available[BusinessFeature
                                              .unitOfMeasureVariety] ==
                                          true ||
                                      (available[BusinessFeature
                                                  .weightBasedPricing] ==
                                              true &&
                                          weight))
                                    DropdownButtonFormField<SaleUnit>(
                                        initialValue: unit,
                                        decoration: const InputDecoration(
                                            labelText: 'Unit / price basis',
                                            helperText:
                                                'Price is charged per selected unit.'),
                                        items: SaleUnit.values
                                            .where((u) => serialTracking
                                                ? !u.fractional
                                                : weight
                                                    ? u == SaleUnit.kilogram ||
                                                        u == SaleUnit.gram
                                                    : (refill || tank)
                                                        ? !u.fractional
                                                        : true)
                                            .map((u) => DropdownMenuItem(
                                                value: u, child: Text(u.label)))
                                            .toList(),
                                        onChanged: (v) => update(() {
                                              unit = v ?? unit;
                                              changed = true;
                                            })),
                                  if (available[BusinessFeature
                                          .madeToOrderTracking] ==
                                      true)
                                    SwitchListTile(
                                        title: const Text('Made to order'),
                                        subtitle: made
                                            ? const Text(
                                                'This item may be sold before fulfillment is completed.')
                                            : null,
                                        value: made,
                                        onChanged: (v) => update(() {
                                              changed = true;
                                              made = v;
                                              if (v) {
                                                batch = false;
                                                refill = false;
                                                tank = false;
                                                stock.text = '0';
                                              }
                                            })),
                                ]),
                            ExpansionTile(
                                title: Row(children: [
                                  const Expanded(
                                      child: Text('Tracking options')),
                                  Text(
                                      serialTracking
                                          ? 'Serialized'
                                          : batch
                                              ? 'Batch'
                                              : 'None',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ]),
                                children: [
                                  SwitchListTile(
                                      title: const Text(
                                          'Individual serial numbers'),
                                      subtitle: serialTracking
                                          ? const Text(
                                              'Every opening or received unit needs its own serial number.')
                                          : null,
                                      value: serialTracking,
                                      onChanged: (v) => update(() {
                                            changed = true;
                                            serialTracking = v;
                                            if (v) {
                                              if (unit.fractional) {
                                                unit = SaleUnit.piece;
                                              }
                                              weight = false;
                                              made = false;
                                            }
                                          })),
                                  if (serialTracking && unit.fractional)
                                    Text(
                                        'Serial-tracked products require a whole-unit sale unit.',
                                        style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .error)),
                                  if (available[BusinessFeature
                                          .expiryBatchTracking] ==
                                      true)
                                    SwitchListTile(
                                        title: const Text('Batch / expiry'),
                                        subtitle: batch
                                            ? const Text(
                                                'Batch numbers and expiry dates are recorded when stock is received.')
                                            : null,
                                        value: batch,
                                        onChanged: (v) => update(() {
                                              changed = true;
                                              batch = v;
                                              if (v) made = false;
                                            })),
                                  if (batch &&
                                      !(product == null &&
                                          stockSetup == 'opening') &&
                                      (product == null ||
                                          (!product.business.batch &&
                                              existingStock > 0))) ...[
                                    TextField(
                                        controller: batchNumber,
                                        decoration: const InputDecoration(
                                            labelText:
                                                'Batch number for stock already on hand')),
                                    ExpiryDateField(
                                        value: expiryDate,
                                        onChanged: (date) => update(() {
                                              expiryDate = date;
                                              changed = true;
                                            })),
                                  ],
                                ]),
                            ExpansionTile(
                                title: Row(children: [
                                  const Expanded(
                                      child: Text('Special selling options')),
                                  Text(
                                      made
                                          ? 'MTO'
                                          : refill
                                              ? 'Refill'
                                              : tank
                                                  ? 'LPG'
                                                  : 'None',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ]),
                                children: [
                                  if (available[BusinessFeature
                                          .containerRefillPricing] ==
                                      true) ...[
                                    SwitchListTile(
                                        title: const Text(
                                            'Water refill / container'),
                                        subtitle: refill
                                            ? const Text(
                                                'Container pricing is applied during checkout.')
                                            : null,
                                        value: refill,
                                        onChanged: (v) => update(() {
                                              refill = v;
                                              changed = true;
                                              if (v) {
                                                unit = SaleUnit.bottle;
                                                weight = false;
                                                tank = false;
                                                made = false;
                                              }
                                            })),
                                    if (refill)
                                      TextField(
                                          controller: containerPrice,
                                          decoration: const InputDecoration(
                                              labelText:
                                                  'Additional container price (pesos)'),
                                          keyboardType: TextInputType.number),
                                  ],
                                  if (available[BusinessFeature
                                          .tankDepositExchange] ==
                                      true) ...[
                                    SwitchListTile(
                                        title: const Text(
                                            'LPG tank exchange / deposit'),
                                        subtitle: tank
                                            ? const Text(
                                                'Tank exchange and deposit are handled during checkout.')
                                            : null,
                                        value: tank,
                                        onChanged: (v) => update(() {
                                              tank = v;
                                              changed = true;
                                              if (v) {
                                                unit = SaleUnit.piece;
                                                weight = false;
                                                refill = false;
                                                made = false;
                                              }
                                            })),
                                    if (tank)
                                      TextField(
                                          controller: deposit,
                                          decoration: const InputDecoration(
                                              labelText:
                                                  'Deposit for no empty return (pesos)'),
                                          keyboardType: TextInputType.number),
                                  ],
                                ]),
                            ExpansionTile(
                                title: Row(children: [
                                  const Expanded(child: Text('Status')),
                                  Text(active ? 'Active' : 'Inactive',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ]),
                                children: [
                                  SwitchListTile(
                                      title: const Text('Active'),
                                      value: active,
                                      onChanged: (v) => update(() {
                                            active = v;
                                            changed = true;
                                          })),
                                ]),
                          ])),
                      const Divider(height: 1),
                      Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                    onPressed: () async {
                                      if (await confirmClose(context) &&
                                          context.mounted) {
                                        Navigator.pop(context);
                                      }
                                    },
                                    child: const Text('Cancel')),
                                FilledButton(
                                    onPressed: () async {
                                      try {
                                        if (name.text.trim().isEmpty) {
                                          throw ArgumentError(
                                              'Name is required.');
                                        }
                                        final priceCents =
                                            tryParseMoney(price.text);
                                        final costCents =
                                            tryParseMoney(cost.text);
                                        if (priceCents == null ||
                                            priceCents < 0) {
                                          throw ArgumentError(
                                              'Selling price is invalid.');
                                        }
                                        if (costCents == null ||
                                            costCents < 0) {
                                          throw ArgumentError(
                                              'Cost is invalid.');
                                        }
                                        final parsedInitialMilli = stockSetup !=
                                                    'opening' ||
                                                stock.text.trim() == '0'
                                            ? 0
                                            : Quantity.tryParse(stock.text,
                                                fractional:
                                                    unit.fractional || weight);
                                        final lowStockThreshold =
                                            int.tryParse(threshold.text.trim());
                                        if (parsedInitialMilli == null ||
                                            lowStockThreshold == null ||
                                            lowStockThreshold < 0) {
                                          throw StateError(
                                              'Enter valid price, cost, and starting stock');
                                        }
                                        var initialMilli = parsedInitialMilli;
                                        if (product == null &&
                                            stockSetup == 'opening' &&
                                            initialMilli <= 0) {
                                          throw StateError(
                                              'Enter an opening quantity greater than zero.');
                                        }
                                        final openingBatches = <OpeningBatch>[];
                                        if (product == null &&
                                            stockSetup == 'opening' &&
                                            batch) {
                                          if (initialMilli <= 0 ||
                                              batchNumber.text.trim().isEmpty) {
                                            throw StateError(
                                                'Enter a quantity and lot for the first opening batch.');
                                          }
                                          openingBatches.add(OpeningBatch(
                                              initialMilli,
                                              batchNumber.text.trim(),
                                              expiryDate));
                                          for (final row
                                              in extraOpeningBatches) {
                                            final quantity = Quantity.tryParse(
                                                row.quantity.text,
                                                fractional:
                                                    unit.fractional || weight);
                                            if (quantity == null ||
                                                quantity <= 0 ||
                                                row.number.text
                                                    .trim()
                                                    .isEmpty) {
                                              throw StateError(
                                                  'Enter a valid quantity and lot for each opening batch.');
                                            }
                                            openingBatches.add(OpeningBatch(
                                                quantity,
                                                row.number.text.trim(),
                                                row.expiry));
                                            initialMilli += quantity;
                                          }
                                        }
                                        if (product == null &&
                                            stockSetup == 'opening' &&
                                            serialTracking &&
                                            (initialMilli <= 0 ||
                                                initialMilli % Quantity.scale !=
                                                    0 ||
                                                openingSerials.length !=
                                                    initialMilli ~/
                                                        Quantity.scale)) {
                                          final missing =
                                              initialMilli ~/ Quantity.scale -
                                                  openingSerials.length;
                                          throw StateError(missing > 0
                                              ? 'Enter $missing more serial numbers to continue.'
                                              : 'Enter exactly one unique serial number per opening unit.');
                                        }
                                        final savedId =
                                            await catalog.saveProduct(
                                                id: product?.id,
                                                name: name.text,
                                                sku: sku.text,
                                                barcode: barcode.text,
                                                categoryId: categoryId,
                                                priceCents: priceCents,
                                                costCents: costCents,
                                                pricingPolicy: pricingPolicy,
                                                startingStockMilli:
                                                    initialMilli,
                                                lowStockThreshold:
                                                    lowStockThreshold,
                                                isActive: active,
                                                serialTracking: serialTracking,
                                                openingSerials: openingSerials,
                                                openingBatches: openingBatches,
                                                business: BusinessProduct(
                                                    unit: unit,
                                                    weight: weight,
                                                    refill: refill,
                                                    containerPriceCents:
                                                        tryParseMoney(
                                                                containerPrice
                                                                    .text) ??
                                                            -1,
                                                    tank: tank,
                                                    depositCents: tryParseMoney(
                                                            deposit.text) ??
                                                        -1,
                                                    batch: batch,
                                                    madeToOrder: made),
                                                batchNumber: batchNumber.text,
                                                batchExpiry: expiryDate);
                                        saved = true;
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }
                                        await refresh();
                                        await waitForDialogExit();
                                        if (product == null) {
                                          widget.onCreated?.call(savedId);
                                        }
                                        if (product == null &&
                                            stockSetup == 'receive') {
                                          widget.onReceiveStock?.call(savedId);
                                        }
                                        if (widget.createOnOpen && mounted) {
                                          Navigator.of(this.context).pop();
                                        }
                                      } catch (e) {
                                        update(
                                            () => formError = safeMessage(e));
                                      }
                                    },
                                    child: Text(product == null
                                        ? stockSetup == 'receive'
                                            ? 'Create & Continue to Receiving'
                                            : 'Create product'
                                        : 'Save changes'))
                              ])),
                    ])))));
    if (widget.createOnOpen && !saved && mounted) {
      Navigator.of(context).pop();
    }
    await waitForDialogExit();
    name.dispose();
    serialInput.dispose();
    sku.dispose();
    barcode.dispose();
    price.dispose();
    cost.dispose();
    stock.dispose();
    threshold.dispose();
    containerPrice.dispose();
    deposit.dispose();
    batchNumber.dispose();
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
    await waitForDialogExit();
    name.dispose();
  }

  Future<void> receiveBatch(PosProduct product) async {
    final number = TextEditingController();
    final quantity = TextEditingController();
    DateTime? expiryDate;
    try {
      await showDialog<void>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: Text('Receive batch · ${product.name}'),
                    content: SizedBox(
                        width: 350,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          TextField(
                              controller: number,
                              decoration: const InputDecoration(
                                  labelText: 'Batch number')),
                          TextField(
                              controller: quantity,
                              decoration: InputDecoration(
                                  labelText:
                                      'Quantity (${product.business.unit.label})'),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true)),
                          ExpiryDateField(
                              value: expiryDate,
                              onChanged: (date) =>
                                  update(() => expiryDate = date)),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () async {
                            try {
                              final milli = Quantity.tryParse(quantity.text,
                                  fractional: product.business.fractional);
                              if (milli == null) {
                                throw StateError('Invalid batch quantity');
                              }
                              await widget.repository.receiveBatch(
                                  product.id,
                                  number.text,
                                  expiryDate,
                                  milli,
                                  widget.auth.current!.id);
                              if (context.mounted) Navigator.pop(context);
                              await refresh();
                            } catch (e) {
                              if (mounted) {
                                setState(() => error = safeMessage(e));
                              }
                            }
                          },
                          child: const Text('Receive')),
                    ],
                  )));
    } finally {
      await waitForDialogExit();
      number.dispose();
      quantity.dispose();
    }
  }

  Future<void> showProduct(PosProduct product) async {
    final categories = await widget.repository.categories();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(product.name),
        content: SizedBox(
          width: 560,
          child: ListView(shrinkWrap: true, children: [
            Text('SKU: ${product.sku?.isNotEmpty == true ? product.sku : '—'}'),
            Text(
                'Barcode: ${product.barcode?.isNotEmpty == true ? product.barcode : '—'}'),
            Text(
                'Category: ${categories.where((c) => c.id == product.categoryId).firstOrNull?.name ?? 'None'}'),
            Text(
                'Pricing policy: ${product.pricingPolicy == 'layer' ? 'Receiving-layer price' : 'Current product price'}'),
            Text(
                'Current selling price: ${money(product.priceCents)} / ${product.business.unit.label}'),
            Text('Current purchase cost: ${money(product.costCents)}'),
            Text('Active purchase cost: ${_costRange(product)}'),
            if (product.pricingPolicy == 'layer')
              Text('Active selling price: ${_sellingRange(product)}'),
            FutureBuilder<int>(
              future: widget.repository.stockMilli(product.id),
              builder: (context, value) => Text(
                  'Physical stock: ${value.data == null ? '…' : Quantity.format(value.data!)} ${product.business.unit.label}'),
            ),
            Text('Low-stock threshold: ${product.lowStockThreshold}'),
            FutureBuilder<int>(
              future: widget.repository.reservedStockMilli(product.id),
              builder: (context, value) => Text(
                  'Reserved: ${value.data == null ? '…' : Quantity.format(value.data!)} ${product.business.unit.label}'),
            ),
            FutureBuilder<List<int>>(
              future: Future.wait([
                widget.repository.stockMilli(product.id),
                widget.repository.reservedStockMilli(product.id)
              ]),
              builder: (context, value) => Text(
                  'Available: ${value.data == null ? '…' : Quantity.format(value.data![0] - value.data![1])} ${product.business.unit.label}'),
            ),
            Text(product.isActive ? 'Active' : 'Inactive'),
            Wrap(spacing: 8, children: [
              if (product.serialTracking) const Chip(label: Text('Serialized')),
              if (product.business.batch)
                const Chip(label: Text('Batch / expiry')),
              if (product.business.weight) const Chip(label: Text('Weight')),
              if (product.business.refill) const Chip(label: Text('Refill')),
              if (product.business.tank) const Chip(label: Text('LPG')),
              if (product.business.madeToOrder)
                const Chip(label: Text('Made to order')),
            ]),
            FutureBuilder<(List<InventoryLayer>, Map<String, String>)>(
              future: (() async => (
                    await widget.repository.layersForProduct(product.id),
                    await widget.repository.layerSupplierNames(product.id)
                  ))(),
              builder: (context, value) => ExpansionTile(
                title: const Text('View stock layers'),
                children: [
                  for (final layer in value.data?.$1 ?? <InventoryLayer>[])
                    ListTile(
                      title: Text(
                          '${Quantity.format(layer.quantityRemainingMilli)} / ${Quantity.format(layer.quantityReceivedMilli)} ${product.business.unit.label} · ${money(layer.unitCostCents)} cost'),
                      subtitle: Text(
                          '${value.data?.$2[layer.id] ?? layer.source} · ${layer.receivedAt}${layer.batchNumber == null ? '' : ' · ${layer.batchNumber}'}${layer.unitSellingPriceCents == null ? '' : ' · ${money(layer.unitSellingPriceCents!)} sell'}${layer.quantityRemainingMilli == 0 ? ' · Depleted' : ''}'),
                      onTap: () async {
                        final reference = await widget.repository
                            .layerReceivingReference(layer.id);
                        final serials =
                            await widget.repository.serialsForLayer(layer.id);
                        if (!context.mounted) return;
                        await showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                                  title: const Text('Stock layer'),
                                  content: SizedBox(
                                      width: 480,
                                      child:
                                          ListView(shrinkWrap: true, children: [
                                        Text(
                                            'Source: ${layer.source == 'opening' ? 'Opening stock' : layer.source}'),
                                        Text(
                                            'Receiving: ${reference ?? 'Opening balance'}'),
                                        Text(
                                            'Supplier: ${value.data?.$2[layer.id] ?? 'None'}'),
                                        Text('Received: ${layer.receivedAt}'),
                                        Text(
                                            'Original: ${Quantity.format(layer.quantityReceivedMilli)} ${product.business.unit.label}'),
                                        Text(
                                            'Remaining: ${Quantity.format(layer.quantityRemainingMilli)} ${product.business.unit.label}'),
                                        Text(
                                            'Purchase cost: ${money(layer.unitCostCents)}'),
                                        if (layer.unitSellingPriceCents != null)
                                          Text(
                                              'Layer selling price: ${money(layer.unitSellingPriceCents!)}'),
                                        if (layer.batchNumber != null)
                                          Text('Batch: ${layer.batchNumber}'),
                                        if (layer.expiryDate != null)
                                          Text('Expiry: ${layer.expiryDate}'),
                                        for (final serial in serials)
                                          Text(
                                              '${serial.serialNumber} · ${serial.status}'),
                                      ])),
                                  actions: [
                                    TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('Close'))
                                  ],
                                ));
                      },
                    ),
                ],
              ),
            ),
            FutureBuilder(
              future: widget.repository.movements(product.id),
              builder: (context, value) => ExpansionTile(
                title: const Text('View stock movements'),
                children: [
                  for (final movement in value.data ?? <InventoryMovement>[])
                    ListTile(
                        title: Text(inventoryMovementLabel(movement.reason)),
                        subtitle: Text(
                            'Quantity: ${Quantity.format(movement.quantityDeltaMilli)}'))
                ],
              ),
            ),
            if (product.serialTracking)
              FutureBuilder<(List<SerialUnit>, List<InventoryLayer>)>(
                future: (() async => (
                      await widget.repository.availableSerials(product.id),
                      await widget.repository.layersForProduct(product.id)
                    ))(),
                builder: (context, value) => ExpansionTile(
                  title: const Text('View available serial units'),
                  subtitle: Text('${value.data?.$1.length ?? 0} available'),
                  children: [
                    for (final serial in value.data?.$1 ?? <SerialUnit>[])
                      ListTile(
                          title: Text(serial.serialNumber),
                          subtitle: Text(
                              '${serial.status} · ${switch (value.data?.$2.where((l) => l.id == serial.inventoryLayerId).firstOrNull?.source) {
                            'opening' => 'Opening stock',
                            'receiving' => 'Supplier receiving',
                            _ => 'Unknown',
                          }}'))
                  ],
                ),
              ),
            if (product.business.batch)
              FutureBuilder(
                future: widget.repository.batches(product.id),
                builder: (context, value) => ExpansionTile(
                  title: const Text('View batches'),
                  children: [
                    for (final lot in value.data ?? <ProductLot>[])
                      ListTile(
                          title: Text(lot.batchNumber),
                          subtitle: Text(
                              '${Quantity.format(lot.quantityMilli)} ${product.business.unit.label} · ${expiryStatus(lot.expiryDate, DateTime.now())}'))
                  ],
                ),
              ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
          TextButton(
              onPressed: () {
                Navigator.pop(context);
                edit(product);
              },
              child: const Text('Edit product')),
          if (widget.onReceiveStock != null && !product.business.madeToOrder)
            FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onReceiveStock!(product.id);
                },
                child: const Text('Receive stock')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Products')),
        body: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1280),
                child: ListView(padding: const EdgeInsets.all(20), children: [
                  if (error != null)
                    Text(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  Wrap(spacing: 8, children: [
                    FilledButton.icon(
                        onPressed: () => edit(),
                        icon: const Icon(Icons.add),
                        label: const Text('Add product')),
                    PopupMenuButton<String>(
                        tooltip: 'More',
                        onSelected: (value) {
                          if (value == 'categories') addCategory();
                        },
                        itemBuilder: (context) => const [
                              PopupMenuItem(
                                  value: 'categories',
                                  child: Text('Manage categories'))
                            ],
                        child: const Padding(
                            padding: EdgeInsets.all(12),
                            child: Icon(Icons.more_horiz))),
                  ]),
                  const SizedBox(height: 16),
                  TextField(
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        labelText: 'Search name, SKU, or barcode'),
                    onChanged: (value) =>
                        setState(() => search = value.toLowerCase().trim()),
                  ),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final choice in [
                      'All',
                      'Active',
                      'Inactive',
                      'Low stock',
                      'Out of stock',
                      'Serialized',
                      'Batch tracked'
                    ])
                      Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(choice),
                            selected: filter == choice,
                            onSelected: (_) => setState(() => filter = choice),
                          )),
                  ]),
                  const SizedBox(height: 16),
                  if (products.isEmpty)
                    Card(
                        child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(children: [
                              const Text('No products yet'),
                              const Text(
                                  'Create your first product to start building the inventory catalog.'),
                              FilledButton(
                                  onPressed: () => edit(),
                                  child: const Text('Add product')),
                            ]))),
                  ...products
                      .where((p) =>
                          (search.isEmpty ||
                              p.name.toLowerCase().contains(search) ||
                              (p.sku ?? '').toLowerCase().contains(search) ||
                              (p.barcode ?? '')
                                  .toLowerCase()
                                  .contains(search) ||
                              (categories
                                          .where((c) => c.id == p.categoryId)
                                          .firstOrNull
                                          ?.name ??
                                      '')
                                  .toLowerCase()
                                  .contains(search)) &&
                          (filter == 'All' ||
                              (filter == 'Active' && p.isActive) ||
                              (filter == 'Inactive' && !p.isActive) ||
                              (filter == 'Out of stock' && p.isActive) ||
                              (filter == 'Serialized' && p.serialTracking) ||
                              (filter == 'Batch tracked' && p.business.batch) ||
                              filter == 'Low stock'))
                      .map((p) {
                    final available = (stockLevels[p.id]?.$1 ?? 0) -
                        (stockLevels[p.id]?.$2 ?? 0);
                    final narrow = MediaQuery.sizeOf(context).width < 700;
                    return (filter == 'Low stock' &&
                                (available <= 0 ||
                                    available >
                                        p.lowStockThreshold *
                                            Quantity.scale)) ||
                            (filter == 'Out of stock' && available > 0)
                        ? const SizedBox.shrink()
                        : Card(
                            child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            onTap: () => showProduct(p),
                            title: Text(p.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (p.sku?.isNotEmpty == true ||
                                      p.categoryId != null ||
                                      !p.isActive)
                                    Text(
                                        '${p.sku ?? categories.where((c) => c.id == p.categoryId).firstOrNull?.name ?? ''}${p.isActive ? '' : ' · Inactive'}'),
                                  Text(
                                      'Selling: ${_sellingRange(p)} / ${p.business.unit.label}   ·   Purchase cost: ${_costRange(p)}'),
                                  if (narrow)
                                    Text(
                                        '${Quantity.format(available)} ${p.business.unit.label} available'),
                                  const SizedBox(height: 4),
                                  Wrap(spacing: 6, runSpacing: 4, children: [
                                    if (p.serialTracking) _badge('Serialized'),
                                    if (p.business.batch) _badge('Batch'),
                                    if (p.business.weight) _badge('Weight'),
                                    if (p.business.refill) _badge('Refill'),
                                    if (p.business.tank) _badge('LPG'),
                                    if (p.business.madeToOrder) _badge('MTO'),
                                  ]),
                                ]),
                            trailing: narrow
                                ? const Icon(Icons.chevron_right)
                                : Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                        Text(
                                            '${Quantity.format(available)} ${p.business.unit.label} available',
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600)),
                                        const Icon(Icons.chevron_right,
                                            size: 18),
                                      ]),
                          ));
                  }),
                ]))),
      );
}
