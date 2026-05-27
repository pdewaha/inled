import 'dart:convert';

import 'package:exled/models/expectation_type.dart';
import 'package:exled/services/expectation_chat_changelog.dart';

/// One row to insert after a successful expectation save (structured or plain).
/// Structured types include 10–16 ([kExpectationMessageTypeChangelogReceiversAdded]).
class ChangelogSaveEvent {
  const ChangelogSaveEvent({
    required this.type,
    required this.messageText,
  });

  final int type;
  /// Plain sentence for [kExpectationMessageTypeChangelogPlain], else JSON (see encoders below).
  final String messageText;
}

const int _payloadVersion = 1;

String _json(Map<String, dynamic> body) =>
    jsonEncode(<String, dynamic>{'v': _payloadVersion, ...body});

String encodeChangelogPayloadDescription({required bool isTopic}) =>
    _json({'kind': 'description', 'isTopic': isTopic});

String encodeChangelogPayloadDeadline({
  DateTime? deadlineAt,
  required String label,
}) =>
    _json({
      'kind': 'deadline',
      'deadlineAt': deadlineAt?.toUtc().toIso8601String(),
      'label': label,
    });

String encodeChangelogPayloadFields({
  required bool isTopic,
  String? statusLabel,
  String? healthLabel,
  int? progressPct,
}) {
  final m = <String, dynamic>{
    'kind': 'fields',
    'isTopic': isTopic,
    if (statusLabel != null) 'statusLabel': statusLabel,
    if (healthLabel != null) 'healthLabel': healthLabel,
    if (progressPct != null) 'progressPct': progressPct,
  };
  return _json(m);
}

String encodeChangelogPayloadVisibility({
  required bool isTopic,
  required bool echo,
}) =>
    _json({'kind': 'visibility', 'isTopic': isTopic, 'echo': echo});

String encodeChangelogPayloadPublished({required bool isTopic}) =>
    _json({'kind': 'published', 'isTopic': isTopic});

String encodeChangelogPayloadUpdateRequested({required bool isTopic}) =>
    _json({'kind': 'update_requested', 'isTopic': isTopic});

/// Receivers appended from the expectation / talking-point detail sheet (handles without `@`).
String encodeChangelogPayloadReceiversAdded({
  required bool isTopic,
  required List<String> handles,
}) {
  final cleaned = <String>[];
  final seen = <String>{};
  for (final raw in handles) {
    var h = raw.trim();
    if (h.startsWith('@')) h = h.substring(1);
    if (h.isEmpty) continue;
    if (seen.add(h.toLowerCase())) cleaned.add(h);
  }
  return _json({'kind': 'receivers_added', 'isTopic': isTopic, 'handles': cleaned});
}

/// Progress-only change (explicit [pct]; avoids empty `fields` payloads in edge cases).
String encodeChangelogPayloadProgress({
  required bool isTopic,
  required int pct,
}) =>
    _json({'kind': 'progress', 'isTopic': isTopic, 'pct': pct.clamp(0, 100)});

bool _payloadVersionMatches(dynamic v) {
  if (v == _payloadVersion || v == 1.0) return true;
  if (v is String && int.tryParse(v.trim()) == _payloadVersion) return true;
  return false;
}

Map<String, dynamic>? _tryDecodeStructured(String messageText) {
  final t = messageText.trim();
  if (!t.startsWith('{')) return null;
  try {
    final o = jsonDecode(t);
    if (o is! Map) return null;
    final m = Map<String, dynamic>.from(o as Map);
    if (!_payloadVersionMatches(m['v'])) return null;
    return m;
  } catch (_) {
    return null;
  }
}

int? _progressPctFromJson(dynamic p) {
  if (p == null) return null;
  if (p is int) return p;
  if (p is num) return p.round();
  if (p is String) return int.tryParse(p.trim());
  return null;
}

/// Parsed structured changelog JSON, or null if not a v1 payload.
Map<String, dynamic>? tryDecodeChangelogPayload(String messageText) {
  final m = _tryDecodeStructured(messageText);
  if (m == null) return null;
  final k = m['kind'];
  if (k is String && k.trim() != k) {
    return Map<String, dynamic>.from(m)..['kind'] = k.trim();
  }
  return m;
}

/// Progress value from a changelog fields payload (handles int/double/String from JSON).
int? changelogProgressPctFromJson(dynamic p) => _progressPctFromJson(p);

String _noun(bool isTopic) =>
    isTopic ? 'talking point' : 'expectation';

/// Single-line text for activity feed rows and non-Flutter consumers.
String expectationChangelogActivityFeedLine({
  required int messageType,
  required String messageText,
  required ExpectationType expectationType,
}) {
  if (messageType == kExpectationMessageTypeChat ||
      messageType == kExpectationMessageTypeChatWithAttachment) {
    final t = messageText.trim();
    if (t == '[Attachment]') return 'Shared an attachment.';
    if (t.isEmpty) {
      return messageType == kExpectationMessageTypeChatWithAttachment
          ? 'Shared an attachment.'
          : '(no message)';
    }
    return t;
  }
  final isTopic = expectationType == ExpectationType.topic;
  final parsed = tryDecodeChangelogPayload(messageText);
  if (parsed == null) {
    final t = messageText.trim();
    if (t.isEmpty) return 'Activity update (no stored text).';
    final lower = t.toLowerCase();
    // Title lives in expectationSummarySnippet below the row; keep intro short.
    if (lower.startsWith('created a new expectation:')) {
      return 'Created a new expectation.';
    }
    if (lower.startsWith('created a new talking point:')) {
      return 'Created a new talking point.';
    }
    if (lower.startsWith('published this expectation:')) {
      return 'Published this expectation.';
    }
    if (lower.startsWith('published this talking point:')) {
      return 'Published this talking point.';
    }
    return t;
  }
  switch (parsed['kind']) {
    case 'description':
      return 'Updated the description of this ${_noun(isTopic)}.';
    case 'deadline':
      final label = (parsed['label'] as String?)?.trim() ?? '';
      return label.isEmpty
          ? 'Changed deadline.'
          : 'Changed deadline to $label.';
    case 'fields':
      final parts = <String>[];
      final sl = (parsed['statusLabel'] as String?)?.trim();
      final hl = (parsed['healthLabel'] as String?)?.trim();
      final p = _progressPctFromJson(parsed['progressPct']);
      if (sl != null && sl.isNotEmpty) parts.add('status to $sl');
      if (hl != null && hl.isNotEmpty) parts.add('health to $hl');
      if (p != null) parts.add('progress to $p%');
      if (parts.isEmpty) return 'Updated this ${_noun(isTopic)}.';
      return 'Changed ${parts.join(', ')}.';
    case 'visibility':
      final echo = parsed['echo'] == true;
      return 'Set visibility to ${echo ? 'shared' : 'private'}.';
    case 'published':
      return 'Published this ${_noun(isTopic)}.';
    case 'update_requested':
      return 'Requested an update -consider updating progress, deadline or status.';
    case 'receivers_added':
      final raw = parsed['handles'];
      final hs = <String>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is String && e.trim().isNotEmpty) hs.add(e.trim());
        }
      }
      if (hs.isEmpty) return 'Added receiver(s).';
      final parts = hs
          .map((h) {
            final t = h.trim();
            return t.startsWith('@') ? t : '@$t';
          })
          .join(', ');
      return 'Added $parts.';
    case 'progress':
      final p = changelogProgressPctFromJson(parsed['pct']);
      if (p == null) return 'Changed progress.';
      return 'Changed progress to $p%.';
    default:
      return messageText.trim();
  }
}
