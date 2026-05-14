/// Ledger UI: show people with a leading `@` when presenting a line label.
///
/// Does not prefix [generalLabel] (default `'General'`). Idempotent if [raw]
/// already starts with `@`.
String ledgerAtMentionLine(String raw, {String generalLabel = 'General'}) {
  final t = raw.trim();
  if (t.isEmpty) return generalLabel;
  if (t == generalLabel) return generalLabel;
  if (t.startsWith('@')) return t;
  return '@$t';
}

/// First letter for [CircleAvatar], skipping a leading `@` from [ledgerAtMentionLine].
String ledgerPersonInitialLetter(String labeledLine) {
  final t = labeledLine.trim();
  if (t.isEmpty || t == 'General') return '?';
  final from = t.startsWith('@') && t.length > 1 ? t.substring(1) : t;
  final s = from.trim();
  if (s.isEmpty) return '?';
  return s[0].toUpperCase();
}
