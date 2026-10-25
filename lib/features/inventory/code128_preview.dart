import 'package:barcode/barcode.dart' as bc;
import 'package:flutter/material.dart';

class Code128Preview extends StatelessWidget {
  final String value;
  const Code128Preview(this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    final code = value.trim();
    if (code.isEmpty) return const Text('No barcode assigned');
    if (code.length + '{'.allMatches(code).length > 253 ||
        !RegExp(r'^[\x20-\x7E]+$').hasMatch(code)) {
      return Text('Unsupported CODE128 barcode value',
          style: TextStyle(color: Theme.of(context).colorScheme.error));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(color: Colors.white, padding: const EdgeInsets.all(4),
        child: SizedBox(height: 62, width: 250,
          child: CustomPaint(painter: _Code128Painter(code)))),
      Text(code, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

class _Code128Painter extends CustomPainter {
  final String code;
  const _Code128Painter(this.code);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black;
    for (final bar in bc.Barcode.code128().make(code,
        width: size.width, height: size.height, drawText: false)) {
      if (bar is bc.BarcodeBar && bar.black) {
        canvas.drawRect(Rect.fromLTWH(bar.left, bar.top, bar.width, bar.height), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Code128Painter oldDelegate) => oldDelegate.code != code;
}
