import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/models/cart.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/services/sale_service.dart';
import 'package:modern_offline_pos/core/services/sales_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/hardware/cash_drawer/cash_drawer.dart';
import 'package:modern_offline_pos/core/models/printer_settings.dart';
import 'package:modern_offline_pos/data/daos/printer_settings_repository.dart';
import 'package:modern_offline_pos/hardware/printer/receipt.dart';
import 'package:modern_offline_pos/hardware/printer/receipt_printer.dart';
import 'package:modern_offline_pos/hardware/printer/receipt_service.dart';

class FakePrinter implements ReceiptPrinter {
  bool fail = false;
  final printed = <ReceiptDocument>[];
  @override
  Future<void> print(ReceiptDocument document, PrinterSettings settings) async {
    printed.add(document);
    if (fail) throw const HardwareException('offline');
  }

  @override
  Future<void> test(PrinterSettings settings) async {}
}

class FakeDrawer implements CashDrawer {
  bool fail = false;
  int attempts = 0;
  @override
  Future<void> open(PrinterSettings settings) async {
    attempts++;
    if (fail) throw const HardwareException('offline');
  }
}

void main() {
  test(
      'post-commit hardware failure preserves sale, payment and stock; reprint is read only',
      () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final owner =
          await auth.bootstrap('Owner', 'ownerPassword123', 'Place?', 'Baguio');
      await auth.login(owner, 'ownerPassword123');
      final pos = PosRepository(db);
      final productId = await pos.saveProduct(
          name: 'Original',
          barcode: '123',
          priceCents: 1250,
          costCents: 100,
          startingStock: 4);
      final cart = Cart()..add((await pos.products()).single);
      final printer = FakePrinter()..fail = true;
      final drawer = FakeDrawer()..fail = true;
      final settings = PrinterSettingsStore(db);
      await settings.save(const PrinterSettings(
          enabled: true,
          host: '127.0.0.1',
          drawerEnabled: true,
          widthMm: 58,
          storeName: 'Shop'));
      final hardware = ReceiptService(
          SalesService(SalesRepository(db), auth), settings, printer, drawer);
      final result = await SaleService(pos, auth).checkout(cart, 2000);
      final outcome = await hardware.afterCommittedCashSale(result.saleId);
      expect(outcome.printed, false);
      expect(outcome.drawerOpened, false);
      expect(drawer.attempts, 1);
      expect((await db.select(db.sales).get()).length, 1);
      expect((await db.select(db.payments).get()).length, 1);
      expect((await db.select(db.inventoryMovements).get()).length, 2);
      expect(await pos.stock(productId), 3);
      expect(printer.printed.single.lines.single.unitCents, 1250);
      await pos.saveProduct(
          id: productId,
          name: 'Renamed',
          priceCents: 9999,
          costCents: 100,
          startingStock: 0);
      printer.fail = false;
      expect(await hardware.reprint(result.saleId), true);
      expect(printer.printed.last.lines.single.name, 'Original');
      expect(printer.printed.last.lines.single.unitCents, 1250);
      expect((await db.select(db.sales).get()).length, 1);
      expect((await db.select(db.payments).get()).length, 1);
      expect(await pos.stock(productId), 3);
      expect(drawer.attempts, 1);
      expect(EscPosEncoder().encode(printer.printed.last, 58),
          containsAll('Original'.codeUnits));
      expect(EscPosEncoder().encode(printer.printed.last, 80),
          containsAll('Original'.codeUnits));
    } finally {
      await db.close();
    }
  });
}
