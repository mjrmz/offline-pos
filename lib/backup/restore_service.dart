import 'dart:io';
import 'package:path/path.dart' as p;
import '../data/database.dart';
import 'backup_service.dart';

class RestoreService {
  final File liveFile;
  final Directory backupDirectory;
  final Future<void> Function() closeDatabase;
  final Future<AppDatabase> Function() openDatabase;
  final Future<void> Function(AppDatabase)? afterVerify;
  RestoreService(this.liveFile, this.backupDirectory,
      {required this.closeDatabase,
      required this.openDatabase,
      this.afterVerify});

  Future<AppDatabase> restore(BackupRecord record) async {
    // All validation and staging happen while the active database remains open.
    if (!p.isWithin(backupDirectory.absolute.path, record.file.absolute.path)) {
      throw StateError('Backup is outside the configured backup directory');
    }
    BackupService.inspect(record.file);
    final staged = File('${liveFile.path}.restore-pending');
    final saved = File('${liveFile.path}.before-restore');
    final savedWal = File('${liveFile.path}.before-restore-wal');
    final savedShm = File('${liveFile.path}.before-restore-shm');
    try {
      if (staged.existsSync()) await staged.delete();
      await record.file.copy(staged.path);
      BackupService.verify(staged);
    } catch (error) {
      if (staged.existsSync()) await staged.delete();
      throw StateError('Could not stage verified backup: $error');
    }
    await closeDatabase();
    var replaced = false;
    AppDatabase? reopened;
    try {
      if (liveFile.existsSync()) {
        for (final file in [saved, savedWal, savedShm]) {
          if (file.existsSync()) await file.delete();
        }
        await liveFile.rename(saved.path);
      }
      final wal = File('${liveFile.path}-wal');
      final shm = File('${liveFile.path}-shm');
      if (wal.existsSync()) await wal.rename(savedWal.path);
      if (shm.existsSync()) await shm.rename(savedShm.path);
      await staged.rename(liveFile.path);
      replaced = true;
      reopened = await openDatabase();
      final rows = await reopened.customSelect('PRAGMA quick_check(1)').get();
      if (rows.single.read<String>('quick_check') != 'ok') {
        throw StateError('Restored database failed verification');
      }
      await afterVerify?.call(reopened);
      return reopened;
    } catch (error) {
      await reopened?.close();
      if (replaced && liveFile.existsSync()) await liveFile.delete();
      if (saved.existsSync()) await saved.rename(liveFile.path);
      if (savedWal.existsSync()) await savedWal.rename('${liveFile.path}-wal');
      if (savedShm.existsSync()) await savedShm.rename('${liveFile.path}-shm');
      throw StateError('Restore failed; original database preserved: $error');
    } finally {
      if (staged.existsSync()) await staged.delete();
    }
  }
}
