import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/quantity.dart';

void main() {
  test('thousandth quantity parses and formats without binary fractions', () {
    for (final entry in <String, int>{
      '1': 1000,
      '0.5': 500,
      '0.25': 250,
      '0.125': 125,
      '1.5': 1500,
      '2.75': 2750,
      '1.375': 1375,
    }.entries) {
      expect(Quantity.tryParse(entry.key), entry.value);
      expect(Quantity.tryParse(Quantity.format(entry.value)), entry.value);
    }
    expect(Quantity.tryParse('0'), isNull);
    expect(Quantity.tryParse('0.000'), isNull);
    expect(Quantity.tryParse('0.0001'), isNull);
    expect(Quantity.tryParse('1.5', fractional: false), isNull);
    expect(Quantity.tryParse('2', fractional: false), 2000);
    expect(Quantity.format(9250, trim: false), '9.250');
  });

  test('integer-cent line totals round half up deterministically', () {
    expect(Quantity.lineCents(5000, 500), 2500);
    expect(Quantity.lineCents(12345, 375), 4629);
    expect(Quantity.lineCents(1, 500), 1);
    expect(Quantity.lineCents(1, 499), 0);
  });
}
