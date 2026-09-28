import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

void main() {
  test('money parsing uses integer cents', () {
    expect(parseMoney('40'), 4000);
    expect(parseMoney('40.05'), 4005);
    expect(() => parseMoney('40.001'), throwsFormatException);
  });
}
