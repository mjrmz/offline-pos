/// Commercial quantities use thousandths. Money remains integer cents.
class Quantity {
  static const scale = 1000;
  static final _pattern = RegExp(r'^(0|[1-9]\d*)(?:\.(\d{1,3}))?$');

  static int? tryParse(String input, {bool fractional = true}) {
    final match = _pattern.firstMatch(input.trim());
    if (match == null) return null;
    final whole = int.tryParse(match.group(1)!);
    final decimal = match.group(2);
    if (whole == null ||
        (!fractional && decimal != null && int.parse(decimal) != 0)) {
      return null;
    }
    final result = whole * scale +
        (decimal == null ? 0 : int.parse(decimal.padRight(3, '0')));
    return result > 0 ? result : null;
  }

  static String format(int milli, {bool trim = true}) {
    final sign = milli < 0 ? '-' : '';
    final value = milli.abs();
    final whole = value ~/ scale;
    var decimals = (value % scale).toString().padLeft(3, '0');
    if (trim) decimals = decimals.replaceFirst(RegExp(r'0+$'), '');
    return decimals.isEmpty ? '$sign$whole' : '$sign$whole.$decimals';
  }

  /// Half up for nonnegative commercial totals.
  static int lineCents(int priceCents, int quantityMilli) {
    if (priceCents < 0 || quantityMilli < 0) {
      throw ArgumentError('Negative commercial amount');
    }
    return (priceCents * quantityMilli + scale ~/ 2) ~/ scale;
  }
}
