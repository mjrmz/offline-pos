import 'package:drift/drift.dart';
import '../../core/models/active_user.dart';
import '../database.dart';
import '../../core/models/quantity.dart';
import 'business_feature_repository.dart';
import 'auth_repository.dart';
import 'customer_credit_repository.dart';
import 'loyalty_repository.dart';

class SaleSummary {
  final Sale sale;
  final String cashierName;
  final String paymentMethod;
  final String customerName;
  const SaleSummary(this.sale, this.cashierName, this.paymentMethod,
      [this.customerName = 'Walk-in']);
}

class SaleDetail {
  final SaleSummary summary;
  final List<SaleItem> items;
  final List<String> productNames;
  final SaleReversal? reversal;
  final int paymentAmountCents;
  final int cashAmountCents;
  final Map<String, List<String>> serialNumbersByItem;
  final List<Payment> payments;
  final List<SaleItemRefund> itemRefunds;
  final List<SalePromotionApplication> promotionApplications;
  final Map<String, List<KitSaleComponentSummary>> kitComponentsByItem;
  const SaleDetail(this.summary, this.items, this.productNames, this.reversal,
      [this.paymentAmountCents = 0,
      this.cashAmountCents = 0,
      this.serialNumbersByItem = const {},
      this.payments = const [],
      this.itemRefunds = const [],
      this.promotionApplications = const [],
      this.kitComponentsByItem = const {}]);
}

class KitSaleComponentSummary {
  final String name;
  final int quantityMilli;
  final int allocatedCostCents;
  final List<String> serials = [];
  final List<String> batches = [];
  KitSaleComponentSummary(this.name, this.quantityMilli, this.allocatedCostCents);
}

class DailyReport {
  final DateTime date;
  final int completedCount;
  final int grossCents;
  final int reversalCents;
  final int netCents;
  final Map<String, int> paymentBreakdown;
  final List<(String, int)> lowStock;
  final List<(String, int, String)> lowStockDetails;
  const DailyReport(this.date, this.completedCount, this.grossCents,
      this.reversalCents, this.netCents, this.paymentBreakdown, this.lowStock,
      [this.lowStockDetails = const []]);
}

class MadeOrderSummary {
  final MadeOrder order;
  final String productName;
  final String saleId;
  const MadeOrderSummary(this.order, this.productName, this.saleId);
}

class ItemRefundQuote {
  final int quantityMilli;
  final int amountCents;
  final int cashAllocationCents;
  final int creditAllocationCents;
  final int receivableReductionCents;
  final int dueCents;
  const ItemRefundQuote(
      this.quantityMilli,
      this.amountCents,
      this.cashAllocationCents,
      this.creditAllocationCents,
      this.receivableReductionCents,
      this.dueCents);
}

class SalesRepository {
  final AppDatabase db;
  SalesRepository(this.db);
  Future<Set<String>> searchSaleIds(String query) async {
    final term = '%${query.trim().toLowerCase()}%';
    final matches = await db.customSelect('''
      SELECT DISTINCT si.sale_id FROM sale_items si
      JOIN products p ON p.id = si.product_id
      LEFT JOIN serial_sale_links sl ON sl.sale_item_id = si.id
      LEFT JOIN serial_units su ON su.id = sl.serial_unit_id
      WHERE LOWER(si.product_name) LIKE ? OR LOWER(COALESCE(p.sku, '')) LIKE ?
        OR LOWER(COALESCE(p.barcode, '')) LIKE ?
        OR LOWER(COALESCE(su.serial_number, '')) LIKE ?
      UNION SELECT original_sale_id AS sale_id FROM sale_returns
        WHERE LOWER(reference) LIKE ?
      UNION SELECT sale_id FROM rma_cases
        WHERE sale_id IS NOT NULL AND LOWER(reference) LIKE ?
      UNION SELECT s.id AS sale_id FROM sales s
        LEFT JOIN customers c ON c.id=s.customer_id
        WHERE LOWER(COALESCE(c.phone,'')) LIKE ?
          OR LOWER(COALESCE(s.walk_in_contact,'')) LIKE ?
    ''', variables: List.generate(8, (_) => Variable.withString(term))).get();
    return matches.map((row) => row.read<String>('sale_id')).toSet();
  }

