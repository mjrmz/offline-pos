import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/daos/import_repository.dart';

void main() {
  test('CSV handles quoted commas, blanks and line endings', () {
    expect(ImportCsv.parse('name,notes\r\n"A, B",\r\nC,"line\nwrap"\n'), [
      ['name', 'notes'],
      ['A, B', ''],
      ['C', 'line\nwrap'],
    ]);
  });

  test('CSV rejects malformed records', () {
    expect(() => ImportCsv.parse('name,notes\n"bad'), throwsFormatException);
    expect(() => ImportCsv.parse('name,notes\nA'), throwsFormatException);
  });

  test('common headers map and price uses cents', () {
    expect(
        ImportCsv.autoMap(
            ['Product Name', 'Item Code', 'Price'], ImportKind.products),
        {'Product Name': 'name', 'Item Code': 'sku', 'Price': 'selling_price'});
    expect(ImportRepository.cents('12.5'), 1250);
    expect(ImportRepository.cents('12.345'), isNull);
  });
}
