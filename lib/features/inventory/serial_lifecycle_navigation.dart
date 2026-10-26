import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/sales_service.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/purchase_return_repository.dart';
import '../../data/daos/rma_repository.dart';
import '../../data/daos/sales_repository.dart';
import '../../data/daos/sales_order_repository.dart';
import '../../data/daos/serial_lifecycle_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../contacts/rma_screen.dart';
import '../contacts/sales_orders_screen.dart';
import '../sales_history/sales_history_screen.dart';
import 'purchase_returns_screen.dart';
import 'stock_receiving_screen.dart';

bool canOpenSerialRecord(SerialLifecycleEvent event, ActiveUser user) =>
    event.sourceId != null &&
    switch (event.source) {
      'receiving' ||
      'purchase_return' =>
        user.can(PosPermission.stockReceiving),
      'sale' || 'return' => user.can(PosPermission.viewOwnSales),
      'rma' => user.can(PosPermission.manageRma),
      'sales_order' => user.can(PosPermission.viewSalesOrders),
      _ => false,
    };

void openSerialRecord(BuildContext context, SerialLifecycleEvent event,
    ActiveUser user, AuthService auth, PosRepository products) {
  if (!canOpenSerialRecord(event, user)) return;
  final id = event.sourceId!;
  final db = products.db;
  final Widget target = switch (event.source) {
    'receiving' => StockReceivingScreen(
        repository: StockReceivingRepository(db),
        directory: DirectoryRepository(db),
        products: products,
        user: user,
        auth: auth,
        initialReceiptId: id),
    'purchase_return' => PurchaseReturnsScreen(
        repository: PurchaseReturnRepository(db),
        user: user,
        initialReturnId: id),
    'sale' || 'return' => SalesHistoryScreen(
        sales: SalesService(SalesRepository(db), auth),
        user: user,
        pos: products,
        initialSaleId: id),
    'rma' =>
      RmaScreen(repository: RmaRepository(db), user: user, initialCaseId: id),
    'sales_order' => SalesOrdersScreen(
        repository: SalesOrderRepository(db),
        directory: DirectoryRepository(db),
        products: products,
        user: user,
        auth: auth,
        initialReference: id),
    _ => throw StateError('No record detail for ${event.source}'),
  };
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => target));
}
