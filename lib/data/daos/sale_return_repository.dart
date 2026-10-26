import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'pos_repository.dart';
import 'loyalty_repository.dart';

class ReturnSelection {
  final String saleItemId;
  final int quantityMilli;
  final bool sellable;
  final List<String> serialIds;
  const ReturnSelection(this.saleItemId, this.quantityMilli,
      {required this.sellable, this.serialIds = const []});
}

class ReturnableLine {
  final SaleItem item;
  final int returnedMilli;
  final List<SerialUnit> returnableSerials;
  final bool serialized;
  final String? limitation;
  const ReturnableLine(this.item, this.returnedMilli, this.returnableSerials,
      this.serialized, this.limitation);
  int get soldMilli => item.quantityMilli == 0
      ? item.quantity * Quantity.scale
      : item.quantityMilli;
  int get remainingMilli => soldMilli - returnedMilli;
}

class CommercialReturn {
  final String id;
  final String reference;
  final String saleId;
  final String kind;
  final String reason;
  final int refundValueCents;
  final int replacementValueCents;
  final int cashEffectCents;
  final String? replacementSaleId;
  final DateTime createdAt;
  const CommercialReturn(
      this.id,
      this.reference,
      this.saleId,
      this.kind,
      this.reason,
      this.refundValueCents,
      this.replacementValueCents,
      this.cashEffectCents,
      this.replacementSaleId,
      this.createdAt);
}

/// Commercial returns are separate from warranty/RMA refunds and sale voids.
class SaleReturnRepository {
  final AppDatabase db;
  const SaleReturnRepository(this.db);

  Future<String?> replacementReceipt(String? saleId) async {
    if (saleId == null) return null;
    final sale = await (db.select(db.sales)..where((s) => s.id.equals(saleId)))
        .getSingleOrNull();
    return sale?.receiptNumber;
  }

  Future<List<CommercialReturn>> history(String saleId) async {
    final rows = await db.customSelect(
        "SELECT * FROM sale_returns WHERE original_sale_id = ? AND status='finalized' ORDER BY created_at, reference",
        variables: [Variable.withString(saleId)]).get();
    return rows.map(_readReturn).toList();
  }

  Future<List<CommercialReturn>> forCustomer(String customerId) async {
    final rows = await db.customSelect('''SELECT r.* FROM sale_returns r
      JOIN sales s ON s.id=r.original_sale_id
      WHERE s.customer_id=? AND r.status='finalized'
      ORDER BY r.created_at DESC, r.reference DESC''',
        variables: [Variable.withString(customerId)]).get();
    return rows.map(_readReturn).toList();
  }

  Future<Map<String, int>> refundTotalsBySale() async {
    final rows = await db.customSelect('''SELECT original_sale_id,
        COALESCE(SUM(refund_value_cents),0) AS amount
      FROM sale_returns WHERE status='finalized'
      GROUP BY original_sale_id''').get();
    return {
      for (final row in rows)
        row.read<String>('original_sale_id'): row.read<int>('amount')
    };
  }

  CommercialReturn _readReturn(QueryRow r) => CommercialReturn(
      r.read<String>('id'),
      r.read<String>('reference'),
      r.read<String>('original_sale_id'),
      r.read<String>('kind'),
      r.read<String>('reason'),
      r.read<int>('refund_value_cents'),
      r.read<int>('replacement_value_cents'),
      r.read<int>('cash_effect_cents'),
      r.readNullable<String>('replacement_sale_id'),
      DateTime.fromMillisecondsSinceEpoch(r.read<int>('created_at')));

