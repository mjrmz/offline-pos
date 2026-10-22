import 'package:flutter/material.dart';

import '../theme/app_layout.dart';

class AppPageHeader extends StatelessWidget {
  const AppPageHeader(
      {super.key, required this.title, this.subtitle, this.action});

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppLayout.space20),
        child: LayoutBuilder(builder: (context, constraints) {
          final heading = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              if (subtitle != null) ...[
                const SizedBox(height: AppLayout.space4),
                Text(subtitle!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ],
          );
          if (constraints.maxWidth < 600) {
            return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  heading,
                  if (action != null) ...[
                    const SizedBox(height: AppLayout.space12),
                    action!,
                  ],
                ]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: heading),
            if (action != null) ...[
              const SizedBox(width: AppLayout.space16),
              action!,
            ],
          ]);
        }),
      );
}

class AppWorkspaceTabs extends StatelessWidget {
  const AppWorkspaceTabs({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    this.trailing,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        for (var index = 0; index < labels.length; index++)
          Padding(
            padding: const EdgeInsets.only(right: AppLayout.space4),
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: selectedIndex == index
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
                backgroundColor: selectedIndex == index
                    ? scheme.primaryContainer
                    : Colors.transparent,
                shape: const RoundedRectangleBorder(
                    borderRadius: AppLayout.controlRadius),
                padding:
                    const EdgeInsets.symmetric(horizontal: AppLayout.space12),
              ),
              onPressed: () => onSelected(index),
              child: Text(labels[index], maxLines: 1),
            ),
          ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

class AppEmptyState extends StatelessWidget {
  const AppEmptyState(
      {super.key, required this.title, this.message, this.action});

  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppLayout.space32),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (message != null) ...[
              const SizedBox(height: AppLayout.space8),
              Text(message!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (action != null) ...[
              const SizedBox(height: AppLayout.space16),
              action!,
            ],
          ]),
        ),
      );
}

class AppStatusBadge extends StatelessWidget {
  const AppStatusBadge({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppLayout.space8, vertical: AppLayout.space4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: AppLayout.controlRadius,
          border: Border.all(color: color.withValues(alpha: .35)),
        ),
        child: Text(label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600)),
      );
}

enum AppStatusTone { success, info, active, warning, danger, neutral }

Color appStatusColor(BuildContext context, AppStatusTone tone) {
  final scheme = Theme.of(context).colorScheme;
  return switch (tone) {
    AppStatusTone.success => Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF81D9A1)
        : const Color(0xFF176B3A),
    AppStatusTone.info => Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF99C9FF)
        : const Color(0xFF245D9C),
    AppStatusTone.active => scheme.primary,
    AppStatusTone.warning => Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFFFC17A)
        : const Color(0xFF9A4B0A),
    AppStatusTone.danger => scheme.error,
    AppStatusTone.neutral => scheme.onSurfaceVariant,
  };
}

AppStatusTone appStatusTone(String label) {
  final value = label.toLowerCase();
  if (value.contains('overdue') ||
      value.contains('expired') ||
      value.contains('rejected') ||
      value.contains('failed')) {
    return AppStatusTone.danger;
  }
  if (value.contains('completed') ||
      value.contains('converted') ||
      value.contains('ready') ||
      value.contains('healthy') ||
      value.contains('resolved')) {
    return AppStatusTone.success;
  }
  if (value.contains('await') ||
      value.contains('low stock') ||
      value.contains('pending')) {
    return AppStatusTone.warning;
  }
  if (value.contains('sent') || value.contains('non-bir')) {
    return AppStatusTone.info;
  }
  if (value.contains('cancel') ||
      value.contains('closed') ||
      value.contains('inactive') ||
      value.contains('legacy')) {
    return AppStatusTone.neutral;
  }
  return AppStatusTone.active;
}

class AppSemanticStatusBadge extends StatelessWidget {
  const AppSemanticStatusBadge({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => AppStatusBadge(
        label: label,
        color: appStatusColor(context, appStatusTone(label)),
      );
}

class AppMetricTile extends StatelessWidget {
  const AppMetricTile(
      {super.key,
      required this.label,
      required this.value,
      this.detail,
      this.icon,
      this.onTap,
      this.width});
  final String label;
  final String value;
  final String? detail;
  final IconData? icon;
  final VoidCallback? onTap;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: AppLayout.metricHeight,
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: AppLayout.panelRadius,
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppLayout.space16, vertical: AppLayout.space8),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall)),
                if (icon != null)
                  Icon(icon,
                      size: AppLayout.metricIconSize,
                      color: scheme.onSurfaceVariant),
              ]),
              const SizedBox(height: AppLayout.space4),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontSize: 28, fontWeight: FontWeight.w700)),
              if (detail != null)
                Text(detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      ),
    );
  }
}

