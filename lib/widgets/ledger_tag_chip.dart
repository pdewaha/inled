import 'package:flutter/material.dart';

/// Compact `#tag` styling aligned with the sidebar rail recent tags.
class LedgerTagChip extends StatelessWidget {
  const LedgerTagChip({
    super.key,
    required this.tag,
    this.selected = false,
    this.onPressed,
  });

  /// Lowercase tag text without `#` (e.g. `security`).
  final String tag;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = Text('#$tag', style: theme.textTheme.labelSmall);
    if (onPressed != null) {
      return ActionChip(
        label: label,
        onPressed: onPressed,
        backgroundColor: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.9)
            : null,
        side: selected
            ? BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.65),
              )
            : null,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      );
    }
    return Chip(
      label: label,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}
