import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/features/recovery/recovery_screen.dart';

void main() {
  testWidgets('unavailable database shows recovery and invalid backup state',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('pos-recovery-ui-');
    try {
      File('${directory.path}/broken.sqlite').writeAsBytesSync([1, 2, 3]);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: RecoveryScreen(
                  backupDirectory: directory,
                  databaseStatus: 'unavailable: corruption detected',
                  onRestore: (_, __, ___) async {}))));
      await tester.pumpAndSettle();
      expect(find.textContaining('corruption detected'), findsOneWidget);
      expect(find.textContaining('1 invalid'), findsOneWidget);
      expect(find.textContaining('Owner name in backup'), findsOneWidget);
      expect(find.text('Create manual backup'), findsNothing);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  testWidgets('unreadable backup directory shows an error without crashing',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('pos-recovery-ui-');
    try {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: RecoveryScreen(
                  backupDirectory: directory,
                  databaseStatus: 'healthy',
                  onRestore: (_, __, ___) async {},
                  listBackupEntries: (_) =>
                      throw FileSystemException('denied')))));
      expect(find.text('Backup directory cannot be read'), findsOneWidget);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}
