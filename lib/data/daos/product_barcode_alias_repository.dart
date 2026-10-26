import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';

class ProductBarcodeAlias {
  const ProductBarcodeAlias(this.id, this.productId, this.barcode, this.type,
      this.label, this.isActive, this.createdAt);
  final String id, productId, barcode;
  final String? type, label;
  final bool isActive;
  final DateTime createdAt;
}

class ProductBarcodeAliasRepository {
  const ProductBarcodeAliasRepository(this.db);
  final AppDatabase db;

  static String normalize(String value) => value.trim();

  Future<List<ProductBarcodeAlias>> forProduct(String productId) async {
    final rows = await db.customSelect(
      'SELECT * FROM product_barcode_aliases WHERE product_id = ? ORDER BY created_at, id',
      variables: [Variable.withString(productId)],
    ).get();
    return [for (final row in rows) ProductBarcodeAlias(
      row.read<String>('id'), row.read<String>('product_id'),
      row.read<String>('barcode'), row.readNullable<String>('type'),
      row.readNullable<String>('label'), row.read<int>('is_active') == 1,
      DateTime.fromMillisecondsSinceEpoch(row.read<int>('created_at') * 1000))];
  }

  Future<String?> productIdFor(String barcode) async {
    final code = normalize(barcode);
    if (code.isEmpty) return null;
    final rows = await db.customSelect(
      'SELECT product_id FROM product_barcode_aliases WHERE barcode = ? AND is_active = 1',
      variables: [Variable.withString(code)],
    ).get();
    return rows.firstOrNull?.read<String>('product_id');
  }

  Future<String?> ownerName(String barcode, {String? exceptProductId}) async {
    final code = normalize(barcode);
    final rows = await db.customSelect('''
      SELECT name FROM products WHERE barcode = ? AND id != COALESCE(?, '')
      UNION ALL
      SELECT p.name FROM product_barcode_aliases a
      JOIN products p ON p.id = a.product_id WHERE a.barcode = ?
      LIMIT 1''', variables: [Variable.withString(code),
        Variable.withString(exceptProductId ?? ''), Variable.withString(code)]).get();
    return rows.firstOrNull?.read<String>('name');
  }

  Future<void> add(ActiveUser actor, String productId, String barcode,
      {String? type, String? label}) async {
    final live = await AuthRepository(db).requireActive(actor.id);
    live.require(PosPermission.manageCatalog);
    final code = normalize(barcode);
    if (code.isEmpty || code.length > 128) {
      throw StateError('Barcode must be 1 to 128 characters');
    }
    await db.transaction(() async {
      final owner = await ownerName(code);
      if (owner != null) throw StateError('This barcode is already assigned to $owner.');
      await db.customStatement('''INSERT INTO product_barcode_aliases
        (id, product_id, barcode, type, label, created_by, created_at, is_active)
        VALUES (?, ?, ?, ?, ?, ?, ?, 1)''', [const Uuid().v4(), productId,
        code, type?.trim(), label?.trim(), live.id,
        DateTime.now().millisecondsSinceEpoch ~/ 1000]);
      await _audit(live.id, 'product.barcode_alias.add', productId, code);
    });
  }

  Future<void> update(ActiveUser actor, ProductBarcodeAlias alias,
      {String? type, String? label, bool? isActive}) async {
    final live = await AuthRepository(db).requireActive(actor.id);
    live.require(PosPermission.manageCatalog);
    await db.transaction(() async {
      await db.customStatement('''UPDATE product_barcode_aliases
        SET type = ?, label = ?, is_active = ? WHERE id = ?''',
        [type?.trim(), label?.trim(), (isActive ?? alias.isActive) ? 1 : 0, alias.id]);
      await _audit(live.id,
        isActive == null ? 'product.barcode_alias.edit' :
          isActive ? 'product.barcode_alias.enable' : 'product.barcode_alias.disable',
        alias.productId, alias.barcode);
    });
  }

  Future<void> _audit(String actorId, String action, String productId,
      String barcode) => db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
        userId: Value(actorId), action: action,
        details: Value('Product $productId barcode $barcode'))).then((_) {});
}
