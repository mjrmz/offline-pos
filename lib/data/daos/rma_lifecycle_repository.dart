import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';
import 'sales_repository.dart';
import 'inventory_layer_repository.dart';
import 'stock_receiving_repository.dart';
import 'rma_repository.dart';

/// Structured, append-only facts for claims opened through the new workflow.
/// Legacy rma_cases deliberately have no synthetic lifecycle events.
class RmaLifecycleRepository {
  final AppDatabase db;
  RmaLifecycleRepository(this.db);

  Future<List<RmaLifecycleEvent>> history(String caseId) =>
      (db.select(db.rmaLifecycleEvents)
            ..where((e) => e.caseId.equals(caseId))
            ..orderBy([
              (e) =>
                  OrderingTerm(expression: const CustomExpression<int>('rowid'))
            ]))
          .get();

  Future<RmaCase> _case(String id) async =>
      (await (db.select(db.rmaCases)..where((r) => r.id.equals(id)))
          .getSingleOrNull()) ??
      (throw StateError('RMA not found'));

  Future<ActiveUser> _actor(ActiveUser actor) async {
    final live = await AuthRepository(db).requireActive(actor.id);
    live.require(PosPermission.manageRma);
    return live;
  }

  Future<RmaLifecycleEvent> _record(
      ActiveUser actor, String caseId, String action,
      {int? quantityMilli,
      String? expectedSerial,
      String? returnedSerial,
      String? condition,
      bool? faultReproduced,
      String? finding,
      String? outcome,
      String? disposition,
      int? amountCents,
      String? method,
      String? serialUnitId,
      String? relatedCaseId,
      String? recipient,
      String? note}) async {
    final event = await db
        .into(db.rmaLifecycleEvents)
        .insertReturning(RmaLifecycleEventsCompanion.insert(
          caseId: caseId,
          actorId: actor.id,
          action: action,
          quantityMilli: Value(quantityMilli),
          expectedSerial: Value(expectedSerial),
          returnedSerial: Value(returnedSerial),
          condition: Value(condition),
          faultReproduced: Value(faultReproduced),
          finding: Value(finding),
          outcome: Value(outcome),
          disposition: Value(disposition),
          amountCents: Value(amountCents),
          method: Value(method),
          serialUnitId: Value(serialUnitId),
          relatedCaseId: Value(relatedCaseId),
          recipient: Value(recipient),
          note: Value(note?.trim()),
        ));
    await AuthRepository(db).audit(actor.id, 'rma.$action', caseId);
    return event;
  }

  int _sum(List<RmaLifecycleEvent> events, String action) => events
      .where((e) => e.action == action)
      .fold<int>(0, (sum, e) => sum + (e.quantityMilli ?? 0));
  bool _has(List<RmaLifecycleEvent> events, String action) =>
      events.any((e) => e.action == action);

  Future<void> _recordWarranty(String serialId, String caseId, String eventId,
      String treatment, String source,
      {String? originalSerialId, DateTime? endAt, String? note}) async {
    if (!{'continue_original', 'restart', 'custom', 'none', 'unknown'}
        .contains(treatment)) {
      throw StateError('Invalid warranty treatment');
    }
    DateTime? start;
    DateTime? end;
    var factSource = source;
    if (treatment == 'continue_original') {
      final prior = originalSerialId == null
          ? null
          : (await (db.select(db.serialWarrantySnapshots)
                    ..where((w) => w.serialUnitId.equals(originalSerialId))
                    ..orderBy([(w) => OrderingTerm.desc(w.createdAt)]))
                  .get())
              .firstOrNull;
      start = prior?.startAt;
      end = prior?.endAt;
      if (prior == null || prior.treatment == 'unknown') {
        factSource = 'legacy_unknown';
      }
    } else if (treatment == 'restart' || treatment == 'custom') {
      start = DateTime.now();
      if (endAt == null || !endAt.isAfter(start)) {
        throw StateError('Enter an explicit future warranty end date');
      }
      end = endAt;
    }
    await db
        .into(db.serialWarrantySnapshots)
        .insert(SerialWarrantySnapshotsCompanion.insert(
          serialUnitId: serialId,
          sourceRmaCaseId: Value(caseId),
          sourceEventId: Value(eventId),
          treatment: treatment,
          source: factSource,
          startAt: Value(start),
          endAt: Value(end),
          note: Value(note?.trim()),
        ));
  }

