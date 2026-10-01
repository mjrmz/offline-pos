import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/shared/utils/money.dart';

void main() {
  test('stored integer cents display as Philippine pesos', () {
    expect(formatPeso(0), '₱0.00');
    expect(formatPeso(500), '₱5.00');
    expect(formatPeso(3020), '₱30.20');
    expect(formatPeso(100000), '₱1,000.00');
    expect(formatPeso(-1500), '-₱15.00');
  });

  test('peso input converts exactly to integer cents', () {
    expect(tryParsePeso('1000'), 100000);
    expect(tryParsePeso('30.20'), 3020);
    expect(tryParsePeso('1.234'), isNull);
  });
}
