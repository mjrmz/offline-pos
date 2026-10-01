String formatPeso(int cents) {
  final absolute = cents.abs();
  final whole = (absolute ~/ 100)
      .toString()
      .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (match) => ',');
  final fraction = (absolute % 100).toString().padLeft(2, '0');
  return '${cents < 0 ? '-' : ''}₱$whole.$fraction';
}

int? tryParsePeso(String value) {
  final input = value.trim();
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(input)) return null;
  final parts = input.split('.');
  final pesos = int.tryParse(parts[0]);
  final fraction = parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0'));
  if (pesos == null || pesos > (0x7fffffffffffffff - fraction) ~/ 100) {
    return null;
  }
  return pesos * 100 + fraction;
}
