import 'package:exled/models/expectation.dart';
import 'package:exled/models/expectation_type.dart';
import 'package:exled/models/expectation_visibility.dart';
import 'package:exled/models/expectation_changelog_payload.dart';
import 'package:exled/utils/hashtag_normalize.dart';
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
  Set<String>? coReceiverPersonIds,
}) {
  if (e.writerUserId == authUserId) return true;
  // Shadow (private/draft): addressees and @mentions are not party until publish (echo).
  if (e.visibility == ExpectationVisibility.shadow) {
    return false;
  }
  final target = e.personId.trim();
  if (target.isNotEmpty && target == myPersonId) return true;
  if (coReceiverPersonIds != null && coReceiverPersonIds.contains(myPersonId)) {
    return true;
  }
  return false;
}

List<Expectation> expectationsPartyForPerson({
  required List<Expectation> expectations,
  required String authUserId,
  required String myPersonId,
  Map<String, Set<String>>? coReceiverPersonIdsByExpectationId,
}) {
  return expectations
      .where(
        (e) => expectationIsPartyForPerson(
          e: e,
          authUserId: authUserId,
          myPersonId: myPersonId,
          coReceiverPersonIds:
              coReceiverPersonIdsByExpectationId?[e.id],
        ),
      )
      .toList();
}

String _snippet(String summary, {int maxLen = 72}) {
  final t = summary.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.length <= maxLen) return t.isEmpty ? '—' : t;
  return '${t.substring(0, maxLen)}…';
}