  Future<List<ReturnableLine>> returnable(String saleId) async {
    final sale = await (db.select(db.sales)..where((s) => s.id.equals(saleId)))
        .getSingleOrNull();
    if (sale == null || sale.status != 'completed') return [];
    final payments = await (db.select(db.payments)
          ..where((p) => p.saleId.equals(saleId)))
        .get();
    final hasCreditPayment = payments.any((p) => p.method == 'credit');
    final items = await (db.select(db.saleItems)
          ..where((i) => i.saleId.equals(saleId)))
        .get();
    final result = <ReturnableLine>[];
    for (final item in items) {
      final sold = item.quantityMilli == 0
          ? item.quantity * Quantity.scale
          : item.quantityMilli;
      final prior = await db.customSelect('''
        SELECT COALESCE(SUM(rl.quantity_milli),0) AS qty
        FROM sale_return_lines rl JOIN sale_returns r ON r.id=rl.return_id
        WHERE rl.sale_item_id=?''',
          variables: [Variable.withString(item.id)]).getSingle();
      final rma = await (db.select(db.saleItemRefunds)
            ..where((r) => r.saleItemId.equals(item.id)))
          .get();
      final returned = prior.read<int>('qty') +
          rma.fold<int>(0, (sum, row) => sum + row.quantityMilli);
      final allocations = await (db.select(db.saleItemInventoryAllocations)
            ..where((a) => a.saleItemId.equals(item.id))
            ..orderBy([
              (a) =>
                  OrderingTerm(expression: const CustomExpression<int>('rowid'))
            ]))
          .get();
      final serialized = allocations.any((a) => a.serialUnitId != null);
      String? limitation;
      final kitSnapshot = await db.customSelect(
        'SELECT 1 FROM sale_item_kit_components WHERE sale_item_id = ? LIMIT 1',
        variables: [Variable.withString(item.id)]).get();
      if (kitSnapshot.isNotEmpty) {
        limitation = 'Kit returns require component restoration and are unavailable in this release.';
      } else if (hasCreditPayment) {
        limitation =
            'Credit sales need a receivable adjustment before a commercial cash return.';
      } else if (item.saleMode == 'made_order' ||
          item.saleMode == 'exchange' ||
          item.saleMode == 'deposit' ||
          item.saleMode == 'refill' ||
          item.saleMode == 'container') {
        limitation = 'This specialty sale needs manual handling.';
      } else if (allocations.fold<int>(0, (sum, a) => sum + a.quantityMilli) !=
          sold) {
        limitation = 'Original inventory allocation is incomplete.';
      } else if (item.batchNumber != null && item.batchId == null) {
        limitation = 'Original batch link is incomplete.';
      } else if (serialized && rma.isNotEmpty) {
        limitation =
            'This serial has an RMA refund; manual handling is required.';
      }
      final serials = <SerialUnit>[];
      for (final allocation
          in allocations.where((a) => a.serialUnitId != null)) {
        final already = await db.customSelect(
            'SELECT 1 FROM sale_return_allocations WHERE original_allocation_id=?',
            variables: [Variable.withString(allocation.id)]).get();
        if (already.isNotEmpty) continue;
        final serial = await (db.select(db.serialUnits)
              ..where((s) => s.id.equals(allocation.serialUnitId!)))
            .getSingleOrNull();
        if (serial != null) serials.add(serial);
      }
      result
          .add(ReturnableLine(item, returned, serials, serialized, limitation));
    }
    return result;
  }

  Future<CommercialReturn> finalize(
          ActiveUser actor, String saleId, List<ReturnSelection> selections,
          {required String reason, String notes = ''}) =>
      _finalize(actor, saleId, selections,
          reason: reason, notes: notes, deferCash: false);

