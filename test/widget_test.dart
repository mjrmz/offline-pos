import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/app_config.dart';
import 'package:modern_offline_pos/main.dart';

void main() {
  testWidgets('Phase 1 app starts', (tester) async {
    await tester.pumpWidget(const PosApp());
    expect(find.text(AppConfig.appName), findsOneWidget);
  });
}
