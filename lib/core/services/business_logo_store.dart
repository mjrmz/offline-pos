import 'dart:io';
import 'dart:ui' as ui;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores only the optional logo location; the business name remains in Settings.
class BusinessLogoStore {
  static const _key = 'business.logo.path';

  Future<File?> load() async {
    final path = (await SharedPreferences.getInstance()).getString(_key);
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    return await file.exists() ? file : null;
  }

  Future<File> save(String sourcePath) async {
    final extension = p.extension(sourcePath).toLowerCase();
    if (!{'.png', '.jpg', '.jpeg'}.contains(extension)) {
      throw ArgumentError('Choose a PNG or JPEG image.');
    }
    final source = File(sourcePath);
    if (await source.length() > 5 * 1024 * 1024) {
      throw ArgumentError('Image must be smaller than 5 MB.');
    }
    final bytes = await source.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    codec.dispose();
    final directory = Directory(p.join(
        (await getApplicationSupportDirectory()).path, 'business_branding'));
    await directory.create(recursive: true);
    final target = File(p.join(directory.path, 'logo$extension'));
    final previous = await load();
    await source.copy(target.path);
    await (await SharedPreferences.getInstance()).setString(_key, target.path);
    if (previous != null && previous.path != target.path) {
      await previous.delete();
    }
    return target;
  }

  Future<void> remove() async {
    final previous = await load();
    await (await SharedPreferences.getInstance()).remove(_key);
    if (previous != null) await previous.delete();
  }
}
