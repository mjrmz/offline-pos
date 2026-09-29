import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'core/models/app_config.dart';
import 'core/models/active_user.dart';
import 'core/models/startup_health.dart';
import 'core/utils/logger.dart';
import 'data/database.dart';
import 'data/daos/pos_repository.dart';
import 'data/daos/auth_repository.dart';
import 'data/daos/sales_repository.dart';
import 'data/daos/database_health_repository.dart';
import 'core/services/auth_service.dart';
import 'features/auth/auth_screen.dart';
import 'features/dashboard/home_screen.dart';
import 'features/recovery/recovery_screen.dart';
import 'backup/backup_service.dart';
import 'backup/restore_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.info('Starting ${AppConfig.appName}');
  runApp(const PosApp());
}

class PosApp extends StatefulWidget {
  const PosApp({super.key});
  @override
  State<PosApp> createState() => _PosAppState();
}

class _PosAppState extends State<PosApp> {
  AppDatabase? database;
  AuthService? auth;
  File? databaseFile;
  StartupHealth? health;
  Timer? backupTimer;
  Future<void> backupTask = Future.value();
  bool restoring = false;
  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    AppDatabase? opening;
    try {
      databaseFile = await AppDatabase.databaseFile();
      final opened = AppDatabase();
      opening = opened;
      await DatabaseHealthRepository(opened).checkStartup();
      database = opened;
      opening = null;
      auth = AuthService(AuthRepository(opened));
      health = const StartupHealth.ready();
      unawaited(runAutomaticBackup());
      backupTimer = Timer.periodic(
          const Duration(hours: 1), (_) => unawaited(runAutomaticBackup()));
    } catch (error) {
      health = StartupHealth.unavailable('unavailable: $error');
      await opening?.close();
      await database?.close();
      database = null;
      auth = null;
    }
    if (mounted) setState(() {});
  }

  Future<void> runAutomaticBackup() async {
    if (restoring) return;
    final db = database;
    final file = databaseFile;
    if (db == null || file == null) return;
    final job = backupTask.then((_) async {
      if (!restoring) {
        await BackupService(db, Directory(p.join(file.parent.path, 'backups')))
            .createDue();
      }
    });
    backupTask = job.catchError((Object error) {
      AppLogger.info('Automatic backup failed: $error');
    });
    await backupTask;
  }

  Future<void> createManualBackup() async {
    if (restoring) throw StateError('Restore in progress');
    final user = auth!.requireSession(PosPermission.manageRecovery);
    final db = database!;
    (await AuthRepository(db).requireActive(user.id))
        .require(PosPermission.manageRecovery);
    final job = backupTask.then((_) async {
      if (restoring) throw StateError('Restore in progress');
      final record = await BackupService(
              db, Directory(p.join(databaseFile!.parent.path, 'backups')))
          .create(BackupKind.manual, rotateAfter: false);
      try {
        await AuthRepository(db)
            .audit(user.id, 'backup.create', record.file.uri.pathSegments.last);
      } catch (error) {
        await record.file.delete();
        await File('${record.file.path}.json').delete();
        throw StateError('Backup audit failed: $error');
      }
      await BackupService(
              db, Directory(p.join(databaseFile!.parent.path, 'backups')))
          .rotate();
    });
    backupTask = job.catchError((Object _) {});
    await job;
  }

  Future<void> restoreBackup(BackupRecord record, String? recoveryName,
      String? recoveryPassword) async {
    if (restoring) throw StateError('Restore already in progress');
    final activeAuth = auth;
    if (activeAuth?.current != null) {
      final actor = activeAuth!.requireSession(PosPermission.manageRecovery);
      (await AuthRepository(database!).requireActive(actor.id))
          .require(PosPermission.manageRecovery);
    } else if (!BackupService.ownerCredentialsMatch(
        record.file, recoveryName ?? '', recoveryPassword ?? '')) {
      throw StateError('Owner credentials from this backup are required');
    }
    restoring = true;
    await backupTask;
    final file = databaseFile!;
    final restorer = RestoreService(
        file, Directory(p.join(file.parent.path, 'backups')),
        closeDatabase: () async {
          await database?.close();
          database = null;
          auth = null;
        },
        openDatabase: () async => AppDatabase(),
        afterVerify: (opened) => AuthRepository(opened)
            .audit(null, 'backup.restore', record.file.uri.pathSegments.last));
    try {
      final opened = await restorer.restore(record);
      database = opened;
      auth = AuthService(AuthRepository(opened));
      health = const StartupHealth.ready();
    } catch (error) {
      // A failed replacement is rolled back on disk. Reopen the preserved DB if possible.
      if (database == null) {
        try {
          final opened = AppDatabase();
          await DatabaseHealthRepository(opened).checkStartup();
          database = opened;
          auth = AuthService(AuthRepository(opened));
          health = const StartupHealth.ready();
        } catch (_) {
          health = StartupHealth.unavailable('unavailable: $error');
        }
      }
      rethrow;
    } finally {
      restoring = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> deleteBackup(File file) async {
    final user = auth!.requireSession(PosPermission.manageRecovery);
    (await AuthRepository(database!).requireActive(user.id))
        .require(PosPermission.manageRecovery);
    final backupDirectory =
        Directory(p.join(databaseFile!.parent.path, 'backups'));
    if (!p.isWithin(backupDirectory.absolute.path, file.absolute.path) ||
        !file.path.endsWith('.sqlite')) {
      throw StateError('Backup path is invalid');
    }
    if (file.existsSync()) await file.delete();
    final metadata = File('${file.path}.json');
    if (metadata.existsSync()) await metadata.delete();
    await AuthRepository(database!)
        .audit(user.id, 'backup.delete', file.uri.pathSegments.last);
  }

  @override
  void dispose() {
    backupTimer?.cancel();
    database?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final db = database;
    final currentAuth = auth;
    return MaterialApp(
      title: AppConfig.appName,
      home: health == null
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : !health!.canUseRegister || db == null || currentAuth == null
              ? RecoveryScreen(
                  backupDirectory: Directory(p.join(
                      databaseFile?.parent.path ?? Directory.systemTemp.path,
                      'backups')),
                  databaseStatus: health!.databaseStatus,
                  onRestore: restoreBackup,
                  onRecheck: () async {
                    await initialize();
                  })
              : currentAuth.current == null
                  ? AuthScreen(
                      auth: currentAuth, onChanged: () => setState(() {}))
                  : HomeScreen(
                      auth: currentAuth,
                      pos: PosRepository(db),
                      salesRepository: SalesRepository(db),
                      recoveryScreen: RecoveryScreen(
                          backupDirectory: Directory(
                              p.join(databaseFile!.parent.path, 'backups')),
                          databaseStatus: health!.databaseStatus,
                          auth: currentAuth,
                          onRestore: restoreBackup,
                          onCreate: createManualBackup,
                          onDelete: deleteBackup),
                      onChanged: () => setState(() {}),
                    ),
    );
  }
}
