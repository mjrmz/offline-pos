import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LicenseStore {
  final File? fileOverride;
  const LicenseStore({this.fileOverride});
  Future<File> get file async =>
      fileOverride ??
      File(p.join((await getApplicationSupportDirectory()).path,
          'signed-license.json'));
  Future<String?> load() async {
    final target = await file;
    if (!await target.exists()) {
      final previous = File('${target.path}.previous');
      if (await previous.exists()) return previous.readAsString();
      return null;
    }
    return target.readAsString();
  }

  Future<void> save(String blob) async {
    final target = await file;
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.tmp');
    final previous = File('${target.path}.previous');
    await temp.writeAsString(blob, flush: true);
    final hadCurrent = await target.exists();
    if (await previous.exists()) await previous.delete();
    if (hadCurrent) await target.rename(previous.path);
    try {
      await temp.rename(target.path);
      if (hadCurrent) await previous.delete();
    } catch (_) {
      if (hadCurrent && await previous.exists()) {
        await previous.rename(target.path);
      }
      rethrow;
    }
  }
}
