import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../shared/utils/money.dart';
import '../database.dart';
import 'auth_repository.dart';

enum ImportKind { products, customers, suppliers, openingInventory }

enum ImportAction { create, update, skip }

class ImportRow {
  ImportRow(this.number, this.values);
  final int number;
  final Map<String, String> values;
  final List<String> errors = [];
  final List<String> warnings = [];
  ImportAction action = ImportAction.create;
  String? existingId;
  String? existingName;
  Map<String, String> changes = {};
  bool get ready => errors.isEmpty && action != ImportAction.skip;
}

class ImportPreview {
  ImportPreview(this.rows, this.missingCategories);
  final List<ImportRow> rows;
  final Set<String> missingCategories;
  int get ready => rows.where((r) => r.ready).length;
  int get errors => rows.where((r) => r.errors.isNotEmpty).length;
  int get warnings => rows.where((r) => r.warnings.isNotEmpty).length;
}

class ImportResult {
  const ImportResult(this.created, this.updated, this.skipped,
      {this.productsAffected = 0,
      this.serialsCreated = 0,
      this.valueCents = 0});
  final int created;
  final int updated;
  final int skipped;
  final int productsAffected;
  final int serialsCreated;
  final int valueCents;
}

class ImportCsv {
  static List<List<String>> parse(String source) {
    final input = source.replaceFirst('\uFEFF', '');
    final rows = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var quoted = false;
    var closed = false;
    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      if (quoted) {
        if (c == '"' && i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i++;
        } else if (c == '"') {
          quoted = false;
          closed = true;
        } else {
          field.write(c);
        }
      } else if (c == '"' && field.isEmpty && !closed) {
        quoted = true;
      } else if (c == ',') {
        row.add(field.toString());
        field = StringBuffer();
        closed = false;
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < input.length && input[i + 1] == '\n') i++;
        row.add(field.toString());
        if (row.any((v) => v.isNotEmpty)) rows.add(row);
        row = <String>[];
        field = StringBuffer();
        closed = false;
      } else if (closed || c == '"') {
        throw const FormatException('Malformed CSV quoting');
      } else {
        field.write(c);
      }
    }
    if (quoted) throw const FormatException('Unclosed quoted field');
    row.add(field.toString());
    if (row.any((v) => v.isNotEmpty)) rows.add(row);
    if (rows.isEmpty || rows.first.every((v) => v.trim().isEmpty)) {
      throw const FormatException('CSV does not contain a header row');
    }
    final width = rows.first.length;
    if (rows.skip(1).any((r) => r.length != width)) {
      throw const FormatException('CSV rows have different column counts');
    }
    return rows;
  }

  static String template(ImportKind kind) => '${fields(kind).join(',')}\r\n';
  static List<String> fields(ImportKind kind) => switch (kind) {
        ImportKind.products => [
            'name',
            'sku',
            'barcode',
            'category',
            'selling_price',
            'cost',
            'reorder_level',
            'target_stock',
            'preferred_supplier',
            'active'
          ],
        ImportKind.customers => ['name', 'phone', 'address', 'notes'],
        ImportKind.suppliers => [
            'name',
            'contact',
            'phone',
            'address',
            'notes'
          ],
        ImportKind.openingInventory => [
            'product',
            'sku',
            'barcode',
            'quantity',
            'unit_cost',
            'unit_selling_price',
            'batch_lot',
            'expiry_date',
            'serial_number'
          ],
      };

  static Map<String, String> autoMap(List<String> headers, ImportKind kind) {
    const aliases = {
      'product name': 'name',
      'item name': 'name',
      'customer name': 'name',
      'supplier name': 'name',
      'item code': 'sku',
      'price': 'selling_price',
      'selling price': 'selling_price',
      'retail price': 'selling_price',
      'mobile': 'phone',
      'telephone': 'phone',
      'category name': 'category',
      'supplier': 'preferred_supplier'
    };
    final allowed = fields(kind).toSet();
    final result = <String, String>{};
    for (final h in headers) {
      final key = h.trim().toLowerCase().replaceAll('_', ' ');
      final field = kind == ImportKind.openingInventory
          ? ({
                'name': 'product',
                'product name': 'product',
                'item name': 'product',
                'item code': 'sku',
                'cost': 'unit_cost',
                'batch': 'batch_lot',
                'lot': 'batch_lot',
                'expiry': 'expiry_date',
                'serial': 'serial_number'
              }[key] ??
              key.replaceAll(' ', '_'))
          : (aliases[key] ?? key.replaceAll(' ', '_'));
      if (allowed.contains(field) && !result.containsValue(field)) {
        result[h] = field;
      }
    }
    return result;
  }
}

