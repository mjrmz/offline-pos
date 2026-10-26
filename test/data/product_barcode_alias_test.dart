import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/global_search_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/product_barcode_alias_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('migration from 52 preserves product and backup accepts 54', () async {
    final dir = await Directory.systemTemp.createTemp('barcode-alias-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    final product = await db.into(db.products).insertReturning(
      ProductsCompanion.insert(name: 'Existing', priceCents: 100,
        barcode: const Value('PRIMARY')));
    await db.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TABLE product_barcode_aliases');
    raw.execute('PRAGMA user_version = 52');
    raw.dispose();
    db = AppDatabase.forTesting(NativeDatabase(file));
    expect((await db.select(db.products).getSingle()).id, product.id);
    expect(await ProductBarcodeAliasRepository(db).forProduct(product.id), isEmpty);
    expect(db.schemaVersion, 55);
    await db.close();
    expect(BackupService.verify(file), 55);
  });

  test('alias resolves same product, can disable, and enforces uniqueness', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap('Owner', 'ownerPassword123',
      'Recovery question?', 'Recovery answer');
    final owner = await auth.login(ownerId, 'ownerPassword123');
    final pos = PosRepository(db);
    final aliases = ProductBarcodeAliasRepository(db);
    final first = await pos.saveProduct(name: 'First', priceCents: 100,
      costCents: 0, barcode: 'PRIMARY');
    final second = await pos.saveProduct(name: 'Second', priceCents: 100,
      costCents: 0, barcode: 'SECOND');
    await aliases.add(owner, first, '  ALT-1  ');
    await db.into(db.users).insert(UsersCompanion.insert(
      id: const Value('cashier'), name: 'Cashier', role: 'cashier'));
    await expectLater(aliases.add(
      const ActiveUser('cashier', 'Cashier', UserRole.cashier), first, 'NOPE'),
      throwsStateError);
    expect((await pos.barcode('PRIMARY'))!.id, first);
    expect((await pos.barcode(' ALT-1 '))!.id, first);
    expect((await GlobalSearchRepository(db).search(owner, 'ALT-1'))
      .any((row) => row.id == first && row.kind == GlobalSearchKind.product), isTrue);
    await expectLater(aliases.add(owner, second, 'ALT-1'), throwsStateError);
    await expectLater(aliases.add(owner, second, 'PRIMARY'), throwsStateError);
    await expectLater(pos.saveProduct(id: second, name: 'Second',
      priceCents: 100, costCents: 0, barcode: 'ALT-1'), throwsStateError);
    final alias = (await aliases.forProduct(first)).single;
    await aliases.update(owner, alias, isActive: false);
    expect(await pos.barcode('ALT-1'), isNull);
    await aliases.update(owner, alias, isActive: true);
    expect((await pos.barcode('ALT-1'))!.id, first);
    await db.customStatement('UPDATE products SET is_active = 0 WHERE id = ?', [first]);
    await expectLater(pos.barcode('ALT-1'), throwsStateError);
    final product = await (db.select(db.products)
      ..where((p) => p.id.equals(first))).getSingle();
    expect(product.barcode, 'PRIMARY');
  });
}