/// Distinct hashtags from [summary], first occurrence order, lowercase body (no `#`).
List<String> activityFeedHashtagsFromSummary(String summary, {int max = 6}) {
  final seen = <String>{};
  final out = <String>[];
  for (final m in kHashtagInTextRegex.allMatches(summary)) {
    final t = normalizeHashtagToken(m.group(1) ?? '');
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

/// True when a changelog row is the initial "Created a new …" line (plain or legacy text).
bool activityFeedMessageIsInitialCreate({
  required int messageType,
  required String messageText,
  required ExpectationType expectationType,
}) {
  if (!expectationMessageTypeIsChangelog(messageType)) return false;
  final line = expectationChangelogActivityFeedLine(
    messageType: messageType,
    messageText: messageText,
    expectationType: expectationType,
  );
  final lower = line.toLowerCase();
  return lower.contains('created a new expectation') ||
      lower.contains('created a new talking point');
}

/// True when changelog is "Published this expectation" (mention row covers receivers).
bool activityFeedMessageIsExpectationPublished({
  required int messageType,
  required String messageText,
  required ExpectationType expectationType,
}) {
  if (expectationType == ExpectationType.topic) return false;
  if (!expectationMessageTypeIsChangelog(messageType)) return false;
  if (messageType == kExpectationMessageTypeChangelogPublished) return true;
  final line = expectationChangelogActivityFeedLine(
    messageType: messageType,
    messageText: messageText,
    expectationType: expectationType,
  );
  return line.toLowerCase().contains('published this expectation');
}

bool _feedLineIsReceiverRedundantChangelog(String displayLine) {
  final lower = displayLine.toLowerCase();
  return lower.contains('created a new expectation') ||
      lower.contains('created a new talking point') ||
      lower.contains('published this expectation');
}

bool _readerIsExpectationReceiver({
  required Expectation expectation,
  required String readerPersonId,
  required Set<String> mentionExpectationIds,
}) {
  if (expectation.type == ExpectationType.topic) return false;
  if (expectation.personId.trim() == readerPersonId) return true;
  return mentionExpectationIds.contains(expectation.id);
}

/// Loads expectation ids where [readerPersonId] has an expectation_mentions row.
Future<Set<String>> expectationIdsWhereReaderIsMentioned({
  required SupabaseClient client,
  required String companyId,
  required String readerPersonId,
}) async {
  try {
    final rows = await client
        .from('expectation_mentions')
        .select('expectation_id')
        .eq('company_id', companyId)
        .eq('mentioned_person_id', readerPersonId);
    final out = <String>{};
    for (final raw in rows as List) {
      if (raw is! Map) continue;
      final id = (raw['expectation_id'] as String?)?.trim() ?? '';
      if (id.isNotEmpty) out.add(id);
    }
    return out;
  } on PostgrestException {
    return {};
  }
}

/// Bell list: receivers keep mention rows; drop matching create/publish changelog duplicates.
List<ExpectationActivityFeedItem> mergeActivityFeedChangelogAndMentions({
  required List<ExpectationActivityFeedItem> changelog,
  required List<ExpectationActivityFeedItem> mentions,
}) {
  final mentionExpectationIds = {for (final m in mentions) m.expectationId};
  final filteredChangelog = changelog.where((item) {
    if (!mentionExpectationIds.contains(item.expectationId)) return true;
    return !_feedLineIsReceiverRedundantChangelog(item.messageText);
  }).toList();
  final merged = [...filteredChangelog, ...mentions]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return merged;
}

/// Hides noise in activity / unread: never surface your own changelog rows, and hide
/// create/publish handoff lines from receivers (mention row is the notification).
bool shouldSuppressChangelogForActivityViewer({
  required Expectation? expectation,
  required String authUserId,
  required String readerPersonId,
  required String? senderPersonId,
  required String messageText,
  required int messageType,
  Set<String> mentionExpectationIds = const {},
}) {
  if (expectation == null) return true;
  if (senderPersonId != null && senderPersonId == readerPersonId) {
    return true;
  }
  final isAuthor =
      expectation.writerUserId != null &&
      expectation.writerUserId == authUserId;
  if (!isAuthor &&
      _readerIsExpectationReceiver(
        expectation: expectation,
        readerPersonId: readerPersonId,
        mentionExpectationIds: mentionExpectationIds,
      )) {
    if (activityFeedMessageIsInitialCreate(
      messageType: messageType,
      messageText: messageText,
      expectationType: expectation.type,
    )) {
      return true;
    }
    if (activityFeedMessageIsExpectationPublished(
      messageType: messageType,
      messageText: messageText,
      expectationType: expectation.type,
    )) {
      return true;
    }
  }
  return false;
}

/// Sets [last_read_at] to the latest activity timestamp for this expectation (changelog
/// and @mention rows for [readerPersonId]), or now when there is none.
/// Returns false if the upsert failed (e.g. RLS / missing table).
Future<bool> syncExpectationChangelogReadWatermark({
  required SupabaseClient client,
  required String companyId,
  required String expectationId,
  required String readerPersonId,
}) async {
  var watermark = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  void bumpWatermark(DateTime? candidate) {
    if (candidate == null) return;
    final u = candidate.toUtc();
    if (u.isAfter(watermark)) watermark = u;
  }

  final changelogRows = await client
      .from('expectation_messages')
      .select('created_at')
      .eq('expectation_id', expectationId)
      .not('type', 'in', expectationMessageTypeChatRowsForPostgrestNotIn())
      .order('created_at', ascending: false)
      .limit(1);
  if ((changelogRows as List).isNotEmpty) {
    final raw = (changelogRows.first as Map)['created_at'] as String?;
    bumpWatermark(DateTime.tryParse(raw ?? ''));
  }

  try {
    final mentionRows = await client
        .from('expectation_mentions')
        .select('created_at')
        .eq('company_id', companyId)
        .eq('expectation_id', expectationId)
        .eq('mentioned_person_id', readerPersonId)
        .order('created_at', ascending: false)
        .limit(1);
    if ((mentionRows as List).isNotEmpty) {
      final raw = (mentionRows.first as Map)['created_at'] as String?;
      bumpWatermark(DateTime.tryParse(raw ?? ''));
    }
  } on PostgrestException {
    // Mentions table / policy not deployed yet.
  }

  if (!watermark.isAfter(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))) {
    watermark = DateTime.now().toUtc();
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

/// Result of scanning activity (changelog + @mention rows) vs read watermarks.
class ChangelogUnreadPartySnapshot {
  const ChangelogUnreadPartySnapshot({
    required this.unreadMessageCount,
    required this.expectationIdsWithAnyUnread,
  });

  /// Rows counted for the activity bell badge (can be > distinct expectations).
  final int unreadMessageCount;

  /// Expectations with unread activity for this reader.
  final Set<String> expectationIdsWithAnyUnread;
}

Map<String, dynamic>? _embeddedRowFromJoin(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is List && value.isNotEmpty) {
    final first = value.first;
    if (first is Map<String, dynamic>) return first;
    if (first is Map) return Map<String, dynamic>.from(first);
  }
  return null;
}

/// Changelog + mention rows after [expectation_changelog_reads] watermarks count as unread.
Future<ChangelogUnreadPartySnapshot> computeChangelogUnreadPartySnapshot({
  required SupabaseClient client,
  required String companyId,
  required String authUserId,
  required String readerPersonId,
  required List<Expectation> partyExpectations,
  Set<String> bellClearedExpectationIds = const {},
}) async {
  final expSet = partyExpectations.map((e) => e.id).toSet();
  final expById = {for (final e in partyExpectations) e.id: e};
  final mentionExpectationIds = await expectationIdsWhereReaderIsMentioned(
    client: client,
    companyId: companyId,
    readerPersonId: readerPersonId,
  );
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
      if (id == null || raw == null) continue;
      readMap[id] =
          DateTime.tryParse(raw)?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  } on PostgrestException {
    readMap = {};
  }

  List<dynamic> msgRows = [];
  try {
    msgRows = await client
        .from('expectation_messages')
        .select('expectation_id,created_at,sender_person_id,message_text,type')
        .eq('company_id', companyId)
        .not('type', 'in', expectationMessageTypeChatRowsForPostgrestNotIn())
        .order('created_at', ascending: false)
        .limit(500) as List<dynamic>;
  } on PostgrestException {
    msgRows = [];
  }

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
          mentionExpectationIds: mentionExpectationIds,
        )) {
      continue;
    }
    final raw = m['created_at'] as String?;
    if (raw == null) continue;
    final created = DateTime.tryParse(raw)?.toUtc() ?? epoch;
    final lastRead = readMap[expId] ?? epoch;
    if (created.isAfter(lastRead)) {
      expUnread.add(expId);
    }
  }

  try {
    final mentionRows = await client
        .from('expectation_mentions')
        .select(
          'created_at,expectation_id,'
          'expectations!inner(expectation_visibility,expectation_type,writer_user_id)',
        )
        .eq('company_id', companyId)
        .eq('mentioned_person_id', readerPersonId)
        .order('created_at', ascending: false)
        .limit(200) as List<dynamic>;
    for (final row in mentionRows) {
      if (row is! Map<String, dynamic>) continue;
      final expId = row['expectation_id'] as String?;
      if (expId == null || bellClearedExpectationIds.contains(expId)) continue;
      final embedded = _embeddedRowFromJoin(row['expectations']);
      if (embedded == null) continue;
      // Your own talking point / expectation should never light up your bell.
      final writerUserId = (embedded['writer_user_id'] as String?)?.trim();
      if (writerUserId != null && writerUserId == authUserId) continue;
      final visIdx = embedded['expectation_visibility'];
      final visibility = visIdx is int
          ? visIdx
          : (visIdx is num ? visIdx.toInt() : int.tryParse('$visIdx'));
      if (visibility == ExpectationVisibility.shadow.index) continue;
      if (visibility != ExpectationVisibility.echo.index) continue;
      final raw = row['created_at'] as String?;
      if (raw == null) continue;
      final created = DateTime.tryParse(raw)?.toUtc() ?? epoch;
      final lastRead = readMap[expId] ?? epoch;
      if (created.isAfter(lastRead)) {
        expUnread.add(expId);
      }
    }
  } on PostgrestException {
    // Table / policy not deployed yet.
  }

  // Bell badge: distinct expectations with unread activity (not per changelog row).
  return ChangelogUnreadPartySnapshot(
    unreadMessageCount: expUnread.length,
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
  final mentionExpectationIds = await expectationIdsWhereReaderIsMentioned(
    client: client,
    companyId: companyId,
    readerPersonId: readerPersonId,
  );
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
          mentionExpectationIds: mentionExpectationIds,
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
