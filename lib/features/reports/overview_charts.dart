import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../data/daos/management_report_repository.dart';
import '../../shared/utils/money.dart';
import 'report_widgets.dart';

int niceAxisMax(int value) {
  if (value <= 0) return 1;
  final roughStep = value / 4;
  final magnitude =
      math.pow(10, (math.log(roughStep) / math.ln10).floor()).toDouble();
  final normalized = roughStep / magnitude;
  final niceStep = (normalized <= 1
          ? 1
          : normalized <= 2
              ? 2
              : normalized <= 2.5
                  ? 2.5
                  : normalized <= 5
                      ? 5
                      : 10) *
      magnitude;
  return (niceStep * 4).ceil();
}

class OverviewTooltip extends StatelessWidget {
  const OverviewTooltip(
      {super.key, required this.title, required this.rows, this.note});
  final String title;
  final List<(String, int, Color)> rows;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
              color: theme.shadowColor.withValues(alpha: .15), blurRadius: 12)
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 7),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                            color: row.$3, shape: BoxShape.circle)),
                    const SizedBox(width: 7),
                    SizedBox(
                        width: 90,
                        child: Text(row.$1, style: theme.textTheme.bodySmall)),
                    Text(formatPeso(row.$2),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ]),
                ),
              if (note != null)
                Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(note!, style: theme.textTheme.bodySmall)),
            ]),
      ),
    );
  }
}

class OverviewPerformanceChart extends StatefulWidget {
  const OverviewPerformanceChart({super.key, required this.report});
  final ManagementReport report;
  @override
  State<OverviewPerformanceChart> createState() =>
      _OverviewPerformanceChartState();
}

class _OverviewPerformanceChartState extends State<OverviewPerformanceChart> {
  int? hovered;
  final enabled = <String>{'Gross sales', 'Net sales', 'Refunds', 'Expenses'};

  @override
  Widget build(BuildContext context) {
    final d = widget.report;
    final scheme = Theme.of(context).colorScheme;
    final dates = <DateTime>[];
    for (var day = d.period.start;
        day.isBefore(d.period.end);
        day = DateTime(day.year, day.month, day.day + 1)) {
      dates.add(day);
    }
    final series = <(String, Color, Map<DateTime, int>)>[
      ('Net sales', ReportColors.net(scheme), d.dailySales),
      ('Gross sales', ReportColors.gross(scheme), d.dailyGrossSales),
      ('Refunds', ReportColors.refunds, d.dailyRefunds),
      ('Expenses', ReportColors.expenses, d.dailyExpenses),
    ];
    final hasActivity = series.any((s) => s.$3.values.any((v) => v != 0));
    if (!hasActivity) {
      return const ReportEmptyState('No sales or expenses in this period.');
    }
    return Column(children: [
      SizedBox(
          height: 305,
          child: LayoutBuilder(builder: (context, box) {
            const left = 58.0, right = 14.0;
            final plotWidth = math.max(1.0, box.maxWidth - left - right);
            final index =
                hovered != null && hovered! < dates.length ? hovered : null;
            return MouseRegion(
              onExit: (_) => setState(() => hovered = null),
              onHover: (e) {
                final next = dates.length == 1
                    ? 0
                    : (((e.localPosition.dx - left) / plotWidth) *
                            (dates.length - 1))
                        .round()
                        .clamp(0, dates.length - 1);
                if (next != hovered) setState(() => hovered = next);
              },
              child: Stack(children: [
                Positioned.fill(
                    child: CustomPaint(
                        painter: _PerformancePainter(
                            dates,
                            series,
                            enabled,
                            index,
                            scheme.outlineVariant,
                            scheme.onSurfaceVariant))),
                if (index != null)
                  Positioned(
                    top: 8,
                    left: (left +
                            (dates.length == 1
                                ? plotWidth / 2
                                : index * plotWidth / (dates.length - 1)) +
                            12)
                        .clamp(0.0, math.max(0.0, box.maxWidth - 220)),
                    child: IgnorePointer(
                        child: OverviewTooltip(
                      title: MaterialLocalizations.of(context)
                          .formatMediumDate(dates[index]),
                      rows: [
                        for (final s in series)
                          (s.$1, s.$3[dates[index]] ?? 0, s.$2)
                      ],
                    )),
                  ),
              ]),
            );
          })),
      const SizedBox(height: 8),
      Wrap(
          spacing: 8,
          runSpacing: 2,
          alignment: WrapAlignment.center,
          children: [
            for (final s in series)
              InkWell(
                onTap: () => setState(() => enabled.contains(s.$1)
                    ? enabled.remove(s.$1)
                    : enabled.add(s.$1)),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                        width: 8,
                        height: 8,
                        color: s.$2.withValues(
                            alpha: enabled.contains(s.$1) ? 1 : .35)),
                    const SizedBox(width: 5),
                    Text(s.$1, style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
              ),
          ]),
    ]);
  }
}

