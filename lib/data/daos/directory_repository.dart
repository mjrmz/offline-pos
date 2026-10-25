import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';

class CustomerSummary {
  final int purchases;
  final int lifetimeCents;
  final int points;
  final int creditCents;
  final String group;
  final DateTime? lastPurchase;
  const CustomerSummary(this.purchases, this.lifetimeCents, this.points,
      this.creditCents, this.group, this.lastPurchase);
}

class SupplierListSummary {
  final DateTime? lastReceiving;
  final DateTime? lastOrder;
  final int purchasedCents;
  const SupplierListSummary(
      this.lastReceiving, this.lastOrder, this.purchasedCents);
}

class DirectoryRepository {
  final AppDatabase db;
  DirectoryRepository(this.db);

  Future<Customer?> customerById(String id) =>
      (db.select(db.customers)..where((c) => c.id.equals(id)))
          .getSingleOrNull();

  Future<Supplier?> supplierById(String id) =>
      (db.select(db.suppliers)..where((s) => s.id.equals(id)))
          .getSingleOrNull();

  Future<int> countCustomers(String search) async {
    final term = '%${search.trim().toLowerCase()}%';
    final row = await db
        .customSelect('''SELECT COUNT(*) AS total FROM customers c
      WHERE lower(c.name) LIKE ? OR lower(COALESCE(c.phone,'')) LIKE ?''',
            variables: [
          Variable.withString(term),
          Variable.withString(term)
        ]).getSingle();
    return row.read<int>('total');
  }

  Future<int> countSuppliers(String search) async {
    final term = '%${search.trim().toLowerCase()}%';
    final row = await db
        .customSelect('''SELECT COUNT(*) AS total FROM suppliers s
      WHERE lower(s.name) LIKE ? OR lower(COALESCE(s.phone,'')) LIKE ?
        OR lower(COALESCE(s.contact,'')) LIKE ?''', variables: [
      Variable.withString(term),
      Variable.withString(term),
      Variable.withString(term)
    ]).getSingle();
    return row.read<int>('total');
  }

  Future<List<Customer>> customerPage(String search, int page) =>
      (db.select(db.customers)
            ..where((c) =>
                c.name.lower().like('%${search.trim().toLowerCase()}%') |
                c.phone.lower().like('%${search.trim().toLowerCase()}%'))
            ..orderBy([(c) => OrderingTerm(expression: c.name)])
            ..limit(50, offset: page * 50))
          .get();

  Future<List<Supplier>> supplierPage(String search, int page) =>
      (db.select(db.suppliers)
            ..where((s) =>
                s.name.lower().like('%${search.trim().toLowerCase()}%') |
                s.phone.lower().like('%${search.trim().toLowerCase()}%') |
                s.contact.lower().like('%${search.trim().toLowerCase()}%'))
            ..orderBy([(s) => OrderingTerm(expression: s.name)])
            ..limit(50, offset: page * 50))
          .get();

