import 'package:drift/drift.dart';
import '../../core/models/product.dart';
import '../../core/models/active_user.dart';
import 'auth_repository.dart';
import '../database.dart';

class SaleLineRequest {
  final String productId;
  final int quantity;
  const SaleLineRequest(this.productId, this.quantity);
}

class CommittedSale {
  final String saleId;
  final int totalCents;
  const CommittedSale(this.saleId, this.totalCents);
}

class PosRepository {
  final AppDatabase db;
  PosRepository(this.db);
  PosProduct _product(Product row) => PosProduct(
      row.id,
      row.name,
      row.barcode,
      row.priceCents,
      row.isActive,
      row.sku,
      row.categoryId,
      row.costCents ?? 0,
      row.lowStockThreshold);

  Future<List<Category>> categories() => (db.select(db.categories)
        ..orderBy([(c) => OrderingTerm(expression: c.name)]))
      .get();
  Future<String> addCategory(String name, {String? parentId}) async {
    if (name.trim().isEmpty) throw ArgumentError('Category name is required');
    final row = await db.into(db.categories).insertReturning(
        CategoriesCompanion.insert(
            name: name.trim(), parentCategoryId: Value(parentId)));
    return row.id;
  }

  Future<List<PosProduct>> products() async => (await (db.select(db.products)
            ..orderBy([(p) => OrderingTerm(expression: p.name)]))
          .get())
      .map(_product)
      .toList();
  Future<PosProduct?> barcode(String code) async {
    final row = await (db.select(db.products)
          ..where((p) => p.barcode.equals(code)))
        .getSingleOrNull();
    if (row == null) return null;
    if (!row.isActive) throw StateError('Product is inactive');
    return _product(row);
  }

  Future<void> _validateCodes(
      String? sku, String? barcode, String? exceptId) async {
    final rows = await db.select(db.products).get();
    if (rows.any((p) =>
        p.id != exceptId && sku != null && sku.isNotEmpty && p.sku == sku)) {
      throw StateError('SKU already exists');
    }
    if (rows.any((p) =>
        p.id != exceptId &&
        barcode != null &&
        barcode.isNotEmpty &&
        p.barcode == barcode)) {
      throw StateError('Barcode already exists');
    }
  }

  Future<String> saveProduct(
      {String? id,
      required String name,
      String? sku,
      String? barcode,
      String? categoryId,
      required int priceCents,
      required int costCents,
      int startingStock = 0,
      int lowStockThreshold = 5,
      bool isActive = true}) async {
    if (name.trim().isEmpty ||
        priceCents < 0 ||
        costCents < 0 ||
        startingStock < 0 ||
        lowStockThreshold < 0) {
      throw ArgumentError('Invalid product values');
    }
    final normalizedSku = sku?.trim().isEmpty == true ? null : sku?.trim();
    final normalizedBarcode =
        barcode?.trim().isEmpty == true ? null : barcode?.trim();
    return db.transaction(() async {
      await _validateCodes(normalizedSku, normalizedBarcode, id);
      if (id != null) {
        final count = await (db.update(db.products)
              ..where((p) => p.id.equals(id)))
            .write(ProductsCompanion(
                name: Value(name.trim()),
                sku: Value(normalizedSku),
                barcode: Value(normalizedBarcode),
                categoryId: Value(categoryId),
                priceCents: Value(priceCents),
                costCents: Value(costCents),
                lowStockThreshold: Value(lowStockThreshold),
                isActive: Value(isActive)));
        if (count != 1) throw StateError('Product not found');
        return id;
      }
      final row = await db.into(db.products).insertReturning(
          ProductsCompanion.insert(
              name: name.trim(),
              sku: Value(normalizedSku),
              barcode: Value(normalizedBarcode),
              categoryId: Value(categoryId),
              priceCents: priceCents,
              costCents: Value(costCents),
              lowStockThreshold: Value(lowStockThreshold),
              isActive: Value(isActive)));
      await db
          .into(db.inventory)
          .insert(InventoryCompanion.insert(productId: row.id));
      if (startingStock > 0) {
        await (db.update(db.inventory)
              ..where((i) => i.productId.equals(row.id)))
            .write(InventoryCompanion(quantity: Value(startingStock)));
        await db.into(db.inventoryMovements).insert(
            InventoryMovementsCompanion.insert(
                productId: row.id,
                quantityDelta: startingStock,
                reason: 'initial_stock'));
      }
      return row.id;
    });
  }

  Future<int> stock(String productId) async =>
      (await (db.select(db.inventory)
                ..where((i) => i.productId.equals(productId)))
              .getSingleOrNull())
          ?.quantity ??
      0;
  Future<List<InventoryMovement>> movements(String productId) =>
      (db.select(db.inventoryMovements)
            ..where((m) => m.productId.equals(productId)))
          .get();

  Future<CommittedSale> completeCashSale(List<SaleLineRequest> items,
          int cashReceivedCents, String cashierId) =>
      db.transaction(() async {
        final actor = await AuthRepository(db).requireActive(cashierId);
        if (!actor.can(PosPermission.sell)) {
          throw StateError('Not authorized to sell');
        }
        if (items.isEmpty) throw StateError('Cart is empty');
        final merged = <String, int>{};
        for (final item in items) {
          if (item.quantity <= 0) throw StateError('Invalid quantity');
          merged.update(item.productId, (v) => v + item.quantity,
              ifAbsent: () => item.quantity);
        }
        final details = <(Product, int)>[];
        var total = 0;
        for (final entry in merged.entries) {
          final product = await (db.select(db.products)
                ..where((p) => p.id.equals(entry.key)))
              .getSingleOrNull();
          if (product == null || !product.isActive) {
            throw StateError('Product is inactive or missing');
          }
          final current = await stock(product.id);
          if (current < entry.value) {
            throw StateError('Insufficient stock for ${product.name}');
          }
          details.add((product, entry.value));
          total += product.priceCents * entry.value;
        }
        if (cashReceivedCents < total) throw StateError('Insufficient cash');
        final sale = await db.into(db.sales).insertReturning(
            SalesCompanion.insert(cashierId: cashierId, totalCents: total));
        for (final (product, quantity) in details) {
          await db.into(db.saleItems).insert(SaleItemsCompanion.insert(
              saleId: sale.id,
              productId: product.id,
              productName: Value(product.name),
              quantity: quantity,
              unitPriceCents: product.priceCents,
              lineTotalCents: Value(product.priceCents * quantity)));
          final updated = await (db.update(db.inventory)
                ..where((i) =>
                    i.productId.equals(product.id) &
                    i.quantity.isBiggerOrEqualValue(quantity)))
              .write(InventoryCompanion(
                  quantity: Value((await stock(product.id)) - quantity)));
          if (updated != 1) {
            throw StateError('Insufficient stock for ${product.name}');
          }
          await db.into(db.inventoryMovements).insert(
              InventoryMovementsCompanion.insert(
                  productId: product.id,
                  quantityDelta: -quantity,
                  reason: 'sale',
                  referenceId: Value(sale.id)));
        }
        await db.into(db.payments).insert(PaymentsCompanion.insert(
            saleId: sale.id, method: 'cash', amountCents: total));
        return CommittedSale(sale.id, total);
      });
}
