class LicenseApiConfiguration {
  static bool isUsable(String origin, {required bool release}) {
    if (origin.isEmpty) return false;
    final Uri uri;
    try {
      uri = Uri.parse(origin);
    } catch (_) {
      return false;
    }
    if (!uri.hasAuthority || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
        uri.hasQuery || uri.hasFragment) {
      return false;
    }
    if (release) {
      if (uri.scheme != 'https') return false;
      final host = uri.host.toLowerCase();
      if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
        return false;
      }
    } else if (uri.scheme != 'https' && uri.scheme != 'http') {
      return false;
    }
    return true;
  }
}
