import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/shared/theme/app_theme.dart';
import 'package:modern_offline_pos/shared/theme/theme_mode_controller.dart';
import 'package:modern_offline_pos/features/settings/business_settings_home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('theme modes persist and invalid values fall back to System', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = ThemeModeController();
    await controller.load();
    expect(controller.mode, ThemeMode.system);
    for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.system]) {
      await controller.setMode(mode);
      final reopened = ThemeModeController();
      await reopened.load();
      expect(reopened.mode, mode);
      reopened.dispose();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(ThemeModeController.preferenceKey, 'unexpected');
    final fallback = ThemeModeController();
    await fallback.load();
    expect(fallback.mode, ThemeMode.system);
    fallback.dispose();
    controller.dispose();
  });

  testWidgets('light, dark and system update without replacing the child',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = ThemeModeController();
    await controller.load();
    final childKey = GlobalKey();
    await tester.pumpWidget(AnimatedBuilder(
      animation: controller,
      builder: (context, _) => AppThemeController(
        controller: controller,
        child: MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: controller.mode,
          home: Scaffold(body: TextField(key: childKey)),
        ),
      ),
    ));
    final original = childKey.currentState;
    expect(Theme.of(childKey.currentContext!).brightness, Brightness.light);
    await controller.setMode(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(Theme.of(childKey.currentContext!).brightness, Brightness.dark);
    expect(childKey.currentState, same(original));
    await controller.setMode(ThemeMode.light);
    await tester.pumpAndSettle();
    expect(Theme.of(childKey.currentContext!).brightness, Brightness.light);
    await controller.setMode(ThemeMode.system);
    await tester.pumpAndSettle();
    expect(controller.mode, ThemeMode.system);
    controller.dispose();
  });

  testWidgets('Settings selector shows and saves every theme mode',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = ThemeModeController();
    await controller.load();
    await tester.pumpWidget(AppThemeController(
      controller: controller,
      child: const MaterialApp(home: Scaffold(body: ThemeSettingTile())),
    ));
    expect(find.byKey(const Key('theme-selector')), findsOneWidget);
    expect(find.text('Use the default navy sidebar with a light workspace.'),
        findsOneWidget);
    for (final label in ['Light', 'Dark', 'System']) {
      await tester.tap(find.byKey(const Key('theme-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(controller.mode.name, label.toLowerCase());
      expect(
          find.text(switch (label) {
            'Light' => 'Use the light workspace appearance.',
            'Dark' => 'Use the dark workspace appearance.',
            _ => 'Use the default navy sidebar with a light workspace.',
          }),
          findsOneWidget);
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeModeController.preferenceKey), 'system');
    controller.dispose();
  });

  test('sidebar colors persist and System keeps a light workspace', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = ThemeModeController();
    await controller.load();
    expect(controller.workspaceMode, ThemeMode.light);
    expect(controller.effectiveSidebarColor, SidebarColorPreset.navy);
    await controller.setSidebarColor(SidebarColorPreset.light);
    final reopened = ThemeModeController();
    await reopened.load();
    expect(reopened.effectiveSidebarColor, SidebarColorPreset.light);
    expect(reopened.effectiveSidebarColor.foreground.computeLuminance(),
        lessThan(.5));
    expect(
        SidebarColorPreset.navy.foreground.computeLuminance(), greaterThan(.5));
    await reopened.setMode(ThemeMode.dark);
    expect(reopened.workspaceMode, ThemeMode.dark);
    await reopened.setSidebarColor(null);
    expect(reopened.effectiveSidebarColor, SidebarColorPreset.dark);
    await reopened.resetAppearance();
    expect(reopened.mode, ThemeMode.system);
    expect(reopened.workspaceMode, ThemeMode.light);
    expect(reopened.effectiveSidebarColor, SidebarColorPreset.navy);
    reopened.dispose();
    controller.dispose();
  });

  test('both palettes keep visible surfaces, borders and status colors', () {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      final scheme = theme.colorScheme;
      final status = theme.extension<AppStatusColors>()!;
      expect(scheme.surface, isNot(scheme.surfaceContainerLow));
      expect(scheme.outlineVariant, isNot(scheme.surface));
      expect(status.success, isNot(status.warning));
      expect(status.warning, isNot(status.info));
      expect(theme.inputDecorationTheme.focusedBorder, isNotNull);
      expect(theme.inputDecorationTheme.errorBorder, isNotNull);
    }
  });
}
