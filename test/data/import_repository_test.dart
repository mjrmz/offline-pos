import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/import_repository.dart';
import 'package:modern_offline_pos/data/database.dart';

void main() {
  late AppDatabase db;
  late ImportRepository imports;
  late ActiveUser owner;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    imports = ImportRepository(db);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Recovery?', 'Baguio');
    owner = ActiveUser(id, 'Owner', UserRole.owner);
  });
  tearDown(() => db.close());

  Future<ImportPreview> preview(ImportKind kind, String text) async {
    final csv = ImportCsv.parse(text);
    return imports.validate(kind, csv, ImportCsv.autoMap(csv.first, kind));
  }

  test('product dry run creates no stock; commit creates one audit row',
      () async {
    final p = await preview(
        ImportKind.products, 'name,sku,barcode,selling_price\nA,A1,B1,12.50\n');
    expect(p.ready, 1);
    expect(await db.select(db.products).get(), isEmpty);
    final result = await imports.commit(
        owner,
        ImportKind.products,
        p,
        {
          'name': 'name',
          'sku': 'sku',
          'barcode': 'barcode',
          'selling_price': 'selling_price'
        },
        'products.csv');
    expect(result.created, 1);
    expect((await db.select(db.products).get()).single.priceCents, 1250);
    expect(await db.select(db.inventory).get(), isEmpty);
    expect(await db.select(db.inventoryLayers).get(), isEmpty);
    expect(await db.select(db.inventoryMovements).get(), isEmpty);
    expect(
        (await db.select(db.auditLogs).get())
            .where((a) => a.action == 'import.products')
            .length,
        1);
  });

  test('duplicate product can update; unmapped values stay intact', () async {
    var p =
        await preview(ImportKind.products, 'name,sku,selling_price\nA,A1,10\n');
    await imports.commit(
        owner,
        ImportKind.products,
        p,
        {'name': 'name', 'sku': 'sku', 'selling_price': 'selling_price'},
        'a.csv');
    p = await preview(ImportKind.products, 'name,sku,selling_price\nA,A1,12\n');
    expect(p.rows.single.action, ImportAction.skip);
    p.rows.single.action = ImportAction.update;
    await imports.commit(
        owner,
        ImportKind.products,
        p,
        {'name': 'name', 'sku': 'sku', 'selling_price': 'selling_price'},
        'b.csv');
    expect((await db.select(db.products).get()).single.priceCents, 1200);
    final history = await db.select(db.priceHistory).get();
    expect(history, hasLength(1));
    expect(history.single.oldPriceCents, 1000);
    expect(history.single.newPriceCents, 1200);
    expect(history.single.userId, owner.id);
    expect(await db.select(db.inventory).get(), isEmpty);
  });

  test('customer and supplier duplicates update without ledger writes',
      () async {
    for (final kind in [ImportKind.customers, ImportKind.suppliers]) {
      final source = kind == ImportKind.customers
          ? 'name,phone,notes\nAlice,123,First\n'
          : 'name,contact,notes\nVendor,Jane,First\n';
      var p = await preview(kind, source);
      final mapping = ImportCsv.autoMap(ImportCsv.parse(source).first, kind);
      await imports.commit(owner, kind, p, mapping, 'contact.csv');
      p = await preview(kind, source);
      expect(p.rows.single.action, ImportAction.skip);
      p.rows.single.action = ImportAction.update;
      await imports.commit(owner, kind, p, mapping, 'contact.csv');
    }
    expect((await db.select(db.customers).get()).length, 1);
    expect((await db.select(db.suppliers).get()).length, 1);
    expect(await db.select(db.customerCreditEntries).get(), isEmpty);
  });

  test('failure rolls back all rows and does not audit success', () async {
    final p = await preview(ImportKind.products, 'name,sku\nA,A1\nB,B1\n');
    p.rows.last.values['sku'] = 'A1';
    await expectLater(
        imports.commit(owner, ImportKind.products, p,
            {'name': 'name', 'sku': 'sku'}, 'bad.csv'),
        throwsStateError);
    expect(await db.select(db.products).get(), isEmpty);
    expect(
        (await db.select(db.auditLogs).get())
            .where((a) => a.action == 'import.products'),
        isEmpty);
  });

  test('missing category blocks import unless category creation is reviewed',
      () async {
    final csv = ImportCsv.parse('name,category,selling_price\nA,Medicine,12\n');
    final mapping = ImportCsv.autoMap(csv.first, ImportKind.products);
    var p = await imports.validate(ImportKind.products, csv, mapping);
    expect(p.errors, 1);
    p = await imports.validate(ImportKind.products, csv, mapping,
        createCategories: true);
    expect(p.missingCategories, {'Medicine'});
    await imports.commit(
        owner, ImportKind.products, p, mapping, 'categories.csv',
        createCategories: true);
    expect((await db.select(db.categories).get()).single.name, 'Medicine');
  });

  test('SKU and barcode conflicts are identified before commit', () async {
    final first =
        await preview(ImportKind.products, 'name,sku,barcode\nA,A1,B1\n');
    await imports.commit(owner, ImportKind.products, first,
        {'name': 'name', 'sku': 'sku', 'barcode': 'barcode'}, 'first.csv');
    final sku = await preview(ImportKind.products, 'name,sku\nOther,A1\n');
    expect(sku.rows.single.action, ImportAction.skip);
    final barcode =
        await preview(ImportKind.products, 'name,barcode\nOther,B1\n');
    expect(barcode.rows.single.action, ImportAction.skip);
  });
}
