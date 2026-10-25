import 'package:flutter/material.dart';
import '../../shared/widgets/app_workspace.dart';
import 'package:drift/drift.dart' show TableUpdateQuery, Variable;
import '../../core/models/cart.dart';
import '../../core/models/manual_discount.dart';
import '../../core/models/promotion_evaluation.dart';
import '../../core/services/promotion_checkout_service.dart';
import '../../data/daos/promotion_repository.dart';
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
import '../../shared/widgets/record_details_drawer.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/sales_order_repository.dart';
import '../../data/daos/loyalty_repository.dart';
import '../../data/daos/held_sale_repository.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../../data/daos/purchase_order_repository.dart';
import '../../data/daos/inventory_planning_repository.dart';
import '../../data/daos/inventory_health_repository.dart';
import '../../data/database.dart';
import '../inventory/inventory_overview.dart' show inventoryMovementLabel;
import '../../hardware/printer/receipt_service.dart';
import '../../hardware/printer/label_printing.dart';
import '../inventory/label_print_dialog.dart';
import '../../hardware/barcode/camera_scanner.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';
import 'pos_layout_preference.dart';
import 'pos_shortcut_profile.dart';

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
  if (totalCents == 0 && value.trim().isEmpty) return null;
  if (value.trim().isEmpty) return 'Enter cash received';
  final cents = tryParseMoney(value);
  if (cents == null) return 'Enter a valid amount (up to 2 decimal places)';
  if (cents < 0 || (cents == 0 && totalCents > 0)) {
    return 'Cash received must be greater than zero';
  }
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

class _LookupIntent extends Intent {
  const _LookupIntent();
}

class _CustomerIntent extends Intent {
  const _CustomerIntent();
}

class _PayIntent extends Intent {
  const _PayIntent();
}

class _HoldIntent extends Intent {
  const _HoldIntent();
}

class _HeldSalesIntent extends Intent {
  const _HeldSalesIntent();
}

class SaleCompletion {
  final String saleId;
  final String reference;
  final int totalCents;
  final List<(String, int)> payments;
  final int changeCents;
  final String customer;
  final int earnedPoints;
  final int? pointsBalance;
  final String? printIssue;
  final List<(String, int)> promotionDiscounts;
  const SaleCompletion(
      this.saleId,
      this.reference,
      this.totalCents,
      this.payments,
      this.changeCents,
      this.customer,
      this.earnedPoints,
      this.pointsBalance,
      this.printIssue,
      [this.promotionDiscounts = const []]);

  SaleCompletion withPrintIssue(String? issue) => SaleCompletion(
      saleId,
      reference,
      totalCents,
      payments,
      changeCents,
      customer,
      earnedPoints,
      pointsBalance,
      issue,
      promotionDiscounts);
}

class _FocusIntent extends Intent {
  const _FocusIntent();
}

class _ScanKeyIntent extends Intent {
  final LogicalKeyboardKey key;
  const _ScanKeyIntent(this.key);
}

enum CheckoutDiscountSource { none, automaticPromotion, manual }

class CheckoutScreen extends StatefulWidget {
  final PosRepository repository;
  final ActiveUser user;
  final AuthService auth;
  final ReceiptService? receipts;
  final CameraBarcodeScanner? camera;
  final String? quotationId;
  final String? quotationReference;
  final String? salesOrderId;
  final String? salesOrderReference;
  final Map<String, int>? salesOrderQuantities;
  final bool focusMode;
  final VoidCallback? onToggleFocus;
  const CheckoutScreen(
      {super.key,
      required this.repository,
      required this.user,
      required this.auth,
      this.receipts,
      this.camera,
      this.quotationId,
      this.quotationReference,
      this.salesOrderId,
      this.salesOrderReference,
      this.salesOrderQuantities,
      this.focusMode = false,
      this.onToggleFocus});
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
  String? walkInName;
  String? walkInContact;
  ManualDiscount? manualDiscount;
  CheckoutDiscountSource discountSource = CheckoutDiscountSource.none;
  PromotionEvaluationResult? promotionPreview;
  String _promotionFingerprint = '';
  int _promotionGeneration = 0;
  bool _promotionPending = false;
  bool _promotionScheduled = false;
  String get _cartFingerprint => cart.lines.map((line) =>
    '${line.id}:${line.product.id}:${line.product.categoryId}:${line.mode}:${line.quantityMilli}:${line.totalCents}').join('|');

  int get promotionDiscountCents =>
      discountSource == CheckoutDiscountSource.automaticPromotion &&
              !_promotionPending && _promotionFingerprint == _cartFingerprint
          ? promotionPreview?.totalDiscountCents ?? 0
          : 0;
  bool get _promotionReady => !_promotionPending &&
      _promotionFingerprint == _cartFingerprint;

  Future<void> _evaluatePromotions() async {
    if (widget.salesOrderId != null) {
      _promotionFingerprint = _cartFingerprint;
      promotionPreview = null;
      _promotionPending = false;
      return;
    }
    final fingerprint = _cartFingerprint;
    final generation = ++_promotionGeneration;
    _promotionFingerprint = fingerprint;
    if (cart.isEmpty) {
      if (mounted) {
        setState(() {
        promotionPreview = null;
        _promotionPending = false;
        _promotionFingerprint = fingerprint;
        if (discountSource != CheckoutDiscountSource.manual) {
          discountSource = CheckoutDiscountSource.none;
        }
        });
      }
      return;
    }
    if (mounted) {
      setState(() => _promotionPending = true);
    }
    try {
      final preview = await PromotionCheckoutService(
              PromotionRepository(widget.repository.db))
          .evaluate(widget.user, cart, DateTime.now());
      if (!mounted || generation != _promotionGeneration ||
          fingerprint != _cartFingerprint) {
        return;
      }
      setState(() {
        promotionPreview = preview;
        _promotionFingerprint = fingerprint;
        _promotionPending = false;
        if (discountSource != CheckoutDiscountSource.manual) {
          discountSource = preview.totalDiscountCents > 0
              ? CheckoutDiscountSource.automaticPromotion
              : CheckoutDiscountSource.none;
        }
      });
    } catch (error) {
      if (!mounted || generation != _promotionGeneration) {
        return;
      }
      setState(() {
        _promotionPending = false;
        promotionPreview = null;
        _promotionFingerprint = fingerprint;
        if (discountSource != CheckoutDiscountSource.manual) {
          discountSource = CheckoutDiscountSource.none;
        }
        message = safeMessage(error);
      });
    }
  }

