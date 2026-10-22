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
import '../auth/users_screen.dart';
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
import '../settings/printer_settings_screen.dart';
import '../settings/business_settings_home_screen.dart';
import '../../data/daos/business_feature_repository.dart';
import '../cash_session/cash_session_screen.dart';
import '../../data/daos/cash_session_repository.dart';
import '../../shared/utils/safe_message.dart';
import '../../data/daos/directory_repository.dart';
import '../contacts/contacts_screen.dart';
import '../contacts/rma_screen.dart';
import '../../data/daos/rma_repository.dart';
import '../contacts/quotation_screen.dart';
import '../../data/daos/quotation_repository.dart';
import '../contacts/layaway_screen.dart';
import '../../data/daos/layaway_repository.dart';
import '../../data/daos/petty_cash_repository.dart';
import '../cash_session/petty_cash_screen.dart';
import '../inventory/inventory_workspace.dart';
import '../inventory/expiry_monitor_screen.dart';
import '../../data/daos/inventory_health_repository.dart';
import '../../data/daos/operational_summary_repository.dart';
import '../reports/operational_summary_screen.dart';
import '../../shared/utils/money.dart';

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
  String? inventoryFilter;
  bool _posSidebarExpanded = false;
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
  final _accountFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    PosLayoutPreference.instance.addListener(_workspacePreferenceChanged);
    PosLayoutPreference.instance.load().then((_) {
      if (mounted && page == 0) {
        setState(() => _posFocused = PosLayoutPreference.instance.startFocused);
      }
    });
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() =>
            _posSidebarExpanded = prefs.getBool('sidebarExpanded') ?? false);
      }
    });
    _shiftStatus = _loadShift();
    _shiftChanges = _cashSessions
        .watchCurrentFor(widget.auth.current!.id)
        .listen((_) => _refreshShift(), onError: (Object error) {
      if (mounted) setState(() => _shiftError = error.toString());
    });
    _shiftTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _refreshShift());
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
    if (page == 0) setState(() => _posFocused = !_posFocused);
  }

  void _setSidebarExpanded(bool expanded) {
    setState(() => _posSidebarExpanded = expanded);
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setBool('sidebarExpanded', expanded));
  }

  Future<CashSessionSummary?> _loadShift() async {
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
    if (index < 0 || index >= _labelsFor(widget.auth.current!).length) return;
    setState(() {
      final enteringPos = page != 0 && index == 0;
      final inventoryIndex =
          _labelsFor(widget.auth.current!).indexOf('Inventory');
      if (page == inventoryIndex && index != inventoryIndex) {
        purchaseProductId = null;
        purchaseSupplierId = null;
        purchaseQuantityMilli = null;
        purchaseQuotationReference = null;
        purchaseExistingOrderId = null;
        purchaseViewOrderId = null;
        purchaseLines = null;
      }
      page = index;
      if (index != 0) _posFocused = false;
      if (enteringPos) {
        _posFocused = PosLayoutPreference.instance.startFocused;
      }
    });
    _refreshShift();
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
            sales: sales,
            user: user,
            active: page == _labelsFor(user).indexOf('Sales History'),
            receipts: receipts,
            pos: widget.pos),
      if (user.can(PosPermission.reports))
        ReportsScreen(
            sales: sales, active: page == _labelsFor(user).indexOf('Reports')),
      if (user.can(PosPermission.manageUsers)) UsersScreen(auth: widget.auth),
      if (user.can(PosPermission.managePrinter))
        PrinterSettingsScreen(
            store: settings, printer: printer, devices: deviceClient),
      if (user.can(PosPermission.manageSettings))
        BusinessSettingsHomeScreen(
            repository: BusinessFeatureRepository(widget.pos.db),
            user: user,
            onOpen: (destination) {
              final labels = _labelsFor(user);
              final index = labels.indexOf(destination);
              if (index >= 0) _go(index);
            }),
      if (user.can(PosPermission.viewContacts))
        ContactsScreen(
            repository: DirectoryRepository(widget.pos.db),
            user: user,
            sales: sales,
            pos: widget.pos,
            receipts: receipts),
      if (user.can(PosPermission.manageRma))
        RmaScreen(repository: RmaRepository(widget.pos.db), user: user),
      if (user.can(PosPermission.manageQuotations))
        QuotationScreen(
            key: ValueKey(('quotations', page, openQuotationReference)),
            repository: QuotationRepository(widget.pos.db, widget.pos),
            directory: DirectoryRepository(widget.pos.db),
            products: widget.pos,
            user: user,
            auth: widget.auth,
            receipts: receipts,
            initialQuotationReference: openQuotationReference,
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
      if (user.can(PosPermission.manageLayaway))
        LayawayScreen(
            repository: LayawayRepository(widget.pos.db, widget.pos),
            directory: DirectoryRepository(widget.pos.db),
            products: widget.pos,
            user: user),
      if (user.can(PosPermission.stockReceiving) ||
          user.can(PosPermission.stockCount) ||
          user.can(PosPermission.manageCatalog))
        InventoryWorkspace(
            key: ValueKey((
              receivingProductId,
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
            initialView: purchaseQuotationReference != null
                ? (user.can(PosPermission.manageCatalog) ? 2 : 1)
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
            onGoPos: () => _go(0)),
    ];
    final showRecovery =
        user.can(PosPermission.manageRecovery) && widget.recoveryScreen != null;
    if (pages.isEmpty) {
      pages.add(
          const Center(child: Text('No features are assigned to this role.')));
    }
    if (showRecovery) {
      final recoveryIndex = pages.length;
      pages.add(page == recoveryIndex
          ? widget.recoveryScreen!
          : const SizedBox.shrink());
    }
    final labels = _labelsFor(user);
    final selected = page.clamp(0, pages.length - 1);
    final groups = <(String, List<String>)>[
      ('SELL', ['POS', 'Sales History', 'Quotations', 'Layaway']),
      ('INVENTORY', ['Inventory']),
      ('CUSTOMERS', ['Customers & Suppliers', 'RMA / Warranty']),
      ('OPERATIONS', ['Operations', 'Expenses', 'Reports', 'Cash session']),
      (
        'ADMIN & SETTINGS',
        ['Settings', 'Users & Roles', 'Printer & Receipt', 'Backup & Recovery']
      ),
    ];
    final mobile = [
      if (labels.contains('POS')) 'POS',
      if (labels.contains('Sales History')) 'Sales History',
      if (labels.contains('Inventory')) 'Inventory',
      if (labels.contains('Customers & Suppliers')) 'Customers & Suppliers'
    ];
    IconData icon(String label) => switch (label) {
          'POS' => Icons.point_of_sale,
          'Sales History' => Icons.receipt_long,
          'Inventory' => Icons.inventory_2,
          'Customers & Suppliers' => Icons.contacts,
          'RMA / Warranty' => Icons.assignment_return,
          'Quotations' => Icons.request_quote,
          'Layaway' => Icons.inventory,
          'Operations' => Icons.dashboard,
          'Reports' => Icons.bar_chart,
          'Expenses' => Icons.receipt_long_outlined,
          'Cash session' => Icons.payments,
          'Settings' => Icons.settings,
          'Users & Roles' => Icons.people,
          'Printer & Receipt' => Icons.print,
          _ => Icons.health_and_safety,
        };
    final width = MediaQuery.sizeOf(context).width;
    final sidebarExpanded = _posSidebarExpanded;
    final focused = selected == 0 && _posFocused;
    final appearance = AppThemeController.maybeOf(context);
    final sidebarPreset =
        appearance?.effectiveSidebarColor ?? SidebarColorPreset.navy;
    final sidebarForeground = sidebarPreset.foreground;
    final roleName =
        user.role.name[0].toUpperCase() + user.role.name.substring(1);
    final content = IndexedStack(index: selected, children: pages);
    final workspace = selected == 0
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
                                  ? _go(0)
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
                      const SizedBox(width: 16),
                      Icon(Icons.account_circle_outlined,
                          color: sidebarForeground),
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
    return Scaffold(
        body: width < 700 || focused
            ? workspace
            : Row(children: [
                SizedBox(
                    width: sidebarExpanded
                        ? AppLayout.sidebarWidth
                        : AppLayout.collapsedSidebarWidth,
                    child: Material(
                        key: const Key('full-height-sidebar'),
                        color: sidebarPreset.color,
                        child: Column(children: [
                          SizedBox(
                              height: 56,
                              child: Row(children: [
                                Expanded(
                                    child: Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: appearance?.logoPath == null
                                            ? Icon(Icons.point_of_sale,
                                                size: sidebarExpanded ? 32 : 28,
                                                color: sidebarForeground)
                                            : Image.file(
                                                File(appearance!.logoPath!),
                                                fit: BoxFit.contain,
                                                cacheWidth: 256,
                                                errorBuilder: (_, __, ___) =>
                                                    Icon(Icons.point_of_sale,
                                                        color:
                                                            sidebarForeground)))),
                                if (sidebarExpanded)
                                  IconButton(
                                      key: const Key('pos-sidebar-toggle'),
                                      tooltip: 'Collapse sidebar',
                                      color: sidebarForeground,
                                      onPressed: () =>
                                          _setSidebarExpanded(false),
                                      icon: const Icon(Icons.menu)),
                              ])),
                          if (!sidebarExpanded)
                            IconButton(
                                key: const Key('pos-sidebar-toggle'),
                                tooltip: 'Expand sidebar',
                                color: sidebarForeground,
                                onPressed: () => _setSidebarExpanded(true),
                                icon: const Icon(Icons.menu)),
                          Expanded(
                              child: ListView(children: [
                            for (final group in groups)
                              if (group.$2.any(labels.contains)) ...[
                                if (sidebarExpanded)
                                  Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          16, 18, 8, 4),
                                      child: Text(group.$1,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                  color: sidebarForeground
                                                      .withValues(
                                                          alpha: .72)))),
                                for (final label in group.$2)
                                  if (labels.contains(label))
                                    Tooltip(
                                        message: label,
                                        child: ListTile(
                                            dense: true,
                                            selected: labels[selected] == label,
                                            textColor: sidebarForeground,
                                            iconColor: sidebarForeground,
                                            selectedColor: sidebarForeground,
                                            selectedTileColor: sidebarForeground
                                                .withValues(alpha: .17),
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8)),
                                            contentPadding:
                                                EdgeInsets.symmetric(
                                                    horizontal: sidebarExpanded
                                                        ? 12
                                                        : 16),
                                            minLeadingWidth: 28,
                                            leading:
                                                Icon(icon(label), size: 20),
                                            title: sidebarExpanded
                                                ? Text(label,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis)
                                                : null,
                                            onTap: () =>
                                                _go(labels.indexOf(label))))
                              ],
                          ])),
                          Divider(
                              height: 1,
                              color: sidebarForeground.withValues(alpha: .25)),
                          account,
                        ]))),
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
                                child: ListView(shrinkWrap: true, children: [
                              for (final group in groups)
                                if (group.$2.any(labels.contains)) ...[
                                  ListTile(title: Text(group.$1)),
                                  for (final label in group.$2)
                                    if (labels.contains(label))
                                      ListTile(
                                          leading: Icon(icon(label)),
                                          title: Text(label),
                                          onTap: () {
                                            Navigator.pop(context);
                                            _go(labels.indexOf(label));
                                          }),
                                ],
                              const Divider(),
                              ListTile(
                                  leading:
                                      const Icon(Icons.account_circle_outlined),
                                  title: Text(user.name),
                                  subtitle: Text(roleName)),
                              ListTile(
                                  leading: const Icon(Icons.lock_outline),
                                  title: const Text('Lock / Switch user'),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _sessionAction(true);
                                  }),
                              if (user.can(PosPermission.refreshLicense) &&
                                  widget.refreshLicense != null)
                                ListTile(
                                    leading: const Icon(Icons.refresh),
                                    title: const Text('Refresh license'),
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
                  ]));
  }

  List<String> _labelsFor(ActiveUser user) => [
        if (user.role == UserRole.custom &&
            user.grantedPermissions?.isEmpty == true)
          'No access',
        if (user.can(PosPermission.sell)) 'POS',
        if (user.can(PosPermission.viewOwnSales)) 'Sales History',
        if (user.can(PosPermission.reports)) 'Reports',
        if (user.can(PosPermission.manageUsers)) 'Users & Roles',
        if (user.can(PosPermission.managePrinter)) 'Printer & Receipt',
        if (user.can(PosPermission.manageSettings)) 'Settings',
        if (user.can(PosPermission.viewContacts)) 'Customers & Suppliers',
        if (user.can(PosPermission.manageRma)) 'RMA / Warranty',
        if (user.can(PosPermission.manageQuotations)) 'Quotations',
        if (user.can(PosPermission.manageLayaway)) 'Layaway',
        if (user.can(PosPermission.stockReceiving) ||
            user.can(PosPermission.stockCount) ||
            user.can(PosPermission.manageCatalog))
          'Inventory',
        if (user.can(PosPermission.reports)) 'Operations',
        if (user.can(PosPermission.manageExpenses)) 'Expenses',
        if (user.can(PosPermission.manageCashSession)) 'Cash session',
        if (user.can(PosPermission.manageRecovery) &&
            widget.recoveryScreen != null)
          'Backup & Recovery',
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
