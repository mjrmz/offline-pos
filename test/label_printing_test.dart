import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/models/product.dart';
import 'package:modern_offline_pos/core/models/printer_settings.dart';
import 'package:modern_offline_pos/hardware/printer/label_printing.dart';
import 'package:modern_offline_pos/hardware/printer/receipt_printer.dart';
import 'package:drift/native.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';

class _RecordingTransport implements PrinterTransport {
  List<int>? bytes;
  bool fail = false;
  @override
  Future<void> send(List<int> data, PrinterSettings settings) async {
    if (fail) throw const HardwareException('Printer unavailable');
    bytes = data;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const product = PosProduct('p', 'Medicine', 'ABC123', 1250, true, 'MED-1');
  const missing = PosProduct('m', 'No code', null, 400, true);
  const settings = PrinterSettings(enabled: true, host: '127.0.0.1');

  test('visible label fields and CODE128 bytes', () {
    final renderer = LabelRenderer();
    final item = LabelItem(product, 2, batchNumber: 'B-1',
        expiryDate: DateTime(2026, 10, 29));
    final lines = renderer.lines(item, LabelTemplate.defaults[2]);
    expect(lines, containsAll(['Medicine', 'Batch: B-1',
      'Exp: 2026-10-29', 'ABC123', 'SKU: MED-1']));
    final bytes = renderer.encode(LabelJob([item], LabelTemplate.defaults[2]), settings);
    expect(bytes.where((b) => b == 123).length, 2);
  });

  test('missing barcode and hidden fields stay absent', () {
    final renderer = LabelRenderer();
    final lines = renderer.lines(const LabelItem(missing, 1),
        const LabelTemplate('Plain', price: false, barcode: false,
            barcodeText: false, sku: false));
    expect(lines, ['No code']);
    expect(() => renderer.encode(const LabelJob(
      [LabelItem(missing, 1)], LabelTemplate('Plain')), settings), returnsNormally);
  });

  test('received quantities are integer and weight defaults to one', () {
    expect(suggestedReceivingLabels(100000, weight: false), 100);
    expect(suggestedReceivingLabels(10500, weight: true), 1);
    expect(suggestedReceivingLabels(10500, weight: false), 1);
  });

  test('multi-item total and serialized count guard', () {
    expect(const LabelJob([LabelItem(product, 10), LabelItem(missing, 5)],
        LabelTemplate('Plain')).total, 15);
    expect(() => const LabelJob([LabelItem(product, 2, serialNumber: 'S1')],
        LabelTemplate('Plain')).validate(), throwsArgumentError);
  });

  test('failed send can retry without touching product data', () async {
    final transport = _RecordingTransport()..fail = true;
    final service = LabelPrintService(transport);
    const job = LabelJob([LabelItem(product, 1)], LabelTemplate('Plain'));
    await expectLater(service.print(job, settings), throwsA(isA<HardwareException>()));
    transport.fail = false;
    await service.print(job, settings);
    expect(transport.bytes, isNotEmpty);
    expect(product.priceCents, 1250);
  });

  test('templates load, edit, duplicate, and retain a default', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LabelTemplateStore();
    expect((await store.load()).first.name, 'Product Barcode');
    await store.save([const LabelTemplate('Edited', price: false),
      const LabelTemplate('Duplicate')]);
    final loaded = await store.load();
    expect(loaded.map((template) => template.name), ['Edited', 'Duplicate']);
    expect(loaded.first.price, false);
    await expectLater(store.save([]), throwsArgumentError);
    expect((await store.load()).length, 2);
  });

  test('default label paper width persists', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = LabelPrintingPreferences();
    expect(await preferences.loadWidth(), 80);
    await preferences.saveWidth(58);
    expect(await preferences.loadWidth(), 58);
    await expectLater(preferences.saveWidth(40), throwsArgumentError);
  });

  test('invalid CODE128 value fails before transport', () async {
    final transport = _RecordingTransport();
    const invalid = PosProduct('bad', 'Invalid', 'bad\ncode', 100, true);
    await expectLater(LabelPrintService(transport).print(
      const LabelJob([LabelItem(invalid, 1)], LabelTemplate('Barcode')),
      settings), throwsArgumentError);
    expect(transport.bytes, isNull);
  });

  test('literal braces are escaped for ESC/POS CODE128', () {
    expect(code128Payload('A{B'), [123, 66, 65, 123, 123, 66]);
  });

  test('catalog label picker searches name, SKU and barcode in SQL', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement("INSERT INTO products (id, name, sku, barcode, price_cents, is_active, created_at) VALUES ('a', 'Medicine', 'MED-1', 'ABC123', 1250, 1, 1)");
    await db.customStatement("INSERT INTO products (id, name, sku, barcode, price_cents, is_active, created_at) VALUES ('b', 'Water', 'WAT-1', 'XYZ789', 300, 1, 1)");
    final repo = PosRepository(db);
    expect((await repo.searchProductsForLabels('med')).single.id, 'a');
    expect((await repo.searchProductsForLabels('wat-1')).single.id, 'b');
    expect((await repo.searchProductsForLabels('abc123')).single.id, 'a');
    expect(await repo.searchProductsForLabels(''), isEmpty);
  });

  test('one audit row follows successful print, none follows failure', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final transport = _RecordingTransport()..fail = true;
    final service = LabelPrintService(transport, null, (job, printer) =>
      AuthRepository(db).audit(null, 'product_labels.printed',
        'labels=${job.total}; transport=${printer.transport.name}'));
    const job = LabelJob([LabelItem(product, 2)], LabelTemplate('Barcode'));
    await expectLater(service.print(job, settings), throwsA(isA<HardwareException>()));
    expect(await db.select(db.auditLogs).get(), isEmpty);
    transport.fail = false;
    await service.print(job, settings);
    final logs = await db.select(db.auditLogs).get();
    expect(logs, hasLength(1));
    expect(logs.single.action, 'product_labels.printed');
  });
}
