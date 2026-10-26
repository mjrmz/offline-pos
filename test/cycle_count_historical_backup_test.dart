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
    late final int productCount;
    late final int countCount;
    try {
      productCount = readOnly
          .select('SELECT COUNT(*) AS n FROM products')
          .single['n'] as int;
      countCount = readOnly
          .select('SELECT COUNT(*) AS n FROM stock_counts')
          .single['n'] as int;
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
      expect((await live.select(live.products).get()).length, productCount);
      expect((await live.select(live.stockCounts).get()).length, countCount);
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
