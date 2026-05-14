import 'package:exled/models/expectation.dart';
import 'package:exled/models/expectation_type.dart';
import 'package:exled/models/expectation_changelog_payload.dart';
import 'package:exled/services/expectation_chat_changelog.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One row for the activity feed (changelog messages across expectations).
class ExpectationActivityFeedItem {
  const ExpectationActivityFeedItem({
    required this.messageId,
    required this.expectationId,
    required this.senderPersonId,
    required this.senderLabel,
    required this.messageText,
    required this.createdAt,
    required this.expectationSummarySnippet,
    required this.kindLabel,
    this.messageType = kExpectationMessageTypeChangelogPlain,
    this.hashtags = const [],
  });

  final String messageId;
  final String expectationId;
  final String senderPersonId;
  final String senderLabel;
  final String messageText;
  final DateTime createdAt;
  final String expectationSummarySnippet;
  final String kindLabel;
  /// [expectation_messages.type]; selects rendering / parsing for [messageText].
  final int messageType;
  /// Normalized #tag tokens (no `#` prefix) from the expectation summary, for chips.
  final List<String> hashtags;
}

String _senderLabelFromPeopleRow(dynamic personObj, String fallbackSenderId) {
  if (personObj is Map) {
    final display = ((personObj['display_name'] as String?) ?? '').trim();
    final handle = ((personObj['handle'] as String?) ?? '').trim();
    if (display.isNotEmpty) return display;
    if (handle.isNotEmpty) return '@$handle';
  }
  if (personObj is List && personObj.isNotEmpty) {
    return _senderLabelFromPeopleRow(personObj.first, fallbackSenderId);
  }
  return fallbackSenderId;
}

bool expectationIsPartyForPerson({
  required Expectation e,
  required String authUserId,
  required String myPersonId,
}) {
  if (e.writerUserId == authUserId) return true;
  final target = e.personId.trim();
  if (target.isNotEmpty && target == myPersonId) return true;
  return false;
}

List<Expectation> expectationsPartyForPerson({
  required List<Expectation> expectations,
  required String authUserId,
  required String myPersonId,
}) {
  return expectations
      .where(
        (e) => expectationIsPartyForPerson(
          e: e,
          authUserId: authUserId,
          myPersonId: myPersonId,
        ),
      )
      .toList();
}

String _snippet(String summary, {int maxLen = 72}) {
  final t = summary.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.length <= maxLen) return t.isEmpty ? '—' : t;
  return '${t.substring(0, maxLen)}…';
}

final RegExp _activityFeedHashTagRe = RegExp(r'#([a-zA-Z0-9._-]+)');

/// Distinct hashtags from [summary], first occurrence order, lowercase body (no `#`).
List<String> activityFeedHashtagsFromSummary(String summary, {int max = 6}) {
  final seen = <String>{};
  final out = <String>[];
  for (final m in _activityFeedHashTagRe.allMatches(summary)) {
    final t = (m.group(1) ?? '').trim().toLowerCase();
    if (t.isEmpty || seen.contains(t)) continue;
    seen.add(t);
    out.add(t);
    if (out.length >= max) break;
  }
  return out;
}

/// Caps long strings for feed rows (explicit `…` suffix, whitespace collapsed).
String activityFeedEllipsis(String input, int maxChars) {
  final s = input.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (s.isEmpty) return '';
  if (s.length <= maxChars) return s;
  if (maxChars < 1) return '…';
  return '${s.substring(0, maxChars)}…';
}

String _kindLabel(ExpectationType type) =>
    type == ExpectationType.topic ? 'Talking point' : 'Expectation';

/// Hides noise in activity / unread: never surface your own changelog rows, and never
/// show the initial "… created a new …" line back to the expectation author (even if
/// [sender_person_id] were wrong in legacy rows).
bool shouldSuppressChangelogForActivityViewer({
  required Expectation? expectation,
  required String authUserId,
  required String readerPersonId,
  required String? senderPersonId,
  required String messageText,
  required int messageType,
}) {
  if (expectation == null) return true;
  if (senderPersonId != null && senderPersonId == readerPersonId) {
    return true;
  }
  if (expectation.writerUserId == authUserId) {
    if (messageType != kExpectationMessageTypeChangelogPlain) return false;
    final lower = messageText.toLowerCase();
    // Legacy copy had a leading name; new copy is impersonal ("Created a new …").
    if (lower.contains('created a new expectation') ||
        lower.contains('created a new talking point')) {
      return true;
    }
  }
  return false;
}

