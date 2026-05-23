/// Canonical #hashtag form: lowercase token in text and in [expectation_tags.name].
final RegExp kHashtagInTextRegex = RegExp(r'#([a-zA-Z0-9._-]+)');

String normalizeHashtagToken(String raw) => raw.trim().toLowerCase();

/// Rewrites `#CPD` → `#cpd` in capture text and summaries.
String normalizeHashtagsInText(String text) {
  return text.replaceAllMapped(kHashtagInTextRegex, (match) {
    final body = normalizeHashtagToken(match.group(1) ?? '');
    if (body.isEmpty) return match.group(0) ?? '';
    return '#$body';
  });
}
