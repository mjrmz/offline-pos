import 'package:flutter/material.dart';

String expiryStatus(DateTime? expiry, DateTime now) {
  if (expiry == null) return 'Valid';
  final day = DateTime(now.year, now.month, now.day);
  final end = DateTime(expiry.year, expiry.month, expiry.day);
  if (end.isBefore(day)) return 'Expired';
  if (end.difference(day).inDays <= 30) return 'Expiring soon';
  return 'Valid';
}

/// A calendar input for a nullable batch expiry date.
class ExpiryDateField extends StatelessWidget {
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  const ExpiryDateField(
      {super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final label = value == null
        ? 'Choose expiry date'
        : MaterialLocalizations.of(context).formatMediumDate(value!);
    return Row(children: [
      Expanded(
        child: OutlinedButton.icon(
          icon: const Icon(Icons.calendar_month),
          label: Text(label),
          onPressed: () async {
            final now = DateTime.now();
            final selected = await showDatePicker(
              context: context,
              initialDate: value ?? now,
              firstDate: DateTime(2000),
              lastDate: DateTime(now.year + 50),
            );
            if (selected != null) onChanged(selected);
          },
        ),
      ),
      if (value != null)
        IconButton(
          tooltip: 'Clear expiry date',
          onPressed: () => onChanged(null),
          icon: const Icon(Icons.clear),
        ),
    ]);
  }
}