  Future<ActiveUser> _actor(ActiveUser actor) =>
      AuthRepository(db).requireActive(actor.id);

  // Allocate pooled sale credit proportionally across refunded line value.
  // Cumulative boundaries make rounding deterministic across multiple RMAs.
  Future<ItemRefundQuote> quoteItemRefund(String rmaCaseId) async {
    final claim = await (db.select(db.rmaCases)
          ..where((r) => r.id.equals(rmaCaseId)))
        .getSingleOrNull();
    if (claim == null ||
        claim.origin != 'customer' ||
        claim.saleItemId == null ||
        claim.saleId == null ||
        (claim.status != 'pending' && claim.status != 'sent_to_supplier')) {
      throw StateError('Customer RMA is not open');
    }
    final existing = await (db.select(db.saleItemRefunds)
          ..where((r) => r.rmaCaseId.equals(rmaCaseId)))
        .getSingleOrNull();
    if (existing != null) throw StateError('RMA was already refunded');
    final sale = await (db.select(db.sales)
          ..where((s) => s.id.equals(claim.saleId!)))
        .getSingle();
    if (sale.status != 'completed' || sale.totalCents <= 0) {
      throw StateError('Original sale is unavailable for item refund');
    }
    final item = await (db.select(db.saleItems)
          ..where((i) => i.id.equals(claim.saleItemId!)))
        .getSingle();
    if ((await db.customSelect(
      'SELECT 1 FROM sale_item_kit_components WHERE sale_item_id = ? LIMIT 1',
      variables: [Variable.withString(item.id)]).get()).isNotEmpty) {
      throw StateError('Kit item refunds require component restoration and are unavailable in this release');
    }
    if (item.saleMode != 'ordinary') {
      throw StateError('This sale mode has no item-level refund policy');
    }
    final totalMilli = item.quantityMilli == 0
        ? item.quantity * Quantity.scale
        : item.quantityMilli;
    final priorRows = await (db.select(db.saleItemRefunds)
          ..where((r) => r.saleItemId.equals(item.id)))
        .get();
    final priorMilli =
        priorRows.fold<int>(0, (sum, row) => sum + row.quantityMilli);
    final commercialPrior = await db.customSelect(
        'SELECT COALESCE(SUM(quantity_milli),0) AS qty FROM sale_return_lines WHERE sale_item_id=?',
        variables: [Variable.withString(item.id)]).getSingle();
    final alreadyReversedMilli = priorMilli + commercialPrior.read<int>('qty');
    if (claim.quantityMilli <= 0 ||
        alreadyReversedMilli + claim.quantityMilli > totalMilli) {
      throw StateError('Refund exceeds original item quantity');
    }
    final itemBefore = item.lineTotalCents * alreadyReversedMilli ~/ totalMilli;
    final itemAfter = item.lineTotalCents *
        (alreadyReversedMilli + claim.quantityMilli) ~/
        totalMilli;
    final amount = itemAfter - itemBefore;
    if (amount <= 0) throw StateError('Refund amount must be positive');
    final payments = await (db.select(db.payments)
          ..where((p) => p.saleId.equals(sale.id)))
        .get();
    final credit = payments
        .where((p) => p.method == 'credit')
        .fold<int>(0, (sum, p) => sum + p.amountCents);
    final priorSaleRefunds = await (db.select(db.saleItemRefunds)
          ..where((r) => r.saleId.equals(sale.id)))
        .get();
    final refundedBefore =
        priorSaleRefunds.fold<int>(0, (sum, row) => sum + row.amountCents);
    final creditPart = credit * (refundedBefore + amount) ~/ sale.totalCents -
        credit * refundedBefore ~/ sale.totalCents;
    final cashPart = amount - creditPart;
    final balance = sale.customerId == null
        ? 0
        : await CustomerCreditRepository(db).balance(sale.customerId!);
    if (balance < 0) throw StateError('Invalid customer balance');
    final reduction = balance < creditPart ? balance : creditPart;
    return ItemRefundQuote(claim.quantityMilli, amount, cashPart, creditPart,
        reduction, amount - reduction);
  }

