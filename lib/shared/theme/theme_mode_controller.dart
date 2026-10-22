import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/services/business_logo_store.dart';

enum SidebarColorPreset { navy, dark, purple, blue, slate, light }

extension SidebarColorStyle on SidebarColorPreset {
  Color get color => switch (this) {
        SidebarColorPreset.navy => const Color(0xFF142443),
        SidebarColorPreset.dark => const Color(0xFF222229),
        SidebarColorPreset.purple => const Color(0xFF443566),
        SidebarColorPreset.blue => const Color(0xFF214C78),
        SidebarColorPreset.slate => const Color(0xFF3B4858),
        SidebarColorPreset.light => const Color(0xFFF1F0F5),
      };

  Color get foreground =>
      color.computeLuminance() < 0.35 ? Colors.white : const Color(0xFF24232B);
}

/// Device-local appearance preference. Business data is never involved.
class ThemeModeController extends ChangeNotifier {
  ThemeModeController({SharedPreferences? preferences})
      : _preferences = preferences;

  static const preferenceKey = 'appearance.themeMode';
  static const sidebarColorKey = 'appearance.sidebarColor';
  SharedPreferences? _preferences;
  ThemeMode _mode = ThemeMode.system;
  SidebarColorPreset? _sidebarColor;
  String? _logoPath;

  ThemeMode get mode => _mode;
  ThemeMode get workspaceMode =>
      _mode == ThemeMode.system ? ThemeMode.light : _mode;
  SidebarColorPreset? get sidebarColor => _sidebarColor;
  SidebarColorPreset get effectiveSidebarColor =>
      _sidebarColor ??
      (_mode == ThemeMode.dark
          ? SidebarColorPreset.dark
          : SidebarColorPreset.navy);
  String? get logoPath => _logoPath;

  Future<void> load() async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    _mode = switch (preferences.getString(preferenceKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final colorName = preferences.getString(sidebarColorKey);
    _sidebarColor = SidebarColorPreset.values
        .where((color) => color.name == colorName)
        .firstOrNull;
    _logoPath = (await BusinessLogoStore().load())?.path;
    notifyListeners();
  }

  Future<void> setSidebarColor(SidebarColorPreset? color) async {
    _sidebarColor = color;
    notifyListeners();
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    if (color == null) {
      await preferences.remove(sidebarColorKey);
    } else {
      await preferences.setString(sidebarColorKey, color.name);
    }
  }

  void setLogoPath(String? path) {
    _logoPath = path;
    notifyListeners();
  }

  Future<void> resetAppearance() async {
    await BusinessLogoStore().remove();
    setLogoPath(null);
    await setSidebarColor(null);
    await setMode(ThemeMode.system);
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
