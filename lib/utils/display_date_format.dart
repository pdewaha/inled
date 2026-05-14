import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Short calendar date using [locale] patterns (e.g. `d.M.y` in much of Europe).
String formatDisplayDateOnly(DateTime dt, Locale locale) {
  final l = dt.toLocal();
  return DateFormat.yMd(locale.toString()).format(l);
}

/// If [label] matches `yyyy-MM-dd`, format for [locale]; else return [label] (e.g. "TBD", prose).
String formatDeadlineLabelForDisplay(String label, Locale locale) {
  final t = label.trim();
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(t);
  if (m == null) return label;
  final y = int.tryParse(m.group(1)!);
  final mo = int.tryParse(m.group(2)!);
  final d = int.tryParse(m.group(3)!);
  if (y == null || mo == null || d == null) return label;
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return label;
  try {
    return formatDisplayDateOnly(DateTime(y, mo, d), locale);
  } catch (_) {
    return label;
  }
}

/// Date and time for tooltips / detail hints (24h where typical for locale).
String formatDisplayDateTime(DateTime dt, Locale locale) {
  final l = dt.toLocal();
  return DateFormat.yMd(locale.toString()).add_Hm().format(l);
}
