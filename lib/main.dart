import 'package:flutter/material.dart';

import 'core/models/app_config.dart';
import 'core/utils/logger.dart';
import 'data/database.dart';
import 'data/daos/pos_repository.dart';
import 'data/daos/auth_repository.dart';
import 'data/daos/sales_repository.dart';
import 'core/services/auth_service.dart';
import 'features/auth/auth_screen.dart';
import 'features/dashboard/home_screen.dart';

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
  final database = AppDatabase();
  late final auth = AuthService(AuthRepository(database));
  @override
  void dispose() {
    database.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      home: auth.current == null
          ? AuthScreen(auth: auth, onChanged: () => setState(() {}))
          : HomeScreen(
              auth: auth,
              pos: PosRepository(database),
              salesRepository: SalesRepository(database),
              onChanged: () => setState(() {}),
            ),
    );
  }
}
