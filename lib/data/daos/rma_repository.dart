import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';
import 'sales_repository.dart';
import 'stock_receiving_repository.dart';
import 'inventory_layer_repository.dart';
import 'paged_result.dart';

class RmaRepository {
  final AppDatabase db;
  RmaRepository(this.db);

  static const _stageSource = '''
    WITH facts AS (
      SELECT case_id, COUNT(*) fact_count,
        MAX(action = 'cancelled') cancelled,
        MAX(action = 'rejected') rejected,
        MAX(action = 'completed') completed,
        MAX(action = 'supplier_fulfilled') fulfilled,
        MAX(action = 'supplier_decision') decision,
        MAX(action = 'supplier_requested') requested,
        MAX(action = 'supplier_intake') intake,
        MAX(action = 'approved') approved,
        MAX(action = 'intent') intent,
        SUM(CASE WHEN action = 'received' THEN COALESCE(quantity_milli, 0) ELSE 0 END) received,
        SUM(CASE WHEN action = 'inspected' THEN COALESCE(quantity_milli, 0) ELSE 0 END) inspected,
        MAX(CASE WHEN action = 'intent' THEN outcome END) intent_outcome,
        MAX(CASE WHEN action = 'intent' THEN disposition END) intent_disposition
      FROM rma_lifecycle_events GROUP BY case_id
    ), staged AS (
      SELECT r.*,
        CASE
          WHEN COALESCE(f.fact_count, 0) = 0 THEN 'Legacy'
          WHEN f.cancelled = 1 THEN CASE WHEN r.origin = 'inbound' THEN 'Cancelled' ELSE 'Rejected / Cancelled' END
          WHEN f.rejected = 1 OR r.status = 'rejected' THEN CASE WHEN r.origin = 'inbound' THEN 'Rejected' ELSE 'Rejected / Cancelled' END
          WHEN r.origin = 'inbound' THEN CASE
            WHEN f.completed = 1 OR f.fulfilled = 1 THEN 'Resolved'
            WHEN f.decision = 1 THEN 'Fulfillment pending'
            WHEN f.requested = 1 THEN 'Awaiting supplier'
            WHEN f.intake = 1 THEN 'Ready to send'
            ELSE 'Requested' END
          WHEN f.completed = 1 THEN 'Completed'
          WHEN f.approved = 0 THEN 'Awaiting approval'
          WHEN f.received < r.quantity_milli THEN 'Awaiting receipt'
          WHEN f.inspected < r.quantity_milli THEN 'Awaiting inspection'
          WHEN f.intent = 0 THEN 'Awaiting resolution'
          WHEN f.intent_outcome = 'supplier_warranty' THEN CASE
            WHEN (SELECT outcome FROM rma_lifecycle_events se
              WHERE se.case_id = (SELECT ce.related_case_id FROM rma_lifecycle_events ce
                WHERE ce.case_id = r.id AND ce.action = 'supplier_claim_opened'
                ORDER BY ce.rowid DESC LIMIT 1)
                AND se.action = 'supplier_fulfilled' ORDER BY se.rowid DESC LIMIT 1)
                IN ('repair', 'no_fault') THEN 'Ready for handoff'
            WHEN (SELECT outcome FROM rma_lifecycle_events se
              WHERE se.case_id = (SELECT ce.related_case_id FROM rma_lifecycle_events ce
                WHERE ce.case_id = r.id AND ce.action = 'supplier_claim_opened'
                ORDER BY ce.rowid DESC LIMIT 1)
                AND se.action = 'supplier_fulfilled' ORDER BY se.rowid DESC LIMIT 1)
                = 'rejected' AND EXISTS (SELECT 1 FROM rma_lifecycle_events se
                  WHERE se.case_id = (SELECT ce.related_case_id FROM rma_lifecycle_events ce
                    WHERE ce.case_id = r.id AND ce.action = 'supplier_claim_opened'
                    ORDER BY ce.rowid DESC LIMIT 1)
                  AND se.action = 'supplier_disposition' AND se.disposition = 'return_to_customer')
              THEN 'Ready for handoff'
            ELSE 'Awaiting supplier' END
          WHEN f.intent_disposition = 'supplier' THEN 'Awaiting supplier'
          WHEN f.intent_outcome = 'replacement' AND
            (SELECT action FROM rma_lifecycle_events re
             WHERE re.case_id = r.id AND re.action IN ('replacement_reserved', 'replacement_released')
             ORDER BY re.rowid DESC LIMIT 1) = 'replacement_reserved'
            THEN 'Ready for handoff'
          WHEN f.intent_outcome IN ('no_fault', 'reject_claim', 'repaired_return') THEN 'Ready for handoff'
          ELSE 'Awaiting resolution' END AS stage
      FROM rma_cases r LEFT JOIN facts f ON f.case_id = r.id
    )
  ''';