class ImportRepository {
  ImportRepository(this.db);
  final AppDatabase db;

  static String norm(String? value) => (value ?? '').trim().toLowerCase();
  static int? cents(String value) {
    return tryParsePeso(value);
  }

  Future<ImportPreview> validate(
      ImportKind kind, List<List<String>> csv, Map<String, String> mapping,
      {bool createCategories = false}) async {
    if (kind == ImportKind.openingInventory) {
      throw StateError('Use OpeningInventoryImportRepository for stock');
    }
    if (!mapping.containsValue('name')) {
      throw const FormatException('Map a Name column');
    }
    final products = kind == ImportKind.products
        ? await db.select(db.products).get()
        : <Product>[];
    final customers = kind == ImportKind.customers
        ? await db.select(db.customers).get()
        : <Customer>[];
    final suppliers = await db.select(db.suppliers).get();
    final categories = kind == ImportKind.products
        ? await db.select(db.categories).get()
        : <Category>[];
    final bySku = {
      for (final p in products)
        if (norm(p.sku).isNotEmpty) norm(p.sku): p
    };
    final byBarcode = {
      for (final p in products)
        if (norm(p.barcode).isNotEmpty) norm(p.barcode): p
    };
    final byProductName = {for (final p in products) norm(p.name): p};
    final byCustomerName = {for (final c in customers) norm(c.name): c};
    final byPhone = {
      for (final c in customers)
        if (norm(c.phone).isNotEmpty) norm(c.phone): c
    };
    final bySupplierName = {for (final s in suppliers) norm(s.name): s};
    final byContact = {
      for (final s in suppliers)
        if (norm(s.contact).isNotEmpty) norm(s.contact): s
    };
    final categoryNames = {for (final c in categories) norm(c.name)};
    final supplierNames = {for (final s in suppliers) norm(s.name)};
    final seenSku = <String>{}, seenBarcode = <String>{}, seenName = <String>{};
    final seenContact = <String>{};
    final missing = <String>{};
    final rows = <ImportRow>[];
    for (var i = 1; i < csv.length; i++) {
      final values = <String, String>{};
      for (var col = 0; col < csv.first.length; col++) {
        final field = mapping[csv.first[col]];
        if (field != null) values[field] = csv[i][col].trim();
      }
      final row = ImportRow(i + 1, values);
      rows.add(row);
      final name = norm(values['name']);
      if (name.isEmpty) row.errors.add('Name is required');
      if (kind == ImportKind.products) {
        final price = values['selling_price'];
        if (price != null && price.isNotEmpty && cents(price) == null) {
          row.errors.add('Invalid selling price');
        }
        final cost = values['cost'];
        if (cost != null && cost.isNotEmpty && cents(cost) == null) {
          row.errors.add('Invalid cost');
        }
        for (final f in ['reorder_level', 'target_stock']) {
          final v = values[f];
          if (v != null &&
              v.isNotEmpty &&
              v != '0' &&
              Quantity.tryParse(v) == null) {
            row.errors.add('Invalid $f');
          }
        }
        final active = norm(values['active']);
        if (active.isNotEmpty &&
            !['true', 'false', 'yes', 'no', '1', '0'].contains(active)) {
          row.errors.add('Invalid active value');
        }
        final category = norm(values['category']);
        if (category.isNotEmpty && !categoryNames.contains(category)) {
          if (createCategories) {
            missing.add(values['category']!);
          } else {
            row.errors.add('Category not found: ${values['category']}');
          }
        }
        final supplier = norm(values['preferred_supplier']);
        if (supplier.isNotEmpty && !supplierNames.contains(supplier)) {
          row.errors.add('Supplier not found: ${values['preferred_supplier']}');
        }
        final sku = norm(values['sku']), barcode = norm(values['barcode']);
        final skuMatch = bySku[sku], barcodeMatch = byBarcode[barcode];
        if (sku.isNotEmpty && !seenSku.add(sku)) {
          row.errors.add('Duplicate SKU in file');
        }
        if (barcode.isNotEmpty && !seenBarcode.add(barcode)) {
          row.errors.add('Duplicate barcode in file');
        }
        if (skuMatch != null &&
            barcodeMatch != null &&
            skuMatch.id != barcodeMatch.id) {
          row.errors.add('SKU and barcode belong to different products');
        }
        final match = skuMatch ?? barcodeMatch;
        if (match != null) {
          row.existingId = match.id;
          row.existingName = match.name;
          row.action = ImportAction.skip;
          row.warnings.add('SKU/barcode belongs to ${match.name}');
          final price = values['selling_price'];
          if (price != null &&
              price.isNotEmpty &&
              cents(price) != null &&
              cents(price) != match.priceCents) {
            row.changes['Selling price'] = '${match.priceCents / 100} → $price';
          }
          final newName = values['name'];
          if (newName != null && newName.isNotEmpty && newName != match.name) {
            row.changes['Name'] = '${match.name} → $newName';
          }
        } else if (name.isNotEmpty && byProductName.containsKey(name)) {
          row.existingId = byProductName[name]!.id;
          row.existingName = byProductName[name]!.name;
          row.action = ImportAction.skip;
          row.warnings.add('Possible duplicate name: ${row.existingName}');
        }
      } else if (kind == ImportKind.customers) {
        final phone = norm(values['phone']);
        if (phone.isNotEmpty && !seenContact.add(phone)) {
          row.errors.add('Duplicate phone in file');
        }
        final match =
            (phone.isEmpty ? null : byPhone[phone]) ?? byCustomerName[name];
        if (match != null) {
          row.existingId = match.id;
          row.existingName = match.name;
          row.action = ImportAction.skip;
          row.warnings.add('Existing customer: ${match.name}');
          if (values['phone']?.isNotEmpty == true &&
              values['phone'] != match.phone) {
            row.changes['Phone'] =
                '${match.phone ?? 'blank'} → ${values['phone']}';
          }
        }
      } else {
        final contact = norm(values['contact']);
        if (contact.isNotEmpty && !seenContact.add(contact)) {
          row.errors.add('Duplicate contact in file');
        }
        final match = bySupplierName[name] ??
            (contact.isEmpty ? null : byContact[contact]);
        if (match != null) {
          row.existingId = match.id;
          row.existingName = match.name;
          row.action = ImportAction.skip;
          row.warnings.add('Existing supplier: ${match.name}');
          if (values['contact']?.isNotEmpty == true &&
              values['contact'] != match.contact) {
            row.changes['Contact'] =
                '${match.contact ?? 'blank'} → ${values['contact']}';
          }
        }
      }
      if (name.isNotEmpty && !seenName.add(name)) {
        row.errors.add('Repeated name in file');
      }
    }
    return ImportPreview(rows, missing);
  }

