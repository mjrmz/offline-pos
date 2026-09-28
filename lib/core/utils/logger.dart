import 'dart:developer' as developer;

class AppLogger {
  AppLogger._();

  static void info(String message) {
    developer.log(message, name: 'app');
  }
}
