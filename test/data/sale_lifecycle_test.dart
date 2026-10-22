import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/daos/sale_lifecycle_repository.dart';

void main() {
  test('commercial returns reduce retained value without changing gross', () {
    const summary = SaleLifecycleSummary(30000, 0, 1, 0, 1);
    expect(summary.netRetained(100000), 70000);
    expect(summary.status('completed', 100000), 'Partially returned');
    expect(summary.activeRmaCount, 1);
  });

  test('exchange and legacy reversals have distinct statuses', () {
    const exchange = SaleLifecycleSummary(100000, 0, 1, 1, 0);
    expect(exchange.netRetained(100000), 0);
    expect(exchange.status('completed', 100000), 'Exchanged');
    expect(exchange.status('voided', 100000), 'Voided');
    expect(exchange.status('refunded', 100000), 'Refunded');
  });

  test('returned value cannot drive retained value below zero', () {
    const summary = SaleLifecycleSummary(120000, 0, 2, 0, 0);
    expect(summary.netRetained(100000), 0);
  });
}