class AppSearchField extends StatelessWidget {
  const AppSearchField(
      {super.key,
      required this.hintText,
      this.onChanged,
      this.controller,
      this.width});
  final String hintText;
  final ValueChanged<String>? onChanged;
  final TextEditingController? controller;
  final double? width;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: AppLayout.searchHeight,
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            hintText: hintText,
            prefixIcon: const Icon(Icons.search, size: 20),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
        ),
      );
}

class AppEntityRow extends StatelessWidget {
  const AppEntityRow(
      {super.key,
      required this.title,
      this.subtitle,
      this.status,
      this.amount,
      required this.onTap});
  final String title;
  final String? subtitle;
  final Widget? status;
  final String? amount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppLayout.space8),
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
            borderRadius: AppLayout.panelRadius,
            side: BorderSide(color: scheme.outlineVariant)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(minHeight: AppLayout.rowMinHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppLayout.space16, vertical: AppLayout.space12),
              child: Row(children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium),
                      if (subtitle != null)
                        Text(subtitle!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall),
                    ])),
                if (amount != null) ...[
                  const SizedBox(width: AppLayout.space12),
                  Text(amount!,
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.titleMedium),
                ],
                if (status != null) ...[
                  const SizedBox(width: AppLayout.space12),
                  status!,
                ],
                const SizedBox(width: AppLayout.space8),
                Icon(Icons.chevron_right,
                    size: AppLayout.rowIconSize,
                    color: scheme.onSurfaceVariant),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class AppPaginationFooter extends StatelessWidget {
  const AppPaginationFooter(
      {super.key,
      required this.page,
      required this.count,
      required this.hasNext,
      required this.onPrevious,
      required this.onNext,
      this.pageSize = 50,
      this.total});

  final int page;
  final int count;
  final int pageSize;
  final int? total;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    if (page == 0 && !hasNext) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final first = page * pageSize + 1;
    final last = page * pageSize + count;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          Text(
              total == null
                  ? 'Showing $first–$last'
                  : 'Showing $first–$last of $total',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            TextButton.icon(
                onPressed: page == 0 ? null : onPrevious,
                icon: const Icon(Icons.chevron_left, size: 18),
                label: const Text('Previous')),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                    total == null
                        ? 'Page ${page + 1}'
                        : 'Page ${page + 1} of ${(total! + pageSize - 1) ~/ pageSize}',
                    style: Theme.of(context).textTheme.bodySmall)),
            TextButton.icon(
                onPressed: hasNext ? onNext : null,
                icon: const Icon(Icons.chevron_right, size: 18),
                label: const Text('Next')),
          ]),
        ],
      ),
    );
  }
}

/// A bounded record workspace. The parent supplies a finite height (normally
/// through Expanded); only the rows scroll, while the title and footer stay put.
class AppPagedListPanel extends StatelessWidget {
  const AppPagedListPanel({super.key, required this.title, required this.total,
    required this.count, required this.itemBuilder, this.loading = false,
    this.page = 0, this.onPrevious, this.onNext, this.emptyTitle = 'No records found',
    this.emptyMessage = 'Try adjusting your search or filters.'});

  final String title;
  final int total;
  final int count;
  final int page;
  final bool loading;
  final IndexedWidgetBuilder itemBuilder;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final String emptyTitle;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pages = (total + 49) ~/ 50;
    return Container(
      decoration: BoxDecoration(color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            Text('$total ${total == 1 ? 'result' : 'results'}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ])),
        Divider(height: 1, color: scheme.outlineVariant),
        Expanded(child: loading
          ? const Center(child: CircularProgressIndicator())
          : count == 0
            ? LayoutBuilder(builder: (context, bounds) => bounds.maxHeight < 170
                ? Center(child: Text(emptyTitle))
                : AppEmptyState(title: emptyTitle, message: emptyMessage))
            : Scrollbar(child: ListView.separated(
                padding: const EdgeInsets.all(10),
                itemCount: count,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: itemBuilder))),
        if (pages > 1) ...[
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [
              Text('Showing ${page * 50 + 1}–${page * 50 + count} of $total',
                style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              Text('Page ${page + 1} of $pages', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: 12),
              if (page > 0) TextButton.icon(onPressed: onPrevious,
                icon: const Icon(Icons.chevron_left), label: const Text('Previous')),
              if (page + 1 < pages) TextButton.icon(onPressed: onNext,
                icon: const Icon(Icons.chevron_right), label: const Text('Next')),
            ])),
        ],
      ]),
    );
  }
}

class AppFilterChip extends StatelessWidget {
  const AppFilterChip(
      {super.key,
      required this.label,
      required this.selected,
      required this.onSelected});
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onSelected(),
      );
}

class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({super.key, required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppLayout.space12),
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      );
}
