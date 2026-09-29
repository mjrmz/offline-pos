import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/models/printer_settings.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/printer_settings_repository.dart';

void main() {
  test(
      'legacy Phase 4 preferences import once into Settings and survive reopen',
      () async {
    SharedPreferences.setMockInitialValues({
      'printer.enabled': true,
      'printer.host': '192.168.1.10',
      'printer.port': 9100,
      'printer.width': 58,
      'printer.drawer': true,
      'store.name': 'Old Shop',
    });
    final dir = await Directory.systemTemp.createTemp('pos-settings-');
    final file = File('${dir.path}/pos.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final store = PrinterSettingsStore(db);
      final legacy = await store.load();
      expect(legacy.storeName, 'Old Shop');
      expect(legacy.host, '192.168.1.10');
      expect(legacy.widthMm, 58);
      expect(legacy.drawerEnabled, true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('printer.host'), false);
      await store.save(const PrinterSettings(
          enabled: true,
          transport: PrinterConnection.bluetooth,
          deviceId: 'AA:BB',
          deviceName: 'BT',
          storeName: 'New Shop'));
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      final loaded = await PrinterSettingsStore(db).load();
      expect(loaded.transport, PrinterConnection.bluetooth);
      expect(loaded.deviceId, 'AA:BB');
      expect(loaded.storeName, 'New Shop');
      expect((await db.select(db.settings).get()).length, 1);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
