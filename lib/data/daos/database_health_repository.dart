import '../database.dart';

class DatabaseHealthRepository {
  final AppDatabase db;
  DatabaseHealthRepository(this.db);

  Future<void> checkStartup() async {
    final schema = await db
        .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ("
            "'products','inventory','sales','sale_items','payments','users',"
            "'audit_logs','settings','cash_sessions','cash_movements')")
        .get();
    if (schema.length != 10) {
      throw StateError('Critical database schema is missing');
    }
    final check = await db.customSelect('PRAGMA quick_check(1)').get();
    if (check.length != 1 || check.single.read<String>('quick_check') != 'ok') {
      throw StateError('Database integrity check failed');
    }
  }
}