class _PerformancePainter extends CustomPainter {
  const _PerformancePainter(
      this.dates, this.series, this.enabled, this.hovered, this.grid, this.ink);
  final List<DateTime> dates;
  final List<(String, Color, Map<DateTime, int>)> series;
  final Set<String> enabled;
  final int? hovered;
  final Color grid, ink;

  @override
  void paint(Canvas canvas, Size size) {
    final top = Rect.fromLTRB(58, 10, size.width - 14, 218);
    final lower = Rect.fromLTRB(58, 237, size.width - 14, 280);
    double x(int i) =>
        top.left +
        (dates.length == 1
            ? top.width / 2
            : top.width * i / (dates.length - 1));
    void label(String value, Offset at, {TextAlign align = TextAlign.left}) {
      final painter = TextPainter(
          text:
              TextSpan(text: value, style: TextStyle(color: ink, fontSize: 10)),
          textDirection: TextDirection.ltr,
          textAlign: align)
        ..layout();
      painter.paint(canvas, at);
    }

    final rawUpperMax = math.max(
        1,
        series
            .take(2)
            .where((s) => enabled.contains(s.$1))
            .expand((s) => s.$3.values)
            .fold<int>(0, math.max));
    final upperMax = niceAxisMax(rawUpperMax);
    final lowerMax = math.max(
        1,
        series
            .skip(2)
            .where((s) => enabled.contains(s.$1))
            .expand((s) => s.$3.values)
            .fold<int>(0, math.max));
    for (var tick = 0; tick <= 4; tick++) {
      final y = top.bottom - top.height * tick / 4;
      canvas.drawLine(
          Offset(top.left, y),
          Offset(top.right, y),
          Paint()
            ..color = grid
            ..strokeWidth = .7);
      label(compactPeso(upperMax * tick ~/ 4), Offset(0, y - 7));
    }
    canvas.drawLine(Offset(lower.left, lower.bottom),
        Offset(lower.right, lower.bottom), Paint()..color = grid);
    for (final s in series.take(2).toList().reversed) {
      if (!enabled.contains(s.$1)) continue;
      final path = Path();
      for (var i = 0; i < dates.length; i++) {
        final y = top.bottom -
            (s.$3[dates[i]] ?? 0).clamp(0, upperMax) / upperMax * top.height;
        if (i == 0) {
          path.moveTo(x(i), y);
        } else {
          path.lineTo(x(i), y);
        }
        if (i == hovered) {
          canvas.drawCircle(Offset(x(i), y), 4, Paint()..color = s.$2);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = s.$2
            ..strokeWidth = s.$1 == 'Net sales' ? 2.8 : 1.5
            ..style = PaintingStyle.stroke);
    }
    final barWidth = math.min(10.0, top.width / math.max(1, dates.length) / 3);
    for (var i = 0; i < dates.length; i++) {
      for (var j = 2; j < 4; j++) {
        final s = series[j];
        if (!enabled.contains(s.$1)) continue;
        final value = (s.$3[dates[i]] ?? 0).abs();
        final height = value / lowerMax * lower.height;
        canvas.drawRect(
            Rect.fromLTWH(x(i) + (j == 2 ? -barWidth : 0),
                lower.bottom - height, barWidth, height),
            Paint()..color = s.$2);
      }
    }
    if (hovered != null) {
      canvas.drawLine(
          Offset(x(hovered!), top.top),
          Offset(x(hovered!), lower.bottom),
          Paint()
            ..color = ink.withValues(alpha: .55)
            ..strokeWidth = 1);
    }
    final step =
        math.max(1, (dates.length / math.max(2, top.width / 80)).ceil());
    for (var i = 0; i < dates.length; i += step) {
      final text = '${_month(dates[i].month)} ${dates[i].day}';
      label(text, Offset(x(i) - 16, 290));
    }
  }

  String _month(int m) => const [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ][m - 1];
  @override
  bool shouldRepaint(covariant _PerformancePainter old) =>
      old.hovered != hovered ||
      old.enabled != enabled ||
      old.series != series ||
      old.dates != dates;
}

class OverviewDonut extends StatefulWidget {
  const OverviewDonut(
      {super.key,
      required this.values,
      required this.emptyMessage,
      this.centerLabel = 'Total'});
  final Map<String, int> values;
  final String emptyMessage;
  final String centerLabel;
  @override
  State<OverviewDonut> createState() => _OverviewDonutState();
}

class _OverviewDonutState extends State<OverviewDonut> {
  int? hovered;
  @override
  Widget build(BuildContext context) {
    final entries = widget.values.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<int>(0, (n, e) => n + e.value);
    if (total <= 0 || widget.values.values.any((v) => v < 0)) {
      return ReportEmptyState(widget.emptyMessage);
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
        builder: (context, box) => Stack(children: [
              SizedBox(
                  height: 160,
                  child: Row(children: [
                    MouseRegion(
                      onExit: (_) => setState(() => hovered = null),
                      onHover: (e) {
                        final dx = e.localPosition.dx - 76,
                            dy = e.localPosition.dy - 76;
                        var angle = math.atan2(dy, dx) + math.pi / 2;
                        if (angle < 0) angle += 2 * math.pi;
                        var cumulative = 0.0;
                        int? hit;
                        if (math.sqrt(dx * dx + dy * dy) >= 38 &&
                            math.sqrt(dx * dx + dy * dy) <= 76) {
                          for (var i = 0; i < entries.length; i++) {
                            cumulative +=
                                entries[i].value / total * 2 * math.pi;
                            if (angle <= cumulative) {
                              hit = i;
                              break;
                            }
                          }
                        }
                        if (hit != hovered) setState(() => hovered = hit);
                      },
                      child: SizedBox(
                          width: 152,
                          height: 152,
                          child: CustomPaint(
                              painter: _OverviewDonutPainter(
                                  entries, colors, hovered),
                              child: Center(
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                    Text(widget.centerLabel,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall),
                                    Text(compactPeso(total),
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.w700))
                                  ])))),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                          for (var i = 0; i < math.min(entries.length, 6); i++)
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 3),
                                child: Row(children: [
                                  Container(
                                      width: 8,
                                      height: 8,
                                      color: colors[i % colors.length]),
                                  const SizedBox(width: 6),
                                  Expanded(
                                      child: Text(entries[i].key,
                                          overflow: TextOverflow.ellipsis)),
                                  Text(
                                      '${(entries[i].value * 100 / total).toStringAsFixed(1)}%',
                                      style:
                                          Theme.of(context).textTheme.bodySmall)
                                ]))
                        ])),
                  ])),
              if (hovered != null)
                Positioned(
                    left: math.min(130, math.max(0, box.maxWidth - 215)),
                    top: 4,
                    child: IgnorePointer(
                        child: OverviewTooltip(
                            title: entries[hovered!].key,
                            note:
                                '${(entries[hovered!].value * 100 / total).toStringAsFixed(1)}% of total',
                            rows: [
                          (
                            'Amount',
                            entries[hovered!].value,
                            colors[hovered! % colors.length]
                          )
                        ]))),
            ]));
  }
}