  Future<PagedResult<RmaCase>> page({
    required String origin,
    String search = '',
    String stage = 'All',
    int page = 0,
    DateTime? from,
    DateTime? until,
  }) async {
    final conditions = <String>['r.origin = ?'];
    final variables = <Variable<Object>>[Variable.withString(origin)];
    if (stage != 'All') {
      conditions.add('r.stage = ?');
      variables.add(Variable.withString(stage));
    }
    if (from != null) {
      conditions.add('r.created_at >= ?');
      variables.add(Variable.withInt(from.millisecondsSinceEpoch ~/ 1000));
    }
    if (until != null) {
      conditions.add('r.created_at < ?');
      variables.add(Variable.withInt(until.millisecondsSinceEpoch ~/ 1000));
    }
    final term = search.trim().toLowerCase();
    if (term.isNotEmpty) {
      conditions.add('''(
        instr(lower(r.reference), ?) > 0 OR
        instr(lower(COALESCE(c.name, s.name, '')), ?) > 0 OR
        instr(lower(COALESCE(c.phone, s.phone, '')), ?) > 0 OR
        instr(lower(COALESCE(si.product_name, p.name, '')), ?) > 0 OR
        instr(lower(COALESCE(p.sku, '')), ?) > 0 OR
        instr(lower(COALESCE(p.barcode, '')), ?) > 0 OR
        instr(lower(COALESCE(su.serial_number, '')), ?) > 0 OR
        instr(lower(COALESCE(sa.receipt_number, '')), ?) > 0 OR
        instr(lower(CAST(sa.bir_invoice_number AS TEXT)), ?) > 0 OR
        instr(lower(COALESCE(sr.external_reference, '')), ?) > 0 OR
        instr(lower(r.issue_description), ?) > 0
      )''');
      for (var i = 0; i < 11; i++) {
        variables.add(Variable.withString(term));
      }
    }
    final source = '''$_stageSource
      SELECT r.id FROM staged r
      LEFT JOIN customers c ON c.id = r.customer_id
      LEFT JOIN suppliers s ON s.id = r.supplier_id
      LEFT JOIN sale_items si ON si.id = r.sale_item_id
      LEFT JOIN stock_receiving_items sri ON sri.id = r.receiving_item_id
      LEFT JOIN products p ON p.id = COALESCE(si.product_id, sri.product_id)
      LEFT JOIN serial_units su ON su.id = r.serial_unit_id
      LEFT JOIN sales sa ON sa.id = r.sale_id
      LEFT JOIN stock_receivings sr ON sr.id = r.receiving_id
      WHERE ${conditions.join(' AND ')}''';
    final countRows = await db
        .customSelect('SELECT COUNT(*) AS total FROM ($source)',
            variables: variables)
        .get();
    final total = countRows.single.read<int>('total');
    final idRows = await db.customSelect('''$source
      ORDER BY r.created_at DESC, r.id DESC LIMIT 50 OFFSET ?''',
        variables: [...variables, Variable.withInt(page * 50)]).get();
    final ids = idRows.map((r) => r.read<String>('id')).toList();
    if (ids.isEmpty) {
      return PagedResult(items: const [], totalCount: total, page: page);
    }
    final cases =
        await (db.select(db.rmaCases)..where((r) => r.id.isIn(ids))).get();
    final byId = {for (final row in cases) row.id: row};
    return PagedResult(
        items: [for (final id in ids) byId[id]!],
        totalCount: total,
        page: page);
  }

  Future<RmaCase?> byId(String id) =>
      (db.select(db.rmaCases)..where((r) => r.id.equals(id))).getSingleOrNull();

  Future<Map<String, int>> stageCounts(String origin) async {
    final rows = await db.customSelect('''$_stageSource
      SELECT stage, COUNT(*) AS total FROM staged
      WHERE origin = ? GROUP BY stage''',
        variables: [Variable.withString(origin)]).get();
    return {
      for (final row in rows) row.read<String>('stage'): row.read<int>('total')
    };
  }