  Future<CommercialReturn> _finalize(
          ActiveUser actor, String saleId, List<ReturnSelection> selections,
          {required String reason,
          required String notes,
          required bool deferCash}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.reverseSale);
        if (reason.trim().isEmpty ||
            (reason == 'Other' && notes.trim().isEmpty)) {
          throw StateError('Select a reason and add notes for Other');
        }
        if (selections.isEmpty ||
            selections.map((s) => s.saleItemId).toSet().length !=
                selections.length) {
          throw StateError('Select at least one unique sale item');
        }
        final sale = await (db.select(db.sales)
              ..where((s) => s.id.equals(saleId)))
            .getSingleOrNull();
        if (sale == null || sale.status != 'completed') {
          throw StateError('Only completed sales can be returned');
        }
        final available = {
          for (final line in await returnable(saleId)) line.item.id: line
        };
        var total = 0;
        final amounts = <String, int>{};
        for (final selection in selections) {
          final line = available[selection.saleItemId];
          if (line == null ||
              line.limitation != null ||
              selection.quantityMilli <= 0 ||
              selection.quantityMilli > line.remainingMilli) {
            throw StateError(line?.limitation ??
                'Return quantity exceeds the remaining sale quantity');
          }
          final allocations = await (db.select(db.saleItemInventoryAllocations)
                ..where((a) => a.saleItemId.equals(line.item.id))
                ..orderBy([
                  (a) => OrderingTerm(
                      expression: const CustomExpression<int>('rowid'))
                ]))
              .get();
          final serialized = allocations.any((a) => a.serialUnitId != null);
          if (serialized) {
            if (selection.quantityMilli !=
                    selection.serialIds.length * Quantity.scale ||
                selection.serialIds.toSet().length !=
                    selection.serialIds.length ||
                !line.returnableSerials
                    .map((s) => s.id)
                    .toSet()
                    .containsAll(selection.serialIds)) {
              throw StateError('Select the exact original serials to return');
            }
          } else if (selection.serialIds.isNotEmpty) {
            throw StateError('This item does not use serial selection');
          }
          final before =
              line.item.lineTotalCents * line.returnedMilli ~/ line.soldMilli;
          final after = line.item.lineTotalCents *
              (line.returnedMilli + selection.quantityMilli) ~/
              line.soldMilli;
          amounts[selection.saleItemId] = after - before;
          total += after - before;
        }
        final rewardSnapshot = await db.customSelect(
            'SELECT * FROM sale_loyalty WHERE sale_id=?',
            variables: [Variable.withString(saleId)]).getSingleOrNull();
        var pointsRestored = 0;
        if (rewardSnapshot != null &&
            rewardSnapshot.read<int>('discount_cents') > 0) {
          final grossSale =
              sale.totalCents + rewardSnapshot.read<int>('discount_cents');
          final priorGrossRow = await db.customSelect(
              '''SELECT COALESCE(SUM(rl.refund_cents),0) AS cents
            FROM sale_return_lines rl JOIN sale_returns r ON r.id=rl.return_id
            WHERE r.original_sale_id=? AND r.status='finalized' ''',
              variables: [Variable.withString(saleId)]).getSingle();
          final beforeGross =
              priorGrossRow.read<int>('cents').clamp(0, grossSale);
          final afterGross = (beforeGross + total).clamp(0, grossSale);
          final discount = rewardSnapshot.read<int>('discount_cents');
          final redeemed = rewardSnapshot.read<int>('redeemed_points');
          total -= discount * afterGross ~/ grossSale -
              discount * beforeGross ~/ grossSale;
          pointsRestored = redeemed * afterGross ~/ grossSale -
              redeemed * beforeGross ~/ grossSale;
        }
        final session = await (db.select(db.cashSessions)
              ..where((s) => s.closedAt.isNull()))
            .getSingleOrNull();
        if (total > 0 && session == null && !deferCash) {
          throw StateError('Open a cash session before paying a cash refund');
        }
        final next = await db.customSelect('''SELECT COALESCE(
      MAX(CAST(SUBSTR(reference,5) AS INTEGER)),0)+1 AS n
      FROM sale_returns WHERE reference GLOB 'RET-[0-9]*' ''').getSingle();
        final reference =
            'RET-${next.read<int>('n').toString().padLeft(6, '0')}';
        final id = const Uuid().v4();
        final now = DateTime.now();
        await db.customStatement('''INSERT INTO sale_returns
      (id,reference,original_sale_id,actor_id,kind,reason,notes,
       status,refund_value_cents,cash_effect_cents,cash_session_id,created_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?)''', [
          id,
          reference,
          saleId,
          live.id,
          'refund',
          reason.trim(),
          notes.trim(),
          deferCash ? 'draft' : 'finalized',
          total,
          deferCash ? 0 : -total,
          deferCash ? null : session?.id,
          now.millisecondsSinceEpoch
        ]);
        for (final selection in selections) {
          final line = available[selection.saleItemId]!;
          final item = line.item;
          final lineId = const Uuid().v4();
          final allocations = await (db.select(db.saleItemInventoryAllocations)
                ..where((a) => a.saleItemId.equals(item.id))
                ..orderBy([
                  (a) => OrderingTerm(
                      expression: const CustomExpression<int>('rowid'))
                ]))
              .get();
          var remaining = selection.quantityMilli;
          var cost = 0;
          final restored = <(SaleItemInventoryAllocation, int)>[];
          for (final allocation in allocations) {
            final prior = await db.customSelect(
                '''SELECT COALESCE(SUM(ra.quantity_milli),0) AS qty
          FROM sale_return_allocations ra JOIN sale_return_lines rl ON rl.id=ra.return_line_id
          WHERE ra.original_allocation_id=?''',
                variables: [Variable.withString(allocation.id)]).getSingle();
            final used = prior.read<int>('qty');
            if (used > allocation.quantityMilli) {
              throw StateError('Return allocation is inconsistent');
            }
            final isSerial = allocation.serialUnitId != null;
            if (isSerial &&
                !selection.serialIds.contains(allocation.serialUnitId)) {
              continue;
            }
            final qty = isSerial
                ? Quantity.scale
                : (remaining < allocation.quantityMilli - used
                    ? remaining
                    : allocation.quantityMilli - used);
            if (qty <= 0) {
              continue;
            }
            remaining -= qty;
            cost += Quantity.lineCents(
                    allocation.unitCostSnapshotCents, used + qty) -
                Quantity.lineCents(allocation.unitCostSnapshotCents, used);
            restored.add((allocation, qty));
            if (remaining == 0) break;
          }
          if (remaining != 0) {
            throw StateError('Original stock allocation is unavailable');
          }
          await db.customStatement('''INSERT INTO sale_return_lines
        (id,return_id,sale_item_id,quantity_milli,refund_cents,disposition,cost_cents)
        VALUES (?,?,?,?,?,?,?)''', [
            lineId,
            id,
            item.id,
            selection.quantityMilli,
            amounts[item.id],
            selection.sellable ? 'sellable' : 'non_sellable',
            cost
          ]);
          for (final part in restored) {
            final allocation = part.$1;
            final qty = part.$2;
            await db.customStatement('''INSERT INTO sale_return_allocations
          (id,return_line_id,original_allocation_id,quantity_milli,serial_unit_id,unit_cost_cents)
          VALUES (?,?,?,?,?,?)''', [
              const Uuid().v4(),
              lineId,
              allocation.id,
              qty,
              allocation.serialUnitId,
              allocation.unitCostSnapshotCents
            ]);
            if (!selection.sellable) continue;
            final layer = await (db.select(db.inventoryLayers)
                  ..where((l) => l.id.equals(allocation.inventoryLayerId)))
                .getSingleOrNull();
            if (layer == null ||
                layer.unitCostCents != allocation.unitCostSnapshotCents) {
              throw StateError(
                  'Original cost layer is unavailable; manual handling required');
            }
            await (db.update(db.inventoryLayers)
                  ..where((l) => l.id.equals(layer.id)))
                .write(InventoryLayersCompanion(
                    quantityRemainingMilli:
                        Value(layer.quantityRemainingMilli + qty)));
            if (allocation.serialUnitId != null) {
              final changed = await (db.update(db.serialUnits)
                    ..where((s) =>
                        s.id.equals(allocation.serialUnitId!) &
                        s.saleItemId.equals(item.id) &
                        s.status.equals('sold')))
                  .write(const SerialUnitsCompanion(
                      status: Value('available'), saleItemId: Value(null)));
              if (changed != 1) {
                throw StateError('Original serial is no longer sold');
              }
            }
          }
          if (selection.sellable) {
            final inventory = await (db.select(db.inventory)
                  ..where((i) => i.productId.equals(item.productId)))
                .getSingleOrNull();
            if (inventory == null) throw StateError('Inventory row is missing');
            final updated = inventory.quantityMilli + selection.quantityMilli;
            await (db.update(db.inventory)
                  ..where((i) => i.productId.equals(item.productId)))
                .write(InventoryCompanion(
                    quantity: Value(updated ~/ Quantity.scale),
                    quantityMilli: Value(updated)));
            if (item.batchId != null) {
              final batch = await (db.select(db.productLots)
                    ..where((b) => b.id.equals(item.batchId!)))
                  .getSingleOrNull();
              if (batch == null) throw StateError('Original batch is missing');
              final today = DateTime.now();
              if (batch.expiryDate != null &&
                  batch.expiryDate!
                      .isBefore(DateTime(today.year, today.month, today.day))) {
                throw StateError(
                    'Original batch has expired; choose non-sellable disposition');
              }
              await (db.update(db.productLots)
                    ..where((b) => b.id.equals(batch.id)))
                  .write(ProductLotsCompanion(
                      quantityMilli: Value(
                          batch.quantityMilli + selection.quantityMilli)));
            }
          }
          await db.into(db.inventoryMovements).insert(
              InventoryMovementsCompanion.insert(
                  productId: item.productId,
                  quantityDelta: selection.sellable
                      ? selection.quantityMilli ~/ Quantity.scale
                      : 0,
                  quantityDeltaMilli:
                      Value(selection.sellable ? selection.quantityMilli : 0),
                  reason: selection.sellable
                      ? 'return_to_stock'
                      : 'return_non_sellable',
                  referenceId: Value(id)));
        }
        if (total > 0 && !deferCash) {
          await db.into(db.cashMovements).insert(CashMovementsCompanion.insert(
              sessionId: session!.id,
              referenceId: Value(id),
              amountCents: -total,
              kind: 'sale_return_refund'));
        }
        final snapshot = rewardSnapshot;
        if (snapshot != null) {
          final eligible = snapshot.read<int>('eligible_cents');
          final earned = snapshot.read<int>('earned_points');
          final prior = await db
              .customSelect('''SELECT COALESCE(SUM(refund_value_cents),0) AS cents
            FROM sale_returns WHERE original_sale_id=? AND id<>? AND status='finalized' ''',
                  variables: [
                Variable.withString(saleId),
                Variable.withString(id)
              ]).getSingle();
          final priorCents = prior.read<int>('cents').clamp(0, eligible);
          final afterCents = (priorCents + total).clamp(0, eligible);
          final reversed = eligible == 0
              ? 0
              : (earned * afterCents ~/ eligible) -
                  (earned * priorCents ~/ eligible);
          await LoyaltyRepository(db).append(
              snapshot.read<String>('customer_id'),
              'return_reversal',
              -reversed,
              sourceId: id,
              actorId: live.id,
              eligibleCents: total,
              snapshot: 'Cumulative proportional earned-point reversal');
          await LoyaltyRepository(db).append(
              snapshot.read<String>('customer_id'),
              'return_restore',
              pointsRestored,
              sourceId: id,
              actorId: live.id,
              eligibleCents: total,
              snapshot: 'Cumulative proportional redemption restoration');
        }
        await AuthRepository(db)
            .audit(live.id, 'sale.return', '$reference:$saleId:$total');
        return CommercialReturn(id, reference, saleId, 'refund', reason.trim(),
            total, 0, deferCash ? 0 : -total, null, now);
      });

  Future<CommercialReturn> exchange(
      ActiveUser actor,
      String saleId,
      List<ReturnSelection> selections,
      List<SaleLineRequest> replacements,
      PosRepository pos,
      {required String reason,
      String notes = '',
      required int cashTenderedCents}) async {
    if (pos.db != db) throw StateError('Exchange must use the same database');
    if (pos.birReady) {
      throw StateError(
          'BIR-ready exchanges require a compliant credit document workflow');
    }
    if (replacements.isEmpty || cashTenderedCents < 0) {
      throw StateError(
          'Select replacement items and enter valid cash tendered');
    }
    return db.transaction(() async {
      final returned = await _finalize(actor, saleId, selections,
          reason: reason, notes: notes, deferCash: true);
      final originalSale = await (db.select(db.sales)
            ..where((s) => s.id.equals(saleId)))
          .getSingle();
      final replacement = await pos.completeExchangeSale(
          replacements, cashTenderedCents, actor.id, returned.refundValueCents,
          customerId: originalSale.customerId);
      final cashEffect = replacement.totalCents - returned.refundValueCents;
      if (cashTenderedCents != (cashEffect > 0 ? cashEffect : 0)) {
        throw StateError('Enter the exact customer payment difference');
      }
      final session = await (db.select(db.cashSessions)
            ..where((s) => s.closedAt.isNull()))
          .getSingleOrNull();
      if (cashEffect < 0) {
        if (session == null) {
          throw StateError('Open a cash session before paying the difference');
        }
        await db.into(db.cashMovements).insert(CashMovementsCompanion.insert(
            sessionId: session.id,
            referenceId: Value(returned.id),
            amountCents: cashEffect,
            kind: 'exchange_refund_difference'));
      }
      await db.customStatement(
          '''UPDATE sale_returns SET kind='exchange',
        replacement_sale_id=?, replacement_value_cents=?,
        cash_effect_cents=?, cash_session_id=?, status='finalized' WHERE id=?''',
          [
            replacement.saleId,
            replacement.totalCents,
            cashEffect,
            session?.id,
            returned.id
          ]);
      return CommercialReturn(
          returned.id,
          returned.reference,
          saleId,
          'exchange',
          reason,
          returned.refundValueCents,
          replacement.totalCents,
          cashEffect,
          replacement.saleId,
          returned.createdAt);
    });
  }
}
