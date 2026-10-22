import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/services/business_logo_store.dart';

class _TestPaths extends PathProviderPlatform {
  final String directory;
  _TestPaths(this.directory);
  @override
  Future<String?> getApplicationSupportPath() async => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('logo is copied into app storage and can be removed', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('pos_logo_test_');
    addTearDown(() => directory.delete(recursive: true));
    final originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    addTearDown(() => PathProviderPlatform.instance = originalPaths);
    final source = File('${directory.path}/chosen.png');
    await source.writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL/nwAAAABJRU5ErkJggg=='));
    final store = BusinessLogoStore();
    final saved = await store.save(source.path);
    expect(saved.path, isNot(source.path));
    await source.delete();
    expect((await store.load())?.existsSync(), isTrue);
    await store.remove();
    expect(await store.load(), isNull);
    expect(saved.existsSync(), isFalse);
  });

  test('missing configured logo falls back to null', () async {
    SharedPreferences.setMockInitialValues(
        {'business.logo.path': 'missing.png'});
    expect(await BusinessLogoStore().load(), isNull);
  });

  test('invalid image leaves the saved logo unchanged', () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('pos_logo_invalid_');
    addTearDown(() => directory.delete(recursive: true));
    final originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    addTearDown(() => PathProviderPlatform.instance = originalPaths);
    final source = File('${directory.path}/chosen.png');
    await source.writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL/nwAAAABJRU5ErkJggg=='));
    final store = BusinessLogoStore();
    final saved = await store.save(source.path);
    await source.writeAsString('not an image');
    await expectLater(store.save(source.path), throwsA(anything));
    expect((await store.load())?.path, saved.path);
  });
}
