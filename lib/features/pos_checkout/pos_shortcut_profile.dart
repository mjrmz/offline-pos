import 'pos_layout_preference.dart';

/// Controls shortcut presentation; keyboard actions remain in checkout state.
enum PosShortcutProfile {
  visualCatalog,
  scanFirst;

  static PosShortcutProfile forLayout(PosLayoutType layout) => switch (layout) {
        PosLayoutType.scanFirst => scanFirst,
        _ => visualCatalog,
      };

  bool get hasCartNavigation => this == scanFirst;
  bool get hasLookup => this == scanFirst;
  bool get hasMore => this == scanFirst;
  String get scannerLabel => this == scanFirst ? 'Scan' : 'Scanner';
}
