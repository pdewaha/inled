/// Label when an item has no single receiver and no @mentions in the text.
const String kLedgerAllMentionLabel = '@All';

/// Ledger UI: show people with a leading `@` when presenting a line label.
///
/// Does not prefix [allMentionLabel] (default [kLedgerAllMentionLabel]). Idempotent
/// if [raw] already starts with `@`.
String ledgerAtMentionLine(
  String raw, {
  String allMentionLabel = kLedgerAllMentionLabel,
}) {
  final t = raw.trim();
  if (t.isEmpty) return allMentionLabel;
  if (t == allMentionLabel) return allMentionLabel;
  if (t.startsWith('@')) return t;
  return '@$t';
}

/// First letter for [CircleAvatar], skipping a leading `@` from [ledgerAtMentionLine].
String ledgerPersonInitialLetter(String labeledLine) {
  final t = labeledLine.trim();
  if (t.isEmpty) return '?';
  final from = t.startsWith('@') && t.length > 1 ? t.substring(1) : t;
  final s = from.trim();
  if (s.isEmpty) return '?';
  return s[0].toUpperCase();
}