  /// Quarantines exact store-owned receiving stock and opens a supplier claim.
  /// No customer or sale is needed for this path.
  Future<RmaCase> requestDirectSupplier(ActiveUser actor,
          String receivingItemId, String issue, String condition,
          {String? serialUnitId, int quantityMilli = 1000, String? notes}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await RmaRepository(db).openInbound(
            live, receivingItemId, issue, condition,
            serialUnitId: serialUnitId,
            quantityMilli: quantityMilli,
            notes: notes);
        await _record(live, row.id, 'supplier_intake',
            quantityMilli: quantityMilli,
            serialUnitId: serialUnitId,
            note: notes);
        return row;
      });

  Future<void> sendDirectSupplier(ActiveUser actor, String caseId,
          {String? note}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await _case(caseId);
        final events = await history(caseId);
        if (row.origin != 'inbound' ||
            !_has(events, 'supplier_intake') ||
            _has(events, 'supplier_requested')) {
          throw StateError('Direct supplier claim awaiting shipment required');
        }
        await _record(live, caseId, 'supplier_requested', note: note);
        await _record(live, caseId, 'custody_supplier',
            serialUnitId: row.serialUnitId);
        await (db.update(db.rmaCases)..where((r) => r.id.equals(caseId)))
            .write(const RmaCasesCompanion(status: Value('sent_to_supplier')));
      });

  Future<RmaCase> request(ActiveUser actor, String saleItemId, String issue,
          {String? serialUnitId, int quantityMilli = 1000, String? notes}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        if (issue.trim().isEmpty) throw StateError('Reported issue required');
        final item = await (db.select(db.saleItems)
              ..where((i) => i.id.equals(saleItemId)))
            .getSingleOrNull();
        if (item == null) throw StateError('Sale item not found');
        final sale = await (db.select(db.sales)
              ..where((s) => s.id.equals(item.saleId)))
            .getSingle();
        if (sale.status != 'completed') {
          throw StateError('Sale is not eligible');
        }
        final product = await (db.select(db.products)
              ..where((p) => p.id.equals(item.productId)))
            .getSingle();
        final config =
            await BusinessFeatureRepository(db).businessProduct(product.id);
        if (quantityMilli <= 0 ||
            quantityMilli > item.quantityMilli ||
            (!config.fractional && quantityMilli % 1000 != 0) ||
            (product.serialTracking && quantityMilli != 1000)) {
          throw StateError('Invalid claim quantity');
        }
        final prior = await (db.select(db.rmaCases)
              ..where((r) => r.saleItemId.equals(item.id)))
            .get();
        if (prior.fold<int>(0, (n, r) => n + r.quantityMilli) + quantityMilli >
            item.quantityMilli) {
          throw StateError('Claim exceeds sold quantity');
        }
        if (product.serialTracking) {
          if (serialUnitId == null) {
            throw StateError('Select exact sold serial');
          }
          final serial = await (db.select(db.serialUnits)
                ..where((s) => s.id.equals(serialUnitId)))
              .getSingleOrNull();
          final link = await (db.select(db.serialSaleLinks)
                ..where((l) =>
                    l.serialUnitId.equals(serialUnitId) &
                    l.saleItemId.equals(item.id)))
              .getSingleOrNull();
          if (serial == null ||
              link == null ||
              serial.status != 'sold' ||
              serial.saleItemId != item.id) {
            throw StateError('Serial was not sold on this receipt');
          }
          final duplicate =
              prior.where((r) => r.serialUnitId == serialUnitId).firstOrNull;
          if (duplicate != null) {
            throw StateError('Serial already has RMA ${duplicate.reference}');
          }
        } else if (serialUnitId != null) {
          throw StateError('This product does not use serials');
        }
        final year = DateTime.now().year;
        final refs = await db.customSelect(
            'SELECT reference FROM rma_cases WHERE reference LIKE ? '
            'ORDER BY reference DESC LIMIT 1',
            variables: [Variable.withString('RMA-$year-%')]).get();
        final last = refs.isEmpty
            ? 0
            : int.tryParse(
                    refs.first.read<String>('reference').split('-').last) ??
                0;
        final reference = 'RMA-$year-${(last + 1).toString().padLeft(6, '0')}';
        final row =
            await db.into(db.rmaCases).insertReturning(RmaCasesCompanion.insert(
                  reference: reference,
                  origin: 'customer',
                  saleId: Value(sale.id),
                  saleItemId: Value(item.id),
                  customerId: Value(sale.customerId),
                  serialUnitId: Value(serialUnitId),
                  issueDescription: issue.trim(),
                  intakeCondition: '',
                  quantityMilli: Value(quantityMilli),
                  notes: Value(notes?.trim()),
                ));
        await _record(live, row.id, 'requested',
            quantityMilli: quantityMilli,
            serialUnitId: serialUnitId,
            note: notes);
        return row;
      });

  Future<void> approve(ActiveUser actor, String caseId, {String? note}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await _case(caseId);
        final events = await history(caseId);
        if (row.status != 'pending' ||
            !_has(events, 'requested') ||
            _has(events, 'approved')) {
          throw StateError('Claim is not awaiting approval');
        }
        await _record(live, caseId, 'approved',
            quantityMilli: row.quantityMilli, note: note);
      });

  Future<void> reject(ActiveUser actor, String caseId, String reason) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final events = await history(caseId);
        if (reason.trim().isEmpty ||
            !_has(events, 'requested') ||
            _has(events, 'approved') ||
            _has(events, 'rejected') ||
            _has(events, 'cancelled')) {
          throw StateError('Cannot reject claim');
        }
        await (db.update(db.rmaCases)..where((r) => r.id.equals(caseId)))
            .write(const RmaCasesCompanion(status: Value('rejected')));
        await _record(live, caseId, 'rejected', note: reason);
      });

  Future<void> cancel(ActiveUser actor, String caseId, String reason) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final events = await history(caseId);
        if (reason.trim().isEmpty ||
            !_has(events, 'requested') ||
            _has(events, 'received') ||
            _has(events, 'refund_executed') ||
            _has(events, 'replacement_reserved') ||
            _has(events, 'cancelled') ||
            _has(events, 'rejected')) {
          throw StateError('Claim cannot be cancelled');
        }
        await (db.update(db.rmaCases)..where((r) => r.id.equals(caseId)))
            .write(const RmaCasesCompanion(status: Value('cancelled')));
        await _record(live, caseId, 'cancelled', note: reason);
      });

  Future<void> receive(ActiveUser actor, String caseId, int quantityMilli,
          {String? returnedSerial, String? overrideReason, String? note}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await _case(caseId);
        final events = await history(caseId);
        if (row.status != 'pending' ||
            !_has(events, 'approved') ||
            _has(events, 'cancelled') ||
            quantityMilli <= 0 ||
            _sum(events, 'received') + quantityMilli > row.quantityMilli) {
          throw StateError('Receipt exceeds approved outstanding quantity');
        }
        String? expected;
        if (row.serialUnitId != null) {
          if (quantityMilli != 1000 || _has(events, 'received')) {
            throw StateError('Serial already received or quantity invalid');
          }
          final serial = await (db.select(db.serialUnits)
                ..where((s) => s.id.equals(row.serialUnitId!)))
              .getSingle();
          expected = serial.serialNumber;
          if (returnedSerial?.trim().isEmpty != false) {
            throw StateError('Record the physical serial');
          }
          if (returnedSerial!.trim() != expected) {
            if (live.role != UserRole.owner ||
                overrideReason?.trim().isEmpty != false) {
              throw StateError('Owner reason required for serial mismatch');
            }
            await _record(live, caseId, 'serial_override',
                expectedSerial: expected,
                returnedSerial: returnedSerial.trim(),
                note: overrideReason);
          }
          if (returnedSerial.trim() == expected) {
            final changed = await (db.update(db.serialUnits)
                  ..where(
                      (s) => s.id.equals(serial.id) & s.status.equals('sold')))
                .write(const SerialUnitsCompanion(status: Value('rma')));
            if (changed != 1) throw StateError('Sold serial state changed');
          }
        }
        await _record(live, caseId, 'received',
            quantityMilli: quantityMilli,
            expectedSerial: expected,
            returnedSerial: returnedSerial?.trim(),
            serialUnitId: row.serialUnitId,
            note: note);
        await _record(live, caseId, 'custody_store',
            quantityMilli: quantityMilli, serialUnitId: row.serialUnitId);
      });

  Future<void> inspect(ActiveUser actor, String caseId, int quantityMilli,
          String condition, bool? faultReproduced, String finding,
          {String? note}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await _case(caseId);
        final events = await history(caseId);
        if (condition.trim().isEmpty ||
            finding.trim().isEmpty ||
            quantityMilli <= 0 ||
            _sum(events, 'inspected') + quantityMilli >
                _sum(events, 'received') ||
            (row.serialUnitId != null &&
                (quantityMilli != 1000 || _has(events, 'inspected')))) {
          throw StateError('Inspection requires uninspected received quantity');
        }
        await _record(live, caseId, 'inspected',
            quantityMilli: quantityMilli,
            condition: condition.trim(),
            faultReproduced: faultReproduced,
            finding: finding.trim(),
            serialUnitId: row.serialUnitId,
            note: note);
      });

  Future<void> authorize(
          ActiveUser actor, String caseId, String outcome, String disposition,
          {int? amountCents, String? method, String? note}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await _case(caseId);
        final events = await history(caseId);
        if (_sum(events, 'inspected') != row.quantityMilli ||
            _has(events, 'intent') ||
            row.status != 'pending') {
          throw StateError('Inspect the full claim before resolution');
        }
        final allowed = <String, Set<String>>{
          'refund': {'restock', 'scrap', 'hold', 'supplier'},
          'replacement': {'restock', 'scrap', 'hold', 'supplier'},
          'supplier_warranty': {'supplier'},
          'no_fault': {'return_to_customer'},
          'reject_claim': {'return_to_customer'},
        };
        if (allowed[outcome]?.contains(disposition) != true) {
          throw StateError('Outcome and disposition are incompatible');
        }
        if (outcome == 'supplier_warranty' && row.serialUnitId == null) {
          throw StateError(
              'Supplier warranty handoff requires an exact serial');
        }
        if (outcome == 'reject_claim' && (note?.trim().isEmpty ?? true)) {
          throw StateError('A rejection reason is required');
        }
        if (outcome == 'refund') {
          if (!{'cash', 'obligation'}.contains(method) ||
              (row.customerId == null && method != 'cash')) {
            throw StateError('Choose a valid refund execution method');
          }
          final quote = await SalesRepository(db).quoteItemRefund(caseId);
          if (amountCents != quote.amountCents) {
            throw StateError('Refund must match original sale value');
          }
        }
        if (disposition == 'restock' &&
            events.where((e) => e.action == 'inspected').any((e) =>
                !{'good', 'opened'}.contains(e.condition?.toLowerCase()))) {
          throw StateError('Inspection condition does not permit restock');
        }
        await _record(live, caseId, 'intent',
            outcome: outcome,
            disposition: disposition,
            amountCents: amountCents,
            method: method,
            note: note);
        if (disposition == 'supplier') {
          await _createLinkedSupplier(live, caseId, note: note);
        }
      });

  Future<void> executeRefund(ActiveUser actor, String caseId,
          {required bool payCashNow}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        live.require(PosPermission.reverseSale);
        final events = await history(caseId);
        final intent = events
            .where((e) => e.action == 'intent' && e.outcome == 'refund')
            .firstOrNull;
        if (intent == null ||
            _has(events, 'refund_executed') ||
            _has(events, 'refund_obligation')) {
          throw StateError('Refund was not authorized or was already executed');
        }
        if ((intent.method == 'cash') != payCashNow) {
          throw StateError('Refund method differs from authorized intent');
        }
        final refund = await SalesRepository(db)
            .refundItemForRma(live, caseId, payCashNow: payCashNow);
        await _record(
            live,
            caseId,
            refund.obligationCents > 0
                ? 'refund_obligation'
                : 'refund_executed',
            amountCents: refund.amountCents,
            method: payCashNow ? 'cash' : 'obligation');
        await _completeIfReady(live, caseId);
      });

  Future<void> confirmRefundSettled(ActiveUser actor, String caseId) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final events = await history(caseId);
        if (!_has(events, 'refund_obligation') ||
            _has(events, 'refund_executed')) {
          throw StateError('No unsettled RMA refund obligation');
        }
        final obligation = await (db.select(db.customerRefundObligations)
              ..where((o) => o.rmaCaseId.equals(caseId)))
            .getSingleOrNull();
        if (obligation == null ||
            obligation.settledCents < obligation.amountCents) {
          throw StateError('Settle the customer refund obligation first');
        }
        await _record(live, caseId, 'refund_executed',
            amountCents: obligation.amountCents, method: 'settled_obligation');
        await _completeIfReady(live, caseId);
      });

  Future<void> reserveReplacement(
          ActiveUser actor, String caseId, String serialUnitId) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await _case(caseId);
        final events = await history(caseId);
        final latestReservation = events
            .where((e) =>
                e.action == 'replacement_reserved' ||
                e.action == 'replacement_released')
            .lastOrNull;
        if (!events.any(
                (e) => e.action == 'intent' && e.outcome == 'replacement') ||
            latestReservation?.action == 'replacement_reserved' ||
            _has(events, 'handoff')) {
          throw StateError('Replacement is not awaiting reservation');
        }
        final item = await (db.select(db.saleItems)
              ..where((i) => i.id.equals(row.saleItemId!)))
            .getSingle();
        final product = await (db.select(db.products)
              ..where((p) => p.id.equals(item.productId)))
            .getSingle();
        if (!product.serialTracking || row.quantityMilli != 1000) {
          throw StateError('Exact serial reservation requires one serial unit');
        }
        final serial = await (db.select(db.serialUnits)
              ..where((s) => s.id.equals(serialUnitId)))
            .getSingleOrNull();
        if (serial == null ||
            serial.productId != product.id ||
            serial.status != 'available') {
          throw StateError('Replacement serial is unavailable');
        }
        final changed = await (db.update(db.serialUnits)
              ..where(
                  (s) => s.id.equals(serial.id) & s.status.equals('available')))
            .write(const SerialUnitsCompanion(status: Value('rma_reserved')));
        if (changed != 1) throw StateError('Replacement already reserved');
        await _record(live, caseId, 'replacement_reserved',
            serialUnitId: serial.id);
      });

  Future<void> releaseReplacement(ActiveUser actor, String caseId,
          {String? reason}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final events = await history(caseId);
        final reservations =
            events.where((e) => e.action == 'replacement_reserved').toList();
        if (reservations.isEmpty ||
            _has(events, 'handoff') ||
            events
                    .lastWhere((e) =>
                        e.action == 'replacement_reserved' ||
                        e.action == 'replacement_released')
                    .action !=
                'replacement_reserved') {
          throw StateError('No active replacement reservation');
        }
        final serialId = reservations.last.serialUnitId!;
        final changed = await (db.update(db.serialUnits)
              ..where((s) =>
                  s.id.equals(serialId) & s.status.equals('rma_reserved')))
            .write(const SerialUnitsCompanion(status: Value('available')));
        if (changed != 1) throw StateError('Reservation state changed');
        await _record(live, caseId, 'replacement_released',
            serialUnitId: serialId, note: reason);
      });

  Future<void> executeDisposition(ActiveUser actor, String caseId) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await _case(caseId);
        final events = await history(caseId);
        final intent = events.where((e) => e.action == 'intent').firstOrNull;
        if (intent == null || _has(events, 'disposition_executed')) {
          throw StateError('No pending physical disposition');
        }
        if (intent.disposition == 'hold' ||
            intent.disposition == 'supplier' ||
            intent.disposition == 'return_to_customer') {
          throw StateError('This disposition needs a separate custody action');
        }
        if (intent.disposition != 'restock' && intent.disposition != 'scrap') {
          throw StateError('Unsupported physical disposition');
        }
        final receipt = events.where((e) => e.action == 'received').firstOrNull;
        final exactSerial = row.serialUnitId == null ||
            receipt?.expectedSerial == receipt?.returnedSerial;
        if (intent.disposition == 'restock' && !exactSerial) {
          throw StateError('Mismatched serial cannot be restocked as original');
        }
        final item = await (db.select(db.saleItems)
              ..where((i) => i.id.equals(row.saleItemId!)))
            .getSingle();
        if (intent.disposition == 'restock') {
          final allocations = await (db.select(db.saleItemInventoryAllocations)
                ..where((a) => a.saleItemId.equals(item.id))
                ..orderBy([
                  (a) => OrderingTerm(expression: a.createdAt),
                  (a) => OrderingTerm(expression: a.id)
                ]))
              .get();
          if (allocations.isEmpty) {
            throw StateError('Original inventory allocation unavailable');
          }
          if (row.serialUnitId != null) {
            final original = allocations
                .where((a) => a.serialUnitId == row.serialUnitId)
                .firstOrNull;
            if (original == null) {
              throw StateError('Original serial allocation unavailable');
            }
            await _restoreLayer(original.inventoryLayerId, row.quantityMilli);
          } else {
            final prior = await (db.select(db.rmaCases)
                  ..where((r) =>
                      r.saleItemId.equals(item.id) &
                      r.unitDisposition.equals('restock')))
                .get();
            var skip = prior.fold<int>(0, (n, r) => n + r.quantityMilli);
            final priorEvents = await db.customSelect('''
              SELECT COALESCE(SUM(c.quantity_milli), 0) AS restored
              FROM rma_cases c JOIN rma_lifecycle_events e ON e.case_id = c.id
              WHERE c.sale_item_id = ? AND e.action = 'disposition_executed'
                AND e.disposition = 'restock'
            ''', variables: [Variable.withString(item.id)]).getSingle();
            skip += priorEvents.read<int>('restored');
            var remaining = row.quantityMilli;
            for (final allocation in allocations) {
              if (skip >= allocation.quantityMilli) {
                skip -= allocation.quantityMilli;
                continue;
              }
              final available = allocation.quantityMilli - skip;
              skip = 0;
              final amount = remaining < available ? remaining : available;
              await _restoreLayer(allocation.inventoryLayerId, amount);
              remaining -= amount;
              if (remaining == 0) break;
            }
            if (remaining != 0) {
              throw StateError('Return exceeds original allocation');
            }
          }
          final stock = await (db.select(db.inventory)
                ..where((i) => i.productId.equals(item.productId)))
              .getSingle();
          final next = stock.quantityMilli + row.quantityMilli;
          await (db.update(db.inventory)
                ..where((i) => i.productId.equals(item.productId)))
              .write(InventoryCompanion(
                  quantity: Value(next ~/ 1000), quantityMilli: Value(next)));
          await db.into(db.inventoryMovements).insert(
              InventoryMovementsCompanion.insert(
                  productId: item.productId,
                  quantityDelta: row.quantityMilli ~/ 1000,
                  quantityDeltaMilli: Value(row.quantityMilli),
                  reason: 'rma_restock',
                  referenceId: Value(caseId)));
          if (item.batchNumber != null) {
            final lot = await (db.select(db.productLots)
                  ..where((l) =>
                      l.productId.equals(item.productId) &
                      l.batchNumber.equals(item.batchNumber!)))
                .getSingle();
            await (db.update(db.productLots)..where((l) => l.id.equals(lot.id)))
                .write(ProductLotsCompanion(
                    quantityMilli:
                        Value(lot.quantityMilli + row.quantityMilli)));
          }
        }
        if (intent.disposition == 'scrap') {
          await db.into(db.inventoryMovements).insert(
              InventoryMovementsCompanion.insert(
                  productId: item.productId,
                  quantityDelta: 0,
                  quantityDeltaMilli: const Value(0),
                  reason: 'rma_scrap',
                  referenceId: Value(caseId)));
        }
        if (row.serialUnitId != null && exactSerial) {
          final next =
              intent.disposition == 'restock' ? 'available' : 'scrapped';
          final changed = await (db.update(db.serialUnits)
                ..where((s) =>
                    s.id.equals(row.serialUnitId!) & s.status.equals('rma')))
              .write(SerialUnitsCompanion(status: Value(next)));
          if (changed != 1) throw StateError('Returned serial state changed');
        }
        await _record(live, caseId, 'disposition_executed',
            quantityMilli: row.quantityMilli,
            disposition: intent.disposition,
            serialUnitId: row.serialUnitId);
        await _completeIfReady(live, caseId);
      });

  Future<void> _restoreLayer(String layerId, int quantityMilli) async {
    final layer = await (db.select(db.inventoryLayers)
          ..where((l) => l.id.equals(layerId)))
        .getSingle();
    final next = layer.quantityRemainingMilli + quantityMilli;
    if (next > layer.quantityReceivedMilli) {
      throw StateError('Original inventory layer is already full');
    }
    await (db.update(db.inventoryLayers)..where((l) => l.id.equals(layerId)))
        .write(InventoryLayersCompanion(quantityRemainingMilli: Value(next)));
  }

  Future<void> handoff(ActiveUser actor, String caseId, String recipient,
          {String? serialUnitId,
          String? note,
          String warrantyTreatment = 'continue_original',
          DateTime? warrantyEndAt,
          String? warrantyNote}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        if ({'restart', 'custom', 'none'}.contains(warrantyTreatment)) {
          live.require(PosPermission.manageUsers);
        }
        final row = await _case(caseId);
        final events = await history(caseId);
        final intent = events.where((e) => e.action == 'intent').firstOrNull;
        if (recipient.trim().isEmpty ||
            intent == null ||
            _has(events, 'handoff')) {
          throw StateError('Customer handoff is not available');
        }
        if (intent.outcome == 'replacement') {
          final latest = events
              .where((e) =>
                  e.action == 'replacement_reserved' ||
                  e.action == 'replacement_released')
              .lastOrNull;
          if (latest == null ||
              latest.action != 'replacement_reserved' ||
              latest.serialUnitId != serialUnitId ||
              (intent.disposition == 'restock' ||
                      intent.disposition == 'scrap') &&
                  !_has(events, 'disposition_executed')) {
            throw StateError(
                'Exact reserved replacement and original disposition required');
          }
          final serial = await (db.select(db.serialUnits)
                ..where((s) => s.id.equals(serialUnitId!)))
              .getSingle();
          if (serial.status != 'rma_reserved') {
            throw StateError('Replacement reservation changed');
          }
          await InventoryLayerRepository(db)
              .consume(serial.productId, 1000, serials: [serial]);
          final stock = await (db.select(db.inventory)
                ..where((i) => i.productId.equals(serial.productId)))
              .getSingle();
          final next = stock.quantityMilli - 1000;
          if (next < 0) throw StateError('Replacement stock unavailable');
          await (db.update(db.inventory)
                ..where((i) => i.productId.equals(serial.productId)))
              .write(InventoryCompanion(
                  quantity: Value(next ~/ 1000), quantityMilli: Value(next)));
          await db.into(db.inventoryMovements).insert(
              InventoryMovementsCompanion.insert(
                  productId: serial.productId,
                  quantityDelta: -1,
                  quantityDeltaMilli: const Value(-1000),
                  reason: 'rma_replacement',
                  referenceId: Value(caseId)));
          await (db.update(db.serialUnits)
                ..where((s) => s.id.equals(serial.id)))
              .write(const SerialUnitsCompanion(status: Value('sold')));
        } else if (intent.outcome == 'supplier_warranty') {
          final link = events
              .where((e) => e.action == 'supplier_claim_opened')
              .lastOrNull;
          if (link?.relatedCaseId == null) {
            throw StateError('Linked supplier claim required');
          }
          final supplierEvents = await history(link!.relatedCaseId!);
          final fulfillment = supplierEvents
              .where((e) =>
                  e.action == 'supplier_fulfilled' &&
                  {'replacement', 'repair', 'no_fault', 'rejected'}
                      .contains(e.outcome))
              .lastOrNull;
          if (fulfillment?.outcome == 'rejected' &&
              !supplierEvents.any((e) =>
                  e.action == 'supplier_disposition' &&
                  e.disposition == 'return_to_customer')) {
            throw StateError('Rejected item is not ready for customer return');
          }
          if (fulfillment?.serialUnitId != serialUnitId) {
            throw StateError('Exact supplier-returned unit required');
          }
          final changed = await (db.update(db.serialUnits)
                ..where(
                    (s) => s.id.equals(serialUnitId!) & s.status.equals('rma')))
              .write(const SerialUnitsCompanion(status: Value('sold')));
          if (changed != 1) {
            throw StateError('Supplier replacement hold changed');
          }
        } else if (intent.outcome == 'no_fault' ||
            intent.outcome == 'reject_claim' ||
            intent.outcome == 'repaired_return') {
          if (row.serialUnitId != null && serialUnitId != row.serialUnitId) {
            throw StateError('Handoff requires the exact original serial');
          }
          final receipt =
              events.where((e) => e.action == 'received').firstOrNull;
          if (row.serialUnitId != null &&
              receipt?.expectedSerial != receipt?.returnedSerial) {
            throw StateError('Mismatched serial needs separate resolution');
          }
          if (row.serialUnitId != null) {
            final changed = await (db.update(db.serialUnits)
                  ..where((s) =>
                      s.id.equals(row.serialUnitId!) & s.status.equals('rma')))
                .write(const SerialUnitsCompanion(status: Value('sold')));
            if (changed != 1) throw StateError('Original serial state changed');
          }
        } else {
          throw StateError('This outcome has no customer handoff');
        }
        final handoffEvent = await _record(live, caseId, 'handoff',
            recipient: recipient.trim(),
            serialUnitId: serialUnitId,
            note: note);
        if (serialUnitId != null) {
          await _recordWarranty(serialUnitId, caseId, handoffEvent.id,
              warrantyTreatment, 'customer_handoff',
              originalSerialId: row.serialUnitId,
              endAt: warrantyEndAt,
              note: warrantyNote);
        }
        if (intent.outcome == 'no_fault' ||
            intent.outcome == 'reject_claim' ||
            intent.outcome == 'repaired_return' ||
            (intent.outcome == 'supplier_warranty' &&
                serialUnitId == row.serialUnitId)) {
          await _record(live, caseId, 'custody_customer',
              serialUnitId: serialUnitId);
        }
        await _completeIfReady(live, caseId);
      });

  Future<RmaCase> _createLinkedSupplier(ActiveUser live, String customerCaseId,
      {String? note}) async {
    final claim = await _case(customerCaseId);
    final events = await history(customerCaseId);
    final intent = events.where((e) => e.action == 'intent').firstOrNull;
    final existing =
        events.where((e) => e.action == 'supplier_claim_opened').lastOrNull;
    if (existing?.relatedCaseId != null) {
      return _case(existing!.relatedCaseId!);
    }
    if (claim.origin != 'customer' ||
        intent?.disposition != 'supplier' ||
        _sum(events, 'inspected') != claim.quantityMilli) {
      throw StateError(
          'Inspected customer claim with supplier disposition required');
    }
    String? receivingItemId;
    if (claim.serialUnitId != null) {
      final receipt = events.where((e) => e.action == 'received').firstOrNull;
      if (receipt?.expectedSerial != receipt?.returnedSerial) {
        throw StateError('Mismatched serial has no safe supplier provenance');
      }
      final serial = await (db.select(db.serialUnits)
            ..where((s) => s.id.equals(claim.serialUnitId!)))
          .getSingle();
      receivingItemId = serial.receivingItemId;
    } else {
      final allocations = await (db.select(db.saleItemInventoryAllocations)
            ..where((a) => a.saleItemId.equals(claim.saleItemId!)))
          .get();
      final sourceIds = <String>{};
      for (final allocation in allocations) {
        final layer = await (db.select(db.inventoryLayers)
              ..where((l) => l.id.equals(allocation.inventoryLayerId)))
            .getSingle();
        if (layer.receivingItemId != null) {
          sourceIds.add(layer.receivingItemId!);
        } else {
          sourceIds.add('unknown');
        }
      }
      if (sourceIds.length == 1 && !sourceIds.contains('unknown')) {
        receivingItemId = sourceIds.single;
      }
    }
    if (receivingItemId == null) {
      throw StateError('Missing or ambiguous receiving provenance');
    }
    final source = await (db.select(db.stockReceivingItems)
          ..where((i) => i.id.equals(receivingItemId!)))
        .getSingle();
    final receiving = await (db.select(db.stockReceivings)
          ..where((r) => r.id.equals(source.receivingId)))
        .getSingle();
    final year = DateTime.now().year;
    final refs = await db.customSelect(
        'SELECT reference FROM rma_cases WHERE reference LIKE ? '
        'ORDER BY reference DESC LIMIT 1',
        variables: [Variable.withString('SRMA-$year-%')]).get();
    final last = refs.isEmpty
        ? 0
        : int.tryParse(refs.first.read<String>('reference').split('-').last) ??
            0;
    final row =
        await db.into(db.rmaCases).insertReturning(RmaCasesCompanion.insert(
              reference: 'SRMA-$year-${(last + 1).toString().padLeft(6, '0')}',
              origin: 'inbound',
              receivingId: Value(receiving.id),
              receivingItemId: Value(source.id),
              supplierId: Value(receiving.supplierId),
              serialUnitId: Value(claim.serialUnitId),
              issueDescription: claim.issueDescription,
              intakeCondition: '',
              quantityMilli: Value(claim.quantityMilli),
              status: const Value('pending'),
            ));
    await _record(live, row.id, 'supplier_created',
        relatedCaseId: customerCaseId,
        quantityMilli: claim.quantityMilli,
        finding:
            events.where((e) => e.action == 'inspected').lastOrNull?.finding,
        note: note);
    await _record(live, customerCaseId, 'supplier_claim_opened',
        relatedCaseId: row.id, note: note);
    return row;
  }

  Future<RmaCase> sendToSupplier(ActiveUser actor, String customerCaseId,
          {String? note, String? supplierReference}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await _createLinkedSupplier(live, customerCaseId);
        await _sendLinkedSupplier(live, row,
            note: note, supplierReference: supplierReference);
        return row;
      });

  Future<RmaCase> createLinkedSupplier(ActiveUser actor, String customerCaseId,
          {String? note}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        return _createLinkedSupplier(live, customerCaseId, note: note);
      });

  Future<void> sendLinkedSupplier(ActiveUser actor, String supplierCaseId,
          {String? note, String? supplierReference}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await _case(supplierCaseId);
        await _sendLinkedSupplier(live, row,
            note: note, supplierReference: supplierReference);
      });

  Future<void> _sendLinkedSupplier(ActiveUser live, RmaCase row,
      {String? note, String? supplierReference}) async {
    final events = await history(row.id);
    final link = events.where((e) => e.action == 'supplier_created').lastOrNull;
    if (link?.relatedCaseId == null ||
        _has(events, 'supplier_requested') ||
        row.status != 'pending') {
      throw StateError('Linked supplier claim is not ready to send');
    }
    final customerCaseId = link!.relatedCaseId!;
    await _record(live, row.id, 'supplier_requested',
        relatedCaseId: customerCaseId,
        quantityMilli: row.quantityMilli,
        finding: supplierReference,
        note: note);
    await (db.update(db.rmaCases)..where((r) => r.id.equals(row.id)))
        .write(const RmaCasesCompanion(status: Value('sent_to_supplier')));
    final claim = await _case(customerCaseId);
    await _record(live, customerCaseId, 'custody_supplier',
        serialUnitId: claim.serialUnitId, relatedCaseId: row.id);
  }

  Future<void> supplierDecision(
          ActiveUser actor, String supplierCaseId, String decision,
          {String? note}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await _case(supplierCaseId);
        final events = await history(supplierCaseId);
        if (row.origin != 'inbound' ||
            !_has(events, 'supplier_requested') ||
            _has(events, 'supplier_decision') ||
            !{'repair', 'replacement', 'credit', 'no_fault', 'rejected'}
                .contains(decision)) {
          throw StateError('Supplier decision unavailable');
        }
        if (row.serialUnitId == null && decision != 'credit') {
          throw StateError('Exact serial required for this supplier outcome');
        }
        await _record(live, supplierCaseId, 'supplier_decision',
            outcome: decision, note: note);
        if (decision == 'rejected') {
          await (db.update(db.rmaCases)
                ..where((r) => r.id.equals(supplierCaseId)))
              .write(const RmaCasesCompanion(status: Value('rejected')));
        }
      });

  Future<void> supplierCredit(ActiveUser actor, String supplierCaseId,
          int amountCents, String externalReference) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final events = await history(supplierCaseId);
        if (amountCents <= 0 ||
            externalReference.trim().isEmpty ||
            !events.any((e) =>
                e.action == 'supplier_decision' && e.outcome == 'credit') ||
            _has(events, 'supplier_fulfilled')) {
          throw StateError('Supplier credit requires decision and reference');
        }
        await _record(live, supplierCaseId, 'supplier_fulfilled',
            outcome: 'credit',
            amountCents: amountCents,
            note: externalReference.trim());
        await (db.update(db.rmaCases)
              ..where((r) => r.id.equals(supplierCaseId)))
            .write(const RmaCasesCompanion(status: Value('resolved')));
        await _record(live, supplierCaseId, 'completed');
      });

  Future<void> supplierReturnOriginal(ActiveUser actor, String supplierCaseId,
          String returnedSerial, String condition,
          {String? reference, String? note}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await _case(supplierCaseId);
        final events = await history(supplierCaseId);
        final decision = events
            .where((e) => e.action == 'supplier_decision')
            .lastOrNull
            ?.outcome;
        if (row.origin != 'inbound' ||
            !{'repair', 'no_fault', 'rejected'}.contains(decision) ||
            !_has(events, 'supplier_requested') ||
            _has(events, 'supplier_fulfilled') ||
            row.serialUnitId == null ||
            condition.trim().isEmpty) {
          throw StateError('Original unit return is not pending');
        }
        final original = await (db.select(db.serialUnits)
              ..where((s) => s.id.equals(row.serialUnitId!)))
            .getSingle();
        if (original.serialNumber != returnedSerial.trim() ||
            original.status != 'rma') {
          throw StateError('Exact original serial must be received');
        }
        await _record(live, supplierCaseId, 'supplier_fulfilled',
            outcome: decision,
            serialUnitId: original.id,
            returnedSerial: returnedSerial.trim(),
            condition: condition.trim(),
            finding: reference,
            note: note);
        await _record(live, supplierCaseId, 'custody_store',
            serialUnitId: original.id);
        final customerId = events
            .where((e) =>
                e.action == 'supplier_created' ||
                e.action == 'supplier_requested')
            .firstOrNull
            ?.relatedCaseId;
        if (customerId != null) {
          await _record(live, customerId, 'custody_store',
              serialUnitId: original.id, relatedCaseId: supplierCaseId);
        }
        if (decision != 'rejected') {
          await (db.update(db.rmaCases)
                ..where((r) => r.id.equals(supplierCaseId)))
              .write(const RmaCasesCompanion(status: Value('resolved')));
          await _record(live, supplierCaseId, 'completed');
        }
      });

  Future<void> supplierRejectedDisposition(
          ActiveUser actor, String supplierCaseId, String disposition,
          {String? note}) =>
      supplierReturnedDisposition(actor, supplierCaseId, disposition,
          note: note);

  Future<void> supplierReturnedDisposition(
          ActiveUser actor, String supplierCaseId, String disposition,
          {String? note}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        final row = await _case(supplierCaseId);
        final events = await history(supplierCaseId);
        final returned = events
            .where((e) =>
                e.action == 'supplier_fulfilled' &&
                {'rejected', 'repair', 'no_fault'}.contains(e.outcome))
            .lastOrNull;
        if (row.origin != 'inbound' ||
            returned == null ||
            _has(events, 'supplier_disposition') ||
            !{'hold', 'scrap', 'restock', 'return_to_customer'}
                .contains(disposition)) {
          throw StateError('Returned supplier item disposition required');
        }
        final customerId = events
            .where((e) => e.action == 'supplier_created')
            .lastOrNull
            ?.relatedCaseId;
        final customerEvents = customerId == null
            ? <RmaLifecycleEvent>[]
            : await history(customerId);
        final customerWaiting = customerEvents.any((e) =>
                e.action == 'intent' && e.outcome == 'supplier_warranty') &&
            !_has(customerEvents, 'completed');
        if (customerWaiting &&
            (returned.outcome != 'rejected' ||
                disposition != 'return_to_customer')) {
          throw StateError('Customer property must be returned');
        }
        if (!customerWaiting && disposition == 'return_to_customer') {
          throw StateError('No customer is waiting for this item');
        }
        if (disposition == 'scrap' && row.serialUnitId != null) {
          await (db.update(db.serialUnits)
                ..where((s) => s.id.equals(row.serialUnitId!)))
              .write(const SerialUnitsCompanion(status: Value('scrapped')));
        }
        if (disposition == 'restock') {
          if (!{'good', 'opened'}.contains(returned.condition) ||
              row.serialUnitId == null) {
            throw StateError('Returned condition does not permit restock');
          }
          final serial = await (db.select(db.serialUnits)
                ..where((s) => s.id.equals(row.serialUnitId!)))
              .getSingle();
          if (serial.status != 'rma' || serial.inventoryLayerId == null) {
            throw StateError('Original inventory provenance unavailable');
          }
          await _restoreLayer(serial.inventoryLayerId!, 1000);
          final stock = await (db.select(db.inventory)
                ..where((i) => i.productId.equals(serial.productId)))
              .getSingle();
          final next = stock.quantityMilli + 1000;
          await (db.update(db.inventory)
                ..where((i) => i.productId.equals(serial.productId)))
              .write(InventoryCompanion(
                  quantity: Value(next ~/ 1000), quantityMilli: Value(next)));
          await (db.update(db.serialUnits)
                ..where((s) => s.id.equals(serial.id)))
              .write(const SerialUnitsCompanion(status: Value('available')));
          await db.into(db.inventoryMovements).insert(
              InventoryMovementsCompanion.insert(
                  productId: serial.productId,
                  quantityDelta: 1,
                  quantityDeltaMilli: const Value(1000),
                  reason: 'rma_supplier_restock',
                  referenceId: Value(supplierCaseId)));
        }
        await _record(live, supplierCaseId, 'supplier_disposition',
            disposition: disposition,
            serialUnitId: row.serialUnitId,
            relatedCaseId: customerId,
            note: note);
        if (!_has(events, 'completed')) {
          await (db.update(db.rmaCases)
                ..where((r) => r.id.equals(supplierCaseId)))
              .write(const RmaCasesCompanion(status: Value('resolved')));
          await _record(live, supplierCaseId, 'completed');
        }
      });

  Future<void> supplierReplacement(
          ActiveUser actor, String supplierCaseId, String newSerial,
          {String? reference,
          String condition = 'new',
          String warrantyTreatment = 'unknown',
          DateTime? warrantyEndAt}) =>
      db.transaction(() async {
        final live = await _actor(actor);
        live.require(PosPermission.stockReceiving);
        if ({'restart', 'custom'}.contains(warrantyTreatment)) {
          live.require(PosPermission.manageUsers);
        }
        final row = await _case(supplierCaseId);
        final events = await history(supplierCaseId);
        if (row.origin != 'inbound' ||
            !events.any((e) =>
                e.action == 'supplier_decision' &&
                e.outcome == 'replacement') ||
            _has(events, 'supplier_fulfilled')) {
          throw StateError('Supplier replacement is not pending');
        }
        if (!{'new', 'good'}.contains(condition)) {
          throw StateError('Choose replacement condition');
        }
        final source = await (db.select(db.stockReceivingItems)
              ..where((i) => i.id.equals(row.receivingItemId!)))
            .getSingle();
        final product = await (db.select(db.products)
              ..where((p) => p.id.equals(source.productId)))
            .getSingle();
        if (!product.serialTracking ||
            row.serialUnitId == null ||
            row.quantityMilli != 1000 ||
            newSerial.trim().isEmpty ||
            newSerial.trim() ==
                (await (db.select(db.serialUnits)
                          ..where((s) => s.id.equals(row.serialUnitId!)))
                        .getSingle())
                    .serialNumber) {
          throw StateError('Provide a new exact replacement serial');
        }
        final received = await StockReceivingRepository(db).receive(
            live,
            row.supplierId!,
            [
              ReceivingLineRequest(product.id, 1000, source.unitCostCents,
                  serialNumbers: [newSerial.trim()])
            ],
            externalReference: reference);
        final item =
            (await StockReceivingRepository(db).items(received.id)).single;
        final serial =
            (await StockReceivingRepository(db).serialsForItem(item.id)).single;
        final customerId = events
            .where((e) => e.action == 'supplier_requested')
            .firstOrNull
            ?.relatedCaseId;
        final customerEvents = customerId == null
            ? <RmaLifecycleEvent>[]
            : await history(customerId);
        final customerWaiting = customerEvents.any((e) =>
                e.action == 'intent' && e.outcome == 'supplier_warranty') &&
            !_has(customerEvents, 'completed');
        if (customerWaiting) {
          await InventoryLayerRepository(db)
              .consume(product.id, 1000, serials: [serial]);
          final stock = await (db.select(db.inventory)
                ..where((i) => i.productId.equals(product.id)))
              .getSingle();
          if (stock.quantityMilli < 1000) {
            throw StateError('Supplier replacement stock changed');
          }
          final next = stock.quantityMilli - 1000;
          await (db.update(db.inventory)
                ..where((i) => i.productId.equals(product.id)))
              .write(InventoryCompanion(
                  quantity: Value(next ~/ 1000), quantityMilli: Value(next)));
          await db.into(db.inventoryMovements).insert(
              InventoryMovementsCompanion.insert(
                  productId: product.id,
                  quantityDelta: -1,
                  quantityDeltaMilli: const Value(-1000),
                  reason: 'rma_supplier_customer_hold',
                  referenceId: Value(supplierCaseId)));
          await (db.update(db.serialUnits)
                ..where((s) => s.id.equals(serial.id)))
              .write(const SerialUnitsCompanion(status: Value('rma')));
        }
        final fulfillment = await _record(
            live, supplierCaseId, 'supplier_fulfilled',
            outcome: 'replacement',
            serialUnitId: serial.id,
            condition: condition,
            note: reference);
        await _recordWarranty(serial.id, supplierCaseId, fulfillment.id,
            warrantyTreatment, 'supplier_rma',
            originalSerialId: row.serialUnitId,
            endAt: warrantyEndAt,
            note: reference);
        await (db.update(db.rmaCases)
              ..where((r) => r.id.equals(supplierCaseId)))
            .write(const RmaCasesCompanion(status: Value('resolved')));
        await _record(live, supplierCaseId, 'completed');
      });

  Future<void> _completeIfReady(ActiveUser actor, String caseId) async {
    final events = await history(caseId);
    if (_has(events, 'completed')) return;
    final intent = events.where((e) => e.action == 'intent').firstOrNull;
    if (intent == null) return;
    final ready = switch (intent.outcome) {
      'refund' => _has(events, 'refund_executed'),
      'replacement' => _has(events, 'handoff'),
      'supplier_warranty' => _has(events, 'handoff'),
      'no_fault' ||
      'reject_claim' ||
      'repaired_return' =>
        _has(events, 'handoff'),
      _ => false,
    };
    if (!ready) return;
    await (db.update(db.rmaCases)..where((r) => r.id.equals(caseId)))
        .write(const RmaCasesCompanion(status: Value('resolved')));
    await _record(actor, caseId, 'completed');
  }

  Future<String> nextAction(String caseId) async {
    final row = await _case(caseId);
    final events = await history(caseId);
    if (events.isEmpty) {
      return 'Legacy record · detailed physical history unavailable';
    }
    if (_has(events, 'completed')) return 'Complete';
    if (_has(events, 'cancelled') || _has(events, 'rejected')) return 'Closed';
    if (row.origin == 'inbound' &&
        _has(events, 'supplier_intake') &&
        !_has(events, 'supplier_requested')) {
      return 'Send to supplier';
    }
    if (row.origin == 'inbound' &&
        _has(events, 'supplier_created') &&
        !_has(events, 'supplier_requested')) {
      return 'Send to supplier';
    }
    if (row.origin == 'inbound' && _has(events, 'supplier_requested')) {
      if (!_has(events, 'supplier_decision')) return 'Record supplier decision';
      if (!_has(events, 'supplier_fulfilled')) {
        return 'Record supplier fulfillment';
      }
      if (events.any(
          (e) => e.action == 'supplier_decision' && e.outcome == 'rejected')) {
        return 'Resolve rejected item';
      }
      return 'Supplier fulfilled';
    }
    if (!_has(events, 'approved')) return 'Approve claim';
    if (_sum(events, 'received') < row.quantityMilli) {
      return 'Receive returned item';
    }
    if (_sum(events, 'inspected') < row.quantityMilli) {
      return 'Inspect returned item';
    }
    if (!_has(events, 'intent')) return 'Choose resolution';
    final intent = events.firstWhere((e) => e.action == 'intent');
    if (intent.outcome == 'refund' && !_has(events, 'refund_executed')) {
      return _has(events, 'refund_obligation')
          ? 'Settle refund obligation'
          : 'Complete refund';
    }
    if (intent.outcome == 'replacement') {
      final latest = events
          .where((e) =>
              e.action == 'replacement_reserved' ||
              e.action == 'replacement_released')
          .lastOrNull;
      return latest?.action == 'replacement_reserved'
          ? 'Hand replacement to customer'
          : 'Reserve replacement';
    }
    if (intent.outcome == 'supplier_warranty') {
      final link =
          events.where((e) => e.action == 'supplier_claim_opened').lastOrNull;
      if (link == null) return 'Send item to supplier';
      final supplierEvents = await history(link.relatedCaseId!);
      if (!_has(supplierEvents, 'supplier_requested')) {
        return 'Send item to supplier';
      }
      final fulfilled = supplierEvents
          .where((e) => e.action == 'supplier_fulfilled')
          .lastOrNull;
      if (fulfilled?.outcome == 'replacement') {
        return 'Hand supplier replacement to customer';
      }
      if (fulfilled?.outcome == 'repair' || fulfilled?.outcome == 'no_fault') {
        return 'Hand repaired item to customer';
      }
      if (fulfilled?.outcome == 'rejected' &&
          supplierEvents.any((e) =>
              e.action == 'supplier_disposition' &&
              e.disposition == 'return_to_customer')) {
        return 'Hand returned item to customer';
      }
      return 'Waiting on supplier';
    }
    if (intent.outcome == 'no_fault' ||
        intent.outcome == 'reject_claim' ||
        intent.outcome == 'repaired_return') {
      return 'Hand item to customer';
    }
    if (intent.disposition == 'restock' || intent.disposition == 'scrap') {
      if (!_has(events, 'disposition_executed')) {
        return 'Execute physical disposition';
      }
    }
    if (intent.disposition == 'supplier') {
      return _has(events, 'supplier_claim_opened')
          ? 'Waiting on supplier'
          : 'Send item to supplier';
    }
    if (intent.disposition == 'hold') return 'Resolve held property';
    return 'Execute physical disposition';
  }
}