  Future<List<RmaChoice>> choices(String origin, String query) async {
    final result = <RmaChoice>[];
    if (origin == 'customer') {
      final search = query.trim();
      final receipt = search
          .replaceFirst(RegExp(r'^Receipt\s*#?', caseSensitive: false), '')
          .trim();
      final candidateIds = await db.customSelect('''
        SELECT si.id FROM sale_items si
        JOIN sales s ON s.id = si.sale_id
        LEFT JOIN customers c ON c.id = s.customer_id
        JOIN products p ON p.id = si.product_id
        WHERE s.status = 'completed' AND (
          s.receipt_number = ? OR s.receipt_number LIKE ? OR
          CAST(s.bir_invoice_number AS TEXT) = ? OR
          LOWER(COALESCE(c.name, '')) LIKE ? OR
          LOWER(COALESCE(c.phone, '')) LIKE ? OR
          LOWER(si.product_name) LIKE ? OR
          LOWER(COALESCE(p.sku, '')) LIKE ? OR
          LOWER(COALESCE(p.barcode, '')) LIKE ? OR
          EXISTS (SELECT 1 FROM serial_sale_links sl
            JOIN serial_units su ON su.id = sl.serial_unit_id
            WHERE sl.sale_item_id = si.id AND LOWER(su.serial_number) LIKE ?)
        )
        ORDER BY CASE WHEN s.receipt_number = ? THEN 0 ELSE 1 END,
          s.created_at DESC LIMIT 100
      ''', variables: [
        Variable.withString(receipt),
        Variable.withString('$receipt%'),
        Variable.withString(search),
        for (var i = 0; i < 6; i++)
          Variable.withString('%${search.toLowerCase()}%'),
        Variable.withString(receipt),
      ]).get();
      for (final candidate in candidateIds) {
        final item = await (db.select(db.saleItems)
              ..where((i) => i.id.equals(candidate.read<String>('id'))))
            .getSingle();
        final sale = await (db.select(db.sales)
              ..where((s) => s.id.equals(item.saleId)))
            .getSingle();
        final customer = sale.customerId == null
            ? null
            : await (db.select(db.customers)
                  ..where((c) => c.id.equals(sale.customerId!)))
                .getSingleOrNull();
        final links = await (db.select(db.serialSaleLinks)
              ..where((l) => l.saleItemId.equals(item.id)))
            .get();
        final serials = <SerialUnit>[];
        for (final link in links) {
          serials.add(await (db.select(db.serialUnits)
                ..where((s) => s.id.equals(link.serialUnitId)))
              .getSingle());
        }
        if (sale.status != 'completed') continue;
        final claims = await (db.select(db.rmaCases)
              ..where((r) => r.saleItemId.equals(item.id)))
            .get();
        serials.removeWhere(
            (serial) => claims.any((claim) => claim.serialUnitId == serial.id));
        final claimed = claims.fold<int>(0, (sum, r) => sum + r.quantityMilli);
        if (claimed >= item.quantityMilli) continue;
        final product = await (db.select(db.products)
              ..where((p) => p.id.equals(item.productId)))
            .getSingle();
        if (product.productType == 'kit') continue;
        final label =
            'Receipt #${sale.receiptNumber ?? 'Legacy sale'} · ${customer?.name ?? 'Walk-in'} · ${item.productName} ${serials.map((s) => s.serialNumber).join(', ')}';
        final searchable = '$label ${customer?.phone ?? ''} '
            '${product.sku ?? ''} ${product.barcode ?? ''} ${sale.birInvoiceNumber ?? ''}';
        if (searchable.toLowerCase().contains(query.toLowerCase())) {
          result.add(RmaChoice(item.id, label, serials,
              soldMilli: item.quantityMilli,
              claimedMilli: claimed,
              customerName: customer?.name ?? 'Walk-in',
              receipt: sale.receiptNumber ?? 'Legacy sale',
              date: sale.createdAt));
        }
      }
    } else if (origin == 'inbound') {
      for (final item in await db.select(db.stockReceivingItems).get()) {
        final receiving = await (db.select(db.stockReceivings)
              ..where((r) => r.id.equals(item.receivingId)))
            .getSingle();
        final supplier = await (db.select(db.suppliers)
              ..where((s) => s.id.equals(receiving.supplierId)))
            .getSingle();
        final product = await (db.select(db.products)
              ..where((p) => p.id.equals(item.productId)))
            .getSingle();
        final serials = await (db.select(db.serialUnits)
              ..where((s) => s.receivingItemId.equals(item.id)))
            .get();
        serials.removeWhere((serial) => serial.status != 'available');
        if (product.serialTracking && serials.isEmpty) continue;
        final layers = await (db.select(db.inventoryLayers)
              ..where((layer) => layer.receivingItemId.equals(item.id)))
            .get();
        if (!product.serialTracking &&
            (layers.length != 1 || layers.single.quantityRemainingMilli <= 0)) {
          continue;
        }
        final label =
            'Delivery ${receiving.externalReference ?? receiving.id.substring(0, 8)} · ${supplier.name} · ${product.name} ${item.batchNumber ?? ''} ${serials.map((s) => s.serialNumber).join(', ')}';
        if ('$label ${product.sku ?? ''} ${product.barcode ?? ''}'
            .toLowerCase()
            .contains(query.toLowerCase())) {
          result.add(RmaChoice(item.id, label, serials,
              soldMilli: layers.length == 1
                  ? layers.single.quantityRemainingMilli
                  : serials.length * 1000));
        }
      }
    }
    return result;
  }

