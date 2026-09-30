// ignore_for_file: curly_braces_in_flow_control_structures
import 'dart:io';
import 'dart:convert';
import 'package:android_id/android_id.dart';
import 'package:cryptography/cryptography.dart';

class DeviceId {
  static Future<String> current() async {
    String raw;
    if (Platform.isAndroid) {
      raw = (await const AndroidId().getId()) ?? '';
    } else if (Platform.isWindows) {
      final result = await Process.run('reg', [
        'query',
        r'HKLM\SOFTWARE\Microsoft\Cryptography',
        '/v',
        'MachineGuid'
      ]);
      if (result.exitCode != 0)
        throw StateError('Windows device ID unavailable');
      final match =
          RegExp(r'MachineGuid\s+REG_SZ\s+(\S+)', caseSensitive: false)
              .firstMatch(result.stdout.toString());
      raw = match?.group(1) ?? '';
    } else {
      throw UnsupportedError('Licensing supports Android and Windows only');
    }
    if (raw.isEmpty) throw StateError('Device ID unavailable');
    final digest = await Sha256().hash(utf8.encode(
        'modern-offline-pos:v1:${Platform.operatingSystem}:${raw.toLowerCase()}'));
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