  Future<ImportResult> commit(ActiveUser actor, ImportKind kind,
          ImportPreview preview, Map<String, String> mapping, String fileName,
          {bool createCategories = false}) =>
      db.transaction(() async {
        if (kind == ImportKind.openingInventory) {
          throw StateError('Use OpeningInventoryImportRepository for stock');
        }
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(kind == ImportKind.products
            ? PosPermission.manageCatalog
            : PosPermission.manageContacts);
        final categories = await db.select(db.categories).get();
        final suppliers = await db.select(db.suppliers).get();
        final categoryIds = {for (final c in categories) norm(c.name): c.id};
        final supplierIds = {for (final s in suppliers) norm(s.name): s.id};
        if (createCategories) {
          for (final name in preview.rows
              .where((r) => r.ready)
              .map((r) => r.values['category'])
              .whereType<String>()
              .where((s) => s.isNotEmpty)) {
            if (!categoryIds.containsKey(norm(name))) {
              categoryIds[norm(name)] = await db
                  .into(db.categories)
                  .insertReturning(CategoriesCompanion.insert(name: name))
                  .then((c) => c.id);
            }
          }
        }
        var created = 0, updated = 0, skipped = 0;
        final existingProducts = kind == ImportKind.products
            ? await db.select(db.products).get()
            : <Product>[];
        for (final row in preview.rows) {
          if (!row.ready) {
            skipped++;
            continue;
          }
          final v = row.values;
          final id = row.action == ImportAction.update ? row.existingId : null;
          if (kind == ImportKind.products) {
            final old = id == null
                ? null
                : existingProducts.where((p) => p.id == id).first;
            String? opt(String key, String? previous) =>
                v[key]?.isNotEmpty == true ? v[key] : previous;
            final sku = opt('sku', old?.sku),
                barcode = opt('barcode', old?.barcode);
            if (existingProducts.any((p) =>
                p.id != id &&
                ((sku != null && norm(p.sku) == norm(sku)) ||
                    (barcode != null && norm(p.barcode) == norm(barcode))))) {
              throw StateError(
                  'Duplicate SKU or barcode at CSV row ${row.number}');
            }
            final category = opt('category', null);
            final supplier = opt('preferred_supplier', null);
            if (category != null && !categoryIds.containsKey(norm(category))) {
              throw StateError('Category not found at CSV row ${row.number}');
            }
            if (supplier != null && !supplierIds.containsKey(norm(supplier))) {
              throw StateError('Supplier not found at CSV row ${row.number}');
            }
            final values = ProductsCompanion(
              name: Value(opt('name', old?.name)!),
              sku: Value(sku),
              barcode: Value(barcode),
              categoryId: Value(category == null
                  ? old?.categoryId
                  : categoryIds[norm(category)]),
              preferredSupplierId: Value(supplier == null
                  ? old?.preferredSupplierId
                  : supplierIds[norm(supplier)]),
              priceCents: Value(v['selling_price']?.isNotEmpty == true
                  ? cents(v['selling_price']!)!
                  : old?.priceCents ?? 0),
              costCents: Value(v['cost']?.isNotEmpty == true
                  ? cents(v['cost']!)
                  : old?.costCents),
              reorderLevelQtyMilli: Value(v['reorder_level']?.isNotEmpty == true
                  ? (v['reorder_level'] == '0'
                      ? 0
                      : Quantity.tryParse(v['reorder_level']!))
                  : old?.reorderLevelQtyMilli),
              targetStockQtyMilli: Value(v['target_stock']?.isNotEmpty == true
                  ? (v['target_stock'] == '0'
                      ? 0
                      : Quantity.tryParse(v['target_stock']!))
                  : old?.targetStockQtyMilli),
              isActive: Value(v['active']?.isNotEmpty == true
                  ? ['true', 'yes', '1'].contains(norm(v['active']))
                  : old?.isActive ?? true),
            );
            if (id == null) {
              final inserted =
                  await db.into(db.products).insertReturning(values);
              existingProducts.add(inserted);
              created++;
            } else {
              await (db.update(db.products)..where((p) => p.id.equals(id)))
                  .write(values);
              updated++;
            }
          } else if (kind == ImportKind.customers) {
            final values = CustomersCompanion(
                name: Value(v['name']!),
                phone: _value(v, 'phone', id != null),
                address: _value(v, 'address', id != null),
                notes: _value(v, 'notes', id != null));
            if (id == null) {
              await db.into(db.customers).insert(values);
              created++;
            } else {
              await (db.update(db.customers)..where((c) => c.id.equals(id)))
                  .write(values);
              updated++;
            }
          } else {
            final values = SuppliersCompanion(
                name: Value(v['name']!),
                contact: _value(v, 'contact', id != null),
                phone: _value(v, 'phone', id != null),
                address: _value(v, 'address', id != null),
                notes: _value(v, 'notes', id != null));
            if (id == null) {
              await db.into(db.suppliers).insert(values);
              created++;
            } else {
              await (db.update(db.suppliers)..where((s) => s.id.equals(id)))
                  .write(values);
              updated++;
            }
          }
        }
        await db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
            userId: Value(live.id),
            action: 'import.${kind.name}',
            details: Value(jsonEncode({
              'file': fileName,
              'created': created,
              'updated': updated,
              'skipped': skipped
            }))));
        return ImportResult(created, updated, skipped);
      });

  static Value<String?> _value(
      Map<String, String> values, String key, bool updating) {
    final value = values[key];
    if (updating && (value == null || value.isEmpty)) {
      return const Value.absent();
    }
    return Value(value?.isEmpty == true ? null : value);
  }
}
