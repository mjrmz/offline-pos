import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_return_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/supplier_payables_repository.dart';
import 'package:modern_offline_pos/features/contacts/supplier_statement_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ActiveUser owner;
  late String supplierId, productId;
  late SupplierPayablesRepository reporting;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    owner = auth.current!;
    supplierId = (await DirectoryRepository(db)
        .saveSupplier(owner, name: 'Supplier A')).id;
    productId = await PosRepository(db).saveProduct(name: 'Widget',
        priceCents: 900, costCents: 500, startingStock: 0);
    reporting = SupplierPayablesRepository(db);
  });
  tearDown(() => db.close());

  Future<StockReceiving> seeded(DateTime at, {bool tracked = true,
      int costCents = 500}) async {
    final next = (await db.customSelect(
        'SELECT COALESCE(MAX(sequence),0)+1 AS next FROM stock_receivings')
        .getSingle()).read<int>('next');
    final receipt = await db.into(db.stockReceivings).insertReturning(
        StockReceivingsCompanion.insert(sequence: Value(next),
            supplierId: supplierId, userId: owner.id,
            receivedAt: Value(at), finalizedAt: Value(at)));
    await db.into(db.stockReceivingItems).insert(
        StockReceivingItemsCompanion.insert(receivingId: receipt.id,
            productId: productId, quantityMilli: 10000,
            unitCostCents: costCents));
    if (tracked) {
      await db.into(db.supplierPayableSources).insert(
          SupplierPayableSourcesCompanion.insert(receivingId: receipt.id));
    }
    return receipt;
  }

  test('five aging buckets sum to collectible balance and exclude legacy', () async {
    final asOf = DateTime(2026, 10, 24);
    for (final days in [0, 10, 40, 70, 100]) {
      await seeded(DateTime(2026, 10, 24 - days));
    }
    await seeded(DateTime(2026, 7, 1), tracked: false);
    final aging = await reporting.aging(supplierId, asOf: asOf);
    expect([aging.currentCents, aging.days1To30Cents,
      aging.days31To60Cents, aging.days61To90Cents,
      aging.daysOver90Cents], [5000, 5000, 5000, 5000, 5000]);
    expect(aging.totalCents, await reporting.outstanding(supplierId));
    expect(await reporting.legacyCount(supplierId), 1);
  });

  test('statement opening, payments, credits and closing use persisted facts', () async {
    final before = await seeded(DateTime(2026, 9, 25));
    final october = await seeded(DateTime(2026, 10, 2));
    await seeded(DateTime(2026, 10, 3), tracked: false);
    await reporting.record(owner, supplierId, 2000, 'gcash',
        DateTime(2026, 10, 4), receivingId: before.id);
    final returns = PurchaseReturnRepository(db);
    // A normal Receiving provides the inventory layer required for a return.
    final sourceReceipt = await StockReceivingRepository(db).receive(owner,
        supplierId, [ReceivingLineRequest(productId, 10000, 500)],
        receivedAt: DateTime(2026, 10, 5));
    final source = (await returns.sources(sourceReceipt.id)).single;
    final draft = await returns.createDraft(owner, sourceReceipt.id, [
      PurchaseReturnLineInput(source.item.id, 2000, PurchaseReturnReason.damaged)
    ]);
    await returns.finalize(owner, draft.id);
    await returns.setResolution(owner, draft.id,
        PurchaseReturnResolution.replacementExpected);
    var statement = await reporting.statementPage(supplierId,
        DateTime(2026, 10), DateTime(2026, 11));
    expect(statement.summary.creditsCents, 0);
    await returns.setResolution(owner, draft.id,
        PurchaseReturnResolution.supplierCredit, creditAmountCents: 1000);
    statement = await reporting.statementPage(supplierId,
        DateTime(2026, 10), DateTime(2026, 11));
    expect(statement.summary.openingCents, 5000);
    expect(statement.summary.chargesCents, 10000);
    expect(statement.summary.paymentsCents, 2000);
    expect(statement.summary.creditsCents, 1000);
    expect(statement.summary.closingCents, 12000);
    expect(statement.summary.legacyCount, 1);
    expect(statement.lines.any((line) => line.reference.startsWith('PRT-')), isTrue);
    expect(statement.lines.last.balanceCents, statement.summary.closingCents);
    expect((await reporting.forReceiving(october))?.remainingCents, 5000);
  });

  test('statement page two retains running balance after 50 rows', () async {
    for (var index = 0; index < 51; index++) {
      await seeded(DateTime(2026, 10, 1).add(Duration(minutes: index)),
          costCents: 100);
    }
    final first = await reporting.statementPage(supplierId,
        DateTime(2026, 10), DateTime(2026, 11));
    final second = await reporting.statementPage(supplierId,
        DateTime(2026, 10), DateTime(2026, 11), page: 1);
    expect(first.summary.count, 51);
    expect(first.lines.length, 50);
    expect(first.lines.last.balanceCents, 50000);
    expect(second.lines.single.balanceCents, 51000);
    expect(second.summary.closingCents, 51000);
  });

  test('full payment closes the statement without altering Receiving', () async {
    final receipt = await seeded(DateTime(2026, 10, 2));
    await reporting.record(owner, supplierId, 5000, 'gcash',
        DateTime(2026, 10, 3));
    final statement = await reporting.statementPage(supplierId,
        DateTime(2026, 10), DateTime(2026, 11));
    expect(statement.summary.chargesCents, 5000);
    expect(statement.summary.paymentsCents, 5000);
    expect(statement.summary.closingCents, 0);
    expect((await reporting.forReceiving(receipt))?.originalCents, 5000);
    expect((await reporting.forReceiving(receipt))?.remainingCents, 0);
  });

  test('PDF uses persisted payable facts and leaves Receiving untouched', () async {
    final receipt = await seeded(DateTime(2026, 10, 2));
    final bytes = await SupplierStatementPdf(db).render(supplierId,
        DateTime(2026, 10), DateTime(2026, 11));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    final after = await (db.select(db.stockReceivings)
          ..where((r) => r.id.equals(receipt.id))).getSingle();
    expect(after, receipt);
    expect((await reporting.statementPage(supplierId,
        DateTime(2026, 10), DateTime(2026, 11))).summary.closingCents, 5000);
  });

  test('excess confirmed credit stays separate from collectible balance', () async {
    final receipt = await StockReceivingRepository(db).receive(owner,
        supplierId, [ReceivingLineRequest(productId, 10000, 500)]);
    final returns = PurchaseReturnRepository(db);
    final source = (await returns.sources(receipt.id)).single;
    final draft = await returns.createDraft(owner, receipt.id, [
      PurchaseReturnLineInput(source.item.id, 1000, PurchaseReturnReason.other)
    ]);
    await returns.finalize(owner, draft.id);
    await returns.setResolution(owner, draft.id,
        PurchaseReturnResolution.supplierCredit, creditAmountCents: 7000);
    final now = DateTime.now();
    final statement = await reporting.statementPage(supplierId,
        DateTime(now.year, now.month), DateTime(now.year, now.month + 1));
    expect(statement.summary.creditsCents, 5000);
    expect(statement.summary.unappliedCreditCents, 2000);
    expect(statement.summary.closingCents, 0);
    expect(statement.lines.last.balanceCents, 0);
  });
}
