import 'package:flutter/material.dart';

import 'core/models/app_config.dart';
import 'core/utils/logger.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.info('Starting ${AppConfig.appName}');
  runApp(const PosApp());
}

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      home: const Scaffold(
        body: Center(child: Text(AppConfig.appName)),
      ),
    );
  }
}
