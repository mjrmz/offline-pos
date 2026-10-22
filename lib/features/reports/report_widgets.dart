import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../shared/utils/money.dart';

class ReportColors {
  static Color gross(ColorScheme s) => s.primary;
  static Color net(ColorScheme s) => s.brightness == Brightness.dark
      ? const Color(0xFF75B6FF)
      : const Color(0xFF246FC0);
  static const refunds = Color(0xFFD05A60);
  static const expenses = Color(0xFFD39739);
  static const profit = Color(0xFF39946A);
  static Color inventory(ColorScheme s) => net(s);
}

class ReportMetricTile extends StatelessWidget {
  const ReportMetricTile(
      {super.key, required this.label, required this.value, this.detail});
  final String label;
  final String value;
  final String? detail;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 104,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall),
        const Spacer(),
        FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                maxLines: 1,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700))),
        if (detail != null)
          Text(detail!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall),
      ]),
    );
  }
}

class ReportMetricGrid extends StatelessWidget {
  const ReportMetricGrid(
      {super.key, required this.values, this.overview = false});
  final List<(String, String)> values;
  final bool overview;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, limits) {
        final columns = overview
            ? (limits.maxWidth >= 1750
                ? 6
                : limits.maxWidth >= 620
                    ? 3
                    : 2)
            : limits.maxWidth >= 1400
                ? 6
                : limits.maxWidth >= 960
                    ? 4
                    : limits.maxWidth >= 620
                        ? 3
                        : 2;
        const gap = 12.0;
        final width = (limits.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(spacing: gap, runSpacing: gap, children: [
          for (final item in values)
            SizedBox(
                width: width,
                child: ReportMetricTile(label: item.$1, value: item.$2)),
        ]);
      });
}

class ReportChartCard extends StatelessWidget {
  const ReportChartCard(
      {super.key, required this.title, required this.child, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          if (subtitle != null)
            Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(subtitle!, style: theme.textTheme.bodySmall)),
          const SizedBox(height: 14),
          child,
        ]));
  }
}

class ReportInfoBanner extends StatelessWidget {
  const ReportInfoBanner(
      {super.key, required this.title, required this.message});
  final String title, message;
  @override
  Widget build(BuildContext context) => Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const Icon(Icons.info_outline),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(message),
                ])),
          ])));
}

class ReportEmptyState extends StatelessWidget {
  const ReportEmptyState(this.message, {super.key});
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 30),
      child: Center(
          child: Text(message, style: Theme.of(context).textTheme.bodyMedium)));
}

class ReportLegend extends StatelessWidget {
  const ReportLegend({super.key, required this.items});
  final List<(String, Color)> items;
  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 16, runSpacing: 6, children: [
        for (final item in items)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: item.$2, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 6),
            Text(item.$1, style: Theme.of(context).textTheme.bodySmall),
          ]),
      ]);
}

String compactPeso(int cents) {
  final value = cents / 100;
  if (value.abs() >= 1000000) {
    return '₱${(value / 1000000).toStringAsFixed(1)}m';
  }
  if (value.abs() >= 1000) {
    return '₱${(value / 1000).toStringAsFixed(value.abs() >= 10000 ? 0 : 1)}k';
  }
  return '₱${value.toStringAsFixed(0)}';
}

class ReportSeries {
  const ReportSeries(this.label, this.color, this.values);
  final String label;
  final Color color;
  final Map<DateTime, int> values;
}

