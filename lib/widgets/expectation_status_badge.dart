import 'package:flutter/material.dart';
import 'package:inled/models/expectation_status.dart';

class ExpectationStatusBadge extends StatelessWidget {
  const ExpectationStatusBadge({super.key, required this.status});

  final ExpectationStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String label, Color fg, Color bg) = switch (status) {
      ExpectationStatus.pending => (
          'Pending',
          scheme.onSurfaceVariant,
          scheme.surfaceContainerHighest,
        ),
      ExpectationStatus.contracted => (
          'Contracted',
          scheme.onTertiaryContainer,
          scheme.tertiaryContainer,
        ),
      ExpectationStatus.breached => (
          'Breached',
          scheme.onErrorContainer,
          scheme.errorContainer,
        ),
    };
    return Chip(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      label: Text(label, style: TextStyle(color: fg, fontSize: 12)),
      backgroundColor: bg,
      side: BorderSide.none,
    );
  }
}