  void _schedulePromotionEvaluation() {
    if (completion != null || _promotionScheduled ||
        _promotionFingerprint == _cartFingerprint) {
      return;
    }
    _promotionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _promotionScheduled = false;
      if (mounted) {
        _evaluatePromotions();
      }
    });
  }
  String? heldReference;
  SaleCompletion? completion;
  int redeemPoints = 0;
  int rewardDiscountCents = 0;
  int get manualDiscountCents {
    final discount = manualDiscount;
    if (discount == null) return 0;
    final basis = discount.scope == 'line'
        ? cart.lines
            .where((l) => l.id == discount.lineKey)
            .fold<int>(0, (sum, l) => sum + l.totalCents)
        : cart.totalCents;
    if (basis != discount.approvedBasisCents) return 0;
    try {
      return discount.effectOn(basis);
    } catch (_) {
      return 0;
    }
  }

  int get payableCents =>
      cart.totalCents - manualDiscountCents - promotionDiscountCents - rewardDiscountCents;

  Widget _promotionRow(BuildContext context) {
    final preview = promotionPreview!;
    final names = preview.recommendedApplications
        .map((application) => application.name).join(' + ');
    return Row(children: [
      Expanded(child: TextButton.icon(
        key: const Key('applied-promotion-row'),
        onPressed: _showPromotionDetails,
        icon: const Icon(Icons.local_offer_outlined, size: 18),
        label: Text('Promotion · $names', maxLines: 1,
          overflow: TextOverflow.ellipsis))),
      Text('-${money(promotionDiscountCents)}',
        style: TextStyle(color: Theme.of(context).colorScheme.primary)),
    ]);
  }

  Future<void> _showPromotionDetails() async {
    final preview = promotionPreview;
    if (preview == null) return;
    await showDialog<void>(context: context, builder: (dialog) => AlertDialog(
      title: const Text('Available promotions'),
      content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final application in preview.eligiblePromotions) ...[
            Text(preview.recommendedApplications.any((selected) =>
                selected.promotionId == application.promotionId)
                ? 'APPLIED' : 'OTHER ELIGIBLE',
              style: Theme.of(dialog).textTheme.labelSmall),
            Text(application.name, style: Theme.of(dialog).textTheme.titleMedium),
            Text('${application.type == 'percentage' ? 'Percentage discount' : application.type == 'fixed' ? 'Fixed discount' : 'Minimum spend discount'} · Save ${money(application.discountCents)}'),
            Text('Eligible subtotal: ${money(application.eligibleSubtotalCents)}'),
            Text('Applied to: ${application.affectedLineIds.map((id) => cart.lines.where((line) => line.id == id).firstOrNull?.product.name ?? 'Item').join(', ')}'),
            const SizedBox(height: 12),
          ],
          const Text('The best valid combination is applied automatically.'),
        ],
      ))),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog),
        child: const Text('Close'))],
    ));
  }
  String? message;
  String? cartNotice;
  Timer? _cartNoticeTimer;
  Timer? _lastScanTimer;

  void _dismissLastScanSoon() {
    _lastScanTimer?.cancel();
    _lastScanTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => lastScanned = null);
    });
  }

  void _showCartNotice(String text) {
    _cartNoticeTimer?.cancel();
    setState(() => cartNotice = text);
    _cartNoticeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => cartNotice = null);
    });
  }

  bool busy = false;
  bool scanning = false;
  int quantityEditRevision = 0;
  bool pricingPending = false;
  int pricingRevision = 0;
  String catalogQuery = '';
  String? lastSaleId;
  String? saleReference;
  String? scanError;
  PosProduct? lastScanned;
  String? lastScanStatus;
  String? unknownCode;
  int selectedCartIndex = 0;
  final layoutPreference = PosLayoutPreference.instance;
  final List<String> quotePriceChanges = [];
  String? quotationStockIssue;
  @override
  void initState() {
    super.initState();
    barcodeFocus.onKeyEvent = (node, event) =>
        layoutPreference.layout == PosLayoutType.scanFirst
            ? _scanKey(node, event)
            : KeyEventResult.ignored;
    layoutPreference.addListener(_layoutChanged);
    layoutPreference.load();
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
          db.stockReservations,
        ]))
        .listen((_) => refresh());
    refresh().then((_) async {
      await _loadQuotation();
      await _loadSalesOrder();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) barcodeFocus.requestFocus();
    });
  }

  Future<void> _loadQuotation() async {
    final quoteId = widget.quotationId;
    if (quoteId == null) return;
    try {
      final db = widget.repository.db;
      final rows = await (db.select(db.quotationItems)
            ..where((item) => item.quotationId.equals(quoteId)))
          .get();
      if (!mounted) return;
      for (final row in rows) {
        if (row.productId == null) {
          throw StateError(
              'Resolve ${row.productNameSnapshot} to an Inventory product before checkout.');
        }
        final product =
            products.where((p) => p.id == row.productId).firstOrNull;
        if (product == null || !product.isActive) {
          throw StateError('${row.productNameSnapshot} is no longer sellable.');
        }
        final available = stockMilli[product.id] ??
            await widget.repository.stockMilli(product.id);
        if (!product.business.madeToOrder && available < row.quantityMilli) {
          quotationStockIssue = 'Stock changed for ${row.productNameSnapshot}. '
              'Quoted ${Quantity.format(row.quantityMilli)} ${row.unitSnapshot}; '
              'available ${Quantity.format(available)}. Cancel conversion and revise the offer.';
        }
        if (product.priceCents != row.unitPriceCents) {
          quotePriceChanges.add(
              '${product.name}: quoted ${money(row.unitPriceCents)}, current ${money(product.priceCents)}');
        }
        final quotedProduct = PosProduct(
            product.id,
            row.productNameSnapshot,
            product.barcode,
            row.unitPriceCents,
            product.isActive,
            product.sku,
            product.categoryId,
            product.costCents,
            product.lowStockThreshold,
            product.business,
            product.serialTracking,
            product.pricingPolicy);
        cart
            .addSpecial(quotedProduct, row.quantityMilli,
                mode: row.saleMode, extraCents: row.extraCents)
            .pricedTotalCents = row.lineTotalCents;
      }
      setState(() {});
    } catch (failure) {
      if (mounted) setState(() => message = safeMessage(failure));
    }
  }

  Future<void> _loadSalesOrder() async {
    final orderId = widget.salesOrderId;
    if (orderId == null) return;
    try {
      final db = widget.repository.db;
      final order = await (db.select(db.salesOrders)
        ..where((o) => o.id.equals(orderId))).getSingle();
      if (order.status != 'confirmed') {
        throw StateError('Sales Order is no longer confirmed');
      }
      final lines = await (db.select(db.salesOrderLines)
        ..where((l) => l.salesOrderId.equals(orderId))).get();
      final fulfilled = await SalesOrderRepository(db).fulfilledByLine(orderId);
      if (!mounted) return;
      customerId = order.customerId;
      for (final line in lines) {
        final quantity = widget.salesOrderQuantities?[line.id] ?? 0;
        if (quantity == 0) continue;
        if (line.productId == null || quantity < 0 ||
            quantity > line.quantityMilli - (fulfilled[line.id] ?? 0)) {
          throw StateError('Sales Order quantity changed');
        }
        final product = products.where((p) => p.id == line.productId)
            .firstOrNull;
        if (product == null || !product.isActive) {
          throw StateError('${line.descriptionSnapshot} is unavailable');
        }
        final snapshot = PosProduct(product.id, line.descriptionSnapshot,
            product.barcode, line.unitPriceCents - line.extraCents,
            product.isActive, line.skuSnapshot, product.categoryId,
            product.costCents, product.lowStockThreshold, product.business,
            product.serialTracking, product.pricingPolicy);
        final before = fulfilled[line.id] ?? 0;
        final after = before + quantity;
        final discount = line.discountCents * after ~/ line.quantityMilli -
            line.discountCents * before ~/ line.quantityMilli;
        final cartLine = CartLine(snapshot, quantity, id: line.id,
            mode: line.saleMode, extraCents: line.extraCents);
        cartLine.pricedTotalCents = Quantity.lineCents(
            line.unitPriceCents, quantity) - discount;
        cart.restoreLine(cartLine);
      }
      if (cart.isEmpty) throw StateError('Choose a remaining quantity');
      setState(() {});
    } catch (failure) {
      if (mounted) setState(() => message = safeMessage(failure));
    }
  }

  @override
  void dispose() {
    _cartNoticeTimer?.cancel();
    _lastScanTimer?.cancel();
    layoutPreference.removeListener(_layoutChanged);
    _catalogChanges?.cancel();
    barcodeController.dispose();
    cashController.dispose();
    barcodeFocus.dispose();
    listController.dispose();
    super.dispose();
  }

  void _layoutChanged() {
    if (!mounted) return;
    setState(() => mobileCartOpen = false);
    if (layoutPreference.layout == PosLayoutType.scanFirst) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && layoutPreference.keepReady) barcodeFocus.requestFocus();
      });
    }
  }

  Future<void> refresh() async {
    final revision = ++_catalogRevision;
    try {
      final rows = await widget.repository.products();
      final categoryRows = await widget.repository.categories();
      final levels = await widget.repository.stockLevels();
      final ownClaims = <String, int>{};
      if (widget.salesOrderId != null) {
        final claims = await (widget.repository.db.select(
            widget.repository.db.stockReservations)
          ..where((r) => r.salesOrderId.equals(widget.salesOrderId!))).get();
        for (final claim in claims.where((claim) => claim.status == 'active')) {
          ownClaims.update(claim.productId,
              (quantity) => quantity + claim.quantityMilli,
              ifAbsent: () => claim.quantityMilli);
        }
      }
      final customerRows = await widget.repository.db
          .select(widget.repository.db.customers)
          .get();
      if (mounted && revision == _catalogRevision) {
        setState(() {
          products = rows;
          categories = categoryRows;
          stockMilli = {
            for (final entry in levels.entries)
              entry.key: entry.value.$1 - entry.value.$2 +
                  (ownClaims[entry.key] ?? 0),
          };
          customers = customerRows.where((c) => c.isActive).toList();
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = safeMessage(e));
    }
  }

  Future<void> _refreshLayerPrices() async {
    if (widget.quotationId != null || widget.salesOrderId != null) return;
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
      String? scannedSerialLabel;
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
          scannedSerialLabel = serial.serialNumber;
        }
      }
      product ??= products
          .where((p) => p.sku?.toLowerCase() == value.toLowerCase())
          .firstOrNull;
      if (product == null) {
        setState(() {
          unknownCode = value;
          lastScanStatus = 'not found';
          scanError = 'Barcode or SKU not found';
        });
        return;
      }
      if (!product.business.madeToOrder && (stockMilli[product.id] ?? 0) <= 0) {
        if (layoutPreference.layout == PosLayoutType.scanFirst) {
          setState(() {
            lastScanned = product;
            lastScanStatus = 'blocked';
          });
        }
        throw StateError('Out of stock');
      }
      if (layoutPreference.layout == PosLayoutType.scanFirst &&
          !layoutPreference.incrementRepeated &&
          scannedSerialId == null &&
          cart.lines.any((line) => line.product.id == product!.id)) {
        setState(() {
          lastScanned = product;
          lastScanStatus = 'warning';
          scanError = 'Already in cart. Edit quantity in Current Sale.';
        });
        return;
      }
      final previous = cart.lines
          .where((line) => line.product.id == product!.id)
          .fold<int>(0, (sum, line) => sum + line.quantityMilli);
      await addToCart(product,
          scannedSerialId: scannedSerialId,
          scannedSerialLabel: scannedSerialLabel);
      if (!mounted) return;
      final current = cart.lines
          .where((line) => line.product.id == product!.id)
          .fold<int>(0, (sum, line) => sum + line.quantityMilli);
      if (current == previous) return;
      setState(() {
        barcodeController.clear();
        scanError = null;
        unknownCode = null;
        lastScanned = product;
        final remaining = (stockMilli[product!.id] ?? 0) - current;
        lastScanStatus = remaining <= product.lowStockThreshold * Quantity.scale
            ? 'warning'
            : 'success';
      });
      _dismissLastScanSoon();
      if (layoutPreference.layout != PosLayoutType.scanFirst ||
          layoutPreference.keepReady) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) barcodeFocus.requestFocus();
        });
      }
    } catch (e) {
      if (mounted && (code != null || barcodeController.text.trim() == value)) {
        setState(() {
          scanError = safeMessage(e);
          lastScanStatus = 'blocked';
        });
        if (layoutPreference.layout == PosLayoutType.scanFirst &&
            safeMessage(e) == 'Out of stock' &&
            lastScanned != null) {
          await showDialog<void>(
              context: context,
              builder: (dialog) => AlertDialog(
                    title: const Text('Product unavailable'),
                    content: Text(
                        '${lastScanned!.name}\nNo sellable stock is currently available.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialog),
                          child: const Text('Close'))
                    ],
                  ));
        }
      }
    } finally {
      scanning = false;
      if (layoutPreference.layout == PosLayoutType.scanFirst &&
          layoutPreference.keepReady) {
        _focusScanner();
      }
    }
  }

  Future<void> addToCart(PosProduct product,
      {String? scannedSerialId, String? scannedSerialLabel}) async {
    if (widget.quotationId != null || widget.salesOrderId != null) {
      setState(() => message =
          'This checkout is linked to a saved quotation. Cancel conversion to change the items.');
      return;
    }
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
    if (scannedSerialId != null &&
        product.serialTracking &&
        !config.weight &&
        !config.refill &&
        !config.tank &&
        !config.batch &&
        !config.madeToOrder &&
        config.unit == SaleUnit.piece) {
      if (cart.lines.any((line) => line.serialIds.contains(scannedSerialId))) {
        setState(() => scanError = 'Serial is already in cart');
        return;
      }
      final inCart = cart.lines
          .where((line) => line.product.id == product.id)
          .fold<int>(0, (sum, line) => sum + line.quantityMilli);
      if ((stockMilli[product.id] ?? 0) < inCart + Quantity.scale) {
        setState(() => scanError = 'No sellable stock is currently available');
        return;
      }
      setState(() {
        cart.addSpecial(product, Quantity.scale, serialIds: [scannedSerialId]);
        serialLabels[scannedSerialId] = scannedSerialLabel ?? scannedSerialId;
      });
      await _refreshLayerPrices();
      return;
    }
    final quantity = TextEditingController(text: '1');
    final serialSearch = TextEditingController();
    final serialFocus = FocusNode();
    String? serialWarning;
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
    String batchDescription(ProductLot batch) {
      final expiry = batch.expiryDate;
      final date = expiry == null
          ? ''
          : ' · expires ${expiry.year}-${expiry.month.toString().padLeft(2, '0')}-${expiry.day.toString().padLeft(2, '0')}';
      return '${batch.batchNumber} · ${Quantity.format(batch.quantityMilli)} available$date';
    }

    String? batchId = eligible.isEmpty ? null : eligible.first.id;
    final availableSerials = product.serialTracking
        ? (await widget.repository.availableSerials(product.id))
            .where((serial) =>
                !cart.lines.any((line) => line.serialIds.contains(serial.id)))
            .toList()
        : <SerialUnit>[];
    final selectedSerialIds = <String>{};
    if (scannedSerialId != null) {
      if (cart.lines.any((line) => line.serialIds.contains(scannedSerialId))) {
        quantity.dispose();
        serialSearch.dispose();
        serialFocus.dispose();
        setState(() => scanError = 'Serial is already in cart');
        return;
      }
      selectedSerialIds.add(scannedSerialId);
    }
    for (final serial in availableSerials) {
      serialLabels[serial.id] = serial.serialNumber;
    }
    for (final batch in eligible) {
      batchLabels[batch.id] = batch.batchNumber;
    }
    if (!mounted) {
      quantity.dispose();
      serialSearch.dispose();
      serialFocus.dispose();
      return;
    }
    final selection = await showDialog<(int, String, String?, List<String>)>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: Text(product.name),
                content: SizedBox(
                    width: 470,
                    child: ListView(shrinkWrap: true, children: [
                      Text(
                          '${money(product.priceCents)} per ${config.unit.label}'),
                      TextField(
                          controller: quantity,
                          onChanged: (_) => update(() {}),
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
                      if (config.batch && eligible.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text('No available batch for this product.'),
                        ),
                      if (config.batch && eligible.length == 1)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Batch'),
                          subtitle: Text(batchDescription(eligible.first)),
                        ),
                      if (config.batch && eligible.length > 1)
                        DropdownButtonFormField<String>(
                            initialValue: batchId,
                            isExpanded: true,
                            decoration: const InputDecoration(
                                labelText: 'Batch',
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 16)),
                            items: eligible
                                .map((b) => DropdownMenuItem<String>(
                                      value: b.id,
                                      child: Text(batchDescription(b),
                                          overflow: TextOverflow.ellipsis),
                                    ))
                                .toList(),
                            onChanged: (v) => update(() => batchId = v)),
                      if (product.serialTracking) ...[
                        const SizedBox(height: 12),
                        Text(
                            'Selected serials: ${selectedSerialIds.length} / ${(Quantity.tryParse(quantity.text, fractional: false) ?? 0) ~/ Quantity.scale}'),
                        if (selectedSerialIds.length >
                            ((Quantity.tryParse(quantity.text,
                                        fractional: false) ??
                                    0) ~/
                                Quantity.scale))
                          const Text(
                              'Deselect serials before reducing quantity.'),
                        if (selectedSerialIds.length <
                            ((Quantity.tryParse(quantity.text,
                                        fractional: false) ??
                                    0) ~/
                                Quantity.scale))
                          Text(
                              'Select ${((Quantity.tryParse(quantity.text, fractional: false) ?? 0) ~/ Quantity.scale) - selectedSerialIds.length} more serial(s) to add to cart.'),
                        const SizedBox(height: 8),
                        TextField(
                          key: const Key('serial-search-input'),
                          controller: serialSearch,
                          focusNode: serialFocus,
                          autofocus: true,
                          decoration: const InputDecoration(
                              labelText: 'Search or scan serial',
                              border: OutlineInputBorder()),
                          onChanged: (_) => update(() => serialWarning = null),
                          onSubmitted: (raw) {
                            final serialText = raw.trim();
                            final matches = availableSerials.where((s) =>
                                s.serialNumber.toLowerCase() ==
                                serialText.toLowerCase());
                            final limit = (Quantity.tryParse(quantity.text,
                                        fractional: false) ??
                                    0) ~/
                                Quantity.scale;
                            update(() {
                              if (serialText.isEmpty) return;
                              if (matches.isEmpty) {
                                serialWarning =
                                    'Serial not available for this product.';
                              } else if (selectedSerialIds
                                  .contains(matches.first.id)) {
                                serialWarning = 'Serial already selected.';
                              } else if (selectedSerialIds.length >= limit) {
                                serialWarning = 'Maximum serials selected.';
                              } else {
                                selectedSerialIds.add(matches.first.id);
                                serialSearch.clear();
                                serialWarning = null;
                              }
                            });
                            serialFocus.requestFocus();
                          },
                        ),
                        if (serialWarning != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(serialWarning!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error)),
                          ),
                        const SizedBox(height: 8),
                        for (final serial in availableSerials.where((s) => s
                            .serialNumber
                            .toLowerCase()
                            .contains(serialSearch.text.trim().toLowerCase())))
                          CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(serial.serialNumber),
                              value: selectedSerialIds.contains(serial.id),
                              onChanged: !selectedSerialIds
                                          .contains(serial.id) &&
                                      selectedSerialIds.length >=
                                          ((Quantity.tryParse(quantity.text,
                                                      fractional: false) ??
                                                  0) ~/
                                              Quantity.scale)
                                  ? null
                                  : (value) => update(() {
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
                      onPressed: (Quantity.tryParse(quantity.text,
                                      fractional: config.fractional) ==
                                  null ||
                              (config.batch && batchId == null) ||
                              (product.serialTracking &&
                                  selectedSerialIds.length !=
                                      ((Quantity.tryParse(quantity.text,
                                                  fractional: false) ??
                                              0) ~/
                                          Quantity.scale)))
                          ? null
                          : () {
                              final milli = Quantity.tryParse(quantity.text,
                                  fractional: config.fractional);
                              if (milli == null ||
                                  (config.batch && batchId == null) ||
                                  (product.serialTracking &&
                                      selectedSerialIds.length !=
                                          milli ~/ Quantity.scale)) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            'Enter a valid quantity, batch, and serial selection')));
                                return;
                              }
                              Navigator.pop(context, (
                                milli,
                                mode,
                                batchId,
                                selectedSerialIds.toList()
                              ));
                            },
                      child: const Text('Add to cart')),
                ],
              )),
    );
    await waitForDialogExit();
    quantity.dispose();
    serialSearch.dispose();
    serialFocus.dispose();
    if (selection == null || !mounted) return;
    final alreadyInCart = cart.lines
        .where((line) => line.product.id == product.id)
        .fold<int>(0, (sum, line) => sum + line.quantityMilli);
    final available = stockMilli[product.id];
    if (!config.madeToOrder &&
        available != null &&
        alreadyInCart + selection.$1 > available) {
      setState(() => message =
          'Only ${Quantity.format(available)} ${config.unit.label} available.');
      _focusScanner();
      return;
    }
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
    await _evaluatePromotions();
    if (!mounted || _promotionPending) return;
    final issue = _cartIssue() ?? quotationStockIssue;
    if (issue != null) {
      setState(() => message = issue);
      return;
    }
    final validation = credit
        ? (tryParseMoney(cashController.text) == null ||
                tryParseMoney(cashController.text)! < 0 ||
                tryParseMoney(cashController.text)! >= payableCents
            ? 'Enter cash paid below the sale total'
            : customerId == null
                ? 'Select a customer'
                : null)
        : cashValidationMessage(cashController.text, payableCents);
    if (cart.isEmpty || cart.totalCents <= 0 || validation != null) {
      setState(
          () => message = validation ?? 'Add a product with a positive total');
      return;
    }
    final cashCents = tryParseMoney(cashController.text) ?? 0;
    final wasCredit = credit;
    final selectedCustomerId = customerId;
    final customerLabel = customers
            .where((c) => c.id == selectedCustomerId)
            .firstOrNull
            ?.name ??
        (walkInName?.isNotEmpty == true
            ? '${walkInName!}${walkInContact?.isNotEmpty == true ? '\n$walkInContact' : ''}'
            : walkInContact?.isNotEmpty == true
                ? walkInContact!
                : 'Anonymous walk-in');
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result = credit
          ? await sales.checkoutCredit(cart, customerId!, cashCents,
              manualDiscount: manualDiscount, heldReference: heldReference,
              salesOrderId: widget.salesOrderId)
          : await sales.checkout(cart, cashCents,
              quotationId: widget.quotationId,
              customerId: customerId,
              redeemPoints: redeemPoints,
              rewardDiscountCents: rewardDiscountCents,
              manualDiscount: manualDiscount,
              walkInName: walkInName,
              walkInContact: walkInContact,
              heldReference: heldReference,
              salesOrderId: widget.salesOrderId);
      lastSaleId = result.saleId;
      final completedSale =
          await (widget.repository.db.select(widget.repository.db.sales)
                ..where((row) => row.id.equals(result.saleId)))
              .getSingle();
      final completedPromotions = await (widget.repository.db
              .select(widget.repository.db.salePromotionApplications)
            ..where((row) => row.saleId.equals(result.saleId)))
          .get();
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
        });
      }
      final hardware = await widget.receipts?.afterCommittedCashSale(
          result.saleId,
          openDrawer: !wasCredit || cashCents > 0);
      if (mounted && hardware != null) {
        setState(() => message = '$completionMessage'
            '${hardware.printerAttempted && !hardware.printed ? ' Receipt could not be printed.' : ''}'
            '${hardware.drawerAttempted && !hardware.drawerOpened ? ' Cash drawer could not be opened.' : ''}');
      }
      await refresh();
      if (mounted && widget.quotationId == null) {
        final reward = await widget.repository.db.customSelect(
            'SELECT earned_points FROM sale_loyalty WHERE sale_id=?',
            variables: [Variable.withString(result.saleId)]).getSingleOrNull();
        final balance = selectedCustomerId == null
            ? null
            : await LoyaltyRepository(widget.repository.db)
                .balance(selectedCustomerId);
        if (mounted) {
          setState(() {
            completion = SaleCompletion(
                result.saleId,
                completedSale.receiptNumber ?? 'Legacy sale',
                result.totalCents,
                [
                  ('Cash', cashCents),
                  if (wasCredit) ('Credit', result.totalCents - cashCents)
                ],
                result.changeCents,
                customerLabel,
                reward?.read<int>('earned_points') ?? 0,
                balance,
                hardware != null &&
                        hardware.printerAttempted &&
                        !hardware.printed
                    ? 'Sale completed. Receipt printing failed.'
                    : null,
                [for (final application in completedPromotions)
                  (application.promotionName, application.discountCents)]);
          });
        }
      }
      if (mounted && (widget.quotationId != null ||
          widget.salesOrderId != null)) {
        Navigator.of(context).pop(result.saleId);
      }
    } catch (e) {
      if (mounted) setState(() => message = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _schedulePromotionEvaluation();
    final compact = MediaQuery.sizeOf(context).width < 850;
    final scanFirst = layoutPreference.layout == PosLayoutType.scanFirst;
    return Scaffold(
      bottomNavigationBar: completion == null &&
              layoutPreference.showShortcutBarFor(layoutPreference.layout)
          ? _shortcutBar(context)
          : null,
      appBar: widget.quotationId == null && widget.salesOrderId == null
          ? null
          : AppBar(
              title: Text(widget.salesOrderId == null
                  ? 'Converting quotation ${widget.quotationReference ?? ''}'
                  : 'Fulfilling Sales Order ${widget.salesOrderReference ?? ''}'),
              bottom: widget.salesOrderId != null ||
                      (quotePriceChanges.isEmpty && quotationStockIssue == null)
                  ? null
                  : PreferredSize(
                      preferredSize: const Size.fromHeight(46),
                      child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                              quotationStockIssue ??
                                  'Quoted price retained · ${quotePriceChanges.join('; ')}',
                              style: Theme.of(context).textTheme.bodySmall)))),
      body: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.f6): _HoldIntent(),
          SingleActivator(LogicalKeyboardKey.f7): _HeldSalesIntent(),
          SingleActivator(LogicalKeyboardKey.f4): _LookupIntent(),
          SingleActivator(LogicalKeyboardKey.f11): _FocusIntent(),
          SingleActivator(LogicalKeyboardKey.f2): _CustomerIntent(),
          SingleActivator(LogicalKeyboardKey.f10): _PayIntent(),
          SingleActivator(LogicalKeyboardKey.f1):
              _ScanKeyIntent(LogicalKeyboardKey.f1),
          SingleActivator(LogicalKeyboardKey.f3):
              _ScanKeyIntent(LogicalKeyboardKey.f3),
          SingleActivator(LogicalKeyboardKey.f5):
              _ScanKeyIntent(LogicalKeyboardKey.f5),
          SingleActivator(LogicalKeyboardKey.f8):
              _ScanKeyIntent(LogicalKeyboardKey.f8),
          SingleActivator(LogicalKeyboardKey.escape):
              _ScanKeyIntent(LogicalKeyboardKey.escape),
          SingleActivator(LogicalKeyboardKey.arrowUp):
              _ScanKeyIntent(LogicalKeyboardKey.arrowUp),
          SingleActivator(LogicalKeyboardKey.arrowDown):
              _ScanKeyIntent(LogicalKeyboardKey.arrowDown),
          SingleActivator(LogicalKeyboardKey.delete):
              _ScanKeyIntent(LogicalKeyboardKey.delete),
        },
        child: Actions(
            actions: {
              _HoldIntent: CallbackAction<_HoldIntent>(onInvoke: (_) {
                _holdSale();
                return null;
              }),
              _HeldSalesIntent: CallbackAction<_HeldSalesIntent>(onInvoke: (_) {
                _heldSales();
                return null;
              }),
              _FocusIntent: CallbackAction<_FocusIntent>(onInvoke: (_) {
                widget.onToggleFocus?.call();
                return null;
              }),
              _ScanKeyIntent:
                  CallbackAction<_ScanKeyIntent>(onInvoke: (intent) {
                _handleScanKey(intent.key);
                return null;
              }),
              _LookupIntent: CallbackAction<_LookupIntent>(onInvoke: (_) {
                if (!scanFirst || layoutPreference.allowLookup) {
                  _openProductLookup();
                }
                return null;
              }),
              _CustomerIntent: CallbackAction<_CustomerIntent>(onInvoke: (_) {
                _chooseCustomer();
                return null;
              }),
              _PayIntent: CallbackAction<_PayIntent>(onInvoke: (_) {
                _scanMoreActions();
                return null;
              }),
            },
            child: AbsorbPointer(
                absorbing: busy,
                child: LayoutBuilder(builder: (context, constraints) {
                  if (completion != null) return _completionScreen(context);
                  if (scanFirst) return _scanWorkspace(context);
                  if (constraints.maxWidth < 850) {
                    return mobileCartOpen
                        ? _salePanel(context, constraints.maxHeight)
                        : scanFirst
                            ? _scanWorkspace(context)
                            : _catalogPanel(context, constraints.maxWidth);
                  }
                  return Row(key: const Key('desktop-pos-two-pane'), children: [
                    Expanded(
                        flex: 55,
                        child: scanFirst
                            ? _scanWorkspace(context)
                            : _catalogPanel(
                                context, constraints.maxWidth * .55)),
                    const VerticalDivider(width: 1),
                    Expanded(
                        flex: 45,
                        child: Material(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerLow,
                            child: _salePanel(context, constraints.maxHeight))),
                  ]);
                }))),
      ),
      floatingActionButton: completion == null &&
              compact &&
              !scanFirst &&
              !mobileCartOpen
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

  void _focusScanner() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) barcodeFocus.requestFocus();
    });
  }

  Widget _completionScreen(BuildContext context) {
    final done = completion!;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.check_circle,
                  size: 50, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text('SALE COMPLETE',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 20),
              ListTile(
                  title: const Text('Receipt'), subtitle: Text(done.reference)),
              ListTile(
                  title: const Text('Total'),
                  trailing: Text(money(done.totalCents))),
              for (final promotion in done.promotionDiscounts)
                ListTile(title: Text('Promotion · ${promotion.$1}'),
                    trailing: Text('-${money(promotion.$2)}')),
              for (final payment in done.payments)
                ListTile(
                    title: Text(payment.$1), trailing: Text(money(payment.$2))),
              if (done.changeCents > 0)
                ListTile(
                    title: const Text('Change'),
                    trailing: Text(money(done.changeCents))),
              ListTile(
                  title: const Text('Customer'), subtitle: Text(done.customer)),
              if (done.pointsBalance != null)
                ListTile(
                    title: const Text('Rewards'),
                    subtitle: Text(
                        '+${done.earnedPoints} pts earned · Balance ${done.pointsBalance} pts')),
              if (done.printIssue != null)
                Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(done.printIssue!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 12),
              Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                        onPressed: widget.receipts == null
                            ? null
                            : () async {
                                final ok =
                                    await widget.receipts!.reprint(done.saleId);
                                if (mounted) {
                                  setState(() => completion = done.withPrintIssue(ok
                                      ? null
                                      : 'Sale completed. Receipt printing failed.'));
                                }
                              },
                        icon: const Icon(Icons.print_outlined),
                        label: Text(done.printIssue == null
                            ? 'Reprint'
                            : 'Retry print')),
                    FilledButton(
                        onPressed: _newSale, child: const Text('New sale')),
                  ]),
            ],
          ),
        ),
      ),
    );
  }

  void _newSale() {
    setState(() {
      cart.clear();
      completion = null;
      customerId = null;
      walkInName = null;
      walkInContact = null;
      manualDiscount = null;
      discountSource = CheckoutDiscountSource.none;
      promotionPreview = null;
      _promotionFingerprint = '';
      heldReference = null;
      redeemPoints = 0;
      rewardDiscountCents = 0;
      credit = false;
      cashController.clear();
      barcodeController.clear();
      message = null;
      scanError = null;
      unknownCode = null;
      lastSaleId = null;
      saleReference = null;
      selectedCartIndex = 0;
    });
    _focusScanner();
  }

  Future<void> _holdSale() async {
    if (completion != null || busy) return;
    if (!widget.user.can(PosPermission.holdSale)) return;
    if (cart.isEmpty) {
      setState(() => message = 'Add an item before holding a sale');
      return;
    }
    final issue = _cartIssue();
    if (issue != null) {
      setState(() => message = issue);
      return;
    }
    final labelInput = TextEditingController(
        text: walkInName ??
            customers.where((c) => c.id == customerId).firstOrNull?.name ??
            '');
    try {
      final label = await showDialog<String>(
          context: context,
          builder: (dialog) => AlertDialog(
                title: const Text('Hold sale'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                      'Held sales do not reserve inventory. Stock is checked again when resumed.'),
                  TextField(
                      key: const Key('held-sale-label'),
                      controller: labelInput,
                      decoration:
                          const InputDecoration(labelText: 'Label (optional)')),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialog, labelInput.text),
                      child: const Text('Hold sale')),
                ],
              ));
      if (label == null || !mounted) return;
      final held = await HeldSaleRepository(widget.repository.db).hold(
          widget.user, cart,
          label: label,
          customerId: customerId,
          walkInName: walkInName,
          walkInContact: walkInContact,
          discount: manualDiscount,
          redeemPoints: redeemPoints,
          quotationId: widget.quotationId);
      if (!mounted) return;
      _newSale();
      setState(
          () => message = '${held.reference} held. Stock is not reserved.');
    } catch (error) {
      if (mounted) setState(() => message = safeMessage(error));
    } finally {
      await waitForDialogExit();
      labelInput.dispose();
    }
  }

  Future<void> _heldSales() async {
    if (completion != null || busy) return;
    if (!widget.user.can(PosPermission.resumeSale)) return;
    final repository = HeldSaleRepository(widget.repository.db);
    final held = await repository.all(widget.user);
    final users =
        await widget.repository.db.select(widget.repository.db.users).get();
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Held sales'),
              content: SizedBox(
                  width: 620,
                  height: 420,
                  child: held.isEmpty
                      ? const Center(child: Text('No held sales.'))
                      : ListView(children: [
                          for (final entry in held)
                            Builder(builder: (_) {
                              final draft = HeldSaleSnapshot.fromRow(entry);
                              final customer = customers
                                  .where((c) => c.id == draft.customerId)
                                  .firstOrNull;
                              final holder = users
                                  .where((u) => u.id == entry.heldBy)
                                  .firstOrNull;
                              return ListTile(
                                title: Text(
                                    '${entry.reference} · ${entry.label ?? customer?.name ?? draft.walkInName ?? 'Walk-in'}'),
                                subtitle: Text(
                                    '${entry.heldAt.toLocal()} · ${draft.lines.length} lines · ${money(draft.subtotalCents)} · ${holder?.name ?? 'Historical user'}'),
                                trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextButton(
                                          onPressed: () async {
                                            Navigator.pop(dialog);
                                            await _resumeHeld(entry, draft);
                                          },
                                          child: const Text('Resume')),
                                      IconButton(
                                          tooltip: 'Discard ${entry.reference}',
                                          onPressed: () async {
                                            Navigator.pop(dialog);
                                            final confirmed =
                                                await showDialog<bool>(
                                                    context: context,
                                                    builder: (confirm) =>
                                                        AlertDialog(
                                                          title: Text(
                                                              'Discard ${entry.reference}?'),
                                                          content: const Text(
                                                              'This removes the held draft. Inventory is unchanged.'),
                                                          actions: [
                                                            TextButton(
                                                                onPressed: () =>
                                                                    Navigator.pop(
                                                                        confirm,
                                                                        false),
                                                                child: const Text(
                                                                    'Cancel')),
                                                            FilledButton(
                                                                onPressed: () =>
                                                                    Navigator.pop(
                                                                        confirm,
                                                                        true),
                                                                child: const Text(
                                                                    'Discard')),
                                                          ],
                                                        ));
                                            if (confirmed == true) {
                                              await repository.remove(
                                                  widget.user, entry.id,
                                                  discard: true);
                                              if (mounted) {
                                                setState(() => message =
                                                    '${entry.reference} discarded.');
                                              }
                                            }
                                          },
                                          icon:
                                              const Icon(Icons.delete_outline)),
                                    ]),
                              );
                            }),
                        ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('Close'))
              ],
            ));
    _focusScanner();
  }

  Future<void> _resumeHeld(HeldSale held, HeldSaleSnapshot draft) async {
    if (!cart.isEmpty) {
      setState(() =>
          message = 'Hold or clear the current sale before resuming another.');
      return;
    }
    if (draft.quotationId != widget.quotationId) {
      setState(() => message =
          'Open the matching quotation checkout to resume this held sale.');
      return;
    }
    await refresh();
    final problems = <String>[];
    final restored = <CartLine>[];
    final byProduct = <String, int>{};
    var priceChanged = false;
    for (final data in draft.lines) {
      final id = data['productId'] as String;
      final product =
          products.where((p) => p.id == id && p.isActive).firstOrNull;
      if (product == null) {
        problems.add('Product ${data['productId']} is no longer active.');
        continue;
      }
      final milli = data['quantityMilli'] as int;
      byProduct.update(id, (old) => old + milli, ifAbsent: () => milli);
      if (product.priceCents != data['unitPriceCents']) priceChanged = true;
      final serials = (data['serialIds'] as List).cast<String>();
      if (serials.isNotEmpty) {
        final available = await widget.repository.availableSerials(id);
        if (serials.any((s) => !available.any((a) => a.id == s))) {
          problems.add('${product.name}: selected serial is unavailable.');
        }
      }
      final batchId = data['batchId'] as String?;
      if (batchId != null) {
        final batches = await widget.repository.batches(id);
        final today = DateTime.now();
        final startOfDay = DateTime(today.year, today.month, today.day);
        if (!batches.any((b) =>
            b.id == batchId &&
            b.quantityMilli >= milli &&
            (b.expiryDate == null || !b.expiryDate!.isBefore(startOfDay)))) {
          problems.add('${product.name}: batch is unavailable.');
        }
      }
      restored.add(CartLine(product, milli,
          id: data['id'] as String,
          mode: data['mode'] as String,
          batchId: batchId,
          serialIds: serials,
          extraCents: data['extraCents'] as int));
    }
    for (final entry in byProduct.entries) {
      final product = products.where((p) => p.id == entry.key).firstOrNull;
      if (product != null &&
          !product.business.madeToOrder &&
          (stockMilli[entry.key] ?? 0) < entry.value) {
        problems.add('${product.name}: some items are no longer available.');
      }
    }
    if (draft.customerId != null &&
        !customers.any((c) => c.id == draft.customerId)) {
      problems.add('Registered customer is no longer active.');
    }
    if (draft.discount != null) {
      final approver =
          await widget.auth.repository.user(draft.discount!.authorizedBy);
      if (approver == null ||
          !approver.isActive ||
          !(await widget.auth.repository.requireActive(approver.id))
              .can(PosPermission.approveDiscount)) {
        problems.add('Discount manager is no longer active.');
      }
    }
    var resumedRewardDiscount = 0;
    if (draft.redeemPoints > 0 && draft.customerId != null) {
      final loyalty = LoyaltyRepository(widget.repository.db);
      final rule = await loyalty.settings();
      if (!rule.enabled ||
          draft.redeemPoints % rule.redeemPoints != 0 ||
          await loyalty.balance(draft.customerId!) < draft.redeemPoints) {
        problems.add('Rewards balance changed; choose redemption again.');
      } else {
        resumedRewardDiscount =
            draft.redeemPoints ~/ rule.redeemPoints * rule.redeemValueCents;
      }
    }
    if (problems.isNotEmpty) {
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (dialog) => AlertDialog(
                title: const Text('Some items are no longer available'),
                content: Text(problems.join('\n')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: const Text('Close'))
                ],
              ));
      return;
    }
    await HeldSaleRepository(widget.repository.db).remove(widget.user, held.id);
    if (!mounted) return;
    setState(() {
      for (final line in restored) {
        cart.restoreLine(line);
      }
      customerId = draft.customerId;
      walkInName = draft.walkInName;
      walkInContact = draft.walkInContact;
      manualDiscount = priceChanged ? null : draft.discount;
      discountSource = manualDiscount == null
          ? CheckoutDiscountSource.none
          : CheckoutDiscountSource.manual;
      redeemPoints = draft.redeemPoints;
      rewardDiscountCents = resumedRewardDiscount;
      heldReference = held.reference;
      message = priceChanged
          ? 'Prices changed while held. Current prices apply; reauthorize any discount.'
          : '${held.reference} resumed. Stock was rechecked.';
    });
    await _refreshLayerPrices();
    if (mounted && cart.totalCents != draft.subtotalCents) {
      setState(() {
        manualDiscount = null;
        message =
            'Prices changed while held. Current prices apply; reauthorize any discount.';
      });
    }
  }

  CartLine? get _selectedLine => cart.lines.isEmpty
      ? null
      : cart.lines[selectedCartIndex.clamp(0, cart.lines.length - 1)];

  Future<void> _editSelectedQuantity() async {
    final line = _selectedLine;
    if (line == null ||
        line.mode != 'ordinary' ||
        line.product.serialTracking ||
        widget.quotationId != null) {
      return;
    }
    final controller =
        TextEditingController(text: Quantity.format(line.quantityMilli));
    final value = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: Text('Quantity: ${line.product.name}'),
              content: TextField(
                controller: controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onSubmitted: (value) => Navigator.pop(dialog, value),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialog, controller.text),
                    child: const Text('Apply')),
              ],
            ));
    if (value != null && mounted) {
      final milli = Quantity.tryParse(value,
          fractional: line.product.business.fractional);
      if (milli == null) {
        _showCartNotice('Enter a valid quantity.');
      } else {
        _changeQuantity(line, milli);
      }
    }
    await waitForDialogExit();
    controller.dispose();
    _focusScanner();
  }

  Future<void> _scanPayment() async {
    if (cart.isEmpty || pricingPending || !_promotionReady ||
        _cartIssue() != null) {
      return;
    }
    await showDialog<void>(
        context: context,
        builder: (dialog) => StatefulBuilder(builder: (context, update) {
              final cash = tryParseMoney(cashController.text);
              final issue = credit
                  ? cash == null || cash < 0 || cash >= payableCents
                      ? 'Enter cash paid below the sale total'
                      : customerId == null
                          ? 'Select a customer for credit'
                          : null
                  : cashValidationMessage(cashController.text, payableCents);
              return AlertDialog(
                title: Text('Payment: ${money(payableCents)}'),
                content: SizedBox(
                  width: 400,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (widget.user.can(PosPermission.customerCredit) &&
                        customerId != null)
                      SwitchListTile(
                          title: const Text('Credit / Utang'),
                          value: credit,
                          onChanged: (value) => update(() {
                                credit = value;
                                if (value) {
                                  redeemPoints = 0;
                                  rewardDiscountCents = 0;
                                }
                                cashController.text = value ? '0' : '';
                              })),
                    if (customerId != null && !credit)
                      TextButton.icon(
                        onPressed: () async {
                          await _redeemRewards();
                          if (dialog.mounted) update(() {});
                        },
                        icon: const Icon(Icons.stars_outlined),
                        label: Text(redeemPoints == 0
                            ? 'Redeem rewards'
                            : '$redeemPoints pts · -${money(rewardDiscountCents)}'),
                      ),
                    TextField(
                      key: const Key('scan-payment-cash'),
                      controller: cashController,
                      autofocus: true,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                          labelText: credit ? 'Cash paid now' : 'Cash tendered',
                          errorText:
                              cashController.text.isEmpty ? null : issue),
                      onChanged: (_) => update(() {}),
                      onSubmitted: (_) async {
                        if (issue == null) {
                          Navigator.pop(dialog);
                          await checkout();
                        }
                      },
                    ),
                    if (cash != null && issue == null && !credit)
                      Text('Change ${money(cash - payableCents)}'),
                  ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: issue == null
                          ? () async {
                              Navigator.pop(dialog);
                              await checkout();
                            }
                          : null,
                      child: const Text('Complete payment')),
                ],
              );
            }));
    _focusScanner();
  }

  Future<void> _scanHelp() async {
    final profile = PosShortcutProfile.forLayout(layoutPreference.layout);
    await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Keyboard shortcuts'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _helpSection('Sale', [
                        const ('F2', 'Customer'),
                        ('F3', profile.scannerLabel),
                        if (profile.hasLookup && layoutPreference.allowLookup)
                          const ('F4', 'Product lookup'),
                        const ('F6', 'Hold sale'),
                        const ('F7', 'Held sales'),
                        const ('F8', 'Pay'),
                      ]),
                      if (profile.hasCartNavigation)
                        _helpSection('Cart', const [
                          ('\u2191 \u2193', 'Select item'),
                          ('F5', 'Edit quantity'),
                          ('+ -', 'Change ordinary quantity'),
                          ('Delete', 'Remove item')
                        ]),
                      _helpSection('Workspace', [
                        if (profile.hasMore) const ('F10', 'More actions'),
                        const ('F11', 'Focus mode'),
                      ]),
                      _helpSection(
                          'General', const [('Esc', 'Close / cancel')]),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('Close'))
              ],
            ));
    _focusScanner();
  }

  Widget _helpSection(String title, List<(String, String)> commands) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title.toUpperCase(),
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          for (final command in commands)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(
                    width: 86,
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: _keycap(command.$1))),
                Expanded(child: Text(command.$2)),
              ]),
            ),
        ]),
      );

  Widget _keycap(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, style: Theme.of(context).textTheme.labelMedium),
      );

  Widget _shortcutBar(BuildContext context) {
    final profile = PosShortcutProfile.forLayout(layoutPreference.layout);
    final selected = profile.hasCartNavigation && _selectedLine != null;
    final canPay = !cart.isEmpty && !pricingPending &&
        _promotionReady && _cartIssue() == null;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SafeArea(
          top: false,
          child: LayoutBuilder(builder: (context, box) {
            final narrow = box.maxWidth < 960;
            Widget item(String key, String label, VoidCallback? action,
                    {bool pay = false}) =>
                TextButton(
                  onPressed: action,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 40),
                    foregroundColor: pay && action != null
                        ? Theme.of(context).colorScheme.primary
                        : null,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    _keycap(key),
                    const SizedBox(width: 4),
                    Text(label),
                  ]),
                );
            return Wrap(
              key: const Key('pos-shortcut-bar'),
              alignment: WrapAlignment.center,
              spacing: 2,
              children: [
                item('F2', 'Customer', _chooseCustomer),
                item('F3', profile.scannerLabel, _focusScanner),
                if (profile.hasLookup)
                  item('F4', 'Lookup',
                      layoutPreference.allowLookup ? _openProductLookup : null),
                item(
                    'F6',
                    'Hold',
                    cart.isEmpty || !widget.user.can(PosPermission.holdSale)
                        ? null
                        : _holdSale),
                item(
                    'F7',
                    'Held',
                    widget.user.can(PosPermission.resumeSale)
                        ? _heldSales
                        : null),
                item('F8', 'Pay', canPay ? _scanPayment : null, pay: true),
                item('F1', 'Help', _scanHelp),
                item('F11', widget.focusMode ? 'Exit focus' : 'Focus',
                    widget.onToggleFocus),
                if (profile.hasMore && !narrow)
                  item('F10', 'More', _scanMoreActions),
                if (profile.hasCartNavigation && !narrow) ...[
                  item('F5', 'Qty', selected ? _editSelectedQuantity : null),
                  if (selected) ...[
                    item(
                        'Del',
                        'Remove',
                        selected && widget.quotationId == null
                            ? () => _handleScanKey(LogicalKeyboardKey.delete)
                            : null),
                    item(
                        '+/-',
                        'Qty',
                        selected &&
                                _selectedLine!.mode == 'ordinary' &&
                                !_selectedLine!.product.serialTracking &&
                                !_selectedLine!.product.business.weight &&
                                widget.quotationId == null
                            ? _editSelectedQuantity
                            : null),
                    item(
                        '\u2191\u2193',
                        'Select',
                        cart.isEmpty
                            ? null
                            : () =>
                                _handleScanKey(LogicalKeyboardKey.arrowDown)),
                  ],
                ],
              ],
            );
          })),
    );
  }

  Future<void> _scanMoreActions() async {
    await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('More actions'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                    title: const Text('Manual discount'),
                    enabled: !cart.isEmpty,
                    onTap: () {
                      Navigator.pop(dialog);
                      _requestManualDiscount();
                    }),
                ListTile(
                    title: const Text('Clear cart'),
                    enabled:
                        cart.lines.isNotEmpty && widget.quotationId == null,
                    onTap: () async {
                      Navigator.pop(dialog);
                      final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (confirm) => AlertDialog(
                                title: const Text('Clear cart?'),
                                content: const Text(
                                    'Remove every item from this sale?'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(confirm, false),
                                      child: const Text('Cancel')),
                                  FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(confirm, true),
                                      child: const Text('Clear cart')),
                                ],
                              ));
                      if (confirmed == true && mounted) {
                        setState(() {
                          cart.clear();
                          selectedCartIndex = 0;
                        });
                      }
                    }),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('Close'))
              ],
            ));
    _focusScanner();
  }

  KeyEventResult _scanKey(FocusNode node, KeyEvent event) =>
      event is KeyDownEvent
          ? _handleScanKey(event.logicalKey)
          : KeyEventResult.ignored;

  KeyEventResult _handleScanKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.f6) {
      _holdSale();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f7) {
      _heldSales();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f1) {
      _scanHelp();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f3) {
      _focusScanner();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f5) {
      _editSelectedQuantity();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f8) {
      _scanPayment();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f10) {
      _scanMoreActions();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && unknownCode != null) {
      setState(() {
        unknownCode = null;
        scanError = null;
      });
      return KeyEventResult.handled;
    }
    if (barcodeFocus.hasFocus && barcodeController.text.isNotEmpty) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      if (cart.isEmpty) return KeyEventResult.ignored;
      setState(() => selectedCartIndex =
          (selectedCartIndex + (key == LogicalKeyboardKey.arrowDown ? 1 : -1))
              .clamp(0, cart.lines.length - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete &&
        _selectedLine != null &&
        widget.quotationId == null) {
      setState(() => cart.remove(_selectedLine!.id));
      _refreshLayerPrices();
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.add ||
            key == LogicalKeyboardKey.numpadAdd ||
            key == LogicalKeyboardKey.minus ||
            key == LogicalKeyboardKey.numpadSubtract) &&
        _selectedLine != null &&
        _selectedLine!.mode == 'ordinary' &&
        !_selectedLine!.product.serialTracking &&
        !_selectedLine!.product.business.weight &&
        widget.quotationId == null) {
      final delta =
          key == LogicalKeyboardKey.add || key == LogicalKeyboardKey.numpadAdd
              ? Quantity.scale
              : -Quantity.scale;
      if (_selectedLine!.quantityMilli + delta > 0) {
        _changeQuantity(_selectedLine!, _selectedLine!.quantityMilli + delta);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _scanWorkspace(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final customer = customers.where((c) => c.id == customerId).firstOrNull;
    final lines = cart.lines;
    final currentQuantity = lastScanned == null
        ? 0
        : lines
            .where((l) => l.product.id == lastScanned!.id)
            .fold<int>(0, (sum, line) => sum + line.quantityMilli);
    final remaining = lastScanned == null
        ? 0
        : ((stockMilli[lastScanned!.id] ?? 0) - currentQuantity)
            .clamp(0, 999999999);
    return Focus(
      onKeyEvent: _scanKey,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            OutlinedButton.icon(
              key: const Key('customer-selector'),
              onPressed: _chooseCustomer,
              icon: const Icon(Icons.person_outline),
              label: Text(
                  'Customer · ${customer?.name ?? walkInName ?? 'Walk-in customer'}  F2',
                  overflow: TextOverflow.ellipsis),
            ),
            const Spacer(),
            IconButton(
                tooltip: 'More actions F10',
                onPressed: _scanMoreActions,
                icon: const Icon(Icons.more_horiz)),
            IconButton(
                tooltip: 'Shortcuts F1',
                onPressed: _scanHelp,
                icon: const Icon(Icons.keyboard_outlined)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: TextField(
              key: const Key('scan-first-input'),
              controller: barcodeController,
              focusNode: barcodeFocus,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Scan barcode / SKU / serial',
                helperText: 'Ready for scanning · F3 focuses scanner',
                prefixIcon: const Icon(Icons.qr_code_scanner),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                    tooltip: 'Add scanned item',
                    onPressed: lookup,
                    icon: const Icon(Icons.keyboard_return)),
              ),
              onSubmitted: (_) => lookup(),
            )),
            if (layoutPreference.allowLookup) ...[
              const SizedBox(width: 8),
              OutlinedButton(
                key: const Key('scan-product-lookup'),
                onPressed: _openProductLookup,
                child: const Text('Lookup  F4'),
              ),
            ]
          ]),
          if (unknownCode != null)
            _unknownBarcodePanel(context)
          else if (scanError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(scanError!, style: TextStyle(color: scheme.error)),
            ),
          if (lastScanned != null && layoutPreference.showLastScanned)
            Container(
              key: const Key('last-scanned-card'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              color: lastScanStatus == 'blocked'
                  ? scheme.errorContainer
                  : scheme.primaryContainer,
              child: Text(lastScanStatus == 'blocked'
                  ? 'Product unavailable · ${lastScanned!.name} · No sellable stock is currently available.'
                  : '${lastScanned!.name} added · Qty in cart: ${Quantity.format(currentQuantity)} · ${money(lastScanned!.priceCents)} each${lastScanStatus == 'warning' ? ' · Low stock: ${Quantity.format(remaining)} remaining' : ''}'),
            ),
          if (cartNotice != null)
            Container(
              key: const Key('current-sale-notice'),
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: scheme.tertiaryContainer,
              child: Text(cartNotice!,
                  style: TextStyle(color: scheme.onTertiaryContainer)),
            ),
          if (message != null) _messageBanner(context),
          const SizedBox(height: 8),
          Expanded(
              child: Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              Container(
                color: scheme.surfaceContainerHigh,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  const SizedBox(width: 28, child: Text('#')),
                  const Expanded(flex: 5, child: Text('ITEM')),
                  const SizedBox(width: 132, child: Text('QTY')),
                  const SizedBox(
                      width: 90,
                      child: Text('UNIT PRICE', textAlign: TextAlign.end)),
                  const SizedBox(
                      width: 110,
                      child: Text('TOTAL', textAlign: TextAlign.end)),
                  const SizedBox(width: 42),
                ]),
              ),
              Expanded(
                  child: lines.isEmpty
                      ? Center(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.qr_code_scanner,
                              size: 42, color: scheme.onSurfaceVariant),
                          const SizedBox(height: 12),
                          Text('Ready to scan',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 4),
                          const Text(
                              'Scan a barcode or press F4 to search products.'),
                          const SizedBox(height: 12),
                          Text(
                              'F3 Scan   ·   F4 Lookup   ·   F2 Customer   ·   F8 Pay',
                              style: Theme.of(context).textTheme.bodySmall),
                        ]))
                      : ListView.builder(
                          key: const Key('scan-cart-items'),
                          itemCount: lines.length,
                          itemBuilder: (context, index) {
                            final line = lines[index];
                            final detail = [
                              saleModeLabel(line.mode),
                              if (line.batchId != null)
                                'Batch ${batchLabels[line.batchId] ?? line.batchId}',
                              for (final id in line.serialIds)
                                'Serial ${serialLabels[id] ?? id}'
                            ].where((s) => s.isNotEmpty).join(' · ');
                            final canStep = line.mode == 'ordinary' &&
                                !line.product.serialTracking &&
                                !line.product.business.weight &&
                                widget.quotationId == null;
                            return InkWell(
                              onTap: () =>
                                  setState(() => selectedCartIndex = index),
                              child: Container(
                                key: ValueKey('scan-line-${line.id}'),
                                color: index == selectedCartIndex
                                    ? scheme.primaryContainer
                                        .withValues(alpha: .35)
                                    : null,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                constraints:
                                    const BoxConstraints(minHeight: 60),
                                child: Row(children: [
                                  SizedBox(
                                      width: 28,
                                      child: Text(index == selectedCartIndex
                                          ? '›'
                                          : '${index + 1}')),
                                  Expanded(
                                      flex: 5,
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(line.product.name,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis),
                                            Text(
                                                detail.isEmpty
                                                    ? (line.product.sku ??
                                                        line.product.barcode ??
                                                        '')
                                                    : detail,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall),
                                          ])),
                                  SizedBox(
                                      width: 132,
                                      child: Row(children: [
                                        if (canStep)
                                          IconButton(
                                              tooltip: 'Decrease quantity',
                                              visualDensity:
                                                  VisualDensity.compact,
                                              onPressed: line.quantityMilli >
                                                      Quantity.scale
                                                  ? () => _changeQuantity(
                                                      line,
                                                      line.quantityMilli -
                                                          Quantity.scale)
                                                  : null,
                                              icon: const Icon(Icons.remove,
                                                  size: 18)),
                                        Expanded(
                                            child: TextButton(
                                          style: TextButton.styleFrom(
                                              minimumSize: const Size(32, 40),
                                              padding: EdgeInsets.zero),
                                          onPressed: () {
                                            setState(() =>
                                                selectedCartIndex = index);
                                            _editSelectedQuantity();
                                          },
                                          child: Text(
                                              '${Quantity.format(line.quantityMilli)}${line.product.business.weight || line.product.serialTracking ? ' ${line.product.business.unit.label}' : ''}',
                                              maxLines: 1),
                                        )),
                                        if (canStep)
                                          IconButton(
                                              tooltip: 'Increase quantity',
                                              visualDensity:
                                                  VisualDensity.compact,
                                              onPressed: () => _changeQuantity(
                                                  line,
                                                  line.quantityMilli +
                                                      Quantity.scale),
                                              icon: const Icon(Icons.add,
                                                  size: 18)),
                                      ])),
                                  SizedBox(
                                      width: 90,
                                      child: Text(
                                          money(line.product.priceCents),
                                          textAlign: TextAlign.end,
                                          style: const TextStyle(fontFeatures: [
                                            FontFeature.tabularFigures()
                                          ]))),
                                  SizedBox(
                                      width: 110,
                                      child: Text(money(line.totalCents),
                                          textAlign: TextAlign.end,
                                          style: const TextStyle(fontFeatures: [
                                            FontFeature.tabularFigures()
                                          ]))),
                                  SizedBox(
                                      width: 42,
                                      child: IconButton(
                                        tooltip: 'Remove item',
                                        icon: const Icon(Icons.close, size: 18),
                                        onPressed: widget.quotationId == null
                                            ? () {
                                                setState(
                                                    () => cart.remove(line.id));
                                                _refreshLayerPrices();
                                              }
                                            : null,
                                      )),
                                ]),
                              ),
                            );
                          },
                        )),
            ]),
          )),
          if (promotionDiscountCents > 0) ...[
            _promotionRow(context),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          Container(
              key: const Key('scan-checkout-footer'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Text(
                    '${lines.length} lines · ${lines.fold<int>(0, (sum, line) => sum + line.quantity)} items'),
                const Spacer(),
                OutlinedButton(
                  onPressed:
                      lines.isEmpty || !widget.user.can(PosPermission.holdSale)
                          ? null
                          : _holdSale,
                  child: const Text('Hold  F6'),
                ),
                const SizedBox(width: 16),
                if (manualDiscount != null)
                  Text('Discount -${money(manualDiscountCents)}  '),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('TOTAL', style: Theme.of(context).textTheme.labelMedium),
                  Text(money(payableCents),
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontFeatures: const [
                        FontFeature.tabularFigures()
                      ])),
                ]),
                const SizedBox(width: 16),
                FilledButton(
                  key: const Key('pay-button'),
                  onPressed:
                      lines.isEmpty || pricingPending || !_promotionReady ||
                              _cartIssue() != null
                          ? null
                          : _scanPayment,
                  child: Text('Pay ${money(payableCents)}  F8'),
                ),
              ])),
        ]),
      ),
    );
  }

  Future<void> openProductLookup(String query) =>
      _openProductLookup(initialQuery: query);

  Future<void> _openProductLookup({String initialQuery = ''}) async {
    final search = TextEditingController(text: initialQuery);
    try {
      await showDialog<void>(
          context: context,
          builder: (dialogContext) =>
              StatefulBuilder(builder: (context, update) {
                final query = search.text.toLowerCase().trim();
                final matches = products
                    .where((p) =>
                        p.isActive &&
                        (p.name.toLowerCase().contains(query) ||
                            (p.sku?.toLowerCase().contains(query) ?? false) ||
                            (p.barcode?.toLowerCase().contains(query) ??
                                false)))
                    .take(50)
                    .toList();
                return AlertDialog(
                    title: const Text('Product lookup'),
                    content: SizedBox(
                        width: 440,
                        height: 420,
                        child: Column(children: [
                          TextField(
                              key: const Key('scan-product-search'),
                              controller: search,
                              autofocus: true,
                              decoration: const InputDecoration(
                                  labelText: 'Name, SKU, or barcode',
                                  prefixIcon: Icon(Icons.search)),
                              onChanged: (_) => update(() {})),
                          Expanded(
                              child: ListView.builder(
                                  itemCount: matches.length,
                                  itemBuilder: (_, index) {
                                    final item = matches[index];
                                    return ListTile(
                                        title: Text(item.name),
                                        subtitle: Text(
                                            '${item.sku ?? ''}  ${item.barcode ?? ''}'),
                                        trailing: Text(money(item.priceCents)),
                                        onTap: () async {
                                          Navigator.of(dialogContext).pop();
                                          if (!item.business.madeToOrder &&
                                              (stockMilli[item.id] ?? 0) <= 0) {
                                            setState(() {
                                              lastScanned = item;
                                              lastScanStatus = 'blocked';
                                              scanError =
                                                  'No sellable stock available';
                                            });
                                          } else {
                                            await addToCart(item);
                                            if (mounted) {
                                              setState(() {
                                                unknownCode = null;
                                                scanError = null;
                                                lastScanned = item;
                                                lastScanStatus = 'success';
                                              });
                                            }
                                          }
                                          if (mounted &&
                                              layoutPreference.keepReady) {
                                            barcodeFocus.requestFocus();
                                          }
                                        });
                                  })),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('Close'))
                    ]);
              }));
    } finally {
      await waitForDialogExit();
      search.dispose();
      if (mounted && layoutPreference.keepReady) barcodeFocus.requestFocus();
    }
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
        if (unknownCode != null) _unknownBarcodePanel(context),
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

  Widget _unknownBarcodePanel(BuildContext context) => Card(
        key: const Key('unknown-barcode-panel'),
        color: Theme.of(context).colorScheme.errorContainer,
        child: ListTile(
          dense: true,
          title: Text('Barcode not found: $unknownCode'),
          subtitle: const Text('Search products or check the scanned code.'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            TextButton(
                onPressed: _openProductLookup,
                child: const Text('Search products')),
            if (widget.user.can(PosPermission.manageCatalog))
              TextButton(
                  onPressed: () async {
                    final scanned = unknownCode;
                    setState(() => unknownCode = null);
                    await Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => ProductScreen(
                            repository: widget.repository,
                            auth: widget.auth,
                            createOnOpen: true,
                            initialBarcode: scanned)));
                    await refresh();
                    _focusScanner();
                  },
                  child: const Text('Create product')),
            TextButton(
                onPressed: () => setState(() {
                      unknownCode = null;
                      scanError = null;
                    }),
                child: const Text('Dismiss')),
          ]),
        ),
      );

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
    if (widget.salesOrderId != null) {
      setState(() => message = 'Sales Order customer is fixed.');
      return;
    }
    String query = '';
    final summaries =
        await DirectoryRepository(widget.repository.db).customerSummaries();
    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
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
                                        labelText:
                                            'Search name or contact number',
                                        prefixIcon: Icon(Icons.search)),
                                    onChanged: (value) => update(() =>
                                        query = value.toLowerCase().trim())),
                                Expanded(
                                    child: ListView(children: [
                                  ListTile(
                                      title: const Text('Walk-in details'),
                                      subtitle: const Text(
                                          'Optional name and contact; no customer account'),
                                      onTap: () =>
                                          Navigator.pop(context, '__walkin__')),
                                  ListTile(
                                      title: const Text('Anonymous walk-in'),
                                      onTap: () => Navigator.pop(
                                          context, '__anonymous__')),
                                  ListTile(
                                      title: const Text('+ New Customer'),
                                      subtitle: const Text(
                                          'Create a registered customer'),
                                      onTap: () =>
                                          Navigator.pop(context, '__create__')),
                                  for (final customer in customers.where((c) =>
                                      c.name.toLowerCase().contains(query) ||
                                      (c.phone?.toLowerCase().contains(query) ??
                                          false)))
                                    ListTile(
                                        title: Text(customer.name),
                                        subtitle: Text(
                                            '${customer.phone ?? 'No contact'} · ${summaries[customer.id]?.group ?? 'Retail'} · ${summaries[customer.id]?.points ?? 0} pts'),
                                        onTap: () => Navigator.pop(
                                            context, customer.id)),
                                ])),
                              ]))),
                )));
    if (choice == '__walkin__' || choice == '__create__') {
      await _customerIdentityDialog(create: choice == '__create__');
    } else if (choice != null) {
      setState(() {
        customerId = choice == '__anonymous__' ? null : choice;
        walkInName = null;
        walkInContact = null;
        redeemPoints = 0;
        rewardDiscountCents = 0;
        credit = false;
        cashController.clear();
      });
    }
    if (mounted) barcodeFocus.requestFocus();
  }

  Future<void> _customerIdentityDialog({required bool create}) async {
    final name = TextEditingController(text: create ? '' : walkInName ?? '');
    final phone =
        TextEditingController(text: create ? '' : walkInContact ?? '');
    try {
      final accepted = await showDialog<bool>(
          context: context,
          builder: (dialog) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: Text(create ? 'New Customer' : 'Walk-in details'),
                    content: SizedBox(
                        width: 390,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          TextField(
                              key: const Key('quick-customer-name'),
                              controller: name,
                              decoration: InputDecoration(
                                  labelText: create
                                      ? 'Name *'
                                      : 'Customer name (optional)'),
                              onChanged: (_) => update(() {})),
                          TextField(
                              key: const Key('quick-customer-contact'),
                              controller: phone,
                              decoration: const InputDecoration(
                                  labelText: 'Contact number (optional)')),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialog, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: create && name.text.trim().isEmpty
                              ? null
                              : () => Navigator.pop(dialog, true),
                          child:
                              Text(create ? 'Create customer' : 'Use walk-in')),
                    ],
                  )));
      if (accepted != true || !mounted) return;
      if (create) {
        final customer = await DirectoryRepository(widget.repository.db)
            .quickCreateCustomer(widget.user,
                name: name.text, phone: phone.text);
        await refresh();
        if (!mounted) return;
        setState(() {
          customerId = customer.id;
          walkInName = null;
          walkInContact = null;
          redeemPoints = 0;
          rewardDiscountCents = 0;
        });
      } else {
        setState(() {
          customerId = null;
          walkInName = name.text.trim().isEmpty ? null : name.text.trim();
          walkInContact = phone.text.trim().isEmpty ? null : phone.text.trim();
          redeemPoints = 0;
          rewardDiscountCents = 0;
          credit = false;
          cashController.clear();
        });
      }
    } catch (error) {
      if (mounted) setState(() => message = safeMessage(error));
    } finally {
      await waitForDialogExit();
      name.dispose();
      phone.dispose();
    }
  }

  Future<void> _requestManualDiscount() async {
    if (cart.isEmpty || completion != null) return;
    final managers = <User>[];
    for (final row in await widget.repository.db
        .select(widget.repository.db.users)
        .get()) {
      if (row.isActive &&
          (await widget.auth.repository.requireActive(row.id))
              .can(PosPermission.approveDiscount)) {
        managers.add(row);
      }
    }
    if (!mounted || managers.isEmpty) return;
    String scope = 'order';
    String kind = 'fixed';
    String? lineKey = cart.lines.first.id;
    String reason = 'Price match';
    String managerId = managers.first.id;
    String? error;
    String? valueError;
    String? notesError;
    var authorizing = false;
    final value = TextEditingController();
    final notes = TextEditingController();
    final password = TextEditingController();
    try {
      final approved = await showDialog<ManualDiscount>(
          context: context,
          builder: (dialog) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: const Text('Manager-approved discount'),
                    content: SizedBox(
                        width: 420,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                              DropdownButtonFormField<String>(
                                  initialValue: scope,
                                  decoration: const InputDecoration(
                                      labelText: 'Apply to'),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'order',
                                        child: Text('Whole sale')),
                                    DropdownMenuItem(
                                        value: 'line', child: Text('One line')),
                                  ],
                                  onChanged: (v) =>
                                      update(() => scope = v ?? scope)),
                              const SizedBox(height: 12),
                              if (scope == 'line')
                                DropdownButtonFormField<String>(
                                    initialValue: lineKey,
                                    decoration: const InputDecoration(
                                        labelText: 'Line'),
                                    items: [
                                      for (final line in cart.lines)
                                        DropdownMenuItem(
                                            value: line.id,
                                            child: Text(
                                                '${line.product.name} · ${money(line.totalCents)}'))
                                    ],
                                    onChanged: (v) =>
                                        update(() => lineKey = v)),
                              if (scope == 'line') const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                  initialValue: kind,
                                  decoration:
                                      const InputDecoration(labelText: 'Type'),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'fixed',
                                        child: Text('Fixed amount')),
                                    DropdownMenuItem(
                                        value: 'percent',
                                        child: Text('Percentage')),
                                  ],
                                  onChanged: (v) => update(() {
                                        kind = v ?? kind;
                                        valueError = null;
                                      })),
                              const SizedBox(height: 12),
                              TextField(
                                  key: const Key('manual-discount-value'),
                                  controller: value,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                  decoration: InputDecoration(
                                      errorText: valueError,
                                      labelText: kind == 'fixed'
                                          ? 'Amount (pesos)'
                                          : 'Percentage (0–100)')),
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                  initialValue: reason,
                                  decoration: const InputDecoration(
                                      labelText: 'Reason'),
                                  items: [
                                    for (final r in const [
                                      'Price match',
                                      'Manager courtesy',
                                      'Damaged packaging',
                                      'Employee discount',
                                      'Manual correction',
                                      'Other'
                                    ])
                                      DropdownMenuItem(value: r, child: Text(r))
                                  ],
                                  onChanged: (v) =>
                                      update(() => reason = v ?? reason)),
                              const SizedBox(height: 12),
                              if (reason == 'Other')
                                TextField(
                                    controller: notes,
                                    decoration: InputDecoration(
                                        labelText: 'Notes *',
                                        errorText: notesError)),
                              if (reason == 'Other') const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                  initialValue: managerId,
                                  decoration: const InputDecoration(
                                      labelText: 'Authorizing manager'),
                                  items: [
                                    for (final manager in managers)
                                      DropdownMenuItem(
                                          value: manager.id,
                                          child: Text(manager.name))
                                  ],
                                  onChanged: (v) =>
                                      update(() => managerId = v ?? managerId)),
                              const SizedBox(height: 12),
                              TextField(
                                  key: const Key('manual-discount-password'),
                                  controller: password,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                      labelText: 'Manager password')),
                              if (error != null)
                                Text(error!,
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error)),
                            ]))),
                    actions: [
                      TextButton(
                          onPressed:
                              authorizing ? null : () => Navigator.pop(dialog),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: authorizing
                              ? null
                              : () async {
                                  update(() {
                                    authorizing = true;
                                    error = null;
                                    valueError = null;
                                    notesError = null;
                                  });
                                  try {
                                    final amount = kind == 'fixed'
                                        ? tryParseMoney(value.text)
                                        : int.tryParse(value.text.trim());
                                    if (amount == null ||
                                        amount < 0 ||
                                        (kind == 'percent' && amount > 100)) {
                                      update(() => valueError = kind ==
                                              'percent'
                                          ? 'Percentage must be between 0 and 100.'
                                          : 'Enter a valid amount.');
                                      return;
                                    }
                                    if (reason == 'Other' &&
                                        notes.text.trim().isEmpty) {
                                      update(() => notesError =
                                          'Notes are required for Other.');
                                      return;
                                    }
                                    final basis = scope == 'line'
                                        ? cart.lines
                                            .where((l) => l.id == lineKey)
                                            .fold<int>(0,
                                                (sum, l) => sum + l.totalCents)
                                        : cart.totalCents;
                                    final manager = await widget.auth
                                        .authorizeDiscount(
                                            managerId, password.text);
                                    final discount = ManualDiscount(
                                        scope: scope,
                                        kind: kind,
                                        lineKey:
                                            scope == 'line' ? lineKey : null,
                                        value: amount,
                                        reason: reason,
                                        notes: notes.text,
                                        requestedBy: widget.user.id,
                                        authorizedBy: manager.id,
                                        authorizedAt: DateTime.now(),
                                        approvedBasisCents: basis);
                                    final effect = discount.effectOn(basis);
                                    if (effect >
                                        cart.totalCents - rewardDiscountCents) {
                                      throw StateError(
                                          'Discount exceeds the payable total');
                                    }
                                    if (dialog.mounted) {
                                      Navigator.pop(dialog, discount);
                                    }
                                  } catch (failure) {
                                    if (dialog.mounted) {
                                      update(
                                          () => error = safeMessage(failure));
                                    }
                                  } finally {
                                    if (dialog.mounted) {
                                      update(() => authorizing = false);
                                    }
                                  }
                                },
                          child: const Text('Authorize')),
                    ],
                  )));
      if (approved != null && mounted) {
        var useManual = true;
        if (promotionPreview != null &&
            promotionPreview!.totalDiscountCents > 0 &&
            discountSource == CheckoutDiscountSource.automaticPromotion) {
          final basis = approved.scope == 'line'
              ? cart.lines.where((line) => line.id == approved.lineKey)
                  .fold<int>(0, (sum, line) => sum + line.totalCents)
              : cart.totalCents;
          final decision = await showDialog<bool>(context: context,
            builder: (dialog) => AlertDialog(
              title: const Text('Choose discount'),
              content: SizedBox(width: 420, child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('This sale already has an automatic promotion applied. Choose which discount should be used.'),
                  const SizedBox(height: 16),
                  Text('Automatic promotion', style: Theme.of(dialog).textTheme.labelMedium),
                  Text(promotionPreview!.recommendedApplications
                      .map((application) => application.name).join(' + ')),
                  Text('-${money(promotionPreview!.totalDiscountCents)}'),
                  const SizedBox(height: 12),
                  Text('Manual discount', style: Theme.of(dialog).textTheme.labelMedium),
                  Text(approved.kind == 'percent' ? '${approved.value}%' : money(approved.value)),
                  Text('-${money(approved.effectOn(basis))}'),
                ])),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
                TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Keep promotion')),
                FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Use manual discount')),
              ],
            ));
          if (decision == null) return;
          useManual = decision;
        }
        if (useManual) {
          setState(() {
            manualDiscount = approved;
            discountSource = CheckoutDiscountSource.manual;
            cashController.clear();
          });
        }
      }
    } finally {
      await waitForDialogExit();
      value.dispose();
      notes.dispose();
      password.dispose();
    }
  }

  Widget _salePanel(BuildContext context, double height) {
    final scheme = Theme.of(context).colorScheme;
    final customer = customers.where((c) => c.id == customerId).firstOrNull;
    final cashCents = tryParseMoney(cashController.text);
    final cashError = credit
        ? cashCents == null || cashCents < 0 || cashCents >= payableCents
            ? 'Enter cash paid below the sale total'
            : customerId == null
                ? 'Select a customer for credit'
                : null
        : cashValidationMessage(cashController.text, payableCents);
    final cartIssue = _cartIssue();
    final ready = !busy &&
        !pricingPending &&
        _promotionReady &&
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
                        'Customer  ·  ${customer?.name ?? walkInName ?? 'Walk-in customer'}',
                        overflow: TextOverflow.ellipsis)),
                const Text('Change'),
              ]),
            ),
            Wrap(spacing: 8, children: [
              TextButton.icon(
                  onPressed:
                      cart.isEmpty || !widget.user.can(PosPermission.holdSale)
                          ? null
                          : _holdSale,
                  icon: const Icon(Icons.pause_circle_outline, size: 18),
                  label: const Text('Hold sale · F6')),
              TextButton.icon(
                  onPressed: widget.user.can(PosPermission.resumeSale)
                      ? _heldSales
                      : null,
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('Held sales · F7')),
            ]),
            if (cartNotice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Semantics(
                  liveRegion: true,
                  child: Container(
                    key: const Key('current-sale-notice'),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(cartNotice!,
                        style: TextStyle(color: scheme.onTertiaryContainer)),
                  ),
                ),
              ),
            if (message != null) _messageBanner(context),
            if (customer != null && !credit)
              Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: FutureBuilder<int>(
                      future: LoyaltyRepository(widget.repository.db)
                          .balance(customer.id),
                      builder: (context, snapshot) => Text(
                          snapshot.hasData
                              ? '${snapshot.data} pts available'
                              : 'Customer linked to this sale',
                          style: Theme.of(context).textTheme.bodySmall))),
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
                  constraints: BoxConstraints(maxHeight: height * .48),
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
                              ? 'Complete payment · ${money(payableCents)}'
                              : 'Pay ${money(payableCents)}')),
            ),
          ],
        ));
  }

  String? _cartIssue() {
    if (payableCents < 0) {
      return 'Discounts exceed the sale total.';
    }
    if (manualDiscount != null) {
      final basis = manualDiscount!.scope == 'line'
          ? cart.lines
              .where((l) => l.id == manualDiscount!.lineKey)
              .fold<int>(0, (sum, l) => sum + l.totalCents)
          : cart.totalCents;
      if (basis != manualDiscount!.approvedBasisCents) {
        return 'Sale changed. Remove or reauthorize the manual discount.';
      }
    }
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
    final otherQuantity = cart.lines
        .where((other) =>
            other.product.id == line.product.id && other.id != line.id)
        .fold<int>(0, (sum, other) => sum + other.quantityMilli);
    if (!line.product.business.madeToOrder &&
        available != null &&
        milli + otherQuantity > available) {
      return 'Only ${Quantity.format(available)} ${line.product.business.unit.label} available.';
    }
    return null;
  }

  void _changeQuantity(CartLine line, int milli) {
    if (widget.quotationId != null || widget.salesOrderId != null) {
      _showCartNotice('The linked order quantity is fixed for this checkout.');
      return;
    }
    final issue = _quantityIssue(line, milli);
    if (issue != null) {
      _showCartNotice(issue);
      setState(() => quantityEditRevision++);
      return;
    }
    setState(() {
      cart.setQuantityMilli(line.id, milli);
      message = null;
    });
    _refreshLayerPrices();
  }

  Future<void> _configureQuotedAllocation(CartLine line) async {
    final product = line.product;
    final serials = product.serialTracking
        ? await widget.repository.availableSerials(product.id)
        : <SerialUnit>[];
    final batches = product.business.batch
        ? await widget.repository.batches(product.id)
        : <ProductLot>[];
    final needed = line.quantityMilli ~/ Quantity.scale;
    if (product.serialTracking && serials.length < needed) {
      if (mounted) {
        setState(() => message =
            '$needed units were quoted, but only ${serials.length} sellable serialized units are currently available for ${product.name}.');
      }
      return;
    }
    final chosen = line.serialIds.toSet();
    String? batchId = line.batchId;
    if (!mounted) return;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: Text('Allocate ${product.name}'),
                    content: SizedBox(
                        width: 420,
                        height: 330,
                        child: ListView(children: [
                          Text(
                              'Quoted quantity: ${Quantity.format(line.quantityMilli)} ${product.business.unit.label}'),
                          if (product.business.batch)
                            DropdownButtonFormField<String>(
                                initialValue: batchId,
                                decoration: const InputDecoration(
                                    labelText: 'Eligible batch'),
                                items: [
                                  for (final batch in batches.where((b) =>
                                      b.quantityMilli >= line.quantityMilli))
                                    DropdownMenuItem(
                                        value: batch.id,
                                        child: Text(batch.batchNumber))
                                ],
                                onChanged: (value) =>
                                    update(() => batchId = value)),
                          if (product.serialTracking)
                            for (final serial in serials)
                              CheckboxListTile(
                                  title: Text(serial.serialNumber),
                                  value: chosen.contains(serial.id),
                                  onChanged: (value) => update(() {
                                        if (value == true) {
                                          chosen.add(serial.id);
                                        } else {
                                          chosen.remove(serial.id);
                                        }
                                      })),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Apply')),
                    ])));
    if (accepted != true || !mounted) return;
    if (product.serialTracking && chosen.length != needed) {
      setState(() =>
          message = 'Select exactly $needed serials for ${product.name}.');
      return;
    }
    if (product.business.batch && batchId == null) {
      setState(() => message = 'Choose an eligible batch for ${product.name}.');
      return;
    }
    final quotedTotal = line.totalCents;
    setState(() {
      line.batchId = batchId;
      line.serialIds = chosen.toList();
      line.pricedTotalCents = quotedTotal;
      for (final serial in serials) {
        serialLabels[serial.id] = serial.serialNumber;
      }
      for (final batch in batches) {
        batchLabels[batch.id] = batch.batchNumber;
      }
      message = null;
    });
  }

  Widget _cartLine(BuildContext context, CartLine line) {
    final canDecrease = widget.quotationId == null &&
        widget.salesOrderId == null &&
        _quantityIssue(line, line.quantityMilli - Quantity.scale) == null;
    final canIncrease = widget.quotationId == null &&
        widget.salesOrderId == null &&
        _quantityIssue(line, line.quantityMilli + Quantity.scale) == null;
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
                if ((widget.quotationId != null || widget.salesOrderId != null) &&
                    (line.product.serialTracking ||
                        line.product.business.batch))
                  TextButton(
                      onPressed: () => _configureQuotedAllocation(line),
                      child: const Text('Allocate')),
                IconButton(
                    tooltip: 'Remove ${line.product.name}',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.quotationId != null ||
                            widget.salesOrderId != null
                        ? null
                        : () {
                            setState(() => cart.remove(line.id));
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
                    tooltip: canDecrease
                        ? 'Decrease quantity'
                        : 'Minimum quantity or serial selection reached',
                    constraints:
                        const BoxConstraints(minWidth: 40, minHeight: 40),
                    onPressed: !canDecrease
                        ? null
                        : () => _changeQuantity(
                            line, line.quantityMilli - Quantity.scale),
                    icon: const Icon(Icons.remove_circle_outline)),
                SizedBox(
                    width: 52,
                    child: TextFormField(
                      key: ValueKey(
                          'quantity-${line.id}-${line.quantityMilli}-$quantityEditRevision'),
                      initialValue: Quantity.format(line.quantityMilli),
                      textAlign: TextAlign.center,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(isDense: true),
                      onFieldSubmitted: (value) {
                        final milli = Quantity.tryParse(value,
                            fractional: line.product.business.fractional);
                        if (milli == null) {
                          _showCartNotice('Enter a valid quantity.');
                          setState(() => quantityEditRevision++);
                          return;
                        }
                        _changeQuantity(line, milli);
                        barcodeFocus.requestFocus();
                      },
                    )),
                IconButton(
                    tooltip: canIncrease
                        ? 'Increase quantity'
                        : 'Maximum quantity or serial selection reached',
                    constraints:
                        const BoxConstraints(minWidth: 40, minHeight: 40),
                    onPressed: canIncrease
                        ? () => _changeQuantity(
                            line, line.quantityMilli + Quantity.scale)
                        : null,
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

  Future<void> _redeemRewards() async {
    if (customerId == null) return;
    final loyalty = LoyaltyRepository(widget.repository.db);
    final rule = await loyalty.settings();
    final available = await loyalty.balance(customerId!);
    if (!mounted) return;
    if (!rule.enabled) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Rewards are disabled')));
      return;
    }
    final input = TextEditingController(text: '$redeemPoints');
    try {
      final selected = await showDialog<int>(
          context: context,
          builder: (dialogContext) =>
              StatefulBuilder(builder: (context, update) {
                final previewPoints = int.tryParse(input.text) ?? 0;
                final previewDiscount = previewPoints > 0 &&
                        previewPoints % rule.redeemPoints == 0
                    ? previewPoints ~/ rule.redeemPoints * rule.redeemValueCents
                    : 0;
                return AlertDialog(
                    title: const Text('Redeem points'),
                    content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Available: $available pts'),
                          Text(
                              '${rule.redeemPoints} pts = ${money(rule.redeemValueCents)}'),
                          TextField(
                              controller: input,
                              keyboardType: TextInputType.number,
                              onChanged: (_) => update(() {}),
                              decoration: const InputDecoration(
                                  labelText: 'Points to redeem')),
                          Text(
                              'Equivalent discount: ${money(previewDiscount)}'),
                          Text(
                              'Remaining points: ${available - previewPoints}'),
                        ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () {
                            final points = int.tryParse(input.text);
                            if (points == null ||
                                points < 0 ||
                                points > available ||
                                points % rule.redeemPoints != 0 ||
                                points ~/
                                        rule.redeemPoints *
                                        rule.redeemValueCents >=
                                    cart.totalCents - manualDiscountCents) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Enter valid points within the sale total')));
                              return;
                            }
                            Navigator.pop(dialogContext, points);
                          },
                          child: const Text('Apply'))
                    ]);
              }));
      if (selected == null || !mounted) return;
      setState(() {
        redeemPoints = selected;
        rewardDiscountCents =
            selected ~/ rule.redeemPoints * rule.redeemValueCents;
      });
    } finally {
      input.dispose();
    }
  }

  Widget _paymentPanel(
      BuildContext context, int? cashCents, String? cashError) {
    final scheme = Theme.of(context).colorScheme;
    final canCredit = widget.quotationId == null &&
        customerId != null &&
        widget.user.can(PosPermission.customerCredit);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Divider(),
      _amountRow(context, 'Subtotal', cart.subtotalCents),
      if (promotionDiscountCents > 0) _promotionRow(context),
      if (customerId != null && !credit)
        TextButton.icon(
            onPressed: _redeemRewards,
            icon: const Icon(Icons.stars_outlined),
            label: Text(redeemPoints == 0
                ? 'Redeem rewards'
                : 'Rewards: -${money(rewardDiscountCents)} ($redeemPoints pts)')),
      Row(children: [
        Expanded(
            child: TextButton.icon(
                onPressed: cart.isEmpty ? null : _requestManualDiscount,
                icon: const Icon(Icons.local_offer_outlined),
                label: Text(manualDiscount == null
                    ? '+ Add discount'
                    : 'Manual discount · ${manualDiscount!.reason}'))),
        if (manualDiscount != null)
          IconButton(
              tooltip: 'Remove manual discount',
              onPressed: () => setState(() {
                manualDiscount = null;
                discountSource = promotionPreview?.totalDiscountCents == 0
                    ? CheckoutDiscountSource.none
                    : CheckoutDiscountSource.automaticPromotion;
              }),
              icon: const Icon(Icons.close)),
      ]),
      if (manualDiscount != null)
        _amountRow(context, 'Manual discount', -manualDiscountCents),
      const Divider(),
      _amountRow(context, 'TOTAL', payableCents, prominent: true),
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
                          redeemPoints = 0;
                          rewardDiscountCents = 0;
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
            ('Exact', payableCents),
            ('₱100', 10000),
            ('₱500', 50000),
            ('₱1,000', 100000),
          ])
            OutlinedButton(
                onPressed: cents < payableCents
                    ? null
                    : () => setState(
                        () => cashController.text = formatPesoInput(cents)),
                child: Text(label)),
        ]),
        if (cashError == null && cashCents != null)
          _amountRow(context, 'Change', cashCents - payableCents),
      ] else if (cashError == null && cashCents != null) ...[
        _amountRow(context, 'Cash', cashCents),
        _amountRow(context, 'Credit', payableCents - cashCents),
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
  final cost = TextEditingController();
  final price = TextEditingController();
  DateTime? expiry;
  void dispose() {
    quantity.dispose();
    number.dispose();
    cost.dispose();
    price.dispose();
  }
}

