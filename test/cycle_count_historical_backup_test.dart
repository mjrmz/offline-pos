import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/backup/restore_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  final sourcePath = Platform.environment['PHASE_L_HISTORICAL_BACKUP'];
  test('genuine historical backup validates and restores on isolated copy',
      skip: sourcePath == null ? 'No historical backup supplied' : false,
      () async {
    final source = File(sourcePath!);
    final sourceModified = source.lastModifiedSync();
    final sourceBytes = source.lengthSync();
    final metadata = File('${source.path}.json');
    final metadataModified = metadata.lastModifiedSync();
    final metadataBytes = metadata.lengthSync();
    final original = BackupService.inspect(source);
    expect(original.schemaVersion, lessThanOrEqualTo(50));
    final readOnly =
        sqlite.sqlite3.open(source.path, mode: sqlite.OpenMode.readOnly);
    const preservedTables = [
      'products',
      'sales',
      'sale_items',
      'inventory_layers',
      'customers',
      'suppliers',
      'audit_logs',
      'bir_compliance_state',
      'z_readings',
      'stock_counts',
    ];
    final beforeCounts = <String, int>{};
    try {
      expect(readOnly.select('PRAGMA user_version').single.values.single,
          original.schemaVersion);
      expect(readOnly.select('PRAGMA integrity_check').single.values.single,
          'ok');
      expect(readOnly.select('PRAGMA foreign_key_check'), isEmpty);
      final existing = readOnly
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((row) => row['name'] as String)
          .toSet();
      for (final table in preservedTables.where(existing.contains)) {
        beforeCounts[table] = readOnly
            .select('SELECT COUNT(*) AS n FROM $table')
            .single['n'] as int;
      }
    } finally {
      readOnly.dispose();
    }
    final dir = await Directory.systemTemp.createTemp('cycle-historical-');
    final backups = Directory('${dir.path}/backups')..createSync();
    final copied =
        await source.copy('${backups.path}/${source.uri.pathSegments.last}');
    await File('${source.path}.json').copy('${copied.path}.json');
    final record = BackupService.inspect(copied);
    expect(record.schemaVersion, original.schemaVersion);
    final liveFile = File('${dir.path}/live.sqlite');
    AppDatabase live = AppDatabase.forTesting(NativeDatabase(liveFile));
    try {
      await live.select(live.products).get();
      final restorer = RestoreService(liveFile, backups,
          closeDatabase: () => live.close(),
          openDatabase: () async =>
              AppDatabase.forTesting(NativeDatabase(liveFile)));
      live = await restorer.restore(record);
      expect(live.schemaVersion, 55);
      expect(
          (await live.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          55);
      expect(
          (await live.customSelect('PRAGMA integrity_check').getSingle())
              .read<String>('integrity_check'),
          'ok');
      expect(await live.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
      for (final entry in beforeCounts.entries) {
        final after = await live
            .customSelect('SELECT COUNT(*) AS n FROM ${entry.key}')
            .getSingle();
        expect(after.read<int>('n'), entry.value,
            reason: '${entry.key} rows changed during migration');
      }
      expect(await live.select(live.cycleCountSchedules).get(), isEmpty);
      expect(BackupService.verify(copied), original.schemaVersion);
      expect(source.lastModifiedSync(), sourceModified);
      expect(source.lengthSync(), sourceBytes);
      expect(metadata.lastModifiedSync(), metadataModified);
      expect(metadata.lengthSync(), metadataBytes);
    } finally {
      await live.close();
      await dir.delete(recursive: true);
    }
  });
}
