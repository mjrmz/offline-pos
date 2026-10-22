import 'package:flutter/material.dart';
import 'app_layout.dart';

class AppStatusColors extends ThemeExtension<AppStatusColors> {
  const AppStatusColors(
      {required this.success, required this.warning, required this.info});

  final Color success;
  final Color warning;
  final Color info;

  @override
  AppStatusColors copyWith({Color? success, Color? warning, Color? info}) =>
      AppStatusColors(
          success: success ?? this.success,
          warning: warning ?? this.warning,
          info: info ?? this.info);

  @override
  AppStatusColors lerp(ThemeExtension<AppStatusColors>? other, double t) {
    if (other is! AppStatusColors) return this;
    return AppStatusColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
    );
  }

  static AppStatusColors of(BuildContext context) =>
      Theme.of(context).extension<AppStatusColors>() ??
      (Theme.of(context).brightness == Brightness.dark
          ? const AppStatusColors(
              success: Color(0xFF81D9A1),
              warning: Color(0xFFFFC17A),
              info: Color(0xFF99C9FF))
          : const AppStatusColors(
              success: Color(0xFF176B3A),
              warning: Color(0xFF9A4B0A),
              info: Color(0xFF245D9C)));
}

class AppTheme {
  static final ThemeData light = _theme(Brightness.light);
  static final ThemeData dark = _theme(Brightness.dark);

  static ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
            seedColor: const Color(0xFF6450AD), brightness: brightness)
        .copyWith(
      primary: dark ? const Color(0xFFC6B5FF) : const Color(0xFF5946A8),
      onPrimary: dark ? const Color(0xFF251449) : Colors.white,
      surface: dark ? const Color(0xFF17171C) : const Color(0xFFF6F6F8),
      onSurface: dark ? const Color(0xFFF1EFF5) : const Color(0xFF24232B),
      surfaceContainerLow: dark ? const Color(0xFF222229) : Colors.white,
      surfaceContainerHigh:
          dark ? const Color(0xFF303039) : const Color(0xFFECECF1),
      outline: dark ? const Color(0xFF777681) : const Color(0xFF777580),
      outlineVariant: dark ? const Color(0xFF464550) : const Color(0xFFD3D1DA),
      error: dark ? const Color(0xFFFFB4AB) : const Color(0xFFB3261E),
    );
    final border = OutlineInputBorder(
        borderRadius: AppLayout.controlRadius,
        borderSide: BorderSide(color: scheme.outlineVariant));
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      extensions: [
        AppStatusColors(
          success: dark ? const Color(0xFF81D9A1) : const Color(0xFF176B3A),
          warning: dark ? const Color(0xFFFFC17A) : const Color(0xFF9A4B0A),
          info: dark ? const Color(0xFF99C9FF) : const Color(0xFF245D9C),
        )
      ],
      scaffoldBackgroundColor: scheme.surface,
      textTheme: TextTheme(
        headlineSmall: TextStyle(
            fontSize: 26, fontWeight: FontWeight.w600, color: scheme.onSurface),
        titleLarge: TextStyle(
            fontSize: 18, fontWeight: FontWeight.w600, color: scheme.onSurface),
        titleMedium: TextStyle(
            fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface),
        bodyMedium: TextStyle(fontSize: 14, color: scheme.onSurface),
        bodySmall: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      dividerColor: scheme.outlineVariant,
      listTileTheme: ListTileThemeData(
        selectedColor: scheme.primary,
        selectedTileColor: scheme.primaryContainer,
        iconColor: scheme.onSurfaceVariant,
      ),
      cardTheme: CardThemeData(
          elevation: 0,
          color: scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
              borderRadius: AppLayout.panelRadius,
              side: BorderSide(color: scheme.outlineVariant))),
      dialogTheme: const DialogThemeData(
          shape: RoundedRectangleBorder(borderRadius: AppLayout.dialogRadius)),
      inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surfaceContainerLow,
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(
              borderSide: BorderSide(color: scheme.primary, width: 2)),
          errorBorder:
              border.copyWith(borderSide: BorderSide(color: scheme.error)),
          focusedErrorBorder: border.copyWith(
              borderSide: BorderSide(color: scheme.error, width: 2)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 40))),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40))),
      chipTheme: ChipThemeData(
        shape:
            const RoundedRectangleBorder(borderRadius: AppLayout.controlRadius),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        labelStyle: TextStyle(fontSize: 13, color: scheme.onSurface),
      ),
      navigationBarTheme: NavigationBarThemeData(
          height: 70,
          labelTextStyle: WidgetStatePropertyAll(
              TextStyle(fontSize: 11, color: scheme.onSurface))),
      scrollbarTheme: ScrollbarThemeData(
          thumbColor: WidgetStatePropertyAll(scheme.outline)),
    );
  }
}
