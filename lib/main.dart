import 'package:flutter/material.dart';

import 'core/models/app_config.dart';
import 'core/utils/logger.dart';
import 'data/database.dart';
import 'data/daos/pos_repository.dart';
import 'features/pos_checkout/checkout_screen.dart';

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
  @override
  void dispose() {
    database.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      home: CheckoutScreen(repository: PosRepository(database)),
    );
  }
}
