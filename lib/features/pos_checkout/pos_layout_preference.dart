import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PosLayoutType { visualCatalog, scanFirst, hybrid, quickKeys, compact }

class PosLayoutPreference extends ChangeNotifier {
  PosLayoutPreference._();
  static final instance = PosLayoutPreference._();
  static const _layoutKey = 'pos.checkoutLayout';
  static const _incrementKey = 'pos.scanFirst.incrementRepeated';
  static const _readyKey = 'pos.scanFirst.keepReady';
  static const _lastKey = 'pos.scanFirst.showLastScanned';
  static const _lookupKey = 'pos.scanFirst.allowLookup';
  static const _focusKey = 'pos.workspace.startFocused';
  static const _legacyShortcutKey = 'pos.workspace.showShortcutBar';
  static const _visualShortcutKey =
      'pos.workspace.visualCatalog.showShortcutBar';
  static const _scanShortcutKey = 'pos.workspace.scanFirst.showShortcutBar';

  PosLayoutType layout = PosLayoutType.visualCatalog;
  bool incrementRepeated = true;
  bool keepReady = true;
  bool showLastScanned = true;
  bool allowLookup = true;
  bool startFocused = false;
  bool showVisualCatalogShortcutBar = false;
  bool showScanFirstShortcutBar = true;
  bool _loaded = false;

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_layoutKey);
    layout = saved == PosLayoutType.scanFirst.name
        ? PosLayoutType.scanFirst
        : PosLayoutType.visualCatalog;
    incrementRepeated = prefs.getBool(_incrementKey) ?? true;
    keepReady = prefs.getBool(_readyKey) ?? true;
    showLastScanned = prefs.getBool(_lastKey) ?? true;
    allowLookup = prefs.getBool(_lookupKey) ?? true;
    startFocused = prefs.getBool(_focusKey) ?? false;
    final legacyShortcut = prefs.getBool(_legacyShortcutKey);
    showVisualCatalogShortcutBar =
        prefs.getBool(_visualShortcutKey) ?? legacyShortcut ?? false;
    showScanFirstShortcutBar =
        prefs.getBool(_scanShortcutKey) ?? legacyShortcut ?? true;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setWorkspaceOption(String key, bool value) async {
    final storageKey = switch (key) {
      'startFocused' => _focusKey,
      'showVisualCatalogShortcutBar' => _visualShortcutKey,
      'showScanFirstShortcutBar' => _scanShortcutKey,
      _ => throw ArgumentError.value(key),
    };
    await (await SharedPreferences.getInstance()).setBool(storageKey, value);
    if (key == 'startFocused') startFocused = value;
    if (key == 'showVisualCatalogShortcutBar') {
      showVisualCatalogShortcutBar = value;
    }
    if (key == 'showScanFirstShortcutBar') showScanFirstShortcutBar = value;
    notifyListeners();
  }

  bool showShortcutBarFor(PosLayoutType layout) => switch (layout) {
        PosLayoutType.scanFirst => showScanFirstShortcutBar,
        _ => showVisualCatalogShortcutBar,
      };

  Future<void> setLayout(PosLayoutType value) async {
    if (value != PosLayoutType.visualCatalog &&
        value != PosLayoutType.scanFirst) {
      throw ArgumentError.value(value, 'value', 'Layout is not available yet');
    }
    await (await SharedPreferences.getInstance())
        .setString(_layoutKey, value.name);
    layout = value;
    notifyListeners();
  }

  Future<void> setScannerOption(String key, bool value) async {
    final storageKey = switch (key) {
      'incrementRepeated' => _incrementKey,
      'keepReady' => _readyKey,
      'showLastScanned' => _lastKey,
      'allowLookup' => _lookupKey,
      _ => throw ArgumentError.value(key),
    };
    await (await SharedPreferences.getInstance()).setBool(storageKey, value);
    switch (key) {
      case 'incrementRepeated':
        incrementRepeated = value;
      case 'keepReady':
        keepReady = value;
      case 'showLastScanned':
        showLastScanned = value;
      case 'allowLookup':
        allowLookup = value;
    }
    notifyListeners();
  }
}
