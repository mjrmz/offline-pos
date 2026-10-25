import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_return_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/supplier_payables_repository.dart';

void main() {
  late AppDatabase db;
  late ActiveUser owner;
  late String supplierId, productId;
  late StockReceivingRepository receiving;
  late SupplierPayablesRepository payable;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    owner = auth.current!;
    supplierId = (await DirectoryRepository(db)
            .saveSupplier(owner, name: 'Supplier A')).id;
    productId = await PosRepository(db).saveProduct(
        name: 'Widget', priceCents: 900, costCents: 500, startingStock: 0);
    receiving = StockReceivingRepository(db);
    payable = SupplierPayablesRepository(db);
  });
  tearDown(() => db.close());

  Future<StockReceiving> receive(int quantityMilli) => receiving.receive(
      owner, supplierId, [ReceivingLineRequest(productId, quantityMilli, 500)]);

  test('new finalized receiving is payable; unknown legacy settlement is excluded', () async {
    final tracked = await receive(10000);
    final legacy = await db.into(db.stockReceivings).insertReturning(
        StockReceivingsCompanion.insert(
            supplierId: supplierId,
            userId: owner.id,
            finalizedAt: Value(DateTime.now())));
    await db.into(db.stockReceivingItems).insert(
        StockReceivingItemsCompanion.insert(
            receivingId: legacy.id, productId: productId,
            quantityMilli: 10000, unitCostCents: 500));
    expect((await payable.payables(supplierId)).single.receivingId, tracked.id);
    expect(await payable.outstanding(supplierId), 5000);
    expect((await payable.ledger(supplierId)).last.reference, 'RCV-000001');
    expect(await payable.legacyCount(supplierId), 1);
  });

  test('partial and multiple allocations, specific payment, cash and overpayment', () async {
    final first = await receive(10000);
    final second = await receive(20000);
    final cash = CashSessionRepository(db);
    final session = await cash.open(owner, 20000);
    final firstPayment = await payable.record(
        owner, supplierId, 7000, 'cash', DateTime.now());
    expect(SupplierPayablesRepository.number(firstPayment), 'SPAY-000001');
    final allocations = await db.select(db.supplierPaymentAllocations).get();
    expect(allocations.map((a) => a.receivingId), [first.id, second.id]);
    expect(allocations.map((a) => a.allocatedCents), [5000, 2000]);
    expect(await cash.expected(session.id), 13000);
    await payable.record(owner, supplierId, 3000, 'gcash', DateTime.now(),
        receivingId: second.id);
    expect(await cash.expected(session.id), 13000);
    expect((await payable.payables(supplierId)).map((p) => p.status),
        ['Paid', 'Partially paid']);
    expect(await payable.outstanding(supplierId), 5000);
    await expectLater(payable.record(owner, supplierId, 5001, 'cash', DateTime.now()),
        throwsStateError);
    expect((await db.select(db.supplierPayments).get()).length, 2);
    expect((await receiving.items(first.id)).single.quantityMilli, 10000);
  });

  test('confirmed supplier credit reduces source payable; replacement does not', () async {
    final receipt = await receive(10000);
    final returns = PurchaseReturnRepository(db);
    final source = (await returns.sources(receipt.id)).single;
    final draft = await returns.createDraft(owner, receipt.id, [
      PurchaseReturnLineInput(source.item.id, 2000, PurchaseReturnReason.damaged)
    ]);
    await returns.finalize(owner, draft.id);
    await returns.setResolution(owner, draft.id,
        PurchaseReturnResolution.replacementExpected);
    expect(await payable.outstanding(supplierId), 5000);
    await returns.setResolution(owner, draft.id,
        PurchaseReturnResolution.supplierCredit, creditAmountCents: 1000);
    expect(await payable.outstanding(supplierId), 4000);
    expect((await db.select(db.purchaseReturns).get()).single.creditAmountCents, 1000);
    await payable.record(owner, supplierId, 4000, 'gcash', DateTime.now());
    expect(await payable.outstanding(supplierId), 0);
  });

  test('failed allocation rolls back payment and cash movement', () async {
    await receive(10000);
    final session = await CashSessionRepository(db).open(owner, 10000);
    await db.customStatement('''CREATE TRIGGER reject_supplier_allocation
      BEFORE INSERT ON supplier_payment_allocations
      BEGIN SELECT RAISE(ABORT, 'allocation rejected'); END''');
    await expectLater(
        payable.record(owner, supplierId, 1000, 'cash', DateTime.now()),
        throwsA(anything));
    expect(await db.select(db.supplierPayments).get(), isEmpty);
    expect(await db.select(db.cashMovements).get(), isEmpty);
    expect(await CashSessionRepository(db).expected(session.id), 10000);
  });

  test('cashier cannot post supplier payment', () async {
    await receive(10000);
    final cashierId = await AuthRepository(db).createUser(
        actorId: owner.id, name: 'Cashier', role: UserRole.cashier,
        hash: 'test-hash');
    final cashier = ActiveUser(cashierId, 'Cashier', UserRole.cashier);
    await expectLater(
        payable.record(cashier, supplierId, 1000, 'gcash', DateTime.now()),
        throwsStateError);
    expect(await db.select(db.supplierPayments).get(), isEmpty);
  });
}