  Future<SaleItemRefund> refundItemForRma(ActiveUser actor, String rmaCaseId,
          {required bool payCashNow}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        live.require(PosPermission.reverseSale);
        final quote = await quoteItemRefund(rmaCaseId);
        final claim = await (db.select(db.rmaCases)
              ..where((r) => r.id.equals(rmaCaseId)))
            .getSingle();
        final sale = await (db.select(db.sales)
              ..where((s) => s.id.equals(claim.saleId!)))
            .getSingle();
        if (sale.customerId == null && quote.dueCents > 0 && !payCashNow) {
          throw StateError('Walk-in refund must be paid from the drawer now');
        }
        final session = await (db.select(db.cashSessions)
              ..where((s) => s.closedAt.isNull()))
            .getSingleOrNull();
        if ((payCashNow && quote.dueCents > 0 ||
                sale.birInvoiceNumber != null) &&
            session == null) {
          throw StateError('Open a cash session before this refund');
        }
        final refund = await db.into(db.saleItemRefunds).insertReturning(
            SaleItemRefundsCompanion.insert(
                rmaCaseId: rmaCaseId,
                saleId: sale.id,
                saleItemId: claim.saleItemId!,
                cashSessionId: Value(session?.id),
                quantityMilli: quote.quantityMilli,
                amountCents: quote.amountCents,
                cashAllocationCents: quote.cashAllocationCents,
                creditAllocationCents: quote.creditAllocationCents,
                receivableReductionCents: quote.receivableReductionCents,
                obligationCents: payCashNow ? 0 : quote.dueCents,
                immediateCashCents: payCashNow ? quote.dueCents : 0));
        if (quote.receivableReductionCents > 0) {
          await db.into(db.customerCreditEntries).insert(
              CustomerCreditEntriesCompanion.insert(
                  customerId: sale.customerId!,
                  saleId: Value(sale.id),
                  userId: live.id,
                  amountCents: -quote.receivableReductionCents,
                  kind: 'item_refund_reversal',
                  note: Value(rmaCaseId)));
        }
        if (!payCashNow && quote.dueCents > 0) {
          final obligation = await db
              .into(db.customerRefundObligations)
              .insertReturning(CustomerRefundObligationsCompanion.insert(
                  customerId: sale.customerId!,
                  rmaCaseId: Value(rmaCaseId),
                  userId: live.id,
                  amountCents: quote.dueCents));
          await (db.update(db.saleItemRefunds)
                ..where((r) => r.id.equals(refund.id)))
              .write(
                  SaleItemRefundsCompanion(obligationId: Value(obligation.id)));
        }
        if (payCashNow && quote.dueCents > 0) {
          final movement = await db.into(db.cashMovements).insertReturning(
              CashMovementsCompanion.insert(
                  sessionId: session!.id,
                  referenceId: Value(refund.id),
                  amountCents: -quote.dueCents,
                  kind: 'item_refund'));
          await (db.update(db.saleItemRefunds)
                ..where((r) => r.id.equals(refund.id)))
              .write(
                  SaleItemRefundsCompanion(cashMovementId: Value(movement.id)));
        }
        await AuthRepository(db).audit(live.id, 'sale.item_refund',
            '$rmaCaseId:qty=${quote.quantityMilli}:amount=${quote.amountCents}:credit=${quote.receivableReductionCents}:due=${quote.dueCents}:cash=${payCashNow ? quote.dueCents : 0}');
        return refund;
      });

  Future<List<MadeOrderSummary>> madeOrders(ActiveUser actor) async {
    final live = await _actor(actor);
    if (!live.can(PosPermission.manageCatalog)) {
      throw StateError('Not authorized to manage orders');
    }
    final rows = await (db.select(db.madeOrders)
          ..orderBy([(o) => OrderingTerm(expression: o.createdAt)]))
        .get();
    final result = <MadeOrderSummary>[];
    for (final order in rows) {
      final item = await (db.select(db.saleItems)
            ..where((i) => i.id.equals(order.saleItemId)))
          .getSingle();
      result.add(MadeOrderSummary(order, item.productName, item.saleId));
    }
    return result;
  }

  Future<void> advanceMadeOrder(ActiveUser actor, String id) =>
      db.transaction(() async {
        final live = await _actor(actor);
        if (!live.can(PosPermission.manageCatalog)) {
          throw StateError('Not authorized to manage orders');
        }
        final order = await (db.select(db.madeOrders)
              ..where((o) => o.id.equals(id)))
            .getSingleOrNull();
        if (order == null) throw StateError('Order not found');
        const next = {
          'ordered': 'preparing',
          'preparing': 'ready',
          'ready': 'completed',
        };
        final status = next[order.status];
        if (status == null) throw StateError('Order cannot advance');
        await (db.update(db.madeOrders)..where((o) => o.id.equals(id))).write(
            MadeOrdersCompanion(
                status: Value(status), updatedAt: Value(DateTime.now())));
        await AuthRepository(db).audit(live.id, 'made_order.$status', id);
      });

  Future<List<SaleSummary>> history(ActiveUser actor) async {
    final live = await _actor(actor);
    live.require(PosPermission.viewOwnSales);
    final rows = await (db.select(db.sales)
          ..orderBy([
            (s) =>
                OrderingTerm(expression: s.createdAt, mode: OrderingMode.desc)
          ]))
        .get();
    final visible = !live.can(PosPermission.viewAllSales)
        ? rows.where((s) => s.cashierId == live.id)
        : rows;
    final users = {
      for (final row in await db.select(db.users).get()) row.id: row.name
    };
    final customers = {
      for (final row in await db.select(db.customers).get()) row.id: row.name
    };
    final payments = <String, List<Payment>>{};
    for (final payment in await db.select(db.payments).get()) {
      (payments[payment.saleId] ??= []).add(payment);
    }
    final result = <SaleSummary>[];
    for (final sale in visible) {
      final payment = payments[sale.id] ?? const <Payment>[];
      result.add(SaleSummary(
          sale,
          users[sale.cashierId] ?? 'Unknown cashier',
          payment.length > 1
              ? 'mixed'
              : payment.firstOrNull?.method ?? 'unknown',
          sale.customerId == null
              ? (sale.walkInName?.trim().isNotEmpty == true
                  ? sale.walkInName!
                  : 'Walk-in / Anonymous')
              : customers[sale.customerId] ?? 'Unknown customer'));
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
    final serialNumbersByItem = <String, List<String>>{};
    for (final item in items) {
      final product = await (db.select(db.products)
            ..where((p) => p.id.equals(item.productId)))
          .getSingleOrNull();
      names.add(item.productName.isNotEmpty
          ? item.productName
          : (product?.name ?? 'Unknown product'));
      final links = await (db.select(db.serialSaleLinks)
            ..where((s) => s.saleItemId.equals(item.id)))
          .get();
      serialNumbersByItem[item.id] = [];
      for (final link in links) {
        final serial = await (db.select(db.serialUnits)
              ..where((s) => s.id.equals(link.serialUnitId)))
            .getSingle();
        serialNumbersByItem[item.id]!.add(serial.serialNumber);
      }
    }
    final reversal = await (db.select(db.saleReversals)
          ..where((r) => r.saleId.equals(saleId)))
        .getSingleOrNull();
    final payment = await (db.select(db.payments)
          ..where((p) => p.saleId.equals(saleId)))
        .get();
    final itemRefunds = await (db.select(db.saleItemRefunds)
          ..where((r) => r.saleId.equals(saleId)))
        .get();
    final promotionApplications = await (db.select(db.salePromotionApplications)
          ..where((p) => p.saleId.equals(saleId))
          ..orderBy([(p) => OrderingTerm.desc(p.priority),
            (p) => OrderingTerm.asc(p.promotionReference)]))
        .get();
    final kitRows = await db.customSelect('''SELECT c.id, c.sale_item_id,
      c.component_name_snapshot, c.total_quantity_milli, c.allocated_cost_cents,
      su.serial_number, l.batch_number
      FROM sale_item_kit_components c
      JOIN sale_items i ON i.id = c.sale_item_id
      LEFT JOIN sale_item_kit_allocations ka ON ka.kit_component_id = c.id
      LEFT JOIN sale_item_inventory_allocations a ON a.id = ka.allocation_id
      LEFT JOIN serial_units su ON su.id = a.serial_unit_id
      LEFT JOIN inventory_layers l ON l.id = a.inventory_layer_id
      WHERE i.sale_id = ? ORDER BY i.id, c.id, ka.allocation_id''',
      variables: [Variable.withString(saleId)]).get();
    final kitComponents = <String, List<KitSaleComponentSummary>>{};
    final bySnapshot = <String, KitSaleComponentSummary>{};
    for (final row in kitRows) {
      final id = row.read<String>('id');
      final component = bySnapshot.putIfAbsent(id, () {
        final summary = KitSaleComponentSummary(
          row.read<String>('component_name_snapshot'),
          row.read<int>('total_quantity_milli'),
          row.read<int>('allocated_cost_cents'));
        kitComponents.putIfAbsent(row.read<String>('sale_item_id'), () => [])
            .add(summary);
        return summary;
      });
      final serial = row.readNullable<String>('serial_number');
      final batch = row.readNullable<String>('batch_number');
      if (serial != null && !component.serials.contains(serial)) {
        component.serials.add(serial);
      }
      if (batch != null && !component.batches.contains(batch)) {
        component.batches.add(batch);
      }
    }
    return SaleDetail(
        summary,
        items,
        names,
        reversal,
        payment.fold<int>(0, (sum, row) => sum + row.amountCents),
        payment
            .where((row) => row.method == 'cash')
            .fold<int>(0, (sum, row) => sum + row.amountCents),
        serialNumbersByItem,
        payment,
        itemRefunds,
        promotionApplications,
        kitComponents);
  }

  Future<void> reverse(ActiveUser actor, String saleId, String kind,
          {required bool stockRestored, bool cashRefundConfirmed = false}) =>
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
        final kitItems = await db.customSelect('''SELECT 1 FROM sale_item_kit_components c
          JOIN sale_items i ON i.id = c.sale_item_id WHERE i.sale_id = ? LIMIT 1''',
          variables: [Variable.withString(saleId)]).get();
        if (kitItems.isNotEmpty) {
          throw StateError('Kit sale void and full refund require component restoration and are unavailable in this release');
        }
        if (kind == 'void' && (await (db.select(db.salesOrderFulfillments)
              ..where((f) => f.saleId.equals(saleId))).get()).isNotEmpty) {
          throw StateError('A Sales Order fulfillment sale cannot be voided; use the normal refund workflow');
        }
        if ((await (db.select(db.saleItemRefunds)
                  ..where((r) => r.saleId.equals(saleId)))
                .get())
            .isNotEmpty) {
          throw StateError(
              'Sale has item refunds; full reversal is unavailable');
        }
        if ((await db.customSelect(
                'SELECT 1 FROM sale_returns WHERE original_sale_id=? LIMIT 1',
                variables: [Variable.withString(saleId)]).get())
            .isNotEmpty) {
          throw StateError(
              'Sale has item returns; full reversal is unavailable');
        }
        if (kind == 'void' && !stockRestored) {
          throw StateError('Voids must restore stock');
        }
        final rmaCases = await (db.select(db.rmaCases)
              ..where((r) => r.saleId.equals(saleId)))
            .get();
        if (rmaCases.isNotEmpty) {
          throw StateError(
              'This sale has an RMA; resolve its items separately');
        }
        final cashPayments = sale.customerId == null
            ? <Payment>[]
            : await (db.select(db.payments)
                  ..where(
                      (p) => p.saleId.equals(saleId) & p.method.equals('cash')))
                .get();
        final cashPortion = cashPayments.fold<int>(
            0, (sum, payment) => sum + payment.amountCents);
        if (cashPortion > 0 && !cashRefundConfirmed) {
          throw StateError('Confirm the full cash refund before reversal');
        }
        CashSession? refundSession;
        if (cashPortion > 0) {
          refundSession = await (db.select(db.cashSessions)
                ..where((s) => s.closedAt.isNull()))
              .getSingleOrNull();
          if (refundSession == null) {
            throw StateError('Open a cash session first');
          }
        }
        final newStatus = kind == 'void' ? 'voided' : 'refunded';
        final count = await (db.update(db.sales)
              ..where(
                  (s) => s.id.equals(saleId) & s.status.equals('completed')))
            .write(SalesCompanion(status: Value(newStatus)));
        if (count != 1) throw StateError('Sale already voided or refunded');
        final reward = await db.customSelect(
            'SELECT * FROM sale_loyalty WHERE sale_id=?',
            variables: [Variable.withString(saleId)]).getSingleOrNull();
        if (reward != null) {
          final earned = reward.read<int>('earned_points');
          await LoyaltyRepository(db).append(
              reward.read<String>('customer_id'), 'sale_reversal', -earned,
              sourceId: saleId, actorId: live.id, reason: kind);
          await LoyaltyRepository(db).append(reward.read<String>('customer_id'),
              'sale_restore', reward.read<int>('redeemed_points'),
              sourceId: saleId, actorId: live.id, reason: kind);
        }
        final reversal = await db.into(db.saleReversals).insertReturning(
            SaleReversalsCompanion.insert(
                saleId: saleId,
                actorId: live.id,
                kind: kind,
                amountCents: sale.totalCents,
                stockRestored: Value(stockRestored)));
        if (refundSession != null) {
          await db.into(db.cashMovements).insert(CashMovementsCompanion.insert(
              sessionId: refundSession.id,
              referenceId: Value(reversal.id),
              amountCents: -cashPortion,
              kind: 'mixed_sale_cash_refund'));
          await AuthRepository(db)
              .audit(live.id, 'sale.cash_refund', '$saleId:$cashPortion');
        }
        if (sale.customerId != null) {
          final creditRows = await (db.select(db.customerCreditEntries)
                ..where((e) =>
                    e.saleId.equals(saleId) & e.kind.equals('credit_sale')))
              .get();
          final creditAmount =
              creditRows.fold<int>(0, (sum, entry) => sum + entry.amountCents);
          if (creditAmount > 0) {
            final balance =
                await CustomerCreditRepository(db).balance(sale.customerId!);
            if (balance < 0) throw StateError('Invalid customer balance');
            final offset = balance < creditAmount ? balance : creditAmount;
            if (offset > 0) {
              await db.into(db.customerCreditEntries).insert(
                  CustomerCreditEntriesCompanion.insert(
                      customerId: sale.customerId!,
                      saleId: Value(saleId),
                      userId: live.id,
                      amountCents: -offset,
                      kind: 'sale_reversal'));
            }
            final obligation = creditAmount - offset;
            if (obligation > 0) {
              await db.into(db.customerRefundObligations).insert(
                  CustomerRefundObligationsCompanion.insert(
                      customerId: sale.customerId!,
                      saleId: Value(saleId),
                      userId: live.id,
                      amountCents: obligation));
            }
            await AuthRepository(db).audit(live.id, 'customer_credit.reversal',
                '$saleId:offset=$offset:refund_due=$obligation');
          }
        }
        if (stockRestored) {
          final items = await (db.select(db.saleItems)
                ..where((i) => i.saleId.equals(saleId)))
              .get();
          for (final item in items) {
            if (item.saleMode == 'made_order') continue;
            final allocations =
                await (db.select(db.saleItemInventoryAllocations)
                      ..where((a) => a.saleItemId.equals(item.id)))
                    .get();
            for (final allocation in allocations) {
              final layer = await (db.select(db.inventoryLayers)
                    ..where((l) => l.id.equals(allocation.inventoryLayerId)))
                  .getSingle();
              await (db.update(db.inventoryLayers)
                    ..where((l) => l.id.equals(layer.id)))
                  .write(InventoryLayersCompanion(
                      quantityRemainingMilli: Value(
                          layer.quantityRemainingMilli +
                              allocation.quantityMilli)));
            }
            final serialLinks = await (db.select(db.serialSaleLinks)
                  ..where((s) => s.saleItemId.equals(item.id)))
                .get();
            for (final link in serialLinks) {
              final count = await (db.update(db.serialUnits)
                    ..where((s) =>
                        s.id.equals(link.serialUnitId) &
                        s.saleItemId.equals(item.id) &
                        s.status.equals('sold')))
                  .write(const SerialUnitsCompanion(
                      status: Value('available'), saleItemId: Value(null)));
              if (count != 1) throw StateError('Serial state changed');
            }
            final milli = item.quantityMilli == 0
                ? item.quantity * Quantity.scale
                : item.quantityMilli;
            final inventory = await (db.select(db.inventory)
                  ..where((i) => i.productId.equals(item.productId)))
                .getSingleOrNull();
            if (inventory == null) throw StateError('Inventory row missing');
            await (db.update(db.inventory)
                  ..where((i) => i.productId.equals(item.productId)))
                .write(InventoryCompanion(
                    quantity: Value(
                        (inventory.quantityMilli + milli) ~/ Quantity.scale),
                    quantityMilli: Value(inventory.quantityMilli + milli)));
            if (item.batchId != null) {
              final batch = await (db.select(db.productLots)
                    ..where((b) => b.id.equals(item.batchId!)))
                  .getSingleOrNull();
              if (batch == null) throw StateError('Original batch missing');
              await (db.update(db.productLots)
                    ..where((b) => b.id.equals(batch.id)))
                  .write(ProductLotsCompanion(
                      quantityMilli: Value(batch.quantityMilli + milli)));
            }
            await db.into(db.inventoryMovements).insert(
                InventoryMovementsCompanion.insert(
                    productId: item.productId,
                    quantityDelta: item.quantity,
                    quantityDeltaMilli: Value(milli),
                    reason: kind,
                    referenceId: Value(saleId)));
            if (item.saleMode == 'exchange') {
              await db.into(db.tankEmptyMovements).insert(
                  TankEmptyMovementsCompanion.insert(
                      productId: item.productId,
                      quantityDelta: -item.quantity,
                      reason: '${kind}_exchange_reversal',
                      referenceId: Value(saleId)));
            }
          }
        }
        final orderItems = await (db.select(db.saleItems)
              ..where((i) =>
                  i.saleId.equals(saleId) & i.saleMode.equals('made_order')))
            .get();
        for (final item in orderItems) {
          await (db.update(db.madeOrders)
                ..where((o) => o.saleItemId.equals(item.id)))
              .write(MadeOrdersCompanion(
                  status: const Value('cancelled'),
                  updatedAt: Value(DateTime.now())));
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
    final itemRefunds = (await db.select(db.saleItemRefunds).get())
        .where((r) => !r.createdAt.isBefore(start) && r.createdAt.isBefore(end))
        .fold<int>(0, (sum, r) => sum + r.amountCents);
    final commercial = await db
        .customSelect('''SELECT COALESCE(SUM(refund_value_cents),0) AS amount
      FROM sale_returns WHERE created_at>=? AND created_at<?''', variables: [
      Variable.withInt(start.millisecondsSinceEpoch),
      Variable.withInt(end.millisecondsSinceEpoch)
    ]).getSingle();
    final commercialRefunds = commercial.read<int>('amount');
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
    final lowDetails = <(String, int, String)>[];
    final products = await (db.select(db.products)
          ..where((p) => p.isActive.equals(true)))
        .get();
    final inventoryRows = await db.select(db.inventory).get();
    final inventoryByProduct = {
      for (final row in inventoryRows) row.productId: row,
    };
    final configs =
        await BusinessFeatureRepository(db).allProductConfigurations();
    for (final product in products) {
      final stock = inventoryByProduct[product.id];
      final quantityMilli = stock?.quantityMilli ?? 0;
      if (quantityMilli <= product.lowStockThreshold * Quantity.scale) {
        low.add((product.name, quantityMilli ~/ Quantity.scale));
        lowDetails.add((
          product.name,
          quantityMilli,
          configs[product.id]?.unit.label ?? 'pcs'
        ));
      }
    }
    return DailyReport(
        start,
        completed.length,
        gross,
        gross - net + itemRefunds + commercialRefunds,
        net - itemRefunds - commercialRefunds,
        breakdown,
        low,
        lowDetails);
  }
}
