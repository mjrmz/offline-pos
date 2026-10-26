import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:io';
import '../../shared/theme/theme_mode_controller.dart';
import '../../shared/theme/app_layout.dart';
import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/sales_service.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/sales_repository.dart';
import '../pos_checkout/checkout_screen.dart';
import '../pos_checkout/pos_layout_preference.dart';
import '../pos_checkout/pos_shift.dart';
import '../sales_history/sales_history_screen.dart';
import '../reports/reports_screen.dart';
import '../../hardware/printer/receipt_service.dart';
import '../../data/daos/printer_settings_repository.dart';
import '../../hardware/printer/receipt_printer.dart';
import '../../hardware/printer/device_transports.dart';
import '../../hardware/cash_drawer/cash_drawer.dart';
import '../settings/business_settings_home_screen.dart';
import '../../data/daos/business_feature_repository.dart';
import '../cash_session/cash_session_screen.dart';
import '../../data/daos/cash_session_repository.dart';
import '../../shared/utils/safe_message.dart';
import '../../data/daos/directory_repository.dart';
import '../contacts/contacts_screen.dart';
import '../contacts/rma_screen.dart';
import '../../data/daos/rma_repository.dart';
import '../../data/daos/serial_lifecycle_repository.dart';
import '../inventory/serial_explorer.dart';
import '../inventory/serial_lifecycle_navigation.dart';
import '../contacts/quotation_screen.dart';
import '../contacts/sales_orders_screen.dart';
import '../../data/daos/sales_order_repository.dart';
import '../../data/daos/quotation_repository.dart';
import '../contacts/layaway_screen.dart';
import '../promotions/promotions_screen.dart';
import '../../data/daos/promotion_repository.dart';
import '../../data/daos/layaway_repository.dart';
import '../../data/daos/petty_cash_repository.dart';
import '../cash_session/petty_cash_screen.dart';
import '../inventory/inventory_workspace.dart';
import '../inventory/expiry_monitor_screen.dart';
import '../../data/daos/inventory_health_repository.dart';
import '../../data/daos/operational_summary_repository.dart';
import '../reports/operational_summary_screen.dart';
import '../../shared/utils/money.dart';
import '../../data/daos/global_search_repository.dart';
import 'global_command_palette.dart';
import 'dashboard_screen.dart';
import 'dashboard_repository.dart';
import '../audit/audit_explorer_screen.dart';
import '../../data/daos/audit_explorer_repository.dart';