class ReportTrendChart extends StatelessWidget {
  const ReportTrendChart(
      {super.key, required this.series, required this.emptyMessage});
  final List<ReportSeries> series;
  final String emptyMessage;
  @override
  Widget build(BuildContext context) {
    final dates = series.expand((s) => s.values.keys).toSet().toList()..sort();
    if (dates.isEmpty) return ReportEmptyState(emptyMessage);
    final maxValue = math.max(
        1, series.expand((s) => s.values.values).fold<int>(0, math.max));
    return Column(children: [
      SizedBox(
          height: 190,
          width: double.infinity,
          child: LayoutBuilder(
              builder: (context, constraints) => Stack(children: [
                    Positioned.fill(
                        child: CustomPaint(
                            painter: _TrendPainter(series, dates, maxValue,
                                Theme.of(context).colorScheme.outlineVariant))),
                    Positioned(
                        left: 0,
                        top: 0,
                        child: Text(compactPeso(maxValue),
                            style: Theme.of(context).textTheme.labelSmall)),
                    Positioned(
                        left: 0,
                        bottom: 0,
                        child: Text('₱0',
                            style: Theme.of(context).textTheme.labelSmall)),
                  ]))),
      const SizedBox(height: 5),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(MaterialLocalizations.of(context).formatMediumDate(dates.first),
            style: Theme.of(context).textTheme.labelSmall),
        Text(MaterialLocalizations.of(context).formatMediumDate(dates.last),
            style: Theme.of(context).textTheme.labelSmall),
      ]),
      const SizedBox(height: 12),
      ReportLegend(items: [for (final s in series) (s.label, s.color)]),
    ]);
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter(this.series, this.dates, this.maxValue, this.grid);
  final List<ReportSeries> series;
  final List<DateTime> dates;
  final int maxValue;
  final Color grid;
  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(50, 12, size.width - 8, size.height - 12);
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.7;
    for (var i = 0; i <= 4; i++) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
    }
    for (final s in series) {
      final path = Path();
      for (var i = 0; i < dates.length; i++) {
        final x = plot.left +
            (dates.length == 1
                ? plot.width / 2
                : plot.width * i / (dates.length - 1));
        final y = plot.bottom -
            (s.values[dates[i]] ?? 0).clamp(0, maxValue) /
                maxValue *
                plot.height;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        if (dates.length == 1) {
          canvas.drawCircle(Offset(x, y), 3, Paint()..color = s.color);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = s.color
            ..strokeWidth = 2.4
            ..style = PaintingStyle.stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.series != series || old.dates != dates;
}

class ReportBars extends StatelessWidget {
  const ReportBars(
      {super.key,
      required this.values,
      this.color,
      this.limit = 8,
      this.emptyMessage = 'No data in this period.'});
  final Map<String, int> values;
  final Color? color;
  final int limit;
  final String emptyMessage;
  @override
  Widget build(BuildContext context) {
    final entries = values.entries.where((e) => e.value != 0).toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    if (entries.isEmpty) return ReportEmptyState(emptyMessage);
    final top = entries.take(limit).toList();
    final maxValue = top.fold<int>(1, (v, e) => math.max(v, e.value.abs()));
    final barColor = color ?? Theme.of(context).colorScheme.primary;
    return Column(children: [
      for (final e in top)
        Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(children: [
              Row(children: [
                Expanded(
                    child: Text(e.key,
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 10),
                Text(formatPeso(e.value),
                    style: const TextStyle(fontWeight: FontWeight.w600))
              ]),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                  value: e.value.abs() / maxValue,
                  minHeight: 7,
                  borderRadius: BorderRadius.circular(5),
                  color: e.value < 0 ? ReportColors.refunds : barColor),
            ]))
    ]);
  }
}

class ReportDonut extends StatelessWidget {
  const ReportDonut(
      {super.key, required this.values, required this.emptyMessage});
  final Map<String, int> values;
  final String emptyMessage;
  @override
  Widget build(BuildContext context) {
    final entries = values.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<int>(0, (v, e) => v + e.value);
    if (total <= 0 || values.values.any((v) => v < 0)) {
      return ReportEmptyState(emptyMessage);
    }
    final scheme = Theme.of(context).colorScheme;
    final colors = [
      scheme.primary,
      ReportColors.net(scheme),
      ReportColors.expenses,
      ReportColors.profit,
      ReportColors.refunds,
      scheme.tertiary
    ];
    return LayoutBuilder(
        builder: (context, limits) => limits.maxWidth < 360
            ? Column(children: [
                SizedBox(
                    width: 120,
                    height: 120,
                    child: CustomPaint(
                        painter:
                            _DonutPainter(entries, colors, scheme.surface))),
                const SizedBox(height: 10),
                _donutLegend(context, entries, colors, total)
              ])
            : Row(children: [
                SizedBox(
                    width: 130,
                    height: 130,
                    child: CustomPaint(
                        painter:
                            _DonutPainter(entries, colors, scheme.surface))),
                const SizedBox(width: 18),
                Expanded(child: _donutLegend(context, entries, colors, total))
              ]));
  }

  Widget _donutLegend(BuildContext context, List<MapEntry<String, int>> entries,
          List<Color> colors, int total) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < entries.length; i++)
          Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(children: [
                Container(
                    width: 9, height: 9, color: colors[i % colors.length]),
                const SizedBox(width: 6),
                Expanded(
                    child:
                        Text(entries[i].key, overflow: TextOverflow.ellipsis)),
                Text(
                    '${(entries[i].value * 100 / total).toStringAsFixed(0)}%  ${formatPeso(entries[i].value)}',
                    style: Theme.of(context).textTheme.bodySmall),
              ]))
      ]);
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter(this.entries, this.colors, this.background);
  final List<MapEntry<String, int>> entries;
  final List<Color> colors;
  final Color background;
  @override
  void paint(Canvas canvas, Size size) {
    final total = entries.fold<int>(0, (v, e) => v + e.value);
    final radius = math.min(size.width, size.height) / 2 - 4;
    final rect =
        Rect.fromCircle(center: size.center(Offset.zero), radius: radius);
    var start = -math.pi / 2;
    for (var i = 0; i < entries.length; i++) {
      final sweep = entries[i].value / total * math.pi * 2;
      canvas.drawArc(
          rect,
          start,
          sweep,
          false,
          Paint()
            ..color = colors[i % colors.length]
            ..style = PaintingStyle.stroke
            ..strokeWidth = 22);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) => old.entries != entries;
}
