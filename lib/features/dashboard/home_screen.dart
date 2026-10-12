import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/sales_service.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/sales_repository.dart';
import '../auth/users_screen.dart';
import '../pos_checkout/checkout_screen.dart';
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
  String? inventoryFilter;
  bool _posSidebarExpanded = false;
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

  @override
  void initState() {
    super.initState();
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
    _shiftTimer?.cancel();
    _shiftChanges?.cancel();
    super.dispose();
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
    setState(() => page = index);
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
                repository: widget.pos,
                user: user,
                auth: widget.auth,
                receipts: receipts);
          }),
      SalesHistoryScreen(
          sales: sales, user: user, active: page == 1, receipts: receipts),
      if (user.can(PosPermission.reports))
        ReportsScreen(sales: sales, active: page == 2),
      if (user.can(PosPermission.manageUsers)) UsersScreen(auth: widget.auth),
      if (user.can(PosPermission.manageUsers))
        PrinterSettingsScreen(
            store: settings, printer: printer, devices: deviceClient),
      if (user.role == UserRole.owner)
        BusinessSettingsHomeScreen(
            repository: BusinessFeatureRepository(widget.pos.db),
            user: user,
            onOpen: (destination) {
              final labels = _labelsFor(user);
              final index = labels.indexOf(destination);
              if (index >= 0) _go(index);
            }),
      ContactsScreen(
          repository: DirectoryRepository(widget.pos.db), user: user),
      if (user.can(PosPermission.manageRma))
        RmaScreen(repository: RmaRepository(widget.pos.db), user: user),
      if (user.can(PosPermission.manageQuotations))
        QuotationScreen(
            repository: QuotationRepository(widget.pos.db, widget.pos),
            directory: DirectoryRepository(widget.pos.db),
            products: widget.pos,
            user: user),
      if (user.can(PosPermission.manageLayaway))
        LayawayScreen(
            repository: LayawayRepository(widget.pos.db, widget.pos),
            directory: DirectoryRepository(widget.pos.db),
            products: widget.pos,
            user: user),
      if (user.can(PosPermission.stockReceiving) ||
          user.can(PosPermission.manageCatalog))
        InventoryWorkspace(
            key: ValueKey((receivingProductId, inventoryFilter)),
            repository: widget.pos,
            auth: widget.auth,
            user: user,
            initialProductId: receivingProductId,
            initialFilter: inventoryFilter ?? 'All',
            initialView: inventoryFilter != null
                ? 1
                : receivingProductId == null
                    ? 0
                    : 2),
      if (user.role == UserRole.owner)
        OperationalSummaryScreen(
            repository: OperationalSummaryRepository(widget.pos.db),
            user: user,
            onInventory: (filter) {
              setState(() => inventoryFilter = filter);
              _go(_labelsFor(user).indexOf('Inventory'));
            },
            onRma: () => _go(_labelsFor(user).indexOf('RMA / Warranty')),
            onLayaway: () => _go(_labelsFor(user).indexOf('Layaway')),
            onCustomers: () =>
                _go(_labelsFor(user).indexOf('Customers & Suppliers'))),
      PettyCashScreen(
          repository: PettyCashRepository(widget.pos.db), user: user),
      CashSessionScreen(
          user: user,
          currentShift:
              _lastShift?.session.openedByUserId == user.id ? _lastShift : null,
          otherShift:
              _lastShift?.session.openedByUserId != user.id ? _lastShift : null,
          useSharedCurrent: true,
          showTitle: false,
          repository: _cashSessions,
          onGoPos: () => _go(0)),
    ];
    final showRecovery =
        user.can(PosPermission.manageRecovery) && widget.recoveryScreen != null;
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
      ('OPERATIONS', ['Operations', 'Reports', 'Petty Cash', 'Cash session']),
      (
        'ADMIN & SETTINGS',
        ['Settings', 'Users & Roles', 'Printer & Receipt', 'Backup & Recovery']
      ),
    ];
    final mobile = [
      'POS',
      'Sales History',
      if (labels.contains('Inventory')) 'Inventory',
      'Customers & Suppliers'
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
          'Petty Cash' => Icons.money_off,
          'Cash session' => Icons.payments,
          'Settings' => Icons.settings,
          'Users & Roles' => Icons.people,
          'Printer & Receipt' => Icons.print,
          _ => Icons.health_and_safety,
        };
    final width = MediaQuery.sizeOf(context).width;
    final sidebarExpanded = _posSidebarExpanded;
    return Scaffold(
        appBar: AppBar(
            leading: width >= 700
                ? IconButton(
                    key: const Key('pos-sidebar-toggle'),
                    tooltip:
                        sidebarExpanded ? 'Collapse sidebar' : 'Expand sidebar',
                    onPressed: () {
                      setState(
                          () => _posSidebarExpanded = !_posSidebarExpanded);
                      SharedPreferences.getInstance().then((prefs) => prefs
                          .setBool('sidebarExpanded', _posSidebarExpanded));
                    },
                    icon: const Icon(Icons.menu))
                : null,
            title: Text(
                selected == 0
                    ? 'Point of Sale'
                    : labels[selected] == 'Cash session'
                        ? 'Cash Session'
                        : labels[selected],
                overflow: TextOverflow.ellipsis),
            actions: [
              FutureBuilder<CashSessionSummary?>(
                  future: _shiftStatus,
                  builder: (context, snapshot) {
                    final shift = _shiftError == null && !snapshot.hasError
                        ? snapshot.connectionState == ConnectionState.done
                            ? (_lastShift ?? snapshot.data)
                            : null
                        : null;
                    return TextButton.icon(
                        key: const Key('global-shift-status'),
                        onPressed: () =>
                            shift == null ? _go(0) : _showShift(shift, user),
                        icon: Icon(
                            shift != null
                                ? Icons.circle
                                : Icons.circle_outlined,
                            size: 12),
                        label: Text(shift == null
                            ? (_shiftError == null && !snapshot.hasError
                                ? 'Shift'
                                : 'Shift unavailable')
                            : shift.session.openedByUserId == user.id
                                ? 'Shift open · Expected ${formatPeso(shift.expectedCents)}'
                                : 'Other shift open'));
                  }),
              if (width >= 900)
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                        child: Text('${user.name} · ${user.role.name}'))),
              MenuAnchor(
                  builder: (context, controller, child) => IconButton(
                      tooltip: 'More actions',
                      icon: const Icon(Icons.more_vert),
                      onPressed: () => controller.isOpen
                          ? controller.close()
                          : controller.open()),
                  menuChildren: [
                    if (user.can(PosPermission.manageUsers) &&
                        widget.refreshLicense != null)
                      MenuItemButton(
                          onPressed: _refreshLicenseDialog,
                          child: const Text('Refresh license')),
                    MenuItemButton(
                        onPressed: () => _sessionAction(true),
                        child: const Text('Lock / Switch user')),
                    MenuItemButton(
                        onPressed: () => _sessionAction(false),
                        child: const Text('Logout')),
                  ]),
            ]),
        body: width < 700
            ? IndexedStack(index: selected, children: pages)
            : Row(children: [
                SizedBox(
                    width: sidebarExpanded ? 210 : 72,
                    child: Material(
                        color:
                            Theme.of(context).colorScheme.surfaceContainerLow,
                        child: ListView(children: [
                          for (final group in groups)
                            if (group.$2.any(labels.contains)) ...[
                              if (sidebarExpanded)
                                Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(16, 18, 8, 4),
                                    child: Text(group.$1,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall)),
                              for (final label in group.$2)
                                if (labels.contains(label))
                                  Tooltip(
                                      message: label,
                                      child: ListTile(
                                          dense: true,
                                          selected: labels[selected] == label,
                                          leading: Icon(icon(label)),
                                          title: sidebarExpanded
                                              ? Text(label,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis)
                                              : null,
                                          onTap: () =>
                                              _go(labels.indexOf(label))))
                            ],
                        ]))),
                const VerticalDivider(width: 1),
                Expanded(child: IndexedStack(index: selected, children: pages)),
              ]),
        bottomNavigationBar: width >= 700
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
                                ]
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
        'POS',
        'Sales History',
        if (user.can(PosPermission.reports)) 'Reports',
        if (user.can(PosPermission.manageUsers)) 'Users & Roles',
        if (user.can(PosPermission.manageUsers)) 'Printer & Receipt',
        if (user.role == UserRole.owner) 'Settings',
        'Customers & Suppliers',
        if (user.can(PosPermission.manageRma)) 'RMA / Warranty',
        if (user.can(PosPermission.manageQuotations)) 'Quotations',
        if (user.can(PosPermission.manageLayaway)) 'Layaway',
        if (user.can(PosPermission.stockReceiving) ||
            user.can(PosPermission.manageCatalog))
          'Inventory',
        if (user.role == UserRole.owner) 'Operations',
        'Petty Cash',
        'Cash session',
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
