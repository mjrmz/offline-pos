// lib/core/services/sale_service.dart
//
// Pure business logic — no Flutter imports. This is what makes it unit
// testable without a UI and reusable across every platform build.
//
// The one rule this file exists to enforce: a sale, its line items, its
// inventory deduction, its payment record, and its audit log entry are
// written in a single database transaction. If any step fails, none of it
// is committed. See docs/ARCHITECTURE.md section 4.

import 'package:drift/drift.dart';
import '../../data/database.dart';

class SaleItemInput {
  final String productId;
  final int quantity;
  final int unitPriceCents;

  const SaleItemInput({
    required this.productId,
    required this.quantity,
    required this.unitPriceCents,
  });
}

class InsufficientStockException implements Exception {
  final String productId;
  InsufficientStockException(this.productId);

  @override
  String toString() => 'Insufficient stock for product $productId';
}

class SaleService {
  final AppDatabase _db;

  SaleService(this._db);

  /// Creates a completed sale: Sale + SaleItems + inventory deduction +
  /// Payment + AuditLog, all inside one transaction. Throws
  /// [InsufficientStockException] and rolls back the whole transaction if
  /// any item doesn't have enough stock — never a partially-completed sale.
  Future<String> createSale({
    required String cashierId,
    required List<SaleItemInput> items,
    required String paymentMethod,
    required int amountTenderedCents,
  }) async {
    final totalCents = items.fold<int>(
      0,
      (sum, item) => sum + (item.unitPriceCents * item.quantity),
    );

    return _db.transaction(() async {
      final saleId = await _insertSale(cashierId, totalCents);

      for (final item in items) {
        await _insertSaleItem(saleId, item);
        await _deductInventory(item.productId, item.quantity, saleId);
      }

      await _insertPayment(saleId, paymentMethod, amountTenderedCents);
      await _writeAuditLog(
        userId: cashierId,
        action: 'sale_created',
        details: '{"saleId":"$saleId","totalCents":$totalCents}',
      );

      return saleId;
    });
  }

  /// Voids a sale — never deletes it. Preserves full history for audit.
  Future<void> voidSale(String saleId, {required String voidedByUserId}) {
    return _db.transaction(() async {
      await (_db.update(_db.sales)..where((s) => s.id.equals(saleId)))
          .write(const SalesCompanion(status: Value('voided')));

      // Reverse inventory movements tied to this sale.
      final items = await (_db.select(_db.saleItems)
            ..where((si) => si.saleId.equals(saleId)))
          .get();

      for (final item in items) {
        await _db.into(_db.inventoryMovements).insert(
              InventoryMovementsCompanion.insert(
                productId: item.productId,
                quantityDelta: item.quantity, // reverse the deduction
                reason: 'void',
                referenceId: Value(saleId),
              ),
            );
      }

      await _writeAuditLog(
        userId: voidedByUserId,
        action: 'sale_voided',
        details: '{"saleId":"$saleId"}',
      );
    });
  }

  // -- internals -------------------------------------------------------

  Future<String> _insertSale(String cashierId, int totalCents) async {
    final row = await _db.into(_db.sales).insertReturning(
          SalesCompanion.insert(
            cashierId: cashierId,
            totalCents: totalCents,
          ),
        );
    return row.id;
  }

  Future<void> _insertSaleItem(String saleId, SaleItemInput item) {
    return _db.into(_db.saleItems).insert(
          SaleItemsCompanion.insert(
            saleId: saleId,
            productId: item.productId,
            quantity: item.quantity,
            unitPriceCents: item.unitPriceCents,
          ),
        );
  }

  Future<void> _deductInventory(
    String productId,
    int quantity,
    String saleId,
  ) async {
    final currentStock = await _currentStock(productId);
    if (currentStock < quantity) {
      throw InsufficientStockException(productId);
    }

    await _db.into(_db.inventoryMovements).insert(
          InventoryMovementsCompanion.insert(
            productId: productId,
            quantityDelta: -quantity,
            reason: 'sale',
            referenceId: Value(saleId),
          ),
        );
  }

  Future<int> _currentStock(String productId) async {
    final query = _db.selectOnly(_db.inventoryMovements)
      ..addColumns([_db.inventoryMovements.quantityDelta.sum()])
      ..where(_db.inventoryMovements.productId.equals(productId));
    final row = await query.getSingleOrNull();
    return row?.read(_db.inventoryMovements.quantityDelta.sum()) ?? 0;
  }

  Future<void> _insertPayment(String saleId, String method, int amountCents) {
    return _db.into(_db.payments).insert(
          PaymentsCompanion.insert(
            saleId: saleId,
            method: method,
            amountCents: amountCents,
          ),
        );
  }

  Future<void> _writeAuditLog({
    required String userId,
    required String action,
    String? details,
  }) {
    return _db.into(_db.auditLogs).insert(
          AuditLogsCompanion.insert(
            userId: Value(userId),
            action: action,
            details: Value(details),
          ),
        );
  }
}
