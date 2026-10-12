import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local appearance preference. Business data is never involved.
class ThemeModeController extends ChangeNotifier {
  ThemeModeController({SharedPreferences? preferences})
      : _preferences = preferences;

  static const preferenceKey = 'appearance.themeMode';
  SharedPreferences? _preferences;
  ThemeMode _mode = ThemeMode.system;

  ThemeMode get mode => _mode;

  Future<void> load() async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    _mode = switch (preferences.getString(preferenceKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    final previous = _mode;
    _mode = mode;
    notifyListeners();
    try {
      final preferences =
          _preferences ??= await SharedPreferences.getInstance();
      await preferences.setString(preferenceKey, mode.name);
    } catch (_) {
      _mode = previous;
      notifyListeners();
      rethrow;
    }
  }
}

class AppThemeController extends InheritedNotifier<ThemeModeController> {
  const AppThemeController(
      {super.key,
      required ThemeModeController controller,
      required super.child})
      : super(notifier: controller);

  static ThemeModeController of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppThemeController>()!
      .notifier!;

  static ThemeModeController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppThemeController>()
      ?.notifier;
}
