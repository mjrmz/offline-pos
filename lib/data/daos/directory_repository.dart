import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';

class DirectoryRepository {
  final AppDatabase db;
  DirectoryRepository(this.db);

  Future<List<Customer>> customers() => (db.select(db.customers)
        ..orderBy([(c) => OrderingTerm(expression: c.name)]))
      .get();

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
