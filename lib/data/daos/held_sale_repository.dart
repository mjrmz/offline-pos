import 'dart:convert';
import 'package:drift/drift.dart';
import '../../core/models/cart.dart';
import '../../core/models/manual_discount.dart';
import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';

class HeldSaleSnapshot {
  final List<Map<String, dynamic>> lines;
  final String? customerId;
  final String? walkInName;
  final String? walkInContact;
  final ManualDiscount? discount;
  final int redeemPoints;
  final int subtotalCents;
  final String? quotationId;

  const HeldSaleSnapshot(this.lines,
      {this.customerId,
      this.walkInName,
      this.walkInContact,
      this.discount,
      this.redeemPoints = 0,
      this.subtotalCents = 0,
      this.quotationId});

  factory HeldSaleSnapshot.fromRow(HeldSale row) {
    final data = jsonDecode(row.snapshotJson) as Map<String, dynamic>;
    return HeldSaleSnapshot(
      (data['lines'] as List).cast<Map<String, dynamic>>(),
      customerId: data['customerId'] as String?,
      walkInName: data['walkInName'] as String?,
      walkInContact: data['walkInContact'] as String?,
      discount: data['discount'] == null
          ? null
          : ManualDiscount.fromJson(
              (data['discount'] as Map).cast<String, dynamic>()),
      redeemPoints: data['redeemPoints'] as int? ?? 0,
      subtotalCents: data['subtotalCents'] as int? ?? 0,
      quotationId: data['quotationId'] as String?,
    );
  }
}

class HeldSaleRepository {
  final AppDatabase db;
  const HeldSaleRepository(this.db);

  Future<List<HeldSale>> all(ActiveUser actor) async {
    (await AuthRepository(db).requireActive(actor.id))
        .require(PosPermission.resumeSale);
    return (db.select(db.heldSales)
          ..orderBy([(h) => OrderingTerm.desc(h.heldAt)]))
        .get();
  }

  Future<HeldSale> hold(ActiveUser actor, Cart cart,
          {String? label,
          String? customerId,
          String? walkInName,
          String? walkInContact,
          ManualDiscount? discount,
          int redeemPoints = 0,
          String? quotationId}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.holdSale);
        if (cart.isEmpty) throw StateError('Add an item before holding a sale');
        final next = await db.customSelect('''
          SELECT COALESCE(MAX(CAST(SUBSTR(reference, 6) AS INTEGER)), 0) + 1
            AS n FROM held_sales WHERE reference GLOB 'HOLD-[0-9]*'
        ''').getSingle();
        final reference =
            'HOLD-${next.read<int>('n').toString().padLeft(6, '0')}';
        final payload = {
          'lines': [
            for (final line in cart.lines)
              {
                'id': line.id,
                'productId': line.product.id,
                'unitPriceCents': line.product.priceCents,
                'quantityMilli': line.quantityMilli,
                'mode': line.mode,
                'batchId': line.batchId,
                'serialIds': line.serialIds,
                'extraCents': line.extraCents,
                'pricedTotalCents': line.pricedTotalCents,
                'kitDefinition': line.kitDefinition,
                'kitChoices': {for (final entry in line.kitChoices.entries)
                  entry.key: entry.value.toJson()},
              }
          ],
          'customerId': customerId,
          'walkInName': walkInName,
          'walkInContact': walkInContact,
          'discount': discount?.toJson(),
          'redeemPoints': redeemPoints,
          'subtotalCents': cart.totalCents,
          'quotationId': quotationId,
        };
        return db.into(db.heldSales).insertReturning(HeldSalesCompanion.insert(
            reference: reference,
            label: Value(label?.trim().isEmpty == true ? null : label?.trim()),
            snapshotJson: jsonEncode(payload),
            heldBy: live.id));
      });

  Future<void> remove(ActiveUser actor, String id, {bool discard = false}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.resumeSale);
        final row = await (db.select(db.heldSales)
              ..where((h) => h.id.equals(id)))
            .getSingleOrNull();
        if (row == null) throw StateError('Held sale no longer exists');
        await (db.delete(db.heldSales)..where((h) => h.id.equals(id))).go();
        if (discard) {
          await AuthRepository(db)
              .audit(live.id, 'held_sale.discard', row.reference);
        }
      });
}