  Future<Map<String, SupplierListSummary>> supplierSummaries(
      List<Supplier> suppliers, DateTime from, DateTime until) async {
    if (suppliers.isEmpty) return {};
    final ids = suppliers.map((s) => s.id).toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.customSelect('''
      SELECT s.id, po.last_order, r.last_receiving,
        COALESCE(r.purchased,0) AS purchased
      FROM suppliers s
      LEFT JOIN (SELECT supplier_id, MAX(order_date) AS last_order
        FROM purchase_orders GROUP BY supplier_id) po ON po.supplier_id=s.id
      LEFT JOIN (SELECT sr.supplier_id, MAX(sr.received_at) AS last_receiving,
        CAST(SUM(CASE WHEN sr.received_at>=? AND sr.received_at<?
          THEN si.quantity_milli * si.unit_cost_cents / 1000 ELSE 0 END) AS INTEGER)
          AS purchased
        FROM stock_receivings sr
        LEFT JOIN stock_receiving_items si ON si.receiving_id=sr.id
        WHERE sr.finalized_at IS NOT NULL GROUP BY sr.supplier_id) r
        ON r.supplier_id=s.id
      WHERE s.id IN ($placeholders)
    ''', variables: [
      Variable.withInt(from.millisecondsSinceEpoch ~/ 1000),
      Variable.withInt(until.millisecondsSinceEpoch ~/ 1000),
      for (final id in ids) Variable.withString(id),
    ]).get();
    DateTime? readDate(QueryRow row, String name) =>
        row.read<int?>(name) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row.read<int>(name) * 1000);
    return {
      for (final row in rows)
        row.read<String>('id'): SupplierListSummary(
            readDate(row, 'last_receiving'),
            readDate(row, 'last_order'),
            row.read<int>('purchased'))
    };
  }

  Future<Map<String, CustomerSummary>> customerSummaries(
      {List<String>? ids}) async {
    if (ids != null && ids.isEmpty) return {};
    final scope = ids == null
        ? ''
        : ' WHERE c.id IN (${List.filled(ids.length, '?').join(',')})';
    final rows = await db.customSelect('''SELECT c.id,
      COALESCE(s.purchases,0) AS purchases,
      s.last_purchase,
      COALESCE(s.spend,0)-COALESCE(r.refunds,0) AS lifetime,
      COALESCE(l.points,0) AS points,
      COALESCE(cr.balance,0) AS credit,
      COALESCE(g.group_name,'Retail') AS group_name
      FROM customers c
      LEFT JOIN (SELECT customer_id,COUNT(*) AS purchases,
        SUM(total_cents) AS spend, MAX(created_at) AS last_purchase
        FROM sales WHERE status='completed'
        GROUP BY customer_id) s ON s.customer_id=c.id
      LEFT JOIN (SELECT s.customer_id,SUM(r.refund_value_cents) AS refunds
        FROM sale_returns r JOIN sales s ON s.id=r.original_sale_id
        WHERE r.status='finalized' AND s.status='completed'
        GROUP BY s.customer_id) r ON r.customer_id=c.id
      LEFT JOIN (SELECT customer_id,SUM(points_delta) AS points
        FROM loyalty_ledger GROUP BY customer_id) l ON l.customer_id=c.id
      LEFT JOIN (SELECT customer_id,SUM(amount_cents) AS balance
        FROM customer_credit_entries GROUP BY customer_id) cr ON cr.customer_id=c.id
      LEFT JOIN customer_groups g ON g.customer_id=c.id$scope''', variables: [
      if (ids != null)
        for (final id in ids) Variable.withString(id)
    ]).get();
    return {
      for (final row in rows)
        row.read<String>('id'): CustomerSummary(
            row.read<int>('purchases'),
            row.read<int>('lifetime'),
            row.read<int>('points'),
            row.read<int>('credit'),
            row.read<String>('group_name'),
            row.read<int?>('last_purchase') == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    row.read<int>('last_purchase') * 1000))
    };
  }

  Future<List<Customer>> customers() => (db.select(db.customers)
        ..orderBy([(c) => OrderingTerm(expression: c.name)]))
      .get();

  Future<Customer> quickCreateCustomer(ActiveUser actor,
          {required String name, String? phone}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.sell);
        final cleanName = name.trim();
        if (cleanName.isEmpty) throw StateError('Customer name is required');
        final result = await db.into(db.customers).insertReturning(
            CustomersCompanion.insert(
                name: cleanName, phone: Value(_optional(phone))));
        await AuthRepository(db)
            .audit(live.id, 'customer.quick_create', result.id);
        return result;
      });

  Future<List<Supplier>> suppliers() => (db.select(db.suppliers)
        ..orderBy([(s) => OrderingTerm(expression: s.name)]))
      .get();

  Future<Customer> saveCustomer(ActiveUser actor,
          {String? id,
          required String name,
          String? phone,
          String? address,
          String? notes,
          bool active = true}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageContacts);
        final cleanName = name.trim();
        if (cleanName.isEmpty) throw ArgumentError('Customer name is required');
        final values = CustomersCompanion(
          name: Value(cleanName),
          phone: Value(_optional(phone)),
          address: Value(_optional(address)),
          notes: Value(_optional(notes)),
          isActive: Value(active),
        );
        final Customer result;
        if (id == null) {
          result = await db.into(db.customers).insertReturning(values);
        } else {
          final old = await (db.select(db.customers)
                ..where((c) => c.id.equals(id)))
              .getSingle();
          await (db.update(db.customers)..where((c) => c.id.equals(id)))
              .write(values);
          result = old.copyWith(
            name: cleanName,
            phone: Value(_optional(phone)),
            address: Value(_optional(address)),
            notes: Value(_optional(notes)),
            isActive: active,
          );
        }
        await AuthRepository(db).audit(live.id, 'customer.save', result.id);
        return result;
      });

  Future<Supplier> saveSupplier(ActiveUser actor,
          {String? id,
          required String name,
          String? contact,
          String? phone,
          String? address,
          String? notes,
          bool active = true}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageContacts);
        final cleanName = name.trim();
        if (cleanName.isEmpty) throw ArgumentError('Supplier name is required');
        final values = SuppliersCompanion(
          name: Value(cleanName),
          contact: Value(_optional(contact)),
          phone: Value(_optional(phone)),
          address: Value(_optional(address)),
          notes: Value(_optional(notes)),
          isActive: Value(active),
        );
        final Supplier result;
        if (id == null) {
          result = await db.into(db.suppliers).insertReturning(values);
        } else {
          final old = await (db.select(db.suppliers)
                ..where((s) => s.id.equals(id)))
              .getSingle();
          await (db.update(db.suppliers)..where((s) => s.id.equals(id)))
              .write(values);
          result = old.copyWith(
            name: cleanName,
            contact: Value(_optional(contact)),
            phone: Value(_optional(phone)),
            address: Value(_optional(address)),
            notes: Value(_optional(notes)),
            isActive: active,
          );
        }
        await AuthRepository(db).audit(live.id, 'supplier.save', result.id);
        return result;
      });

  String? _optional(String? value) =>
      value?.trim().isEmpty == true ? null : value?.trim();
}