/// Sets [last_read_at] to the latest changelog timestamp on this expectation (or now if none).
/// Returns false if the upsert failed (e.g. RLS / missing table).
Future<bool> syncExpectationChangelogReadWatermark({
  required SupabaseClient client,
  required String companyId,
  required String expectationId,
  required String readerPersonId,
}) async {
  final rows = await client
      .from('expectation_messages')
      .select('created_at')
      .eq('expectation_id', expectationId)
      .not('type', 'in', expectationMessageTypeChatRowsForPostgrestNotIn())
      .order('created_at', ascending: false)
      .limit(1);
  DateTime watermark;
  if ((rows as List).isEmpty) {
    watermark = DateTime.now().toUtc();
  } else {
    final raw = (rows.first as Map)['created_at'] as String?;
    watermark = DateTime.tryParse(raw ?? '')?.toUtc() ?? DateTime.now().toUtc();
  }
  try {
    await client.from('expectation_changelog_reads').upsert(
      {
        'company_id': companyId,
        'expectation_id': expectationId,
        'reader_person_id': readerPersonId,
        'last_read_at': watermark.toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'expectation_id,reader_person_id',
    );
    return true;
  } on PostgrestException {
    // Table or policy not deployed yet — ignore.
    return false;
  }
}

/// Result of scanning changelog messages vs read watermarks for party expectations.
class ChangelogUnreadPartySnapshot {
  const ChangelogUnreadPartySnapshot({
    required this.unreadMessageCount,
    required this.expectationIdsWithAnyUnread,
  });

  /// Rows counted for the activity bell badge (can be > distinct expectations).
  final int unreadMessageCount;

  /// Expectations that have at least one unread changelog row for this reader.
  final Set<String> expectationIdsWithAnyUnread;
}

/// Changelog rows from others after your last read watermark count as unread.
Future<ChangelogUnreadPartySnapshot> computeChangelogUnreadPartySnapshot({
  required SupabaseClient client,
  required String companyId,
  required String authUserId,
  required String readerPersonId,
  required List<Expectation> partyExpectations,
}) async {
  if (partyExpectations.isEmpty) {
    return ChangelogUnreadPartySnapshot(
      unreadMessageCount: 0,
      expectationIdsWithAnyUnread: {},
    );
  }
  final expSet = partyExpectations.map((e) => e.id).toSet();
  final expById = {for (final e in partyExpectations) e.id: e};
  Map<String, DateTime> readMap = {};
  try {
    final readRows = await client
        .from('expectation_changelog_reads')
        .select('expectation_id,last_read_at')
        .eq('reader_person_id', readerPersonId)
        .eq('company_id', companyId);
    for (final r in readRows as List) {
      final m = r as Map<String, dynamic>;
      final id = m['expectation_id'] as String?;
      final raw = m['last_read_at'] as String?;
      if (id == null || raw == null || !expSet.contains(id)) continue;
      readMap[id] =
          DateTime.tryParse(raw)?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  } on PostgrestException {
    readMap = {};
  }

  List<dynamic> msgRows;
  try {
    msgRows = await client
        .from('expectation_messages')
        .select('expectation_id,created_at,sender_person_id,message_text,type')
        .eq('company_id', companyId)
        .not('type', 'in', expectationMessageTypeChatRowsForPostgrestNotIn())
        .order('created_at', ascending: false)
        .limit(500) as List<dynamic>;
  } on PostgrestException {
    return ChangelogUnreadPartySnapshot(
      unreadMessageCount: 0,
      expectationIdsWithAnyUnread: {},
    );
  }

  var n = 0;
  final expUnread = <String>{};
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  for (final row in msgRows) {
    final m = row as Map<String, dynamic>;
    final expId = m['expectation_id'] as String?;
    if (expId == null || !expSet.contains(expId)) continue;
    final sender = m['sender_person_id'] as String?;
    final text = ((m['message_text'] as String?) ?? '').trim();
    final rawTy = m['type'];
    final msgType = rawTy is int
        ? rawTy
        : (rawTy is num ? rawTy.toInt() : int.tryParse('$rawTy') ?? kExpectationMessageTypeChangelogPlain);
    if (shouldSuppressChangelogForActivityViewer(
          expectation: expById[expId],
          authUserId: authUserId,
          readerPersonId: readerPersonId,
          senderPersonId: sender,
          messageText: text,
          messageType: msgType,
        )) {
      continue;
    }
    final raw = m['created_at'] as String?;
    if (raw == null) continue;
    final created = DateTime.tryParse(raw)?.toUtc() ?? epoch;
    final lastRead = readMap[expId] ?? epoch;
    if (created.isAfter(lastRead)) {
      n++;
      expUnread.add(expId);
    }
  }
  return ChangelogUnreadPartySnapshot(
    unreadMessageCount: n,
    expectationIdsWithAnyUnread: expUnread,
  );
}

/// Changelog rows from others after your last read watermark count as unread.
Future<int> countUnreadChangelogForPartyExpectations({
  required SupabaseClient client,
  required String companyId,
  required String authUserId,
  required String readerPersonId,
  required List<Expectation> partyExpectations,
}) async {
  final snap = await computeChangelogUnreadPartySnapshot(
    client: client,
    companyId: companyId,
    authUserId: authUserId,
    readerPersonId: readerPersonId,
    partyExpectations: partyExpectations,
  );
  return snap.unreadMessageCount;
}

Future<List<ExpectationActivityFeedItem>> loadChangelogActivityFeed({
  required SupabaseClient client,
  required String companyId,
  required String authUserId,
  required String readerPersonId,
  required List<Expectation> partyExpectations,
  int limit = 80,
}) async {
  if (partyExpectations.isEmpty) return [];
  final byId = {for (final e in partyExpectations) e.id: e};
  List<dynamic> rows;
  try {
    rows = await client
        .from('expectation_messages')
        .select(
          'id,expectation_id,message_text,created_at,sender_person_id,type,'
          // Disambiguate vs expectation_message_reads → people (reader).
          'people!expectation_messages_sender_person_id_fkey(display_name,handle)',
        )
        .eq('company_id', companyId)
        .not('type', 'in', expectationMessageTypeChatRowsForPostgrestNotIn())
        .order('created_at', ascending: false)
        .limit(200) as List<dynamic>;
  } on PostgrestException {
    return const [];
  }
  final out = <ExpectationActivityFeedItem>[];
  for (final raw in rows) {
    final r = raw as Map<String, dynamic>;
    final expId = r['expectation_id'] as String?;
    if (expId == null || !byId.containsKey(expId)) continue;
    final e = byId[expId];
    if (e == null) continue;
    final rawMsg = r['message_text'];
    final text = (rawMsg == null ? '' : '$rawMsg')
        .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
        .trim();
    final senderId = (r['sender_person_id'] as String?) ?? '';
    final rawTy = r['type'];
    final msgType = rawTy is int
        ? rawTy
        : (rawTy is num ? rawTy.toInt() : int.tryParse('$rawTy') ?? kExpectationMessageTypeChangelogPlain);
    final personObj = r['people'];
    final senderLabel = _senderLabelFromPeopleRow(personObj, senderId);
    if (shouldSuppressChangelogForActivityViewer(
          expectation: e,
          authUserId: authUserId,
          readerPersonId: readerPersonId,
          senderPersonId: senderId.isEmpty ? null : senderId,
          messageText: text,
          messageType: msgType,
        )) {
      continue;
    }
    final summary = e.summary;
    final displayText = expectationChangelogActivityFeedLine(
      messageType: msgType,
      messageText: text,
      expectationType: e.type,
    );
    out.add(
      ExpectationActivityFeedItem(
        messageId: r['id'] as String,
        expectationId: expId,
        senderPersonId: senderId,
        senderLabel: senderLabel,
        messageText: displayText,
        createdAt: DateTime.tryParse((r['created_at'] as String?) ?? '') ??
            DateTime.now().toUtc(),
        expectationSummarySnippet: _snippet(summary, maxLen: 52),
        kindLabel: _kindLabel(e.type),
        messageType: msgType,
        hashtags: activityFeedHashtagsFromSummary(summary),
      ),
    );
    if (out.length >= limit) break;
  }
  return out;
}