class _OverviewDonutPainter extends CustomPainter {
  const _OverviewDonutPainter(this.entries, this.colors, this.hovered);
  final List<MapEntry<String, int>> entries;
  final List<Color> colors;
  final int? hovered;
  @override
  void paint(Canvas canvas, Size size) {
    final total = entries.fold<int>(0, (n, e) => n + e.value);
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: 64);
    var start = -math.pi / 2;
    for (var i = 0; i < entries.length; i++) {
      final sweep = entries[i].value / total * 2 * math.pi;
      canvas.drawArc(
          rect,
          start,
          sweep,
          false,
          Paint()
            ..color = colors[i % colors.length]
            ..style = PaintingStyle.stroke
            ..strokeWidth = hovered == i ? 25 : 21);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _OverviewDonutPainter old) =>
      old.hovered != hovered || old.entries != entries;
}

class OverviewBars extends StatefulWidget {
  const OverviewBars(
      {super.key, required this.values, required this.emptyMessage});
  final Map<String, int> values;
  final String emptyMessage;
  @override
  State<OverviewBars> createState() => _OverviewBarsState();
}

class _OverviewBarsState extends State<OverviewBars> {
  int? hovered;
  @override
  Widget build(BuildContext context) {
    final entries = widget.values.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) return ReportEmptyState(widget.emptyMessage);
    final top = entries.take(5).toList();
    final max = top.first.value;
    final total = entries.fold<int>(0, (n, e) => n + e.value);
    final color = ReportColors.net(Theme.of(context).colorScheme);
    return Stack(children: [
      Column(children: [
        for (var i = 0; i < top.length; i++)
          MouseRegion(
              onEnter: (_) => setState(() => hovered = i),
              onExit: (_) => setState(() => hovered = null),
              child: Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Column(children: [
                    Row(children: [
                      Expanded(
                          child: Text(top[i].key,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall)),
                      Text(formatPeso(top[i].value),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontWeight: FontWeight.w600))
                    ]),
                    const SizedBox(height: 3),
                    LinearProgressIndicator(
                        value: top[i].value / max,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(4),
                        color: color),
                  ]))),
      ]),
      if (hovered != null)
        Positioned(
            right: 4,
            top: math.min(hovered! * 24.0, 45),
            child: IgnorePointer(
                child: OverviewTooltip(
                    title: top[hovered!].key,
                    rows: [('Net sales', top[hovered!].value, color)],
                    note:
                        '${(top[hovered!].value * 100 / total).toStringAsFixed(1)}% of positive sales'))),
    ]);
  }
}
