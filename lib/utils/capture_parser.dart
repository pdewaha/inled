/// Parsed capture line — prototype rules, no NLP.
///
/// Example: `!John: Audit the security by Friday #SecurityGoal`
class CaptureParseResult {
  const CaptureParseResult({
    this.personHandle,
    this.body,
    this.goalTag,
    this.deadlineHint,
    this.raw = '',
  });

  final String? personHandle;
  final String? body;
  final String? goalTag;
  final String? deadlineHint;
  final String raw;

  bool get hasAnySignal =>
      personHandle != null ||
      body != null ||
      goalTag != null ||
      deadlineHint != null;
}

final RegExp _person = RegExp(r'^!([^:\s]+)\s*:\s*', caseSensitive: false);
final RegExp _goalTag = RegExp(r'#(\w+)');
final RegExp _deadline = RegExp(
  r'\b(by|before)\s+([^#]+?)(?=\s*#|\s*$)',
  caseSensitive: false,
);

CaptureParseResult parseCaptureLine(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    return CaptureParseResult(raw: input);
  }

  var rest = trimmed;
  String? personHandle;
  final personMatch = _person.firstMatch(trimmed);
  if (personMatch != null) {
    personHandle = personMatch.group(1);
    rest = trimmed.substring(personMatch.end);
  }

  RegExpMatch? goalMatch;
  String? goalTag;
  goalMatch = _goalTag.firstMatch(rest);
  if (goalMatch != null) {
    goalTag = goalMatch.group(1);
  }

  RegExpMatch? deadlineMatch;
  String? deadlineHint;
  deadlineMatch = _deadline.firstMatch(rest);
  if (deadlineMatch != null) {
    deadlineHint =
        '${deadlineMatch.group(1)} ${deadlineMatch.group(2)?.trim()}';
  }

  var working = rest;
  if (goalMatch != null) {
    working = working.replaceFirst(goalMatch.group(0)!, '');
  }
  if (deadlineMatch != null) {
    working = working.replaceFirst(deadlineMatch.group(0)!, '');
  }
  working = working.replaceAll(RegExp(r'\s+'), ' ').trim();
  final body = working.isEmpty ? null : working;

  return CaptureParseResult(
    personHandle: personHandle,
    body: body,
    goalTag: goalTag,
    deadlineHint: deadlineHint,
    raw: input,
  );
}
