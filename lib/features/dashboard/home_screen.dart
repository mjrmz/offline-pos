import 'package:flutter/material.dart';
import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/sales_service.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/sales_repository.dart';
import '../auth/users_screen.dart';
import '../pos_checkout/checkout_screen.dart';
import '../sales_history/sales_history_screen.dart';
import '../reports/reports_screen.dart';
import '../../hardware/printer/receipt_service.dart';
import '../../data/daos/printer_settings_repository.dart';
import '../../hardware/printer/receipt_printer.dart';
import '../../hardware/printer/device_transports.dart';
import '../../hardware/cash_drawer/cash_drawer.dart';
import '../settings/printer_settings_screen.dart';
import '../cash_session/cash_session_screen.dart';
import '../../data/daos/cash_session_repository.dart';

class HomeScreen extends StatefulWidget {
  final AuthService auth;
  final PosRepository pos;
  final SalesRepository salesRepository;
  final VoidCallback onChanged;
  final Widget? recoveryScreen;
  const HomeScreen(
      {super.key,
      required this.auth,
      required this.pos,
      required this.salesRepository,
      required this.onChanged,
      this.recoveryScreen});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int page = 0;
  late final settings = PrinterSettingsStore(widget.pos.db);
  late final deviceClient = PluginPrinterClient();
  late final transport = ConfiguredPrinterTransport(LanEscPosTransport(),
      UsbEscPosTransport(deviceClient), BluetoothEscPosTransport(deviceClient));
  @override
  Widget build(BuildContext context) {
    final user = widget.auth.current!;
    final sales = SalesService(widget.salesRepository, widget.auth);
    final printer = EscPosReceiptPrinter(transport);
    final receipts =
        ReceiptService(sales, settings, printer, EscPosCashDrawer(transport));
    final pages = <Widget>[
      CheckoutScreen(
          repository: widget.pos,
          user: user,
          auth: widget.auth,
          receipts: receipts),
      SalesHistoryScreen(
          sales: sales, user: user, active: page == 1, receipts: receipts),
      if (user.can(PosPermission.reports))
        ReportsScreen(sales: sales, active: page == 2),
      if (user.can(PosPermission.manageUsers)) UsersScreen(auth: widget.auth),
      if (user.can(PosPermission.manageUsers))
        PrinterSettingsScreen(
            store: settings, printer: printer, devices: deviceClient),
      CashSessionScreen(
          user: user, repository: CashSessionRepository(widget.pos.db)),
      if (user.can(PosPermission.manageRecovery) &&
          widget.recoveryScreen != null)
        widget.recoveryScreen!,
    ];
    final labels = <String>[
      'Checkout',
      'Sales history',
      if (user.can(PosPermission.reports)) 'Reports',
      if (user.can(PosPermission.manageUsers)) 'Users',
      if (user.can(PosPermission.manageUsers)) 'Printer',
      'Cash session',
      if (user.can(PosPermission.manageRecovery) &&
          widget.recoveryScreen != null)
        'Recovery',
    ];
    return Scaffold(
        appBar:
            AppBar(title: Text('${user.name} · ${user.role.name}'), actions: [
          PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'lock') {
                  await widget.auth.lock();
                } else {
                  await widget.auth.logout();
                }
                widget.onChanged();
              },
              itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'lock', child: Text('Lock / Switch user')),
                    const PopupMenuItem(value: 'logout', child: Text('Logout'))
                  ])
        ]),
        body: IndexedStack(
            index: page.clamp(0, pages.length - 1), children: pages),
        bottomNavigationBar: NavigationBar(
            selectedIndex: page.clamp(0, pages.length - 1),
            onDestinationSelected: (index) => setState(() => page = index),
            destinations: [
              for (final label in labels)
                NavigationDestination(
                    icon: Icon(label == 'Checkout'
                        ? Icons.point_of_sale
                        : label == 'Sales history'
                            ? Icons.receipt_long
                            : label == 'Reports'
                                ? Icons.bar_chart
                                : label == 'Printer'
                                    ? Icons.print
                                    : label == 'Cash session'
                                        ? Icons.payments
                                        : label == 'Recovery'
                                            ? Icons.health_and_safety
                                            : Icons.people),
                    label: label)
            ]));
  }
}
