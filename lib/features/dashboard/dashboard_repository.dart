import 'package:drift/drift.dart';
import '../../core/models/active_user.dart';
import '../../data/database.dart';
import '../../data/daos/supplier_payables_repository.dart';
import '../../data/daos/operational_summary_repository.dart';
import '../../data/daos/inventory_health_repository.dart';
import '../../data/daos/customer_credit_repository.dart';

class DashboardSnapshot {
  final int? salesCents, transactions, heldSales, receivablesCents;
  final int? openSalesOrders, failedDeliveries, openPurchaseOrders;
  final int? openRmas, pendingHandovers;
  final int? payablesCents;
  final int? lowStock, outOfStock, nearExpiry;
  const DashboardSnapshot(
      {this.salesCents,
      this.transactions,
      this.heldSales,
      this.receivablesCents,
      this.openSalesOrders,
      this.failedDeliveries,
      this.openPurchaseOrders,
      this.openRmas,
      this.pendingHandovers,
      this.payablesCents,
      this.lowStock,
      this.outOfStock,
      this.nearExpiry});
}

class DashboardRepository {
  final AppDatabase db;
  const DashboardRepository(this.db);

  Future<DashboardSnapshot> load(ActiveUser user) async {
    int? sales, transactions, held, receivables;
    int? openSalesOrders, failedDeliveries, openPurchaseOrders;
    int? openRmas, pendingHandovers;
    int? payables;
    int? lowStock, outOfStock, nearExpiry;
    if (user.can(PosPermission.viewOwnSales)) {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day);
      final end = start.add(const Duration(days: 1));
      final own = !user.can(PosPermission.viewAllSales);
      final row = await db.customSelect('''SELECT COUNT(*) AS transactions,
        COALESCE(SUM(total_cents), 0) AS sales FROM sales
        WHERE status = 'completed' AND created_at >= ? AND created_at < ?
        ${own ? 'AND cashier_id = ?' : ''}''', variables: [
        Variable.withInt(start.millisecondsSinceEpoch ~/ 1000),
        Variable.withInt(end.millisecondsSinceEpoch ~/ 1000),
        if (own) Variable.withString(user.id),
      ]).getSingle();
      sales = row.read<int>('sales');
      transactions = row.read<int>('transactions');
    }
    if (user.can(PosPermission.sell) && user.can(PosPermission.resumeSale)) {
      final row = await db.customSelect(
          '''SELECT COUNT(*) AS total FROM held_sales
        WHERE held_by = ?''',
          variables: [Variable.withString(user.id)]).getSingle();
      held = row.read<int>('total');
    }
    if (user.can(PosPermission.viewContacts) &&
        user.can(PosPermission.customerCredit)) {
      receivables = await CustomerCreditRepository(db).totalOutstanding();
    }
    if (user.can(PosPermission.viewContacts) &&
        user.can(PosPermission.reports)) {
      payables = await SupplierPayablesRepository(db).totalOutstanding();
    }
    if (user.can(PosPermission.viewSalesOrders)) {
      openSalesOrders = await _count("sales_orders WHERE status = 'confirmed' "
          "AND physical_status NOT IN ('delivered','picked_up','cancelled')");
      failedDeliveries = await _count("sales_orders WHERE status = 'confirmed' "
          "AND physical_status = 'failed_delivery'");
    }
    if (user.can(PosPermission.stockReceiving)) {
      openPurchaseOrders = await _count(
          "purchase_orders WHERE status IN ('draft','sent','partially_received')");
    }
    if (user.can(PosPermission.manageRma)) {
      openRmas =
          await _count("rma_cases WHERE status NOT IN ('resolved','rejected')");
    }
    if (user.can(PosPermission.acknowledgeShiftHandover)) {
      pendingHandovers = await _count(
          "cash_shift_handovers WHERE status = 'awaiting_acknowledgment'");
    }
    if (user.can(PosPermission.manageCatalog) ||
        user.can(PosPermission.stockCount) ||
        user.can(PosPermission.stockReceiving)) {
      final alerts = await OperationalSummaryRepository(db).stockAlerts();
      lowStock = alerts.low.length;
      outOfStock = alerts.out.length;
      nearExpiry = await InventoryHealthRepository(db).nearExpiryCount();
    }
    return DashboardSnapshot(
        salesCents: sales,
        transactions: transactions,
        heldSales: held,
        receivablesCents: receivables,
        openSalesOrders: openSalesOrders,
        failedDeliveries: failedDeliveries,
        openPurchaseOrders: openPurchaseOrders,
        openRmas: openRmas,
        pendingHandovers: pendingHandovers,
        payablesCents: payables,
        lowStock: lowStock,
        outOfStock: outOfStock,
        nearExpiry: nearExpiry);
  }

  Future<int> _count(String trustedTableAndWhere) async {
    final row = await db
        .customSelect('SELECT COUNT(*) AS total FROM $trustedTableAndWhere')
        .getSingle();
    return row.read<int>('total');
  }
}