class HomeScreen extends StatefulWidget {
  final AuthService auth;
  final PosRepository pos;
  final SalesRepository salesRepository;
  final VoidCallback onChanged;
  final Future<void> Function(String)? refreshLicense;
  final Widget? recoveryScreen;
  const HomeScreen(
      {super.key,
      required this.auth,
      required this.pos,
      required this.salesRepository,
      required this.onChanged,
      this.refreshLicense,
      this.recoveryScreen});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int page = 0;
  String? openSaleId, openRmaId, openLayawayId;
  String? openCustomerId, openSupplierId, openReceiptId, catalogProductId;
  String? inventoryTarget;
  bool createPurchaseOrderOnOpen = false;
  bool createQuotationOnOpen = false;
  bool _paletteOpen = false;
  String? receivingProductId;
  String? receivingSupplierId;
  int? receivingSuggestedQuantityMilli;
  String? receivingQuotationReference;
  String? purchaseProductId;
  String? purchaseSupplierId;
  int? purchaseQuantityMilli;
  String? purchaseQuotationReference;
  String? purchaseExistingOrderId;
  String? purchaseViewOrderId;
  List<({String productId, int quantityMilli})>? purchaseLines;
  String? openQuotationReference;
  String? openSalesOrderReference;
  String? inventoryFilter;
  bool _posSidebarExpanded = false;
  String _businessName = 'Vertex POS';
  bool _posFocused = false;
  Timer? _shiftTimer;
  StreamSubscription<dynamic>? _shiftChanges;
  late final CashSessionRepository _cashSessions = CashSessionRepository(
      widget.pos.db,
      birEntitled: () => widget.pos.birReady,
      protection: widget.pos.protection);
  Future<CashSessionSummary?>? _shiftStatus;
  CashSessionSummary? _lastShift;
  String? _shiftError;
  int _shiftRefreshRevision = 0;
  final _checkoutKey = GlobalKey<CheckoutScreenState>();
  final _dashboardKey = GlobalKey<DashboardScreenState>();
  final _accountFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadBusinessName();
    PosLayoutPreference.instance.addListener(_workspacePreferenceChanged);
    PosLayoutPreference.instance.load().then((_) {
      if (mounted && page == _labelsFor(widget.auth.current!).indexOf('POS')) {
        setState(() => _posFocused = PosLayoutPreference.instance.startFocused);
      }
    });
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() =>
            _posSidebarExpanded = prefs.getBool('sidebarExpanded') ?? false);
      }
    });
    _shiftStatus = _loadShift().then((shift) {
      if (mounted) setState(() => _lastShift = shift);
      return shift;
    });
    if (widget.auth.current!.can(PosPermission.sell) ||
        widget.auth.current!.can(PosPermission.manageCashSession)) {
      _shiftChanges = _cashSessions
          .watchCurrentFor(widget.auth.current!.id)
          .listen((_) => _refreshShift(), onError: (Object error) {
        if (mounted) setState(() => _shiftError = error.toString());
      });
      _shiftTimer =
          Timer.periodic(const Duration(seconds: 15), (_) => _refreshShift());
    }
  }

  @override
  void dispose() {
    _accountFocusNode.dispose();
    PosLayoutPreference.instance.removeListener(_workspacePreferenceChanged);
    _shiftTimer?.cancel();
    _shiftChanges?.cancel();
    super.dispose();
  }

  void _workspacePreferenceChanged() {
    if (mounted) setState(() {});
  }

  void _togglePosFocus() {
    if (page == _labelsFor(widget.auth.current!).indexOf('POS')) {
      setState(() => _posFocused = !_posFocused);
    }
  }

  void _setSidebarExpanded(bool expanded) {
    setState(() => _posSidebarExpanded = expanded);
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setBool('sidebarExpanded', expanded));
  }

  Future<void> _loadBusinessName() async {
    try {
      final settings = await PrinterSettingsStore(widget.pos.db).load();
      if (mounted) {
        setState(() => _businessName = settings.storeName.trim().isEmpty
            ? 'Vertex POS'
            : settings.storeName.trim());
      }
    } catch (_) {
      // The brand header can safely use the application name until settings load.
    }
  }

  Future<CashSessionSummary?> _loadShift() async {
    if (!widget.auth.current!.can(PosPermission.sell) &&
        !widget.auth.current!.can(PosPermission.manageCashSession)) {
      return null;
    }
    final userId = widget.auth.current!.id;
    final own = await _cashSessions.currentFor(userId);
    if (own != null) return own;
    final other = await _cashSessions.active();
    return other == null
        ? null
        : CashSessionSummary(
            other, await _cashSessions.expected(other.id), null);
  }

  Future<void> _refreshShift() async {
    final revision = ++_shiftRefreshRevision;
    CashSessionSummary? shift;
    try {
      shift = await _loadShift();
    } catch (error) {
      if (mounted && revision == _shiftRefreshRevision) {
        setState(() => _shiftError = error.toString());
      }
      return;
    }
    if (!mounted || revision != _shiftRefreshRevision) return;
    if (_shiftError != null) setState(() => _shiftError = null);
    final previous = _lastShift;
    if (previous?.session.id == shift?.session.id &&
        previous?.expectedCents == shift?.expectedCents &&
        previous?.session.closedAt == shift?.session.closedAt) {
      return;
    }
    _lastShift = shift;
    if (previous?.session.id == shift?.session.id) {
      setState(() {});
      return;
    }
    setState(() {
      _shiftStatus = Future.value(shift);
    });
  }

  void _go(int index) {
    _loadBusinessName();
    if (index < 0 || index >= _labelsFor(widget.auth.current!).length) return;
    setState(() {
      if (page == _labelsFor(widget.auth.current!).indexOf('Quotations') &&
          index != page) {
        createQuotationOnOpen = false;
      }
      final enteringPos =
          page != _labelsFor(widget.auth.current!).indexOf('POS') &&
              index == _labelsFor(widget.auth.current!).indexOf('POS');
      final inventoryIndex =
          _labelsFor(widget.auth.current!).indexOf('Inventory');
      if (page == inventoryIndex && index != inventoryIndex) {
        inventoryTarget = null;
        openReceiptId = null;
        catalogProductId = null;
        createPurchaseOrderOnOpen = false;
        purchaseProductId = null;
        purchaseSupplierId = null;
        purchaseQuantityMilli = null;
        purchaseQuotationReference = null;
        purchaseExistingOrderId = null;
        purchaseViewOrderId = null;
        purchaseLines = null;
      }
      page = index;
      if (index != _labelsFor(widget.auth.current!).indexOf('POS')) {
        _posFocused = false;
      }
      if (enteringPos) {
        _posFocused = PosLayoutPreference.instance.startFocused;
      }
    });
    _refreshShift();
    if (index == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _dashboardKey.currentState?.refresh();
      });
    }
  }

  void _goLabel(String label) {
    final index = _labelsFor(widget.auth.current!).indexOf(label);
    if (index >= 0) _go(index);
  }

  void _dashboardGo(String target) {
    if (target == 'Low stock' || target == 'Out of stock') {
      final user = widget.auth.current!;
      if (user.can(PosPermission.manageCatalog)) {
        setState(() {
          inventoryTarget = 'Products';
          inventoryFilter = target;
        });
      }
      _goLabel('Inventory');
      return;
    }
    if (target == 'Expiry Monitor') {
      final user = widget.auth.current!;
      if (user.can(PosPermission.manageCatalog) ||
          user.can(PosPermission.stockCount) ||
          user.can(PosPermission.stockReceiving)) {
        Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => ExpiryMonitorScreen(
                repository: InventoryHealthRepository(widget.pos.db),
                user: user)));
      }
      return;
    }
    if (target == 'Receiving' ||
        target == 'Purchase Orders' ||
        target == 'Stock Counts') {
      setState(() => inventoryTarget = target);
      _goLabel('Inventory');
      return;
    }
    _goLabel(target);
  }

  Future<void> _openGlobalSearch() async {
    if (_paletteOpen || !mounted || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final checkout = _checkoutKey.currentState;
    if (checkout != null &&
        checkout.barcodeFocus.hasFocus &&
        checkout.barcodeController.text.isNotEmpty) {
      return;
    }
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    final editing = focusedContext?.widget is EditableText ||
        focusedContext?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (editing && (checkout == null || !checkout.barcodeFocus.hasFocus)) {
      return;
    }
    _paletteOpen = true;
    try {
      final selected = await showDialog<GlobalSearchResult>(
          context: context,
          builder: (_) => GlobalCommandPalette(
              repository: GlobalSearchRepository(widget.pos.db),
              user: widget.auth.current!));
      if (selected != null && mounted) await _activateSearchResult(selected);
    } finally {
      _paletteOpen = false;
    }
  }

  Future<void> _activateSearchResult(GlobalSearchResult result) async {
    final user = widget.auth.current!;
    switch (result.kind) {
      case GlobalSearchKind.command:
        switch (result.id) {
          case 'New Sale':
            _goLabel('POS');
          case 'Receive Stock':
            setState(() {
              inventoryTarget = 'Receiving';
              openReceiptId = null;
            });
            _goLabel('Inventory');
          case 'Create Purchase Order':
            setState(() {
              inventoryTarget = 'Purchase Orders';
              createPurchaseOrderOnOpen = true;
              purchaseViewOrderId = null;
            });
            _goLabel('Inventory');
          case 'Create Quotation':
            setState(() {
              createQuotationOnOpen = true;
              openQuotationReference = null;
            });
            _goLabel('Quotations');
          case 'Open Inventory':
            _goLabel('Inventory');
          case 'Open Customers':
            _goLabel('Customers & Suppliers');
          case 'Open Reports':
            _goLabel('Reports');
          case 'Open Cash Session':
            _goLabel('Cash session');
          case 'Open Settings':
            _goLabel('Settings');
        }
      case GlobalSearchKind.product:
        if (user.can(PosPermission.manageCatalog)) {
          setState(() {
            catalogProductId = result.id;
            inventoryTarget = 'Products';
          });
          _goLabel('Inventory');
        } else if (user.can(PosPermission.sell)) {
          _goLabel('POS');
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _checkoutKey.currentState?.openProductLookup(result.title);
            }
          });
        } else if (user.can(PosPermission.stockReceiving)) {
          setState(() {
            receivingProductId = result.id;
            inventoryTarget = 'Receiving';
          });
          _goLabel('Inventory');
        }
      case GlobalSearchKind.customer:
        setState(() {
          openCustomerId = result.id;
          openSupplierId = null;
        });
        _goLabel('Customers & Suppliers');
      case GlobalSearchKind.supplier:
        setState(() {
          openSupplierId = result.id;
          openCustomerId = null;
        });
        _goLabel('Customers & Suppliers');
      case GlobalSearchKind.sale:
        setState(() => openSaleId = result.id);
        _goLabel('Sales History');
      case GlobalSearchKind.serial:
        if (user.can(PosPermission.stockReceiving)) {
          Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => SerialExplorer(
                  repository: SerialLifecycleRepository(widget.pos.db),
                  user: user,
                  initialSerialId: result.id,
                  canOpenRecord: (event) => canOpenSerialRecord(event, user),
                  onOpenRecord: (event) => openSerialRecord(
                      context, event, user, widget.auth, widget.pos))));
        }
      case GlobalSearchKind.quotation:
        setState(() {
          openQuotationReference = result.reference;
          createQuotationOnOpen = false;
        });
        _goLabel('Quotations');
      case GlobalSearchKind.salesOrder:
        setState(() => openSalesOrderReference = result.reference);
        _goLabel('Sales Orders');
      case GlobalSearchKind.layaway:
        setState(() => openLayawayId = result.id);
        _goLabel('Layaway');
      case GlobalSearchKind.purchaseOrder:
        setState(() {
          purchaseViewOrderId = result.id;
          inventoryTarget = 'Purchase Orders';
          createPurchaseOrderOnOpen = false;
        });
        _goLabel('Inventory');
      case GlobalSearchKind.receiving:
        setState(() {
          openReceiptId = result.id;
          inventoryTarget = 'Receiving';
        });
        _goLabel('Inventory');
      case GlobalSearchKind.rma:
        setState(() => openRmaId = result.id);
        _goLabel('RMA / Warranty');
    }
  }

  Future<void> _showShift(CashSessionSummary shift, ActiveUser user) async {
    if (shift.session.openedByUserId != user.id) {
      _go(_labelsFor(user).indexOf('Cash session'));
      return;
    }
    final action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('CURRENT SHIFT'),
                content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Opened by ${user.name}'),
                      Text(
                          'Opened ${MaterialLocalizations.of(context).formatMediumDate(shift.session.openedAt.toLocal())} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(shift.session.openedAt.toLocal()))}'),
                      Text(
                          'Opening cash ${formatPeso(shift.session.startingCashCents)}'),
                      Text('Expected cash ${formatPeso(shift.expectedCents)}'),
                    ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, 'details'),
                      child: const Text('View details')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, 'close'),
                      child: const Text('Close shift')),
                ]));
    if (!mounted) return;
    if (action == 'details') _go(_labelsFor(user).indexOf('Cash session'));
    if (action == 'close') {
      if (_checkoutKey.currentState?.hasActiveCart == true) {
        await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('Current sale has items'),
                    content: const Text(
                        'Finish or clear the current sale before closing the shift.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Back to sale'))
                    ]));
        return;
      }
      final latest = await _cashSessions.currentFor(user.id);
      if (!mounted || latest == null || latest.session.id != shift.session.id) {
        _refreshShift();
        return;
      }
      if (!mounted) return;
      if (await showPosCloseShift(context, _cashSessions, user, latest)) {
        _refreshShift();
      }
    }
  }

  late final settings = PrinterSettingsStore(widget.pos.db);
  late final deviceClient = PluginPrinterClient();
  late final transport = ConfiguredPrinterTransport(LanEscPosTransport(),
      UsbEscPosTransport(deviceClient), BluetoothEscPosTransport(deviceClient));
  Future<void> _refreshLicenseDialog() async {
    widget.auth.requireSession(PosPermission.refreshLicense);
    // MenuAnchor removes its overlay before this callback's next frame.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final key = await showDialog<String>(
        context: context, builder: (_) => const _RefreshLicenseDialog());
    if (key == null || key.trim().isEmpty || !mounted) return;
    try {
      await widget.refreshLicense?.call(key);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('License refreshed')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(safeMessage(error))));
      }
    }
  }

  Future<void> _sessionAction(bool lock) async {
    if (lock) {
      await widget.auth.lock();
    } else {
      await widget.auth.logout();
    }
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.auth.current!;
    final sales = SalesService(widget.salesRepository, widget.auth);
    final printer = EscPosReceiptPrinter(transport);
    final receipts =
        ReceiptService(sales, settings, printer, EscPosCashDrawer(transport));
    final pages = <Widget>[
      DashboardScreen(
          key: _dashboardKey,
          user: user,
          repository: DashboardRepository(widget.pos.db),
          shift: _lastShift,
          navigate: _dashboardGo),
      if (user.can(PosPermission.sell))
        FutureBuilder<CashSessionSummary?>(
            future: _shiftStatus,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (_shiftError != null || snapshot.hasError) {
                return Center(
                    child: Text(_shiftError ?? snapshot.error.toString()));
              }
              final shift = _lastShift ?? snapshot.data;
              if (shift == null || shift.session.openedByUserId != user.id) {
                return PosShiftClosed(
                    user: user,
                    repository: _cashSessions,
                    otherUser: shift == null ? null : 'Another user',
                    onOpened: _refreshShift,
                    onSessions: () =>
                        _go(_labelsFor(user).indexOf('Cash session')));
              }
              return CheckoutScreen(
                  key: _checkoutKey,
                  focusMode: _posFocused,
                  onToggleFocus: _togglePosFocus,
                  repository: widget.pos,
                  user: user,
                  auth: widget.auth,
                  receipts: receipts);
            }),
      if (user.can(PosPermission.viewOwnSales))
        SalesHistoryScreen(
            key: ValueKey(('sale', openSaleId)),
            sales: sales,
            user: user,
            initialSaleId: openSaleId,
            active: page == _labelsFor(user).indexOf('Sales History'),
            receipts: receipts,
            pos: widget.pos),
      if (user.can(PosPermission.reports))
        ReportsScreen(
            sales: sales, active: page == _labelsFor(user).indexOf('Reports')),
      if (user.can(PosPermission.manageUsers))
        AuditExplorerScreen(repository: AuditExplorerRepository(widget.pos.db),
            user: user, auth: widget.auth, products: widget.pos),
      if (user.can(PosPermission.manageSettings) ||
          user.can(PosPermission.manageUsers) ||
          user.can(PosPermission.managePrinter) ||
          user.can(PosPermission.manageRecovery))
        BusinessSettingsHomeScreen(
            repository: BusinessFeatureRepository(widget.pos.db),
            user: user,
            auth: widget.auth,
            printerStore: settings,
            printer: printer,
            devices: deviceClient,
            recoveryScreen: widget.recoveryScreen),
      if (user.can(PosPermission.viewContacts))
        ContactsScreen(
            key: ValueKey(('contacts', openCustomerId, openSupplierId)),
            repository: DirectoryRepository(widget.pos.db),
            user: user,
            initialCustomerId: openCustomerId,
            initialSupplierId: openSupplierId,
            sales: sales,
            pos: widget.pos,
            receipts: receipts),
      if (user.can(PosPermission.manageRma))
        RmaScreen(
            key: ValueKey(('rma', openRmaId)),
            repository: RmaRepository(widget.pos.db),
            user: user,
            initialCaseId: openRmaId),
      if (user.can(PosPermission.manageQuotations))
        QuotationScreen(
            key: ValueKey((
              'quotations',
              page,
              openQuotationReference,
              createQuotationOnOpen
            )),
            repository: QuotationRepository(widget.pos.db, widget.pos),
            directory: DirectoryRepository(widget.pos.db),
            products: widget.pos,
            user: user,
            auth: widget.auth,
            receipts: receipts,
            initialQuotationReference: openQuotationReference,
            createOnOpen: createQuotationOnOpen,
            onReceiveStock: user.can(PosPermission.stockReceiving)
                ? (productId, supplierId, quantityMilli, quotationReference) {
                    setState(() {
                      receivingProductId = productId;
                      receivingSupplierId = supplierId;
                      receivingSuggestedQuantityMilli = quantityMilli;
                      receivingQuotationReference = quotationReference;
                      inventoryFilter = null;
                    });
                    _go(_labelsFor(user).indexOf('Inventory'));
                  }
                : null,
            onCreatePurchaseOrder: user.can(PosPermission.stockReceiving)
                ? (productId, supplierId, quantityMilli, quotationReference) {
                    setState(() {
                      purchaseProductId = productId;
                      purchaseSupplierId = supplierId;
                      purchaseQuantityMilli = quantityMilli;
                      purchaseQuotationReference = quotationReference;
                      purchaseExistingOrderId = null;
                      purchaseViewOrderId = null;
                      purchaseLines = null;
                    });
                    _go(_labelsFor(user).indexOf('Inventory'));
                  }
                : null,
            onAddToPurchaseOrder: user.can(PosPermission.stockReceiving)
                ? (orderId, productId, quantityMilli, quotationReference) {
                    setState(() {
                      purchaseExistingOrderId = orderId;
                      purchaseViewOrderId = null;
                      purchaseLines = null;
                      purchaseProductId = productId;
                      purchaseQuantityMilli = quantityMilli;
                      purchaseQuotationReference = quotationReference;
                    });
                    _go(_labelsFor(user).indexOf('Inventory'));
                  }
                : null,
            onViewPurchaseOrder: user.can(PosPermission.stockReceiving)
                ? (orderId, quotationReference) {
                    setState(() {
                      purchaseViewOrderId = orderId;
                      purchaseExistingOrderId = null;
                      purchaseProductId = null;
                      purchaseLines = null;
                      purchaseQuotationReference = quotationReference;
                    });
                    _go(_labelsFor(user).indexOf('Inventory'));
                  }
                : null,
            onCreatePurchaseOrderForLines:
                user.can(PosPermission.stockReceiving)
                    ? (lines, supplierId, quotationReference) {
                        setState(() {
                          purchaseLines = lines;
                          purchaseProductId = null;
                          purchaseExistingOrderId = null;
                          purchaseViewOrderId = null;
                          purchaseSupplierId = supplierId;
                          purchaseQuotationReference = quotationReference;
                        });
                        _go(_labelsFor(user).indexOf('Inventory'));
                      }
                    : null),
      if (user.can(PosPermission.viewSalesOrders))
        SalesOrdersScreen(
            key: ValueKey(('sales-orders', openSalesOrderReference)),
            repository: SalesOrderRepository(widget.pos.db),
            directory: DirectoryRepository(widget.pos.db),
            products: widget.pos,
            user: user,
            auth: widget.auth,
            receipts: receipts,
            initialReference: openSalesOrderReference),
      if (user.can(PosPermission.manageLayaway))
        LayawayScreen(
            key: ValueKey(('layaway', openLayawayId)),
            repository: LayawayRepository(widget.pos.db, widget.pos),
            directory: DirectoryRepository(widget.pos.db),
            products: widget.pos,
            user: user,
            initialLayawayId: openLayawayId),
      if (user.can(PosPermission.viewPromotions))
        PromotionsScreen(
            repository: PromotionRepository(widget.pos.db), user: user),
      if (user.can(PosPermission.stockReceiving) ||
          user.can(PosPermission.stockCount) ||
          user.can(PosPermission.manageCatalog))
        InventoryWorkspace(
            key: ValueKey((
              receivingProductId,
              openReceiptId,
              catalogProductId,
              inventoryTarget,
              createPurchaseOrderOnOpen,
              receivingSupplierId,
              receivingSuggestedQuantityMilli,
              purchaseProductId,
              purchaseExistingOrderId,
              purchaseViewOrderId,
              purchaseLines,
              purchaseQuantityMilli,
              inventoryFilter,
              purchaseQuotationReference
            )),
            repository: widget.pos,
            auth: widget.auth,
            user: user,
            initialProductId: receivingProductId,
            initialCatalogProductId: catalogProductId,
            initialReceiptId: openReceiptId,
            createPurchaseOrderOnOpen: createPurchaseOrderOnOpen,
            initialSupplierId: receivingSupplierId,
            suggestedQuantityMilli: receivingSuggestedQuantityMilli,
            initialPurchaseProductId: purchaseProductId,
            initialPurchaseOrderId: purchaseExistingOrderId,
            initialPurchaseViewOrderId: purchaseViewOrderId,
            initialPurchaseLines: purchaseLines,
            initialPurchaseSupplierId: purchaseSupplierId,
            initialPurchaseQuantityMilli: purchaseQuantityMilli,
            initialPurchaseQuotationReference: purchaseQuotationReference,
            onOpenQuotation: (reference) {
              setState(() => openQuotationReference = reference);
              _go(_labelsFor(user).indexOf('Quotations'));
            },
            returnToQuotationReference:
                purchaseQuotationReference ?? receivingQuotationReference,
            onReturnToQuotation: purchaseQuotationReference == null &&
                    receivingQuotationReference == null
                ? null
                : () {
                    setState(() {
                      openQuotationReference = purchaseQuotationReference ??
                          receivingQuotationReference;
                      purchaseQuotationReference = null;
                      purchaseProductId = null;
                      purchaseSupplierId = null;
                      purchaseQuantityMilli = null;
                      purchaseExistingOrderId = null;
                      purchaseViewOrderId = null;
                      purchaseLines = null;
                      receivingQuotationReference = null;
                      receivingProductId = null;
                      receivingSupplierId = null;
                      receivingSuggestedQuantityMilli = null;
                    });
                    _go(_labelsFor(user).indexOf('Quotations'));
                  },
            initialFilter: inventoryFilter ?? 'All',
            initialView: inventoryTarget == 'Products'
                ? 1
                : inventoryTarget == 'Purchase Orders'
                    ? (user.can(PosPermission.manageCatalog) ? 2 : 1)
                    : inventoryTarget == 'Receiving'
                        ? (user.can(PosPermission.manageCatalog) ? 3 : 2)
                        : inventoryTarget == 'Stock Counts'
                            ? 1 +
                                (user.can(PosPermission.manageCatalog)
                                    ? 1
                                    : 0) +
                                (user.can(PosPermission.stockReceiving) ? 3 : 0)
                            : purchaseQuotationReference != null
                                ? (user.can(PosPermission.manageCatalog)
                                    ? 2
                                    : 1)
                                : inventoryFilter != null
                                    ? 1
                                    : receivingProductId == null
                                        ? 0
                                        : user.can(PosPermission.manageCatalog)
                                            ? 3
                                            : 2),
      if (user.can(PosPermission.reports))
        OperationalSummaryScreen(
            repository: OperationalSummaryRepository(widget.pos.db),
            user: user,
            onInventory: (filter) {
              setState(() => inventoryFilter = filter);
              _go(_labelsFor(user).indexOf('Inventory'));
            },
            onRma: () => _go(_labelsFor(user).indexOf('RMA / Warranty')),
            onExpiry: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ExpiryMonitorScreen(
                    repository: InventoryHealthRepository(widget.pos.db),
                    user: user))),
            onLayaway: () => _go(_labelsFor(user).indexOf('Layaway')),
            onCustomers: () =>
                _go(_labelsFor(user).indexOf('Customers & Suppliers'))),
      if (user.can(PosPermission.manageExpenses))
        PettyCashScreen(
            repository: PettyCashRepository(widget.pos.db), user: user),
      if (user.can(PosPermission.manageCashSession))
        CashSessionScreen(
            user: user,
            currentShift: _lastShift?.session.openedByUserId == user.id
                ? _lastShift
                : null,
            otherShift: _lastShift?.session.openedByUserId != user.id
                ? _lastShift
                : null,
            useSharedCurrent: true,
            showTitle: true,
            repository: _cashSessions,
            onGoPos: () => _goLabel('POS')),
    ];
    if (pages.isEmpty) {
      pages.add(
          const Center(child: Text('No features are assigned to this role.')));
    }
    final labels = _labelsFor(user);
    final selected = page.clamp(0, pages.length - 1);
    final groups = <(String, List<String>)>[
      ('HOME', ['Home']),
      (
        'SELL',
        [
          'POS',
          'Sales History',
          'Quotations',
          'Sales Orders',
          'Layaway',
          'Promotions'
        ]
      ),
      ('INVENTORY', ['Inventory']),
      ('CUSTOMERS', ['Customers & Suppliers', 'RMA / Warranty']),
      ('OPERATIONS', ['Operations', 'Expenses', 'Reports', 'Cash session']),
      ('ADMIN & SETTINGS', ['Audit Explorer', 'Settings']),
    ];
    final mobile = [
      'Home',
      if (labels.contains('POS')) 'POS',
      if (labels.contains('Sales History')) 'Sales History',
      if (labels.contains('Inventory')) 'Inventory',
      if (labels.contains('Customers & Suppliers')) 'Customers & Suppliers'
    ];
    IconData icon(String label) => switch (label) {
          'Home' => Icons.home_outlined,
          'POS' => Icons.point_of_sale,
          'Sales History' => Icons.receipt_long,
          'Inventory' => Icons.inventory_2,
          'Customers & Suppliers' => Icons.contacts,
          'RMA / Warranty' => Icons.assignment_return,
          'Quotations' => Icons.request_quote,
          'Sales Orders' => Icons.assignment_outlined,
          'Layaway' => Icons.inventory,
          'Promotions' => Icons.local_offer,
          'Operations' => Icons.dashboard,
          'Reports' => Icons.bar_chart,
          'Expenses' => Icons.receipt_long_outlined,
          'Cash session' => Icons.payments,
          'Settings' => Icons.settings,
          'Audit Explorer' => Icons.history,
          'Users & Roles' => Icons.people,
          'Printer & Receipt' => Icons.print,
          _ => Icons.health_and_safety,
        };
    final width = MediaQuery.sizeOf(context).width;
    final sidebarExpanded = _posSidebarExpanded;
    final focused = labels[selected] == 'POS' && _posFocused;
    final appearance = AppThemeController.maybeOf(context);
    final sidebarPreset =
        appearance?.effectiveSidebarColor ?? SidebarColorPreset.navy;
    final sidebarForeground = sidebarPreset.foreground;
    final sidebarMuted = sidebarForeground.withValues(alpha: .68);
    final sidebarLine = sidebarForeground.withValues(alpha: .13);
    final roleName =
        user.role.name[0].toUpperCase() + user.role.name.substring(1);
    final content = IndexedStack(index: selected, children: pages);
    final workspace = labels[selected] == 'POS'
        ? Column(children: [
            SizedBox(
                height: 48,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (width < 700)
                      IconButton(
                          key: const Key('pos-focus-toggle'),
                          tooltip: focused ? 'Exit focus mode' : 'Focus mode',
                          onPressed: _togglePosFocus,
                          icon: Icon(focused
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen))
                    else
                      TextButton.icon(
                          key: const Key('pos-focus-toggle'),
                          onPressed: _togglePosFocus,
                          icon: Icon(focused
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen),
                          label: Text(focused
                              ? 'Exit focus mode · F11'
                              : 'Focus mode')),
                    FutureBuilder<CashSessionSummary?>(
                        future: _shiftStatus,
                        builder: (context, snapshot) {
                          final shift = _shiftError == null &&
                                  !snapshot.hasError
                              ? snapshot.connectionState == ConnectionState.done
                                  ? (_lastShift ?? snapshot.data)
                                  : null
                              : null;
                          return TextButton.icon(
                              key: const Key('pos-shift-status'),
                              onPressed: () => shift == null
                                  ? _goLabel('POS')
                                  : _showShift(shift, user),
                              icon: Icon(
                                  shift != null
                                      ? Icons.circle
                                      : Icons.circle_outlined,
                                  size: 12),
                              label: Text(shift == null
                                  ? (_shiftError == null && !snapshot.hasError
                                      ? 'Shift closed'
                                      : 'Shift unavailable')
                                  : shift.session.openedByUserId == user.id
                                      ? 'Shift open · Expected ${formatPeso(shift.expectedCents)}'
                                      : 'Other shift open'));
                        }),
                    const SizedBox(width: 12),
                  ],
                )),
            Expanded(child: content),
          ])
        : content;
    final account = MenuAnchor(
      style: const MenuStyle(
          minimumSize: WidgetStatePropertyAll(Size(220, 0)),
          maximumSize: WidgetStatePropertyAll(Size(240, double.infinity))),
      builder: (context, controller, child) => Tooltip(
        message: '${user.name} · $roleName',
        child: Focus(
          focusNode: _accountFocusNode,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape &&
                controller.isOpen) {
              controller.close();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const Key('sidebar-account'),
                onTap: () {
                  _accountFocusNode.requestFocus();
                  controller.isOpen ? controller.close() : controller.open();
                },
                child: SizedBox(
                    height: 64,
                    child: Row(children: [
                      const SizedBox(width: 14),
                      CircleAvatar(
                          radius: 18,
                          backgroundColor:
                              sidebarForeground.withValues(alpha: .13),
                          child: Icon(Icons.account_circle_outlined,
                              size: 22, color: sidebarForeground)),
                      if (sidebarExpanded) ...[
                        const SizedBox(width: 10),
                        Expanded(
                            child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(user.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: sidebarForeground,
                                      fontWeight: FontWeight.w600)),
                              Text(roleName,
                                  style: TextStyle(
                                      color: sidebarForeground.withValues(
                                          alpha: .75))),
                            ])),
                        Icon(Icons.more_vert, color: sidebarForeground),
                        const SizedBox(width: 8),
                      ],
                    ])),
              )),
        ),
      ),
      menuChildren: [
        MenuItemButton(
            onPressed: () => _sessionAction(true),
            leadingIcon: const Icon(Icons.lock_outline),
            child: const Text('Lock / Switch user')),
        if (user.can(PosPermission.refreshLicense) &&
            widget.refreshLicense != null)
          MenuItemButton(
              onPressed: _refreshLicenseDialog,
              leadingIcon: const Icon(Icons.refresh),
              child: const Text('Refresh license')),
        const Divider(height: 1),
        MenuItemButton(
            onPressed: () => _sessionAction(false),
            leadingIcon: const Icon(Icons.logout),
            child: const Text('Logout')),
      ],
    );
    return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _openGlobalSearch
        },
        child: Focus(
            autofocus: true,
            child: Scaffold(
                body: width < 700 || focused
                    ? workspace
                    : Row(children: [
                        AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeInOutCubic,
                            width: sidebarExpanded
                                ? AppLayout.sidebarWidth
                                : AppLayout.collapsedSidebarWidth,
                            child: ClipRect(
                                child: OverflowBox(
                                    alignment: Alignment.topLeft,
                                    minWidth: AppLayout.sidebarWidth,
                                    maxWidth: AppLayout.sidebarWidth,
                                    child: Material(
                                        key: const Key('full-height-sidebar'),
                                        color: sidebarPreset.color,
                                        child: Column(children: [
                                          SizedBox(
                                              height: 64,
                                              child: Row(children: [
                                                Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            left: 12),
                                                    child: Container(
                                                        key: const Key(
                                                            'sidebar-brand-logo'),
                                                        width: 44,
                                                        height: 44,
                                                        alignment:
                                                            Alignment.center,
                                                        clipBehavior:
                                                            Clip.antiAlias,
                                                        decoration: BoxDecoration(
                                                            color: sidebarForeground
                                                                .withValues(
                                                                    alpha: .12),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                    10)),
                                                        child: appearance?.logoPath == null
                                                            ? Text(
                                                                _businessName
                                                                    .split(RegExp(r'\s+'))
                                                                    .take(2)
                                                                    .map((word) => word[0].toUpperCase())
                                                                    .join(),
                                                                style: TextStyle(color: sidebarForeground, fontWeight: FontWeight.w700))
                                                            : Image.file(File(appearance!.logoPath!), width: 44, height: 44, fit: BoxFit.contain, errorBuilder: (_, __, ___) => Text(_businessName[0], style: TextStyle(color: sidebarForeground))))),
                                                if (sidebarExpanded)
                                                  Expanded(
                                                      child: Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .only(
                                                                  left: 10),
                                                          child: Tooltip(
                                                              message:
                                                                  _businessName,
                                                              child: Column(
                                                                  mainAxisAlignment:
                                                                      MainAxisAlignment
                                                                          .center,
                                                                  crossAxisAlignment:
                                                                      CrossAxisAlignment
                                                                          .start,
                                                                  children: [
                                                                    Text(
                                                                        _businessName,
                                                                        key: const Key(
                                                                            'sidebar-business-name'),
                                                                        maxLines:
                                                                            1,
                                                                        overflow:
                                                                            TextOverflow
                                                                                .ellipsis,
                                                                        style: TextStyle(
                                                                            color:
                                                                                sidebarForeground,
                                                                            fontSize:
                                                                                15,
                                                                            fontWeight:
                                                                                FontWeight.w600)),
                                                                    Text(
                                                                        'Point of Sale',
                                                                        style: TextStyle(
                                                                            color:
                                                                                sidebarMuted,
                                                                            fontSize:
                                                                                11)),
                                                                  ])))),
                                                if (sidebarExpanded)
                                                  IconButton(
                                                      key: const Key(
                                                          'pos-sidebar-toggle'),
                                                      tooltip:
                                                          'Collapse sidebar',
                                                      color: sidebarForeground,
                                                      onPressed: () =>
                                                          _setSidebarExpanded(
                                                              false),
                                                      icon: const Icon(
                                                          Icons.chevron_left)),
                                              ])),
                                          if (!sidebarExpanded)
                                            Align(
                                                alignment: Alignment.centerLeft,
                                                child: SizedBox(
                                                    width: AppLayout
                                                        .collapsedSidebarWidth,
                                                    child: IconButton(
                                                        key: const Key(
                                                            'pos-sidebar-toggle'),
                                                        tooltip:
                                                            'Expand sidebar',
                                                        color:
                                                            sidebarForeground,
                                                        onPressed: () =>
                                                            _setSidebarExpanded(
                                                                true),
                                                        icon: const Icon(Icons
                                                            .chevron_right)))),
                                          Divider(
                                              height: 1, color: sidebarLine),
                                          Tooltip(
                                              message: 'Search · Ctrl K',
                                              child: ListTile(
                                                key: const Key(
                                                    'global-search-button'),
                                                dense: true,
                                                leading: Icon(Icons.search,
                                                    color: sidebarForeground),
                                                title: sidebarExpanded
                                                    ? Text('Search',
                                                        style: TextStyle(
                                                            color:
                                                                sidebarForeground))
                                                    : null,
                                                onTap: _openGlobalSearch,
                                              )),
                                          Expanded(
                                              child: Align(
                                                  alignment: Alignment.topLeft,
                                                  child: SizedBox(
                                                      width: sidebarExpanded
                                                          ? AppLayout
                                                              .sidebarWidth
                                                          : AppLayout
                                                              .collapsedSidebarWidth,
                                                      child: ListView(
                                                          key: const Key(
                                                              'sidebar-navigation'),
                                                          padding:
                                                              const EdgeInsets
                                                                  .fromLTRB(
                                                                  8, 4, 8, 12),
                                                          children: [
                                                            for (final group
                                                                in groups)
                                                              if (group.$2.any(
                                                                  labels
                                                                      .contains)) ...[
                                                                if (sidebarExpanded)
                                                                  Padding(
                                                                      padding: const EdgeInsets
                                                                          .fromLTRB(
                                                                          8,
                                                                          16,
                                                                          8,
                                                                          5),
                                                                      child: Text(
                                                                          group
                                                                              .$1,
                                                                          style: TextStyle(
                                                                              color: sidebarMuted,
                                                                              fontSize: 10,
                                                                              fontWeight: FontWeight.w600,
                                                                              letterSpacing: 1.1))),
                                                                if (!sidebarExpanded)
                                                                  Padding(
                                                                      padding: const EdgeInsets
                                                                          .symmetric(
                                                                          vertical:
                                                                              7,
                                                                          horizontal:
                                                                              12),
                                                                      child: Divider(
                                                                          height:
                                                                              1,
                                                                          color:
                                                                              sidebarLine)),
                                                                for (final label
                                                                    in group.$2)
                                                                  if (labels.contains(
                                                                      label))
                                                                    Tooltip(
                                                                        message:
                                                                            label,
                                                                        child: ListTile(
                                                                            dense:
                                                                                true,
                                                                            selected: labels[selected] ==
                                                                                label,
                                                                            textColor:
                                                                                sidebarForeground,
                                                                            iconColor:
                                                                                sidebarForeground,
                                                                            selectedColor:
                                                                                sidebarForeground,
                                                                            selectedTileColor:
                                                                                sidebarForeground.withValues(alpha: .10),
                                                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                                                            contentPadding: EdgeInsets.symmetric(horizontal: sidebarExpanded ? 12 : 16),
                                                                            minLeadingWidth: 22,
                                                                            leading: Icon(icon(label), size: 21),
                                                                            title: sidebarExpanded ? Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: labels[selected] == label ? FontWeight.w600 : FontWeight.w400)) : null,
                                                                            onTap: () => _go(labels.indexOf(label))))
                                                              ],
                                                          ])))),
                                          Divider(
                                              height: 1,
                                              color: sidebarForeground
                                                  .withValues(alpha: .25)),
                                          Align(
                                              alignment: Alignment.centerLeft,
                                              child: SizedBox(
                                                  width: sidebarExpanded
                                                      ? AppLayout.sidebarWidth
                                                      : AppLayout
                                                          .collapsedSidebarWidth,
                                                  child: account)),
                                        ]))))),
                        const VerticalDivider(width: 1),
                        Expanded(child: workspace),
                      ]),
                bottomNavigationBar: width >= 700 || focused
                    ? null
                    : NavigationBar(
                        selectedIndex: mobile.contains(labels[selected])
                            ? mobile.indexOf(labels[selected])
                            : mobile.length,
                        onDestinationSelected: (index) {
                          if (index < mobile.length) {
                            _go(labels.indexOf(mobile[index]));
                          } else {
                            showModalBottomSheet<void>(
                                context: context,
                                isScrollControlled: true,
                                builder: (context) => SafeArea(
                                        child: ListView(
                                            shrinkWrap: true,
                                            children: [
                                          for (final group in groups)
                                            if (group.$2
                                                .any(labels.contains)) ...[
                                              ListTile(title: Text(group.$1)),
                                              for (final label in group.$2)
                                                if (labels.contains(label))
                                                  ListTile(
                                                      leading:
                                                          Icon(icon(label)),
                                                      title: Text(label),
                                                      onTap: () {
                                                        Navigator.pop(context);
                                                        _go(labels
                                                            .indexOf(label));
                                                      }),
                                            ],
                                          const Divider(),
                                          ListTile(
                                              leading: const Icon(Icons
                                                  .account_circle_outlined),
                                              title: Text(user.name),
                                              subtitle: Text(roleName)),
                                          ListTile(
                                              leading: const Icon(
                                                  Icons.lock_outline),
                                              title: const Text(
                                                  'Lock / Switch user'),
                                              onTap: () {
                                                Navigator.pop(context);
                                                _sessionAction(true);
                                              }),
                                          if (user.can(PosPermission
                                                  .refreshLicense) &&
                                              widget.refreshLicense != null)
                                            ListTile(
                                                leading:
                                                    const Icon(Icons.refresh),
                                                title: const Text(
                                                    'Refresh license'),
                                                onTap: () {
                                                  Navigator.pop(context);
                                                  _refreshLicenseDialog();
                                                }),
                                          ListTile(
                                              leading: const Icon(Icons.logout),
                                              title: const Text('Logout'),
                                              onTap: () {
                                                Navigator.pop(context);
                                                _sessionAction(false);
                                              }),
                                        ])));
                          }
                        },
                        destinations: [
                            for (final label in mobile)
                              NavigationDestination(
                                  icon: Icon(icon(label)),
                                  label: label == 'Customers & Suppliers'
                                      ? 'Customers'
                                      : label),
                            const NavigationDestination(
                                icon: Icon(Icons.more_horiz), label: 'More'),
                          ]))));
  }

  List<String> _labelsFor(ActiveUser user) => [
        'Home',
        if (user.can(PosPermission.sell)) 'POS',
        if (user.can(PosPermission.viewOwnSales)) 'Sales History',
        if (user.can(PosPermission.reports)) 'Reports',
        if (user.can(PosPermission.manageUsers)) 'Audit Explorer',
        if (user.can(PosPermission.manageSettings) ||
            user.can(PosPermission.manageUsers) ||
            user.can(PosPermission.managePrinter) ||
            user.can(PosPermission.manageRecovery))
          'Settings',
        if (user.can(PosPermission.viewContacts)) 'Customers & Suppliers',
        if (user.can(PosPermission.manageRma)) 'RMA / Warranty',
        if (user.can(PosPermission.manageQuotations)) 'Quotations',
        if (user.can(PosPermission.viewSalesOrders)) 'Sales Orders',
        if (user.can(PosPermission.manageLayaway)) 'Layaway',
        if (user.can(PosPermission.viewPromotions)) 'Promotions',
        if (user.can(PosPermission.stockReceiving) ||
            user.can(PosPermission.stockCount) ||
            user.can(PosPermission.manageCatalog))
          'Inventory',
        if (user.can(PosPermission.reports)) 'Operations',
        if (user.can(PosPermission.manageExpenses)) 'Expenses',
        if (user.can(PosPermission.manageCashSession)) 'Cash session',
      ];
}

class _RefreshLicenseDialog extends StatefulWidget {
  const _RefreshLicenseDialog();

  @override
  State<_RefreshLicenseDialog> createState() => _RefreshLicenseDialogState();
}

class _RefreshLicenseDialogState extends State<_RefreshLicenseDialog> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Refresh license'),
        content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Activation key')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Refresh')),
        ],
      );
}