  Future<List<RmaCase>> cases({String? origin}) {
    final query = db.select(db.rmaCases)
      ..orderBy([
        (r) => OrderingTerm(expression: r.createdAt, mode: OrderingMode.desc)
      ]);
    if (origin != null) query.where((r) => r.origin.equals(origin));
    return query.get();
  }

  Future<List<RmaEvent>> events(String caseId) => (db.select(db.rmaEvents)
        ..where((e) => e.caseId.equals(caseId))
        ..orderBy([(e) => OrderingTerm(expression: e.createdAt)]))
      .get();

  Future<List<SerialUnit>> availableReplacementSerials(String caseId) async {
    final row = await (db.select(db.rmaCases)
          ..where((r) => r.id.equals(caseId)))
        .getSingle();
    if (row.origin != 'customer' || row.saleItemId == null) return [];
    final item = await (db.select(db.saleItems)
          ..where((i) => i.id.equals(row.saleItemId!)))
        .getSingle();
    return (db.select(db.serialUnits)
          ..where((s) =>
              s.productId.equals(item.productId) &
              s.status.equals('available')))
        .get();
  }

  Future<RmaCase> openCustomer(
          ActiveUser actor, String saleItemId, String issue, String condition,
          {String? serialUnitId, String? notes, int quantityMilli = 1000}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageRma);
        if (issue.trim().isEmpty || condition.trim().isEmpty) {
          throw StateError('Issue and intake condition are required');
        }
        final item = await (db.select(db.saleItems)
              ..where((i) => i.id.equals(saleItemId)))
            .getSingleOrNull();
        if (item == null) throw StateError('Sale item not found');
        final product = await (db.select(db.products)
              ..where((p) => p.id.equals(item.productId)))
            .getSingle();
        if (product.productType == 'kit') {
          throw StateError('Kit Sale RMA needs component-specific handling and is unavailable in this release');
        }
        final config =
            await BusinessFeatureRepository(db).businessProduct(product.id);
        if (quantityMilli <= 0 ||
            quantityMilli > item.quantityMilli ||
            (!config.fractional && quantityMilli % 1000 != 0) ||
            (product.serialTracking && quantityMilli != 1000)) {
          throw StateError('Invalid RMA quantity');
        }
        final claimed = (await (db.select(db.rmaCases)
                  ..where((r) => r.saleItemId.equals(item.id)))
                .get())
            .fold<int>(0, (sum, row) => sum + row.quantityMilli);
        if (claimed + quantityMilli > item.quantityMilli) {
          throw StateError('Sale item quantity is already claimed');
        }
        if (product.serialTracking && serialUnitId == null) {
          throw StateError('Select the sold serial');
        }
        final sale = await (db.select(db.sales)
              ..where((s) => s.id.equals(item.saleId)))
            .getSingle();
        if (sale.status != 'completed') {
          throw StateError('Only completed sales can enter customer RMA');
        }
        if (serialUnitId != null) {
          final priorClaims = await (db.select(db.rmaCases)
                ..where((r) =>
                    r.serialUnitId.equals(serialUnitId) &
                    r.origin.equals('customer')))
              .get();
          if (priorClaims.isNotEmpty) {
            throw StateError(
                'Serial already has an RMA: ${priorClaims.first.reference}');
          }
          final links = await (db.select(db.serialSaleLinks)
                ..where((l) =>
                    l.serialUnitId.equals(serialUnitId) &
                    l.saleItemId.equals(item.id)))
              .get();
          if (links.isEmpty) {
            throw StateError('Serial was not sold on this receipt');
          }
          final serial = await (db.select(db.serialUnits)
                ..where((s) => s.id.equals(serialUnitId)))
              .getSingle();
          if (serial.status != 'sold' || serial.saleItemId != item.id) {
            throw StateError('Serial is not currently sold on this receipt');
          }
        }
        final row = await db.into(db.rmaCases).insertReturning(
            RmaCasesCompanion.insert(
                reference: await _reference('customer'),
                origin: 'customer',
                saleId: Value(sale.id),
                saleItemId: Value(item.id),
                customerId: Value(sale.customerId),
                serialUnitId: Value(serialUnitId),
                issueDescription: issue.trim(),
                intakeCondition: condition.trim(),
                quantityMilli: Value(quantityMilli),
                notes: Value(_clean(notes))));
        if (serialUnitId != null) {
          await (db.update(db.serialUnits)
                ..where((s) => s.id.equals(serialUnitId)))
              .write(const SerialUnitsCompanion(status: Value('rma')));
        }
        await _event(live, row.id, 'pending', 'Customer intake');
        return row;
      });

  Future<RmaCase> openInbound(ActiveUser actor, String receivingItemId,
          String issue, String condition,
          {String? serialUnitId, String? notes, int quantityMilli = 1000}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageRma);
        if (issue.trim().isEmpty || condition.trim().isEmpty) {
          throw StateError('Issue and intake condition are required');
        }
        final item = await (db.select(db.stockReceivingItems)
              ..where((i) => i.id.equals(receivingItemId)))
            .getSingleOrNull();
        if (item == null) throw StateError('Receiving item not found');
        final product = await (db.select(db.products)
              ..where((p) => p.id.equals(item.productId)))
            .getSingle();
        final config =
            await BusinessFeatureRepository(db).businessProduct(product.id);
        if (quantityMilli <= 0 ||
            quantityMilli > item.quantityMilli ||
            (!config.fractional && quantityMilli % 1000 != 0) ||
            (product.serialTracking && quantityMilli != 1000)) {
          throw StateError('Invalid RMA quantity');
        }
        final claimed = (await (db.select(db.rmaCases)
                  ..where((r) => r.receivingItemId.equals(item.id)))
                .get())
            .fold<int>(0, (sum, row) => sum + row.quantityMilli);
        if (claimed + quantityMilli > item.quantityMilli) {
          throw StateError('Receiving item quantity is already claimed');
        }
        if (product.serialTracking && serialUnitId == null) {
          throw StateError('Select a received serial');
        }
        final receiving = await (db.select(db.stockReceivings)
              ..where((r) => r.id.equals(item.receivingId)))
            .getSingle();
        if (serialUnitId != null) {
          final serial = await (db.select(db.serialUnits)
                ..where((s) =>
                    s.id.equals(serialUnitId) &
                    s.receivingItemId.equals(item.id)))
              .getSingleOrNull();
          if (serial == null || serial.status != 'available') {
            throw StateError('Serial is not available from this delivery');
          }
          await (db.update(db.serialUnits)
                ..where((s) => s.id.equals(serialUnitId)))
              .write(const SerialUnitsCompanion(status: Value('rma')));
        }
        await _changeStock(
            item.productId, -quantityMilli, 'inbound_rma', receiving.id);
        final sourceLayer = await (db.select(db.inventoryLayers)
              ..where((l) => l.receivingItemId.equals(item.id)))
            .getSingle();
        await _adjustLayer(sourceLayer.id, -quantityMilli);
        if (item.batchNumber != null) {
          await _changeLot(item.productId, item.batchNumber!, -quantityMilli);
        }
        final row = await db.into(db.rmaCases).insertReturning(
            RmaCasesCompanion.insert(
                reference: await _reference('inbound'),
                origin: 'inbound',
                receivingId: Value(receiving.id),
                receivingItemId: Value(item.id),
                supplierId: Value(receiving.supplierId),
                serialUnitId: Value(serialUnitId),
                issueDescription: issue.trim(),
                intakeCondition: condition.trim(),
                quantityMilli: Value(quantityMilli),
                notes: Value(_clean(notes))));
        await _event(live, row.id, 'pending', 'Supplier intake');
        return row;
      });

  Future<void> transition(ActiveUser actor, String caseId, String status,
          {String? note,
          String? customerResolution,
          String? unitDisposition,
          String? replacementSerialUnitId,
          bool payCashNow = false}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageRma);
        final row = await (db.select(db.rmaCases)
              ..where((r) => r.id.equals(caseId)))
            .getSingleOrNull();
        if (row == null) throw StateError('RMA not found');
        if ((await (db.select(db.rmaLifecycleEvents)
                  ..where((e) => e.caseId.equals(caseId)))
                .get())
            .isNotEmpty) {
          throw StateError('Use the explicit RMA lifecycle actions');
        }
        final next = <String, Set<String>>{
          'pending': {'sent_to_supplier', 'resolved', 'rejected'},
          'sent_to_supplier': {'resolved', 'rejected'},
        };
        if (next[row.status]?.contains(status) != true) {
          throw StateError('Invalid RMA status transition');
        }
        if (status != 'resolved' && customerResolution != null) {
          throw StateError('Customer resolution requires resolved status');
        }
        if (status != 'resolved' &&
            status != 'rejected' &&
            unitDisposition != null) {
          throw StateError('Unit disposition requires final status');
        }
        if (status == 'resolved' && row.origin == 'customer') {
          if (!{'repaired_return', 'same_item_replacement', 'refund'}
              .contains(customerResolution)) {
            throw StateError('This customer resolution is not executable');
          }
          if (customerResolution == 'repaired_return' &&
              unitDisposition != 'return_to_customer') {
            throw StateError('Repaired item must return to customer');
          }
          if (customerResolution == 'same_item_replacement' &&
              unitDisposition == 'return_to_customer') {
            throw StateError('Original unit cannot also be returned');
          }
          if (customerResolution == 'refund' &&
              unitDisposition == 'return_to_customer') {
            throw StateError('Refunded unit cannot return to customer');
          }
        }
        if (status == 'resolved' &&
            row.origin == 'inbound' &&
            !{'return_to_supplier', 'restock', 'scrap'}
                .contains(unitDisposition)) {
          throw StateError('Invalid inbound resolution');
        }
        if ((status == 'resolved' || status == 'rejected') &&
            (unitDisposition == null ||
                unitDisposition.trim().isEmpty ||
                (status == 'resolved' &&
                    row.origin == 'customer' &&
                    (customerResolution == null ||
                        customerResolution.trim().isEmpty)))) {
          throw StateError('Resolution and unit disposition are required');
        }
        if ((status == 'resolved' || status == 'rejected') &&
            !{'restock', 'scrap', 'return_to_supplier', 'return_to_customer'}
                .contains(unitDisposition)) {
          throw StateError('Choose a valid unit disposition');
        }
        if ((status == 'resolved' || status == 'rejected') &&
            row.origin == 'inbound' &&
            unitDisposition == 'return_to_customer') {
          throw StateError('Inbound item cannot return to customer');
        }
        SaleItemRefund? refund;
        if (status == 'resolved' && customerResolution == 'refund') {
          refund = await SalesRepository(db)
              .refundItemForRma(live, row.id, payCashNow: payCashNow);
        } else if (payCashNow) {
          throw StateError('Cash payout requires refund resolution');
        }
        if (status == 'resolved' &&
            customerResolution == 'same_item_replacement') {
          final item = await (db.select(db.saleItems)
                ..where((i) => i.id.equals(row.saleItemId!)))
              .getSingle();
          final product = await (db.select(db.products)
                ..where((p) => p.id.equals(item.productId)))
              .getSingle();
          if (item.batchId != null) {
            throw StateError(
                'Batch replacement needs a selected replacement batch');
          }
          if (product.serialTracking) {
            if (replacementSerialUnitId == null) {
              throw StateError('Select an available replacement serial');
            }
            final serial = await (db.select(db.serialUnits)
                  ..where((s) => s.id.equals(replacementSerialUnitId)))
                .getSingleOrNull();
            if (serial == null ||
                serial.productId != product.id ||
                serial.status != 'available') {
              throw StateError('Replacement serial is unavailable');
            }
            await (db.update(db.serialUnits)
                  ..where((s) => s.id.equals(serial.id)))
                .write(SerialUnitsCompanion(
                    status: const Value('sold'), saleItemId: Value(item.id)));
            await db.into(db.serialSaleLinks).insert(
                SerialSaleLinksCompanion.insert(
                    serialUnitId: serial.id, saleItemId: item.id));
            await AuthRepository(db).audit(
                live.id, 'rma.replacement_serial', '${row.id}:${serial.id}');
          } else if (replacementSerialUnitId != null) {
            throw StateError('This product does not use serials');
          }
          await _changeStock(
              item.productId, -row.quantityMilli, 'rma_replacement', row.id);
          await InventoryLayerRepository(db).consume(
              item.productId, row.quantityMilli,
              serials: product.serialTracking
                  ? [
                      (await (db.select(db.serialUnits)
                            ..where(
                                (s) => s.id.equals(replacementSerialUnitId!)))
                          .getSingle())
                    ]
                  : const []);
          await AuthRepository(db).audit(live.id, 'rma.replacement', row.id);
        } else if (replacementSerialUnitId != null) {
          throw StateError(
              'Replacement serial requires replacement resolution');
        }
        if ((status == 'resolved' || status == 'rejected') &&
            unitDisposition == 'restock') {
          if (row.origin == 'inbound') {
            final item = await (db.select(db.stockReceivingItems)
                  ..where((i) => i.id.equals(row.receivingItemId!)))
                .getSingle();
            await _changeStock(
                item.productId, row.quantityMilli, 'rma_restock', row.id);
            final layer = await (db.select(db.inventoryLayers)
                  ..where((l) => l.receivingItemId.equals(item.id)))
                .getSingle();
            await _adjustLayer(layer.id, row.quantityMilli);
            if (item.batchNumber != null) {
              await _changeLot(
                  item.productId, item.batchNumber!, row.quantityMilli);
            }
          } else {
            final item = await (db.select(db.saleItems)
                  ..where((i) => i.id.equals(row.saleItemId!)))
                .getSingle();
            await _changeStock(
                item.productId, row.quantityMilli, 'rma_restock', row.id);
            final allocations =
                await (db.select(db.saleItemInventoryAllocations)
                      ..where((a) => a.saleItemId.equals(item.id))
                      ..orderBy([
                        (a) => OrderingTerm(expression: a.createdAt),
                        (a) => OrderingTerm(expression: a.id)
                      ]))
                    .get();
            if (allocations.isEmpty) {
              throw StateError('Sale layer allocation missing');
            }
            if (row.serialUnitId != null) {
              final exact = allocations
                  .where((a) => a.serialUnitId == row.serialUnitId)
                  .firstOrNull;
              if (exact == null) {
                throw StateError('Original serial allocation missing');
              }
              await _adjustLayer(exact.inventoryLayerId, row.quantityMilli);
            } else {
              final priorCases = await (db.select(db.rmaCases)
                    ..where((r) =>
                        r.saleItemId.equals(item.id) &
                        r.unitDisposition.equals('restock') &
                        (r.status.equals('resolved') |
                            r.status.equals('rejected'))))
                  .get();
              var skip =
                  priorCases.fold<int>(0, (sum, r) => sum + r.quantityMilli);
              var remainingReturn = row.quantityMilli;
              for (final allocation in allocations) {
                if (skip >= allocation.quantityMilli) {
                  skip -= allocation.quantityMilli;
                  continue;
                }
                final available = allocation.quantityMilli - skip;
                skip = 0;
                final restore =
                    remainingReturn < available ? remainingReturn : available;
                await _adjustLayer(allocation.inventoryLayerId, restore);
                remainingReturn -= restore;
                if (remainingReturn == 0) break;
              }
              if (remainingReturn != 0) {
                throw StateError('Return exceeds original allocation');
              }
            }
            if (item.batchNumber != null) {
              await _changeLot(
                  item.productId, item.batchNumber!, row.quantityMilli);
            }
          }
        }
        if (row.serialUnitId != null &&
            (status == 'resolved' || status == 'rejected')) {
          final serial = await (db.select(db.serialUnits)
                ..where((s) => s.id.equals(row.serialUnitId!)))
              .getSingle();
          if (serial.status != 'rma') {
            throw StateError('RMA serial state changed');
          }
          final nextStatus = switch (unitDisposition) {
            'restock' => 'available',
            'scrap' => 'scrapped',
            'return_to_supplier' => 'returned',
            'return_to_customer' => 'sold',
            _ => throw StateError('Invalid unit disposition')
          };
          await (db.update(db.serialUnits)
                ..where((s) => s.id.equals(serial.id)))
              .write(SerialUnitsCompanion(status: Value(nextStatus)));
        }
        await (db.update(db.rmaCases)..where((r) => r.id.equals(caseId))).write(
            RmaCasesCompanion(
                status: Value(status),
                customerResolution: Value(_clean(customerResolution)),
                unitDisposition: Value(_clean(unitDisposition)),
                replacementSerialUnitId: Value(replacementSerialUnitId)));
        await _event(
            live,
            caseId,
            status,
            refund == null
                ? note
                : 'Refund qty=${refund.quantityMilli} amount=${refund.amountCents} '
                    'receivable=${refund.receivableReductionCents} '
                    'due=${refund.obligationCents} cash=${refund.immediateCashCents} '
                    'disposition=$unitDisposition${_clean(note) == null ? '' : ' note=${_clean(note)}'}');
      });

  Future<InboundRmaReplacement> receiveSupplierReplacement(
          ActiveUser actor, String caseId,
          {String? serialNumber,
          String? batchNumber,
          DateTime? expiryDate,
          String? supplierReference,
          String? notes}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageRma);
        live.require(PosPermission.stockReceiving);
        final row = await (db.select(db.rmaCases)
              ..where((r) => r.id.equals(caseId)))
            .getSingleOrNull();
        if (row == null ||
            row.origin != 'inbound' ||
            row.status != 'sent_to_supplier') {
          throw StateError('Inbound RMA must be sent to supplier first');
        }
        if ((await (db.select(db.inboundRmaReplacements)
                  ..where((r) => r.rmaCaseId.equals(caseId)))
                .get())
            .isNotEmpty) {
          throw StateError('Supplier replacement already received');
        }
        final original = await (db.select(db.stockReceivingItems)
              ..where((i) => i.id.equals(row.receivingItemId!)))
            .getSingle();
        final product = await (db.select(db.products)
              ..where((p) => p.id.equals(original.productId)))
            .getSingle();
        final serials = serialNumber == null ? <String>[] : [serialNumber];
        final header = await StockReceivingRepository(db).receive(
            live,
            row.supplierId!,
            [
              ReceivingLineRequest(
                  product.id, row.quantityMilli, original.unitCostCents,
                  unitSellingPriceCents: original.unitSellingPriceCents,
                  serialNumbers: serials,
                  batchNumber: batchNumber,
                  expiryDate: expiryDate)
            ],
            externalReference: supplierReference,
            notes: notes);
        final replacementItem =
            (await StockReceivingRepository(db).items(header.id)).single;
        final replacementSerials = await StockReceivingRepository(db)
            .serialsForItem(replacementItem.id);
        final replacement = await db
            .into(db.inboundRmaReplacements)
            .insertReturning(InboundRmaReplacementsCompanion.insert(
                rmaCaseId: caseId,
                receivingId: header.id,
                receivingItemId: replacementItem.id,
                serialUnitId: Value(replacementSerials.firstOrNull?.id),
                quantityMilli: row.quantityMilli));
        if (row.serialUnitId != null) {
          final count = await (db.update(db.serialUnits)
                ..where((s) =>
                    s.id.equals(row.serialUnitId!) & s.status.equals('rma')))
              .write(const SerialUnitsCompanion(status: Value('returned')));
          if (count != 1) throw StateError('Original serial state changed');
        }
        await (db.update(db.rmaCases)..where((r) => r.id.equals(caseId))).write(
            const RmaCasesCompanion(
                status: Value('resolved'),
                unitDisposition: Value('return_to_supplier')));
        await _event(live, caseId, 'resolved',
            'Supplier replacement received: ${header.id}${_clean(notes) == null ? '' : ' · ${_clean(notes)}'}');
        await AuthRepository(db).audit(
            live.id, 'rma.supplier_replacement', '$caseId:${replacement.id}');
        return replacement;
      });

  Future<void> _event(
      ActiveUser actor, String caseId, String status, String? note) async {
    await db.into(db.rmaEvents).insert(RmaEventsCompanion.insert(
        caseId: caseId,
        actorId: actor.id,
        status: status,
        note: Value(_clean(note))));
    await AuthRepository(db).audit(actor.id, 'rma.$status', caseId);
  }

  Future<String> _reference(String origin) async {
    final prefix = origin == 'customer' ? 'RMA' : 'SRMA';
    final year = DateTime.now().year;
    final rows = await db.customSelect(
      'SELECT reference FROM rma_cases WHERE reference LIKE ? '
      'ORDER BY reference DESC LIMIT 1',
      variables: [Variable.withString('$prefix-$year-%')],
    ).get();
    final last = rows.isEmpty
        ? 0
        : int.tryParse(rows.first.read<String>('reference').split('-').last) ??
            0;
    return '$prefix-$year-${(last + 1).toString().padLeft(6, '0')}';
  }

  String? _clean(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  Future<int> posStock(String productId) async =>
      (await (db.select(db.inventory)
                ..where((i) => i.productId.equals(productId)))
              .getSingle())
          .quantityMilli;

  Future<void> _changeStock(String productId, int deltaMilli, String reason,
      String referenceId) async {
    final current = await posStock(productId);
    final next = current + deltaMilli;
    if (next < 0) throw StateError('Insufficient stock');
    await (db.update(db.inventory)..where((i) => i.productId.equals(productId)))
        .write(InventoryCompanion(
            quantity: Value(next ~/ 1000), quantityMilli: Value(next)));
    await db.into(db.inventoryMovements).insert(
        InventoryMovementsCompanion.insert(
            productId: productId,
            quantityDelta: deltaMilli ~/ 1000,
            quantityDeltaMilli: Value(deltaMilli),
            reason: reason,
            referenceId: Value(referenceId)));
  }

  Future<void> _changeLot(
      String productId, String batchNumber, int deltaMilli) async {
    final lot = await (db.select(db.productLots)
          ..where((l) =>
              l.productId.equals(productId) &
              l.batchNumber.equals(batchNumber)))
        .getSingleOrNull();
    if (lot == null || lot.quantityMilli + deltaMilli < 0) {
      throw StateError('Batch stock is unavailable');
    }
    await (db.update(db.productLots)..where((l) => l.id.equals(lot.id))).write(
        ProductLotsCompanion(
            quantityMilli: Value(lot.quantityMilli + deltaMilli)));
  }

  Future<void> _adjustLayer(String id, int deltaMilli) async {
    final layer = await (db.select(db.inventoryLayers)
          ..where((l) => l.id.equals(id)))
        .getSingle();
    final next = layer.quantityRemainingMilli + deltaMilli;
    if (next < 0 || next > layer.quantityReceivedMilli) {
      throw StateError('Inventory layer quantity is unavailable');
    }
    await (db.update(db.inventoryLayers)..where((l) => l.id.equals(id)))
        .write(InventoryLayersCompanion(quantityRemainingMilli: Value(next)));
  }
}

class RmaChoice {
  final String itemId;
  final String label;
  final List<SerialUnit> serials;
  final int? soldMilli;
  final int? claimedMilli;
  final String? customerName;
  final String? receipt;
  final DateTime? date;
  const RmaChoice(this.itemId, this.label, this.serials,
      {this.soldMilli,
      this.claimedMilli,
      this.customerName,
      this.receipt,
      this.date});
}
