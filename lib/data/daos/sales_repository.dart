import 'package:drift/drift.dart';
import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';

class SaleSummary {
  final Sale sale;
  final String cashierName;
  final String paymentMethod;
  const SaleSummary(this.sale, this.cashierName, this.paymentMethod);
}

class SaleDetail {
  final SaleSummary summary;
  final List<SaleItem> items;
  final List<String> productNames;
  final SaleReversal? reversal;
  const SaleDetail(this.summary, this.items, this.productNames, this.reversal);
}

class DailyReport {
  final DateTime date;
  final int completedCount;
  final int grossCents;
  final int reversalCents;
  final int netCents;
  final Map<String, int> paymentBreakdown;
  final List<(String, int)> lowStock;
  const DailyReport(this.date, this.completedCount, this.grossCents,
      this.reversalCents, this.netCents, this.paymentBreakdown, this.lowStock);
}

class SalesRepository {
  final AppDatabase db;
  SalesRepository(this.db);
  Future<ActiveUser> _actor(ActiveUser actor) =>
      AuthRepository(db).requireActive(actor.id);

  Future<List<SaleSummary>> history(ActiveUser actor) async {
    final live = await _actor(actor);
    final rows = await (db.select(db.sales)
          ..orderBy([
            (s) =>
                OrderingTerm(expression: s.createdAt, mode: OrderingMode.desc)
          ]))
        .get();
    final visible = live.role == UserRole.cashier
        ? rows.where((s) => s.cashierId == live.id)
        : rows;
    final result = <SaleSummary>[];
    for (final sale in visible) {
      final cashier = await (db.select(db.users)
            ..where((u) => u.id.equals(sale.cashierId)))
          .getSingleOrNull();
      final payment = await (db.select(db.payments)
            ..where((p) => p.saleId.equals(sale.id)))
          .getSingleOrNull();
      result.add(SaleSummary(sale, cashier?.name ?? 'Unknown cashier',
          payment?.method ?? 'unknown'));
    }
    return result;
  }

  Future<SaleDetail> detail(ActiveUser actor, String saleId) async {
    final summaries = await history(actor);
    final summary = summaries.where((s) => s.sale.id == saleId).firstOrNull;
    if (summary == null) throw StateError('Sale not found or not authorized');
    final items = await (db.select(db.saleItems)
          ..where((i) => i.saleId.equals(saleId)))
        .get();
    final names = <String>[];
    for (final item in items) {
      final product = await (db.select(db.products)
            ..where((p) => p.id.equals(item.productId)))
          .getSingleOrNull();
      names.add(product?.name ?? 'Unknown product');
    }
    final reversal = await (db.select(db.saleReversals)
          ..where((r) => r.saleId.equals(saleId)))
        .getSingleOrNull();
    return SaleDetail(summary, items, names, reversal);
  }

  Future<void> reverse(
          ActiveUser actor, String saleId, String kind, DateTime now) =>
      db.transaction(() async {
        final live = await _actor(actor);
        if (!live.can(PosPermission.reverseSale)) {
          throw StateError('Not authorized for this action');
        }
        if (kind != 'void' && kind != 'refund') {
          throw StateError('Invalid reversal');
        }
        final sale = await (db.select(db.sales)
              ..where((s) => s.id.equals(saleId)))
            .getSingleOrNull();
        if (sale == null) throw StateError('Sale not found');
        if (sale.status != 'completed') {
          throw StateError('Sale already voided or refunded');
        }
        if (kind == 'void' &&
            (sale.createdAt.year != now.year ||
                sale.createdAt.month != now.month ||
                sale.createdAt.day != now.day)) {
          throw StateError('Only same-day sales can be voided; use refund');
        }
        final newStatus = kind == 'void' ? 'voided' : 'refunded';
        final count = await (db.update(db.sales)
              ..where(
                  (s) => s.id.equals(saleId) & s.status.equals('completed')))
            .write(SalesCompanion(status: Value(newStatus)));
        if (count != 1) throw StateError('Sale already voided or refunded');
        await db.into(db.saleReversals).insert(SaleReversalsCompanion.insert(
            saleId: saleId,
            actorId: live.id,
            kind: kind,
            amountCents: sale.totalCents));
        final items = await (db.select(db.saleItems)
              ..where((i) => i.saleId.equals(saleId)))
            .get();
        for (final item in items) {
          final inventory = await (db.select(db.inventory)
                ..where((i) => i.productId.equals(item.productId)))
              .getSingleOrNull();
          if (inventory == null) throw StateError('Inventory row missing');
          await (db.update(db.inventory)
                ..where((i) => i.productId.equals(item.productId)))
              .write(InventoryCompanion(
                  quantity: Value(inventory.quantity + item.quantity)));
          await db.into(db.inventoryMovements).insert(
              InventoryMovementsCompanion.insert(
                  productId: item.productId,
                  quantityDelta: item.quantity,
                  reason: kind,
                  referenceId: Value(saleId)));
        }
        await AuthRepository(db).audit(
            live.id, kind == 'void' ? 'sale_voided' : 'sale_refunded', saleId);
      });

  Future<DailyReport> report(ActiveUser actor, DateTime date) async {
    final live = await _actor(actor);
    if (!live.can(PosPermission.reports)) {
      throw StateError('Not authorized for this action');
    }
    final start = DateTime(date.year, date.month, date.day);
    final end = start.add(const Duration(days: 1));
    final all = await db.select(db.sales).get();
    final today = all
        .where((s) => !s.createdAt.isBefore(start) && s.createdAt.isBefore(end))
        .toList();
    final completed = today.where((s) => s.status == 'completed').toList();
    final gross = today.fold<int>(0, (sum, s) => sum + s.totalCents);
    final net = completed.fold<int>(0, (sum, s) => sum + s.totalCents);
    final breakdown = <String, int>{};
    for (final sale in completed) {
      final payments = await (db.select(db.payments)
            ..where((p) => p.saleId.equals(sale.id)))
          .get();
      for (final payment in payments) {
        breakdown.update(payment.method, (v) => v + payment.amountCents,
            ifAbsent: () => payment.amountCents);
      }
    }
    final low = <(String, int)>[];
    final products = await (db.select(db.products)
          ..where((p) => p.isActive.equals(true)))
        .get();
    for (final product in products) {
      final stock = await (db.select(db.inventory)
            ..where((i) => i.productId.equals(product.id)))
          .getSingleOrNull();
      final quantity = stock?.quantity ?? 0;
      if (quantity <= product.lowStockThreshold) {
        low.add((product.name, quantity));
      }
    }
    return DailyReport(
        start, completed.length, gross, gross - net, net, breakdown, low);
  }
}