class ProductScreen extends StatefulWidget {
  final PosRepository repository;
  final AuthService auth;
  final ValueChanged<String>? onReceiveStock;
  final ValueChanged<String>? onCreatePurchaseOrder;
  final ValueChanged<String>? onCreated;
  final bool createOnOpen;
  final String initialFilter;
  final String? initialBarcode;
  final String? initialProductId;
  const ProductScreen(
      {super.key,
      required this.repository,
      required this.auth,
      this.onReceiveStock,
      this.onCreatePurchaseOrder,
      this.onCreated,
      this.createOnOpen = false,
      this.initialBarcode,
      this.initialProductId,
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
  Map<String, InventoryPlanningRow> planning = {};
  Map<String, InventoryProductHealth> inventoryHealth = {};
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
    final health = await InventoryHealthRepository(widget.repository.db).load();
    final plans = {
      for (final entry in health.products.entries)
        entry.key: entry.value.planning
    };
    if (mounted) {
      setState(() {
        products = rows;
        categories = categoryRows;
        activeLayers = layerRows;
        stockLevels = levels;
        planning = plans;
        inventoryHealth = health.products;
      });
      if (widget.initialProductId != null && !_openedInitialProduct) {
        _openedInitialProduct = true;
        final product = rows.where((row) => row.id == widget.initialProductId)
            .firstOrNull;
        if (product != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) edit(product);
          });
        }
      }
    }
  }

  bool _openedInitialProduct = false;

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

  String _sellingRange(PosProduct product) {
    if (product.pricingPolicy != 'layer') return money(product.priceCents);
    final prices = (activeLayers[product.id] ?? [])
        .map((l) => l.unitSellingPriceCents)
        .whereType<int>()
        .toList();
    return prices.isEmpty ? 'No priced stock' : _range(prices, 0);
  }

  Future<void> edit([PosProduct? product]) async {
    var saved = false;
    final name = TextEditingController(text: product?.name);
    final sku = TextEditingController(text: product?.sku);
    final barcode =
        TextEditingController(text: product?.barcode ?? widget.initialBarcode);
    final price = TextEditingController(
        text: product == null
            ? ''
            : '${product.priceCents ~/ 100}.${(product.priceCents % 100).toString().padLeft(2, '0')}');
    final cost = TextEditingController(
        text: product == null
            ? ''
            : '${product.costCents ~/ 100}.${(product.costCents % 100).toString().padLeft(2, '0')}');
    final stock = TextEditingController();
    final openingCost = TextEditingController();
    final openingPrice = TextEditingController();
    final serialInput = TextEditingController();
    final openingSerials = <String>[];
    String? serialError;
    final threshold =
        TextEditingController(text: '${product?.lowStockThreshold ?? 5}');
    final containerPrice = TextEditingController(
        text: product == null
            ? '0.00'
            : formatPesoInput(product.business.containerPriceCents));
    final deposit = TextEditingController(
        text: product == null
            ? '0.00'
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
    String? stockError;
    String? openingCostError;
    String? sellingPriceError;
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
      openingCost,
      openingPrice,
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
                    width: 1240,
                    height: (MediaQuery.sizeOf(context).height - 48)
                        .clamp(0.0, 800.0),
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
                                  'Product details, behavior, pricing, and inventory setup'),
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
                          child: LayoutBuilder(builder: (context, constraints) {
                        final desktop = constraints.maxWidth >= 900;
                        final left = SingleChildScrollView(
                          key: const ValueKey('product-editor-left'),
                          padding: const EdgeInsets.fromLTRB(12, 12, 8, 20),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (formError != null)
                                  Text(formError!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error)),
                                Wrap(spacing: 16, runSpacing: 16, children: [
                                  SizedBox(
                                      width: double.infinity,
                                      child: Card(
                                          child: Padding(
                                              padding: const EdgeInsets.all(20),
                                              child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text('PRODUCT',
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .titleMedium),
                                                    TextField(
                                                        controller: name,
                                                        decoration:
                                                            const InputDecoration(
                                                                labelText:
                                                                    'Product name *')),
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
                                                              controller:
                                                                  barcode,
                                                              decoration:
                                                                  const InputDecoration(
                                                                      labelText:
                                                                          'Barcode')))
                                                    ]),
                                                    const SizedBox(height: 12),
                                                    DropdownButtonFormField<
                                                            String?>(
                                                        key: ValueKey(
                                                            categoryId),
                                                        initialValue:
                                                            categoryId,
                                                        decoration:
                                                            const InputDecoration(
                                                                labelText:
                                                                    'Category'),
                                                        items: [
                                                          const DropdownMenuItem<
                                                                  String?>(
                                                              value: null,
                                                              child:
                                                                  Text('None')),
                                                          ...categories.map((c) =>
                                                              DropdownMenuItem<
                                                                      String?>(
                                                                  value: c.id,
                                                                  child: Text(
                                                                      c.name)))
                                                        ],
                                                        onChanged: (v) =>
                                                            update(() {
                                                              categoryId = v;
                                                              changed = true;
                                                            })),
                                                    Align(
                                                        alignment: Alignment
                                                            .centerLeft,
                                                        child: TextButton.icon(
                                                            onPressed: () =>
                                                                createCategory(
                                                                    context,
                                                                    update),
                                                            icon: const Icon(
                                                                Icons.add),
                                                            label: const Text(
                                                                'Create new category'))),
                                                    DropdownButtonFormField<
                                                            SaleUnit>(
                                                        key: ValueKey(unit),
                                                        initialValue: unit,
                                                        decoration: const InputDecoration(
                                                            labelText: 'Unit'),
                                                        items: SaleUnit.values
                                                            .where((u) =>
                                                                available[BusinessFeature.unitOfMeasureVariety] ==
                                                                    true ||
                                                                u ==
                                                                    SaleUnit
                                                                        .piece ||
                                                                u == unit ||
                                                                (available[BusinessFeature.weightBasedPricing] ==
                                                                        true &&
                                                                    (u == SaleUnit.kilogram ||
                                                                        u ==
                                                                            SaleUnit
                                                                                .gram)))
                                                            .where((u) =>
                                                                serialTracking
                                                                    ? !u
                                                                        .fractional
                                                                    : weight
                                                                        ? u == SaleUnit.kilogram ||
                                                                            u ==
                                                                                SaleUnit
                                                                                    .gram
                                                                        : (refill ||
                                                                                tank)
                                                                            ? !u
                                                                                .fractional
                                                                            : true)
                                                            .map((u) => DropdownMenuItem(
                                                                value: u,
                                                                child: Text(
                                                                    u.label)))
                                                            .toList(),
                                                        onChanged: available[BusinessFeature.unitOfMeasureVariety] ==
                                                                    true ||
                                                                available[BusinessFeature.weightBasedPricing] == true
                                                            ? (v) => update(() {
                                                                  unit =
                                                                      v ?? unit;
                                                                  changed =
                                                                      true;
                                                                })
                                                            : null),
                                                  ])))),
                                ]),
                                Card(
                                    child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text('STARTING INVENTORY',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium),
                                              if (product == null && !made) ...[
                                                const SizedBox(height: 12),
                                                for (final choice in <(
                                                  String,
                                                  String,
                                                  String,
                                                  IconData
                                                )>[
                                                  (
                                                    'zero',
                                                    'No stock yet',
                                                    'Add inventory later.',
                                                    Icons.inventory_2_outlined
                                                  ),
                                                  (
                                                    'opening',
                                                    'I already have stock',
                                                    'Record stock already owned.',
                                                    Icons.warehouse_outlined
                                                  ),
                                                  if (widget.onReceiveStock !=
                                                      null)
                                                    (
                                                      'receive',
                                                      'Receive from supplier',
                                                      'Continue to Receiving.',
                                                      Icons
                                                          .local_shipping_outlined
                                                    ),
                                                ])
                                                  ListTile(
                                                    dense: true,
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                    selected: false,
                                                    shape:
                                                        RoundedRectangleBorder(
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        8)),
                                                    tileColor: stockSetup ==
                                                            choice.$1
                                                        ? Theme.of(context)
                                                            .colorScheme
                                                            .primaryContainer
                                                            .withValues(
                                                                alpha: 0.28)
                                                        : null,
                                                    leading: Icon(stockSetup ==
                                                            choice.$1
                                                        ? Icons
                                                            .radio_button_checked
                                                        : Icons
                                                            .radio_button_unchecked),
                                                    onTap: () => update(() {
                                                      stockSetup = choice.$1;
                                                      stockError = null;
                                                      openingCostError = null;
                                                      sellingPriceError = null;
                                                      changed = true;
                                                    }),
                                                    title: Text(choice.$2),
                                                    subtitle: Text(choice.$3),
                                                  ),
                                              ],
                                            ]))),
                                SizedBox(
                                    width: double.infinity,
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
                                                  DropdownButtonFormField<
                                                          String>(
                                                      initialValue:
                                                          pricingPolicy,
                                                      isExpanded: true,
                                                      decoration:
                                                          const InputDecoration(
                                                              labelText:
                                                                  'How should this product be priced?'),
                                                      items: [
                                                        const DropdownMenuItem(
                                                            value: 'current',
                                                            child: Text(
                                                                'Use one product price')),
                                                        DropdownMenuItem(
                                                            value: 'layer',
                                                            enabled: !(refill ||
                                                                tank ||
                                                                made),
                                                            child: const Text(
                                                                'Price each stock layer separately')),
                                                      ],
                                                      onChanged: (value) =>
                                                          update(() {
                                                            pricingPolicy =
                                                                value ??
                                                                    'current';
                                                            sellingPriceError =
                                                                null;
                                                            changed = true;
                                                          })),
                                                  const SizedBox(height: 12),
                                                  if (pricingPolicy ==
                                                          'current' &&
                                                      (product != null ||
                                                          stockSetup !=
                                                              'opening' ||
                                                          batch ||
                                                          serialTracking))
                                                    TextField(
                                                        key: const ValueKey(
                                                            'product-selling-price'),
                                                        controller: price,
                                                        decoration: InputDecoration(
                                                            labelText:
                                                                'Selling price *',
                                                            prefixText: '₱ ',
                                                            suffixText:
                                                                '/ ${unit.label}',
                                                            errorText:
                                                                sellingPriceError),
                                                        keyboardType:
                                                            TextInputType
                                                                .number),
                                                  const SizedBox(height: 8),
                                                  Row(children: [
                                                    Expanded(
                                                        child: Text(pricingPolicy ==
                                                                'layer'
                                                            ? 'Enter a selling price when stock is added.'
                                                            : 'One selling price applies to available stock.')),
                                                    Tooltip(
                                                        message: pricingPolicy ==
                                                                'layer'
                                                            ? 'Each opening or received stock layer keeps its own cost and selling price.'
                                                            : 'Supplier purchase costs remain on inventory layers; the product price controls sales.',
                                                        child: const Icon(
                                                            Icons.help_outline,
                                                            size: 18)),
                                                  ]),
                                                  if (refill || tank || made)
                                                    const Text(
                                                        'This selling method uses one product price.'),
                                                ])))),
                                if (product == null && !made) ...[
                                  if (stockSetup == 'opening') ...[
                                    const SizedBox(height: 12),
                                    const Text('Existing inventory',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600)),
                                  ],
                                  if (stockSetup == 'opening' &&
                                      !batch &&
                                      !serialTracking)
                                    TextField(
                                        controller: stock,
                                        decoration: InputDecoration(
                                            labelText: 'Opening quantity *',
                                            suffixText: unit.label,
                                            errorText: stockError,
                                            helperText:
                                                'Use for inventory you already owned before setting up this POS.'),
                                        keyboardType:
                                            TextInputType.numberWithOptions(
                                                decimal:
                                                    unit.fractional || weight),
                                        onChanged: (_) =>
                                            update(() => stockError = null)),
                                  if (stockSetup == 'opening' && batch) ...[
                                    Text('OPENING BATCHES',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall),
                                    const SizedBox(height: 8),
                                    SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: SizedBox(
                                        width: pricingPolicy == 'layer'
                                            ? 860
                                            : 730,
                                        child: Table(
                                          defaultVerticalAlignment:
                                              TableCellVerticalAlignment.middle,
                                          columnWidths: {
                                            0: const FixedColumnWidth(170),
                                            1: const FixedColumnWidth(100),
                                            2: const FixedColumnWidth(125),
                                            if (pricingPolicy == 'layer')
                                              3: const FixedColumnWidth(125),
                                            pricingPolicy == 'layer' ? 4 : 3:
                                                const FixedColumnWidth(245),
                                            pricingPolicy == 'layer' ? 5 : 4:
                                                const FixedColumnWidth(55),
                                          },
                                          children: [
                                            TableRow(children: [
                                              const Text('Batch / Lot'),
                                              const Text('Qty'),
                                              const Text('Cost'),
                                              if (pricingPolicy == 'layer')
                                                const Text('Selling'),
                                              const Text('Expiry'),
                                              const SizedBox.shrink(),
                                            ]),
                                            TableRow(children: [
                                              TextField(
                                                  controller: batchNumber,
                                                  decoration:
                                                      const InputDecoration(
                                                          labelText:
                                                              'Batch / lot *')),
                                              TextField(
                                                  controller: stock,
                                                  decoration: InputDecoration(
                                                      labelText: 'Qty *',
                                                      errorText: stockError),
                                                  keyboardType:
                                                      const TextInputType
                                                          .numberWithOptions(
                                                          decimal: true),
                                                  onChanged: (_) =>
                                                      update(() {})),
                                              TextField(
                                                  controller: openingCost,
                                                  decoration: InputDecoration(
                                                      labelText: 'Cost *',
                                                      errorText:
                                                          openingCostError),
                                                  keyboardType:
                                                      TextInputType.number),
                                              if (pricingPolicy == 'layer')
                                                TextField(
                                                    controller: openingPrice,
                                                    decoration: InputDecoration(
                                                        labelText: 'Selling *',
                                                        errorText:
                                                            sellingPriceError),
                                                    keyboardType:
                                                        TextInputType.number),
                                              ExpiryDateField(
                                                  value: expiryDate,
                                                  onChanged: (date) => update(
                                                      () => expiryDate = date)),
                                              const SizedBox.shrink(),
                                            ]),
                                            for (var index = 0;
                                                index <
                                                    extraOpeningBatches.length;
                                                index++)
                                              TableRow(children: [
                                                TextField(
                                                    controller:
                                                        extraOpeningBatches[
                                                                index]
                                                            .number,
                                                    decoration:
                                                        const InputDecoration(
                                                            labelText:
                                                                'Batch / lot *')),
                                                TextField(
                                                    controller:
                                                        extraOpeningBatches[
                                                                index]
                                                            .quantity,
                                                    decoration:
                                                        const InputDecoration(
                                                            labelText: 'Qty *'),
                                                    keyboardType:
                                                        const TextInputType
                                                            .numberWithOptions(
                                                            decimal: true),
                                                    onChanged: (_) =>
                                                        update(() {})),
                                                TextField(
                                                    controller:
                                                        extraOpeningBatches[
                                                                index]
                                                            .cost,
                                                    decoration:
                                                        const InputDecoration(
                                                            labelText:
                                                                'Cost *'),
                                                    keyboardType:
                                                        TextInputType.number),
                                                if (pricingPolicy == 'layer')
                                                  TextField(
                                                      controller:
                                                          extraOpeningBatches[
                                                                  index]
                                                              .price,
                                                      decoration:
                                                          const InputDecoration(
                                                              labelText:
                                                                  'Selling *'),
                                                      keyboardType:
                                                          TextInputType.number),
                                                ExpiryDateField(
                                                    value: extraOpeningBatches[
                                                            index]
                                                        .expiry,
                                                    onChanged: (date) => update(
                                                        () =>
                                                            extraOpeningBatches[
                                                                        index]
                                                                    .expiry =
                                                                date)),
                                                IconButton(
                                                    tooltip: 'Remove batch',
                                                    icon:
                                                        const Icon(Icons.close),
                                                    onPressed: () => update(() {
                                                          extraOpeningBatches
                                                              .removeAt(index)
                                                              .dispose();
                                                          changed = true;
                                                        })),
                                              ]),
                                          ],
                                        ),
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: () => update(() {
                                        extraOpeningBatches
                                            .add(_OpeningBatchEditor());
                                        changed = true;
                                      }),
                                      icon: const Icon(Icons.add),
                                      label: const Text('Add batch'),
                                    ),
                                    Text(
                                        'Total opening quantity: ${Quantity.format((Quantity.tryParse(stock.text, fractional: unit.fractional || weight) ?? 0) + extraOpeningBatches.fold<int>(0, (sum, row) => sum + (Quantity.tryParse(row.quantity.text, fractional: unit.fractional || weight) ?? 0)))} ${unit.label}'),
                                  ],
                                  if (stockSetup == 'opening' && !batch)
                                    LayoutBuilder(builder: (context, box) {
                                      final width = box.maxWidth >= 520
                                          ? (box.maxWidth - 12) / 2
                                          : box.maxWidth;
                                      return Wrap(
                                          spacing: 12,
                                          runSpacing: 8,
                                          children: [
                                            SizedBox(
                                                width: width,
                                                child: TextField(
                                                    controller: openingCost,
                                                    decoration: InputDecoration(
                                                        labelText:
                                                            'Cost per unit *',
                                                        prefixText: '₱ ',
                                                        suffixText:
                                                            '/ ${unit.label}',
                                                        errorText:
                                                            openingCostError),
                                                    keyboardType:
                                                        TextInputType.number)),
                                            if (!serialTracking ||
                                                pricingPolicy == 'layer')
                                              SizedBox(
                                                  width: width,
                                                  child: TextField(
                                                      key: const ValueKey(
                                                          'opening-selling-price'),
                                                      controller:
                                                          pricingPolicy ==
                                                                  'layer'
                                                              ? openingPrice
                                                              : price,
                                                      decoration: InputDecoration(
                                                          labelText:
                                                              'Selling price *',
                                                          prefixText: '₱ ',
                                                          suffixText:
                                                              '/ ${unit.label}',
                                                          errorText:
                                                              sellingPriceError),
                                                      keyboardType:
                                                          TextInputType
                                                              .number)),
                                          ]);
                                    }),
                                  if (stockSetup == 'opening' &&
                                      serialTracking) ...[
                                    Text(
                                        'OPENING SERIALS · ${openingSerials.length} units',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall),
                                    const Text(
                                        'Enter the serial numbers already physically on hand.'),
                                    TextField(
                                      controller: serialInput,
                                      decoration: const InputDecoration(
                                          labelText:
                                              'Scan or enter serial number',
                                          helperText:
                                              'Paste one serial per line, then add them.'),
                                      minLines: 1,
                                      maxLines: 3,
                                    ),
                                    Align(
                                        alignment: Alignment.centerRight,
                                        child: Wrap(spacing: 8, children: [
                                          TextButton(
                                              onPressed: () =>
                                                  addOpeningSerials(
                                                      serialInput.text, update),
                                              child: const Text('Add serial')),
                                          TextButton.icon(
                                              onPressed: () =>
                                                  addOpeningSerials(
                                                      serialInput.text, update),
                                              icon: const Icon(
                                                  Icons.content_paste),
                                              label:
                                                  const Text('Paste serials')),
                                        ])),
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
                                            icon: const Icon(Icons.close,
                                                size: 18),
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
                                if (product != null &&
                                    batch &&
                                    !product.business.batch &&
                                    existingStock > 0)
                                  TextField(
                                    controller: batchNumber,
                                    decoration: const InputDecoration(
                                        labelText:
                                            'Batch / lot for existing stock *',
                                        helperText:
                                            'Assigns a lot to stock already on hand.'),
                                  ),
                              ]),
                        );
                        final right = SingleChildScrollView(
                          key: const ValueKey('product-editor-right'),
                          padding: const EdgeInsets.fromLTRB(8, 12, 12, 20),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text('PRODUCT BEHAVIOR',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                Card(
                                    child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Wrap(
                                            spacing: 16,
                                            runSpacing: 8,
                                            children: [
                                              SizedBox(
                                                  width: double.infinity,
                                                  child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text('TRACKING',
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .titleSmall),
                                                        CheckboxListTile(
                                                            dense: true,
                                                            visualDensity:
                                                                VisualDensity
                                                                    .compact,
                                                            controlAffinity:
                                                                ListTileControlAffinity
                                                                    .leading,
                                                            contentPadding:
                                                                EdgeInsets.zero,
                                                            title: const Text(
                                                                'Serial numbers'),
                                                            subtitle:
                                                                serialTracking
                                                                    ? const Text(
                                                                        'Every opening or received unit needs its own serial number.')
                                                                    : weight ||
                                                                            made
                                                                        ? const Text(
                                                                            'Unavailable with weight or made-to-order.')
                                                                        : null,
                                                            value:
                                                                serialTracking,
                                                            onChanged:
                                                                weight || made
                                                                    ? null
                                                                    : (v) =>
                                                                        update(
                                                                            () {
                                                                          changed =
                                                                              true;
                                                                          serialTracking =
                                                                              v ?? false;
                                                                          if (v ==
                                                                              true) {
                                                                            if (unit.fractional) {
                                                                              unit = SaleUnit.piece;
                                                                            }
                                                                            weight =
                                                                                false;
                                                                            made =
                                                                                false;
                                                                          }
                                                                        })),
                                                        if (serialTracking &&
                                                            unit.fractional)
                                                          Text(
                                                              'Serial-tracked products require a whole-unit sale unit.',
                                                              style: TextStyle(
                                                                  color: Theme.of(
                                                                          context)
                                                                      .colorScheme
                                                                      .error)),
                                                        if (available[
                                                                BusinessFeature
                                                                    .expiryBatchTracking] ==
                                                            true)
                                                          CheckboxListTile(
                                                              dense: true,
                                                              visualDensity:
                                                                  VisualDensity
                                                                      .compact,
                                                              controlAffinity:
                                                                  ListTileControlAffinity
                                                                      .leading,
                                                              contentPadding:
                                                                  EdgeInsets
                                                                      .zero,
                                                              title: const Text(
                                                                  'Batch / expiry'),
                                                              subtitle: batch
                                                                  ? const Text(
                                                                      'Batch numbers and expiry dates are recorded when inventory is added.')
                                                                  : made
                                                                      ? const Text(
                                                                          'Unavailable with made-to-order.')
                                                                      : null,
                                                              value: batch,
                                                              onChanged: made
                                                                  ? null
                                                                  : (v) =>
                                                                      update(
                                                                          () {
                                                                        changed =
                                                                            true;
                                                                        batch = v ??
                                                                            false;
                                                                        if (v ==
                                                                            true) {
                                                                          made =
                                                                              false;
                                                                        }
                                                                      })),
                                                      ])),
                                              SizedBox(
                                                  width: double.infinity,
                                                  child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text('SELLING METHOD',
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .titleSmall),
                                                        if (available[
                                                                BusinessFeature
                                                                    .weightBasedPricing] ==
                                                            true)
                                                          CheckboxListTile(
                                                              dense: true,
                                                              visualDensity:
                                                                  VisualDensity
                                                                      .compact,
                                                              controlAffinity:
                                                                  ListTileControlAffinity
                                                                      .leading,
                                                              contentPadding:
                                                                  EdgeInsets
                                                                      .zero,
                                                              title: const Text(
                                                                  'Sold by weight'),
                                                              subtitle:
                                                                  serialTracking
                                                                      ? const Text(
                                                                          'Unavailable for serialized products.')
                                                                      : refill ||
                                                                              tank ||
                                                                              made
                                                                          ? const Text(
                                                                              'Unavailable with refill, LPG, or made-to-order.')
                                                                          : null,
                                                              value: weight,
                                                              onChanged:
                                                                  serialTracking ||
                                                                          refill ||
                                                                          tank ||
                                                                          made
                                                                      ? null
                                                                      : (v) =>
                                                                          update(
                                                                              () {
                                                                            changed =
                                                                                true;
                                                                            weight =
                                                                                v ?? false;
                                                                            if (v ==
                                                                                true) {
                                                                              unit = SaleUnit.kilogram;
                                                                              refill = false;
                                                                              tank = false;
                                                                            }
                                                                          })),
                                                        if (available[
                                                                BusinessFeature
                                                                    .madeToOrderTracking] ==
                                                            true)
                                                          CheckboxListTile(
                                                              dense: true,
                                                              visualDensity:
                                                                  VisualDensity
                                                                      .compact,
                                                              controlAffinity:
                                                                  ListTileControlAffinity
                                                                      .leading,
                                                              contentPadding:
                                                                  EdgeInsets
                                                                      .zero,
                                                              title: const Text(
                                                                  'Made to order'),
                                                              subtitle: serialTracking ||
                                                                      batch ||
                                                                      weight ||
                                                                      refill ||
                                                                      tank
                                                                  ? const Text(
                                                                      'Unavailable with tracking, weight, refill, or LPG.')
                                                                  : made
                                                                      ? const Text(
                                                                          'This item may be sold before fulfillment is completed.')
                                                                      : null,
                                                              value: made,
                                                              onChanged: serialTracking ||
                                                                      batch ||
                                                                      weight ||
                                                                      refill ||
                                                                      tank
                                                                  ? null
                                                                  : (v) =>
                                                                      update(
                                                                          () {
                                                                        changed =
                                                                            true;
                                                                        made = v ??
                                                                            false;
                                                                        if (v ==
                                                                            true) {
                                                                          pricingPolicy =
                                                                              'current';
                                                                          batch =
                                                                              false;
                                                                          refill =
                                                                              false;
                                                                          tank =
                                                                              false;
                                                                          stockSetup =
                                                                              'zero';
                                                                          stock
                                                                              .clear();
                                                                        }
                                                                      })),
                                                      ])),
                                              SizedBox(
                                                  width: double.infinity,
                                                  child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text('SPECIAL SELLING',
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .titleSmall),
                                                        if (available[
                                                                BusinessFeature
                                                                    .containerRefillPricing] ==
                                                            true) ...[
                                                          CheckboxListTile(
                                                              dense: true,
                                                              visualDensity:
                                                                  VisualDensity
                                                                      .compact,
                                                              controlAffinity:
                                                                  ListTileControlAffinity
                                                                      .leading,
                                                              contentPadding:
                                                                  EdgeInsets
                                                                      .zero,
                                                              title: const Text(
                                                                  'Refill / container'),
                                                              subtitle: refill
                                                                  ? const Text(
                                                                      'Container pricing is applied during checkout.')
                                                                  : weight ||
                                                                          tank ||
                                                                          made
                                                                      ? const Text(
                                                                          'Unavailable with weight, LPG, or made-to-order.')
                                                                      : null,
                                                              value: refill,
                                                              onChanged: weight ||
                                                                      tank ||
                                                                      made
                                                                  ? null
                                                                  : (v) =>
                                                                      update(
                                                                          () {
                                                                        refill =
                                                                            v ??
                                                                                false;
                                                                        changed =
                                                                            true;
                                                                        if (v ==
                                                                            true) {
                                                                          unit =
                                                                              SaleUnit.bottle;
                                                                          pricingPolicy =
                                                                              'current';
                                                                          weight =
                                                                              false;
                                                                          tank =
                                                                              false;
                                                                          made =
                                                                              false;
                                                                        }
                                                                      })),
                                                        ],
                                                        if (available[
                                                                BusinessFeature
                                                                    .tankDepositExchange] ==
                                                            true) ...[
                                                          CheckboxListTile(
                                                              dense: true,
                                                              visualDensity:
                                                                  VisualDensity
                                                                      .compact,
                                                              controlAffinity:
                                                                  ListTileControlAffinity
                                                                      .leading,
                                                              contentPadding:
                                                                  EdgeInsets
                                                                      .zero,
                                                              title: const Text(
                                                                  'LPG tank exchange / deposit'),
                                                              subtitle: tank
                                                                  ? const Text(
                                                                      'Tank exchange and deposit are handled during checkout.')
                                                                  : weight ||
                                                                          refill ||
                                                                          made
                                                                      ? const Text(
                                                                          'Unavailable with weight, refill, or made-to-order.')
                                                                      : null,
                                                              value: tank,
                                                              onChanged: weight ||
                                                                      refill ||
                                                                      made
                                                                  ? null
                                                                  : (v) =>
                                                                      update(
                                                                          () {
                                                                        tank = v ??
                                                                            false;
                                                                        changed =
                                                                            true;
                                                                        if (v ==
                                                                            true) {
                                                                          unit =
                                                                              SaleUnit.piece;
                                                                          pricingPolicy =
                                                                              'current';
                                                                          weight =
                                                                              false;
                                                                          refill =
                                                                              false;
                                                                          made =
                                                                              false;
                                                                        }
                                                                      })),
                                                        ],
                                                      ])),
                                            ]))),
                                if (refill || tank)
                                  Card(
                                      child: Padding(
                                          padding: const EdgeInsets.all(16),
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                    refill
                                                        ? 'REFILL / CONTAINER'
                                                        : 'LPG TANK',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium),
                                                const SizedBox(height: 8),
                                                TextField(
                                                    controller: refill
                                                        ? containerPrice
                                                        : deposit,
                                                    decoration: InputDecoration(
                                                        border:
                                                            const OutlineInputBorder(),
                                                        labelText: refill
                                                            ? 'Container charge'
                                                            : 'Deposit charge',
                                                        prefixText: '₱ '),
                                                    keyboardType:
                                                        TextInputType.number),
                                              ]))),
                                const SizedBox(height: 16),
                                Card(
                                    child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text('ADVANCED',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium),
                                              Padding(
                                                padding:
                                                    const EdgeInsets.all(12),
                                                child: LayoutBuilder(
                                                    builder: (context, box) {
                                                  final width = box.maxWidth >=
                                                          520
                                                      ? (box.maxWidth - 12) / 2
                                                      : box.maxWidth;
                                                  return Wrap(
                                                      spacing: 12,
                                                      runSpacing: 12,
                                                      children: [
                                                        SizedBox(
                                                            width: width,
                                                            child: TextField(
                                                                controller:
                                                                    threshold,
                                                                decoration: const InputDecoration(
                                                                    border:
                                                                        OutlineInputBorder(),
                                                                    labelText:
                                                                        'Low-stock alert threshold'),
                                                                keyboardType:
                                                                    TextInputType
                                                                        .number)),
                                                        SizedBox(
                                                            width: width,
                                                            child: TextField(
                                                                controller:
                                                                    cost,
                                                                decoration: const InputDecoration(
                                                                    border:
                                                                        OutlineInputBorder(),
                                                                    labelText:
                                                                        'Reference purchase cost',
                                                                    prefixText:
                                                                        '₱ ',
                                                                    helperText:
                                                                        'Default only. Actual cost is recorded on each stock layer.'),
                                                                keyboardType:
                                                                    TextInputType
                                                                        .number)),
                                                      ]);
                                                }),
                                              ),
                                              if (product != null)
                                                CheckboxListTile(
                                                    dense: true,
                                                    controlAffinity:
                                                        ListTileControlAffinity
                                                            .leading,
                                                    title: const Text('Active'),
                                                    value: active,
                                                    onChanged: (v) =>
                                                        update(() {
                                                          active = v ?? false;
                                                          changed = true;
                                                        })),
                                            ]))),
                              ]),
                        );
                        if (!desktop) {
                          return SingleChildScrollView(
                              child: Column(children: [
                            SizedBox(height: 720, child: left),
                            SizedBox(height: 700, child: right)
                          ]));
                        }
                        return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 64, child: left),
                              Expanded(flex: 36, child: right),
                            ]);
                      })),
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
                                        update(() {
                                          formError = null;
                                          stockError = null;
                                          openingCostError = null;
                                          sellingPriceError = null;
                                        });
                                        if (name.text.trim().isEmpty) {
                                          throw ArgumentError(
                                              'Name is required.');
                                        }
                                        final priceCents =
                                            pricingPolicy == 'layer'
                                                ? (product?.priceCents ?? 0)
                                                : tryParseMoney(price.text);
                                        final costCents =
                                            cost.text.trim().isEmpty
                                                ? 0
                                                : tryParseMoney(cost.text);
                                        if (priceCents == null ||
                                            priceCents < 0) {
                                          update(() => sellingPriceError = price
                                                  .text
                                                  .trim()
                                                  .isEmpty
                                              ? 'Selling price is required.'
                                              : 'Enter a valid selling price.');
                                          return;
                                        }
                                        if (costCents == null ||
                                            costCents < 0) {
                                          throw ArgumentError(
                                              'Cost is invalid.');
                                        }
                                        final parsedInitialMilli = stockSetup !=
                                                    'opening' ||
                                                serialTracking
                                            ? 0
                                            : Quantity.tryParse(stock.text,
                                                fractional:
                                                    unit.fractional || weight);
                                        final lowStockThreshold =
                                            int.tryParse(threshold.text.trim());
                                        if (stockSetup == 'opening' &&
                                            !serialTracking &&
                                            (parsedInitialMilli == null ||
                                                parsedInitialMilli <= 0)) {
                                          update(() => stockError = stock.text
                                                  .trim()
                                                  .isEmpty
                                              ? batch
                                                  ? 'Batch quantity is required.'
                                                  : 'Opening quantity is required.'
                                              : 'Quantity must be greater than zero.');
                                          return;
                                        }
                                        if (lowStockThreshold == null ||
                                            lowStockThreshold < 0) {
                                          throw StateError(
                                              'Enter a valid low-stock threshold.');
                                        }
                                        var initialMilli = serialTracking &&
                                                stockSetup == 'opening'
                                            ? openingSerials.length *
                                                Quantity.scale
                                            : parsedInitialMilli!;
                                        final openingLayerPrice =
                                            pricingPolicy == 'layer' &&
                                                    stockSetup == 'opening'
                                                ? tryParseMoney(
                                                    openingPrice.text)
                                                : null;
                                        final openingLayerCost = stockSetup ==
                                                'opening'
                                            ? tryParseMoney(openingCost.text)
                                            : null;
                                        if (stockSetup == 'opening' &&
                                            (openingLayerCost == null ||
                                                openingLayerCost < 0)) {
                                          update(() => openingCostError =
                                              openingCost.text.trim().isEmpty
                                                  ? 'Opening cost is required.'
                                                  : 'Enter a valid opening cost.');
                                          return;
                                        }
                                        if (pricingPolicy == 'layer' &&
                                            stockSetup == 'opening' &&
                                            (openingLayerPrice == null ||
                                                openingLayerPrice <= 0)) {
                                          update(() => sellingPriceError = openingPrice
                                                  .text
                                                  .trim()
                                                  .isEmpty
                                              ? 'Opening selling price is required.'
                                              : 'Opening selling price must be greater than zero.');
                                          return;
                                        }
                                        if (product == null &&
                                            stockSetup == 'opening' &&
                                            serialTracking &&
                                            initialMilli <= 0) {
                                          throw StateError(
                                              'Enter at least one opening serial number.');
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
                                              expiryDate,
                                              unitCostCents: openingLayerCost,
                                              unitSellingPriceCents:
                                                  openingLayerPrice));
                                          for (final row
                                              in extraOpeningBatches) {
                                            final quantity = Quantity.tryParse(
                                                row.quantity.text,
                                                fractional:
                                                    unit.fractional || weight);
                                            if (quantity == null ||
                                                quantity <= 0 ||
                                                tryParseMoney(row.cost.text) ==
                                                    null ||
                                                (tryParseMoney(row.cost.text) ??
                                                        -1) <
                                                    0 ||
                                                (pricingPolicy == 'layer' &&
                                                    (tryParseMoney(row
                                                                .price.text) ??
                                                            0) <=
                                                        0) ||
                                                row.number.text
                                                    .trim()
                                                    .isEmpty) {
                                              throw StateError(
                                                  'Enter a valid quantity and lot for each opening batch.');
                                            }
                                            openingBatches.add(OpeningBatch(
                                                quantity,
                                                row.number.text.trim(),
                                                row.expiry,
                                                unitCostCents: tryParseMoney(
                                                    row.cost.text),
                                                unitSellingPriceCents:
                                                    pricingPolicy == 'layer'
                                                        ? tryParseMoney(
                                                            row.price.text)
                                                        : null));
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
                                                openingCostCents:
                                                    openingLayerCost,
                                                openingSellingPriceCents:
                                                    openingLayerPrice,
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
    openingCost.dispose();
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
    final snapshot =
        await InventoryHealthRepository(widget.repository.db).load();
    final health = snapshot.products[product.id];
    final plan = health?.planning;
    final stock = await Future.wait<int>([
      widget.repository.stockMilli(product.id),
      widget.repository.reservedStockMilli(product.id),
      PurchaseOrderRepository(widget.repository.db)
          .incomingForProduct(product.id),
    ]);
    final physical = stock[0];
    final reserved = stock[1];
    final incoming = stock[2];
    final available = physical - reserved;
    final unit = product.business.unit.label;
    if (!mounted) return;
    await showRecordDetailsDrawer<void>(
      context: context,
      builder: (context) => RecordDetailsDrawer(
        title: Text(product.name),
        width: 680,
        subtitle: Text(
            'SKU ${product.sku?.isNotEmpty == true ? product.sku : 'Not set'} · ${categories.where((c) => c.id == product.categoryId).firstOrNull?.name ?? 'Uncategorized'}'),
        badges: [
          DrawerStatusBadge(product.isActive ? 'Active' : 'Inactive',
              color: product.isActive
                  ? null
                  : Theme.of(context).colorScheme.error),
          if (physical <= 0)
            DrawerStatusBadge('Out of stock',
                color: Theme.of(context).colorScheme.error),
          if (physical > 0 &&
              physical <= product.lowStockThreshold * Quantity.scale)
            DrawerStatusBadge('Low stock',
                color: Theme.of(context).colorScheme.tertiary),
          if (product.serialTracking) const DrawerStatusBadge('Serialized'),
          if (product.business.batch) const DrawerStatusBadge('Batch tracked'),
        ],
        content:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DrawerSection(
            title: 'Stock snapshot',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DrawerMetricGrid(metrics: [
                  DrawerMetric(
                      label: 'Physical',
                      value: '${Quantity.format(physical)} $unit'),
                  DrawerMetric(
                      label: 'Available',
                      value: '${Quantity.format(available)} $unit'),
                  DrawerMetric(
                      label: 'Reserved',
                      value: '${Quantity.format(reserved)} $unit'),
                  DrawerMetric(
                      label: 'Incoming',
                      value: '${Quantity.format(incoming)} $unit'),
                ]),
                const SizedBox(height: 16),
                if (physical > 0 && reserved >= 0 && reserved <= physical)
                  DrawerStockDonut(
                    available: available,
                    reserved: reserved,
                    availableLabel: '${Quantity.format(available)} $unit',
                    reservedLabel: '${Quantity.format(reserved)} $unit',
                  )
                else if (physical <= 0)
                  const Text('No physical stock on hand.')
                else
                  const Text(
                      'Stock breakdown unavailable because reserved stock exceeds physical stock.'),
              ],
            ),
          ),
          DrawerSection(
            title: 'Pricing',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    product.pricingPolicy == 'layer'
                        ? '${_sellingRange(product)} / $unit'
                        : '${money(product.priceCents)} / $unit',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                DrawerLabelValue(
                    label: 'Active purchase cost', value: _costRange(product)),
                DrawerLabelValue(
                    label: 'Reference purchase cost',
                    value: money(product.costCents)),
                DrawerLabelValue(
                    label: 'Inventory cost value',
                    value: plan == null
                        ? 'Unavailable'
                        : money(plan.costValueCents)),
                DrawerLabelValue(
                    label: 'Pricing method',
                    value: product.pricingPolicy == 'layer'
                        ? 'By stock layer'
                        : 'Single product price'),
              ],
            ),
          ),
          DrawerSection(
            title: 'Inventory health',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DrawerLabelValue(
                    label: 'Low-stock threshold',
                    value: '${product.lowStockThreshold} $unit'),
                DrawerLabelValue(
                    label: 'Reorder level',
                    value: plan?.reorderLevelMilli == null
                        ? 'Not set'
                        : '${Quantity.format(plan!.reorderLevelMilli!)} $unit'),
                DrawerLabelValue(
                    label: 'Suggested reorder',
                    value: plan == null
                        ? 'Unavailable'
                        : '${Quantity.format(plan.suggestedReorderMilli)} $unit'),
                if (plan != null) ...[
                  DrawerLabelValue(
                      label: 'Target stock',
                      value: plan.targetStockMilli == null
                          ? 'Not set'
                          : '${Quantity.format(plan.targetStockMilli!)} $unit'),
                  DrawerLabelValue(
                      label: 'Projected stock',
                      value: '${Quantity.format(plan.projectedMilli)} $unit'),
                  DrawerLabelValue(
                      label: 'Last purchase cost',
                      value: plan.lastPurchaseCostCents == null
                          ? 'No receiving history'
                          : money(plan.lastPurchaseCostCents!)),
                  if (plan.previousPurchaseCostCents != null)
                    DrawerLabelValue(
                        label: 'Previous purchase cost',
                        value: money(plan.previousPurchaseCostCents!)),
                  if (plan.oldestStockAt != null)
                    DrawerLabelValue(
                        label: 'Oldest remaining stock',
                        value:
                            '${DateTime.now().difference(plan.oldestStockAt!).inDays} days'),
                ],
                if (health != null) ...[
                  DrawerLabelValue(
                      label: 'Net sold, 30 days',
                      value: '${Quantity.format(health.netSold30Milli)} $unit'),
                  DrawerLabelValue(
                      label: 'Net sold, 90 days',
                      value: '${Quantity.format(health.netSold90Milli)} $unit'),
                  DrawerLabelValue(
                      label: 'Last sold',
                      value: health.lastSoldAt == null
                          ? 'Never sold'
                          : MaterialLocalizations.of(context)
                              .formatMediumDate(health.lastSoldAt!)),
                  DrawerLabelValue(
                      label: 'Estimated stock cover', value: health.coverLabel),
                  if (health.deadStock || health.slowMoving)
                    DrawerStatusBadge(
                        health.deadStock ? 'Dead stock' : 'Slow moving'),
                  if ((health.deadStock || health.slowMoving) &&
                      (health.lastSoldAt != null ||
                          plan?.oldestStockAt != null))
                    DrawerLabelValue(
                      label: health.lastSoldAt == null
                          ? 'Oldest stock age'
                          : 'Days since last sale',
                      value:
                          '${DateTime.now().difference((health.lastSoldAt ?? plan!.oldestStockAt!)).inDays} days · threshold ${health.deadStock ? snapshot.settings.deadStockDays : snapshot.settings.slowMovingDays} days',
                    ),
                  if (health.newestStockAt != null)
                    DrawerLabelValue(
                        label: 'Newest remaining stock',
                        value:
                            '${DateTime.now().difference(health.newestStockAt!).inDays} days'),
                  for (final bucket
                      in health.aging.where((b) => b.quantityMilli > 0))
                    DrawerLabelValue(
                        label: bucket.label,
                        value:
                            '${Quantity.format(bucket.quantityMilli)} $unit'),
                  if (product.business.batch) ...[
                    DrawerLabelValue(
                        label: 'Near expiry',
                        value:
                            '${Quantity.format(health.nearExpiryMilli)} $unit'),
                    DrawerLabelValue(
                        label: 'Expired',
                        value: '${Quantity.format(health.expiredMilli)} $unit'),
                  ],
                ] else
                  const Text('No sales activity available yet.'),
              ],
            ),
          ),
          DrawerSection(
              title: 'Product information',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DrawerLabelValue(
                      label: 'SKU',
                      value: product.sku?.isNotEmpty == true
                          ? product.sku!
                          : 'Not set'),
                  DrawerLabelValue(
                      label: 'Barcode',
                      value: product.barcode?.isNotEmpty == true
                          ? product.barcode!
                          : 'Not set'),
                  DrawerLabelValue(
                      label: 'Category',
                      value: categories
                              .where((c) => c.id == product.categoryId)
                              .firstOrNull
                              ?.name ??
                          'None'),
                  if (product.business.weight)
                    const DrawerStatusBadge('Weight'),
                  if (product.business.refill)
                    const DrawerStatusBadge('Refill'),
                  if (product.business.tank) const DrawerStatusBadge('LPG'),
                  if (product.business.madeToOrder)
                    const DrawerStatusBadge('Made to order'),
                ],
              )),
          ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Stock layers'),
              children: [
                FutureBuilder<
                    (
                      List<InventoryLayer>,
                      Map<String, String>,
                      Map<String, String?>
                    )>(
                  future: (() async {
                    final layers =
                        await widget.repository.layersForProduct(product.id);
                    final suppliers =
                        await widget.repository.layerSupplierNames(product.id);
                    final references = <String, String?>{};
                    for (final layer in layers) {
                      references[layer.id] = await widget.repository
                          .layerReceivingReference(layer.id);
                    }
                    return (layers, suppliers, references);
                  })(),
                  builder: (context, value) {
                    final live = (value.data?.$1 ?? <InventoryLayer>[])
                        .where((layer) => layer.quantityRemainingMilli > 0)
                        .toList();
                    return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (live.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Text('No stock on hand.'),
                            )
                          else
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: DataTable(
                                headingRowHeight: 40,
                                dataRowMinHeight: 40,
                                dataRowMaxHeight: 52,
                                columnSpacing: 18,
                                columns: [
                                  const DataColumn(
                                      label: Text('Layer / Batch')),
                                  const DataColumn(label: Text('Available')),
                                  const DataColumn(label: Text('Cost')),
                                  if (product.pricingPolicy == 'layer')
                                    const DataColumn(label: Text('Selling')),
                                  const DataColumn(label: Text('Unit')),
                                  const DataColumn(label: Text('Received')),
                                  const DataColumn(label: Text('Expiry')),
                                ],
                                rows: [
                                  for (final layer in live)
                                    DataRow(cells: [
                                      DataCell(Text(layer.batchNumber ??
                                          value.data?.$3[layer.id] ??
                                          (layer.source == 'opening'
                                              ? 'Opening stock'
                                              : value.data?.$2[layer.id] ??
                                                  'Received stock'))),
                                      DataCell(Text(
                                          '${Quantity.format(layer.quantityRemainingMilli)} ${product.business.unit.label}')),
                                      DataCell(Text(
                                          '${money(layer.unitCostCents)}/${product.business.unit.label}')),
                                      if (product.pricingPolicy == 'layer')
                                        DataCell(Text(layer
                                                    .unitSellingPriceCents ==
                                                null
                                            ? '—'
                                            : '${money(layer.unitSellingPriceCents!)}/${product.business.unit.label}')),
                                      DataCell(
                                          Text(product.business.unit.label)),
                                      DataCell(Text(MaterialLocalizations.of(
                                              context)
                                          .formatMediumDate(layer.receivedAt))),
                                      DataCell(Text(layer.expiryDate == null
                                          ? '—'
                                          : MaterialLocalizations.of(context)
                                              .formatMediumDate(
                                                  layer.expiryDate!))),
                                    ]),
                                ],
                              ),
                            ),
                        ]);
                  },
                )
              ]),
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
                    await widget.repository.layersForProduct(product.id),
                  ))(),
              builder: (context, value) => ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title:
                    Text('AVAILABLE SERIALS (${value.data?.$1.length ?? 0})'),
                children: [
                  if ((value.data?.$1 ?? const <SerialUnit>[]).isEmpty)
                    const ListTile(title: Text('No available serials.'))
                  else
                    SizedBox(
                        height: (value.data?.$1.length ?? 0) > 4
                            ? 240
                            : ((value.data?.$1.length ?? 0) * 48 + 40)
                                .toDouble(),
                        child: SingleChildScrollView(
                            child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            headingRowHeight: 40,
                            dataRowMinHeight: 40,
                            dataRowMaxHeight: 48,
                            columnSpacing: 18,
                            columns: const [
                              DataColumn(label: Text('Serial')),
                              DataColumn(label: Text('Status')),
                              DataColumn(label: Text('Cost')),
                              DataColumn(label: Text('Selling')),
                              DataColumn(label: Text('Source')),
                              DataColumn(label: Text('Received')),
                            ],
                            rows: (value.data?.$1 ?? <SerialUnit>[])
                                .map((serial) {
                              final layer = value.data?.$2
                                  .where((l) => l.id == serial.inventoryLayerId)
                                  .firstOrNull;
                              return DataRow(cells: [
                                DataCell(Text(serial.serialNumber)),
                                DataCell(Text(serial.status)),
                                DataCell(Text(layer == null
                                    ? '—'
                                    : money(layer.unitCostCents))),
                                DataCell(Text(product.pricingPolicy == 'layer'
                                    ? (layer?.unitSellingPriceCents == null
                                        ? '—'
                                        : money(layer!.unitSellingPriceCents!))
                                    : money(product.priceCents))),
                                DataCell(Text(layer?.source == 'opening'
                                    ? 'Opening stock'
                                    : 'Supplier receiving')),
                                DataCell(Text(layer == null
                                    ? '—'
                                    : MaterialLocalizations.of(context)
                                        .formatMediumDate(layer.receivedAt))),
                              ]);
                            }).toList(),
                          ),
                        ))),
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
        primaryAction: FilledButton(
            onPressed: () {
              Navigator.pop(context);
              edit(product);
            },
            child: const Text('Edit product')),
        secondaryActions: [
          OutlinedButton(
              onPressed: () {
                Navigator.pop(context);
                showLabelPrintDialog(context, widget.repository.db,
                    [LabelItem(product, 1)], products: widget.repository,
                    actorId: widget.auth.current?.id);
              },
              child: const Text('Print label')),
          OutlinedButton(
              onPressed: () {
                Navigator.pop(context);
                _editPlanning(product, plan);
              },
              child: const Text('Reorder settings')),
          if (widget.onReceiveStock != null && !product.business.madeToOrder)
            OutlinedButton(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onReceiveStock!(product.id);
                },
                child: const Text('Receive stock')),
          if (widget.onCreatePurchaseOrder != null &&
              !product.business.madeToOrder)
            OutlinedButton(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onCreatePurchaseOrder!(product.id);
                },
                child: const Text('Create Purchase Order')),
        ],
        tertiaryAction: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ),
    );
  }

  Future<void> _editPlanning(
      PosProduct product, InventoryPlanningRow? plan) async {
    final suppliers =
        await widget.repository.db.select(widget.repository.db.suppliers).get();
    if (!mounted) return;
    String? supplierId = plan?.preferredSupplierId;
    final reorder = TextEditingController(
        text: plan?.reorderLevelMilli == null
            ? ''
            : Quantity.format(plan!.reorderLevelMilli!));
    final target = TextEditingController(
        text: plan?.targetStockMilli == null
            ? ''
            : Quantity.format(plan!.targetStockMilli!));
    String? errorText;
    try {
      await showDialog<void>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: Text('Reorder settings · ${product.name}'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: reorder,
                          decoration: const InputDecoration(
                              labelText: 'Reorder level')),
                      TextField(
                          controller: target,
                          decoration:
                              const InputDecoration(labelText: 'Target stock')),
                      DropdownButtonFormField<String?>(
                        initialValue: suppliers.any((s) => s.id == supplierId)
                            ? supplierId
                            : null,
                        decoration: const InputDecoration(
                            labelText: 'Preferred supplier'),
                        items: [
                          const DropdownMenuItem<String?>(
                              value: null, child: Text('None')),
                          for (final supplier in suppliers
                              .where((s) => s.isActive || s.id == supplierId))
                            DropdownMenuItem<String?>(
                                value: supplier.id, child: Text(supplier.name))
                        ],
                        onChanged: (value) => update(() => supplierId = value),
                      ),
                      if (errorText != null)
                        Text(errorText!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () async {
                            final r = reorder.text.trim().isEmpty
                                ? null
                                : reorder.text.trim() == '0'
                                    ? 0
                                    : Quantity.tryParse(reorder.text,
                                        fractional:
                                            product.business.fractional);
                            final t = target.text.trim().isEmpty
                                ? null
                                : target.text.trim() == '0'
                                    ? 0
                                    : Quantity.tryParse(target.text,
                                        fractional:
                                            product.business.fractional);
                            if ((reorder.text.trim().isNotEmpty && r == null) ||
                                (target.text.trim().isNotEmpty && t == null)) {
                              update(
                                  () => errorText = 'Enter valid quantities');
                              return;
                            }
                            try {
                              await InventoryPlanningRepository(
                                      widget.repository.db)
                                  .saveSettings(product.id,
                                      reorderLevelMilli: r,
                                      targetStockMilli: t,
                                      preferredSupplierId: supplierId);
                              if (context.mounted) Navigator.pop(context);
                              await refresh();
                            } catch (e) {
                              update(() => errorText = safeMessage(e));
                            }
                          },
                          child: const Text('Save')),
                    ],
                  )));
    } finally {
      reorder.dispose();
      target.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: AppWorkspacePadding(
            child: ListView(padding: EdgeInsets.zero, children: [
          AppPageHeader(
              title: 'Products',
              subtitle:
                  'Manage products, stock visibility, and catalog details.',
              action: FilledButton.icon(
                  onPressed: () => edit(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add product'))),
          if (error != null)
            Text(error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          Wrap(spacing: 8, children: [
            PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (value) {
                  if (value == 'categories') addCategory();
                },
                itemBuilder: (context) => const [
                      PopupMenuItem(
                          value: 'categories', child: Text('Manage categories'))
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
              'Reorder',
              'Incoming',
              'Slow moving',
              'Dead stock',
              'Never sold',
              'Near expiry',
              'Expired',
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
                      (p.barcode ?? '').toLowerCase().contains(search) ||
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
                      (filter == 'Reorder' && p.isActive) ||
                      (filter == 'Incoming' && p.isActive) ||
                      (filter == 'Slow moving' && p.isActive) ||
                      (filter == 'Dead stock' && p.isActive) ||
                      (filter == 'Never sold' && p.isActive) ||
                      (filter == 'Near expiry' && p.isActive) ||
                      (filter == 'Expired' && p.isActive) ||
                      (filter == 'Serialized' && p.serialTracking) ||
                      (filter == 'Batch tracked' && p.business.batch) ||
                      filter == 'Low stock'))
              .map((p) {
            final available =
                (stockLevels[p.id]?.$1 ?? 0) - (stockLevels[p.id]?.$2 ?? 0);
            final plan = planning[p.id];
            final health = inventoryHealth[p.id];
            final narrow = MediaQuery.sizeOf(context).width < 700;
            return (filter == 'Low stock' &&
                        (available <= 0 ||
                            available >
                                p.lowStockThreshold * Quantity.scale)) ||
                    (filter == 'Out of stock' && available > 0) ||
                    (filter == 'Reorder' &&
                        (plan == null || !plan.belowReorderLevel)) ||
                    (filter == 'Incoming' &&
                        (plan == null || plan.incomingMilli <= 0)) ||
                    (filter == 'Slow moving' && health?.slowMoving != true) ||
                    (filter == 'Dead stock' && health?.deadStock != true) ||
                    (filter == 'Never sold' &&
                        (health?.neverSold != true || available <= 0)) ||
                    (filter == 'Near expiry' &&
                        (health?.nearExpiryMilli ?? 0) <= 0) ||
                    (filter == 'Expired' && (health?.expiredMilli ?? 0) <= 0)
                ? const SizedBox.shrink()
                : Card(
                    child: ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    onTap: () => showProduct(p),
                    title: Text(p.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
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
                          if (plan != null && plan.incomingMilli > 0)
                            Text(
                                '${Quantity.format(plan.incomingMilli)} ${p.business.unit.label} incoming'),
                          const SizedBox(height: 4),
                          Wrap(spacing: 6, runSpacing: 4, children: [
                            if (p.serialTracking) _badge('Serialized'),
                            if (p.business.batch) _badge('Batch'),
                            if (p.business.weight) _badge('Weight'),
                            if (p.business.refill) _badge('Refill'),
                            if (p.business.tank) _badge('LPG'),
                            if (p.business.madeToOrder) _badge('MTO'),
                            if (plan?.belowReorderLevel == true)
                              _badge(plan!.incomingCoversShortage
                                  ? 'Incoming covers shortage'
                                  : 'Reorder needed'),
                            if (health?.deadStock == true)
                              _badge('Dead stock')
                            else if (health?.slowMoving == true)
                              _badge('Slow moving'),
                            if (health?.neverSold == true && available > 0)
                              _badge('Never sold'),
                            if ((health?.expiredMilli ?? 0) > 0)
                              _badge('Expired'),
                            if ((health?.nearExpiryMilli ?? 0) > 0)
                              _badge('Near expiry'),
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
                                const Icon(Icons.chevron_right, size: 18),
                              ]),
                  ));
          }),
        ])),
      );
}
