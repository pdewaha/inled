import 'package:flutter/material.dart';

/// Compact token chip (default `#tag`); use [tokenPrefix] `@` for `@handle` rows.
class LedgerTagChip extends StatelessWidget {
  const LedgerTagChip({
    super.key,
    required this.tag,
    this.tokenPrefix = '#',
    this.selected = false,
    this.onPressed,
    /// When set, selected state uses this instead of [ColorScheme.primary].
    this.selectionAccent,
  });

  /// Display prefix before [tag] (default `#` for hashtags, `@` for handles).
  final String tokenPrefix;

  /// Tag or handle text without the prefix character (e.g. `security`, `alex`).
  final String tag;
  final bool selected;
  final VoidCallback? onPressed;
  final Color? selectionAccent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = selectionAccent;
    final labelStyle = theme.textTheme.labelSmall;
    final Color? labelColor = selected && accent != null
        ? (ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
            ? Colors.white
            : scheme.onSurface)
        : null;
    final label = Text(
      '$tokenPrefix$tag',
      style: labelStyle?.copyWith(color: labelColor),
    );
    if (onPressed != null) {
      return ActionChip(
        label: label,
        onPressed: onPressed,
        backgroundColor: selected
            ? (accent != null
                ? accent.withValues(alpha: 0.38)
                : scheme.primaryContainer.withValues(alpha: 0.9))
            : null,
        side: selected
            ? BorderSide(
                color: accent != null
                    ? accent.withValues(alpha: 0.85)
                    : scheme.primary.withValues(alpha: 0.65),
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
