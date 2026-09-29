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

class HomeScreen extends StatefulWidget {
  final AuthService auth;
  final PosRepository pos;
  final SalesRepository salesRepository;
  final VoidCallback onChanged;
  const HomeScreen(
      {super.key,
      required this.auth,
      required this.pos,
      required this.salesRepository,
      required this.onChanged});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int page = 0;
  @override
  Widget build(BuildContext context) {
    final user = widget.auth.current!;
    final sales = SalesService(widget.salesRepository, widget.auth);
    final pages = <Widget>[
      CheckoutScreen(repository: widget.pos, user: user, auth: widget.auth),
      SalesHistoryScreen(sales: sales, user: user, active: page == 1),
      if (user.can(PosPermission.reports))
        ReportsScreen(sales: sales, active: page == 2),
      if (user.can(PosPermission.manageUsers)) UsersScreen(auth: widget.auth),
    ];
    final labels = <String>[
      'Checkout',
      'Sales history',
      if (user.can(PosPermission.reports)) 'Reports',
      if (user.can(PosPermission.manageUsers)) 'Users'
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
                                : Icons.people),
                    label: label)
            ]));
  }
}
