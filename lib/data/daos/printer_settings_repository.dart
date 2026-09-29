import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/models/printer_settings.dart';
import '../database.dart';

class PrinterSettingsStore {
  final AppDatabase db;
  PrinterSettingsStore(this.db);

  Future<PrinterSettings> load() async {
    var row = await (db.select(db.settings)..where((s) => s.id.equals(1)))
        .getSingleOrNull();
    if (row == null) {
      // Phase 4 prerelease builds stored these values in SharedPreferences.
      final p = await SharedPreferences.getInstance();
      final legacy = PrinterSettings(
        enabled: p.getBool('printer.enabled') ?? false,
        host: p.getString('printer.host') ?? '',
        port: p.getInt('printer.port') ?? 9100,
        widthMm: p.getInt('printer.width') ?? 80,
        drawerEnabled: p.getBool('printer.drawer') ?? false,
        storeName: p.getString('store.name') ?? '',
      );
      await db
          .into(db.settings)
          .insert(_companion(legacy), mode: InsertMode.insertOrIgnore);
      row = await (db.select(db.settings)..where((s) => s.id.equals(1)))
          .getSingle();
      for (final key in [
        'printer.enabled',
        'printer.host',
        'printer.port',
        'printer.width',
        'printer.drawer',
        'store.name'
      ]) {
        await p.remove(key);
      }
    }
    return _fromRow(row);
  }

  Future<void> save(PrinterSettings settings) async {
    if (settings.widthMm != 58 && settings.widthMm != 80) {
      throw ArgumentError('Unsupported paper width');
    }
    if (settings.port < 1 || settings.port > 65535) {
      throw ArgumentError('Invalid printer port');
    }
    // Import any legacy row before overwriting it, preserving other settings.
    await load();
    await db
        .into(db.settings)
        .insert(_companion(settings), mode: InsertMode.insertOrReplace);
  }

  SettingsCompanion _companion(PrinterSettings s) => SettingsCompanion.insert(
    id: const Value(1),
        storeName: Value(s.storeName),
        printerEnabled: Value(s.enabled),
        printerTransport: Value(s.transport.name),
        printerHost: Value(s.host),
        printerPort: Value(s.port),
        printerDeviceId: Value(s.deviceId),
        printerDeviceName: Value(s.deviceName),
        printerWidthMm: Value(s.widthMm),
        drawerEnabled: Value(s.drawerEnabled),
      );

  PrinterSettings _fromRow(Setting row) => PrinterSettings(
        enabled: row.printerEnabled,
        transport: PrinterConnection.values
                .where((t) => t.name == row.printerTransport)
                .firstOrNull ??
            PrinterConnection.lan,
        host: row.printerHost,
        port: row.printerPort,
        deviceId: row.printerDeviceId,
        deviceName: row.printerDeviceName,
        widthMm: row.printerWidthMm,
        drawerEnabled: row.drawerEnabled,
        storeName: row.storeName,
      );
}
