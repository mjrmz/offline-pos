import 'dart:io';

import 'package:path/path.dart' as p;

/// Only internal smoke builds compiled with RC_ISOLATED_DATA may redirect data.
/// Ordinary release builds ignore this environment variable entirely.
class ReleaseSmokeDataRoot {
  static const enabled = bool.fromEnvironment('RC_ISOLATED_DATA');
  static const environmentName = 'MODERN_POS_RC_DATA_DIR';

  static Directory? get directory {
    if (!enabled) return null;
    return validate(Platform.environment[environmentName]);
  }

  static Directory validate(String? path) {
    if (path == null || path.trim().isEmpty || !p.isAbsolute(path)) {
      throw StateError('$environmentName must be an absolute directory in an internal smoke build.');
    }
    final normalized = p.normalize(path);
    if (p.dirname(normalized) == normalized) {
      throw StateError('$environmentName cannot be a filesystem root.');
    }
    return Directory(normalized);
  }
}
