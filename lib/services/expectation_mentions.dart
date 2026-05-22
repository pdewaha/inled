import 'package:exled/models/expectation.dart';
import 'package:exled/models/expectation_type.dart';
import 'package:exled/models/expectation_visibility.dart';
import 'package:exled/models/person.dart';
import 'package:exled/services/expectation_activity_feed.dart';
import 'package:exled/utils/person_display.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final RegExp expectationMentionHandleRe = RegExp(r'@([a-zA-Z0-9._-]+)');

final RegExp _leadingMentionTokenRegex =
    RegExp(r'^\s*@([a-zA-Z0-9._-]+)\b\s*');

/// Removes a leading run of @mentions (`@a @b @c …`); @mentions later in text stay.
String stripLeadingMentionBurst(String text) {
  var t = text.trim();
  while (_leadingMentionTokenRegex.hasMatch(t)) {
    t = t.replaceFirst(_leadingMentionTokenRegex, '');
  }
  return t.trim();
}

/// Index of @handles and mentioned person ids per expectation.
class ExpectationMentionsIndex {
  ExpectationMentionsIndex({
    Map<String, List<String>>? handlesByExpectationId,
    Map<String, Set<String>>? personIdsByExpectationId,
  })  : handlesByExpectationId =
            handlesByExpectationId ?? <String, List<String>>{},
        personIdsByExpectationId =
            personIdsByExpectationId ?? <String, Set<String>>{};

  final Map<String, List<String>> handlesByExpectationId;
  final Map<String, Set<String>> personIdsByExpectationId;

  static ExpectationMentionsIndex empty() => ExpectationMentionsIndex();
}

/// Distinct @handles in [text], first occurrence order (case-insensitive dedupe).
List<String> extractMentionHandlesFromText(String text) {
  final seen = <String>{};
  final out = <String>[];
  for (final m in expectationMentionHandleRe.allMatches(text)) {
    final h = (m.group(1) ?? '').trim();
    if (h.isEmpty) continue;
    final key = h.toLowerCase();
    if (seen.add(key)) out.add(h);
  }
  return out;
}

/// All @handles for a talking point: persisted rows plus any still in [summary].
List<String> talkingPointMentionHandleList({
  required String summary,
  Iterable<String> persistedMentionHandles = const [],
}) {
  final seen = <String>{};
  final out = <String>[];
  void add(String raw) {
    final h = raw.trim();
    if (h.isEmpty) return;
    final k = h.toLowerCase();
    if (seen.add(k)) out.add(h);
  }

  for (final h in persistedMentionHandles) {
    add(h);
  }
  for (final h in extractMentionHandlesFromText(summary)) {
    add(h);
  }
  return out;
}

/// Expectation receivers: primary person + persisted @rows + any @ still in [summary].
List<String> expectationReceiverHandleList({
  required String summary,
  String? primaryPersonHandle,
  Iterable<String> persistedMentionHandles = const [],
}) {
  final seen = <String>{};
  final out = <String>[];
  void add(String raw) {
    final h = raw.trim();
    if (h.isEmpty) return;
    final k = h.toLowerCase();
    if (seen.add(k)) out.add(h);
  }

  add(primaryPersonHandle ?? '');
  for (final h in persistedMentionHandles) {
    add(h);
  }
  for (final h in extractMentionHandlesFromText(summary)) {
    add(h);
  }
  return out;
}

/// List-tile header for talking points: `@a @b` when cited, else [fallback].
String talkingPointMentionWhoLabel(
  String summary, {
  Iterable<String> persistedMentionHandles = const [],
  Iterable<String> persistedMentionPersonIds = const [],
  Map<String, Person> peopleById = const {},
  String fallback = kLedgerAllMentionLabel,
}) {
  final seen = <String>{};
  final out = <String>[];
  void addHandle(String raw) {
    final h = raw.trim();
    if (h.isEmpty) return;
    final k = h.toLowerCase();
    if (seen.add(k)) out.add(h);
  }

  for (final h in talkingPointMentionHandleList(
    summary: summary,
    persistedMentionHandles: persistedMentionHandles,
  )) {
    addHandle(h);
  }
  for (final id in persistedMentionPersonIds) {
    final h = peopleById[id.trim()]?.handle.trim() ?? '';
    if (h.isNotEmpty) addHandle(h);
  }
  if (out.isEmpty) return fallback;
  return out.map((h) => '@$h').join(' ');
}

/// Expectation list/detail receivers: linked person, co-@mentions, or [@All].
String expectationReceiverWhoLabel({
  required String summary,
  String? personDisplayName,
  String? personHandle,
  String personId = '',
  Iterable<String> persistedMentionHandles = const [],
}) {
  final handles = expectationReceiverHandleList(
    summary: summary,
    primaryPersonHandle: personHandle,
    persistedMentionHandles: persistedMentionHandles,
  );
  if (handles.isNotEmpty) {
    return handles.map((h) => '@$h').join(' ');
  }
  final name = (personDisplayName ?? '').trim();
  if (name.isNotEmpty) return name;
  final handle = (personHandle ?? '').trim();
  if (handle.isNotEmpty) return handle;
  if (personId.trim().isNotEmpty) return personId.trim();
  return kLedgerAllMentionLabel;
}

bool expectationAppliesToPerson({
  required Expectation e,
  required String myPersonId,
  ExpectationMentionsIndex? mentionsIndex,
}) {
  if (e.personId.trim() == myPersonId) return true;
  // Private prep talking points: @mentions are not receivers until published (echo).
  if (e.type == ExpectationType.topic &&
      e.visibility == ExpectationVisibility.shadow) {
    return false;
  }
  final co = mentionsIndex?.personIdsByExpectationId[e.id];
  if (co != null && co.contains(myPersonId)) return true;
  return false;
}

/// Record @mentions from the **capture line** (before leading @ is stripped from summary).
Future<void> syncTalkingPointMentions({
  required SupabaseClient client,
  required String companyId,
  required String expectationId,
  required String summary,
  required String authorPersonId,
  required List<Person> people,
  required Future<Person?> Function(String handle) resolveMe,
  required Future<Person> Function(String handle) createPlaceholder,
  bool replaceExisting = false,
}) async {
  await _syncMentionsFromText(
    client: client,
    companyId: companyId,
    expectationId: expectationId,
    summary: summary,
    authorPersonId: authorPersonId,
    people: people,
    resolveMe: resolveMe,
    createMe: resolveMe,
    createPlaceholder: createPlaceholder,
    replaceExisting: replaceExisting,
  );
}

/// Expectation receivers (@Marc @John …): first @ → [target_person_id], rest → [expectation_mentions].
Future<void> syncExpectationCoReceiverMentions({
  required SupabaseClient client,
  required String companyId,
  required String expectationId,
  required String mentionSourceText,
  required String authorPersonId,
  required List<Person> people,
  required Future<Person?> Function(String handle) resolveMe,
  required Future<Person> Function(String handle) createPlaceholder,
  bool replaceExisting = true,
}) async {
  final handles = extractMentionHandlesFromText(mentionSourceText);
  if (handles.isEmpty) return;

  final byHandle = {for (final p in people) p.handle.toLowerCase(): p};
  final resolved = <Person>[];
  for (final raw in handles) {
    Person? person;
    if (raw.toLowerCase() == 'me') {
      person = await resolveMe(raw);
    } else {
      person = byHandle[raw.toLowerCase()];
      person ??= await createPlaceholder(raw);
    }
    if (person != null) resolved.add(person);
  }
  if (resolved.isEmpty) return;

  final primary = resolved.first;
  try {
    await client
        .from('expectations')
        .update({'target_person_id': primary.id})
        .eq('company_id', companyId)
        .eq('id', expectationId);
  } on PostgrestException {
    // RLS / column not writable.
  }

  if (replaceExisting) {
    try {
      await client
          .from('expectation_mentions')
          .delete()
          .eq('company_id', companyId)
          .eq('expectation_id', expectationId);
    } on PostgrestException {
      // Table / policy not deployed yet.
    }
  }

  final coReceiverIds = <String>{};
  for (var i = 1; i < resolved.length; i++) {
    final p = resolved[i];
    if (p.id == authorPersonId) continue;
    if (p.id == primary.id) continue;
    coReceiverIds.add(p.id);
  }

  for (final personId in coReceiverIds) {
    try {
      await client.from('expectation_mentions').insert({
        'company_id': companyId,
        'expectation_id': expectationId,
        'mentioned_person_id': personId,
      });
    } on PostgrestException {
      // Duplicate or table not deployed yet.
    }
  }
}

Future<void> _syncMentionsFromText({
  required SupabaseClient client,
  required String companyId,
  required String expectationId,
  required String summary,
  required String authorPersonId,
  required List<Person> people,
  required Future<Person?> Function(String handle) resolveMe,
  required Future<Person?> Function(String handle) createMe,
  required Future<Person> Function(String handle) createPlaceholder,
  required bool replaceExisting,
}) async {
  final handles = extractMentionHandlesFromText(summary);
  if (handles.isEmpty) return;

  if (replaceExisting) {
    try {
      await client
          .from('expectation_mentions')
          .delete()
          .eq('company_id', companyId)
          .eq('expectation_id', expectationId);
    } on PostgrestException {
      // Table / policy not deployed yet.
    }
  }

  final byHandle = {for (final p in people) p.handle.toLowerCase(): p};
  final mentionedIds = <String>{};

  for (final raw in handles) {
    Person? person;
    if (raw.toLowerCase() == 'me') {
      person = await createMe(raw);
    } else {
      person = byHandle[raw.toLowerCase()];
      person ??= await createPlaceholder(raw);
    }
    if (person == null) continue;
    if (person.id == authorPersonId) continue;
    mentionedIds.add(person.id);
  }

  for (final personId in mentionedIds) {
    try {
      await client.from('expectation_mentions').insert({
        'company_id': companyId,
        'expectation_id': expectationId,
        'mentioned_person_id': personId,
      });
    } on PostgrestException {
      // Duplicate or table not deployed yet.
    }
  }
}

/// @handles and mentioned person ids per expectation.
Future<ExpectationMentionsIndex> loadMentionHandlesByExpectationId({
  required SupabaseClient client,
  required String companyId,
  required Iterable<String> expectationIds,
  required Map<String, Person> peopleById,
}) async {
  final ids = expectationIds.where((id) => id.trim().isNotEmpty).toList();
  if (ids.isEmpty) {
    return ExpectationMentionsIndex.empty();
  }

  try {
    final rows = await client
        .from('expectation_mentions')
        .select(
          'expectation_id,mentioned_person_id,'
          'people!expectation_mentions_mentioned_person_id_fkey(handle)',
        )
        .eq('company_id', companyId)
        .inFilter('expectation_id', ids);

    final handles = <String, List<String>>{};
    final personIds = <String, Set<String>>{};
    for (final raw in rows as List) {
      if (raw is! Map) continue;
      final expId = (raw['expectation_id'] as String?)?.trim() ?? '';
      if (expId.isEmpty) continue;
      final mentionedPersonId =
          (raw['mentioned_person_id'] as String?)?.trim() ?? '';
      if (mentionedPersonId.isNotEmpty) {
        personIds.putIfAbsent(expId, () => <String>{}).add(mentionedPersonId);
      }
      final personObj = raw['people'];
      String? handle;
      if (personObj is Map) {
        handle = (personObj['handle'] as String?)?.trim();
      }
      handle ??= peopleById[mentionedPersonId]?.handle.trim();
      if (handle == null || handle.isEmpty) continue;
      handles.putIfAbsent(expId, () => <String>[]);
      final list = handles[expId]!;
      if (!list.any((h) => h.toLowerCase() == handle!.toLowerCase())) {
        list.add(handle);
      }
    }
    return ExpectationMentionsIndex(
      handlesByExpectationId: handles,
      personIdsByExpectationId: personIds,
    );
  } on PostgrestException {
    return ExpectationMentionsIndex.empty();
  }
}

/// Expectations where [myPersonId] is @mentioned (talking points + co-receiver expectations).
Future<List<Expectation>> fetchExpectationsMentioningPerson({
  required SupabaseClient client,
  required String companyId,
  required String myPersonId,
  required Expectation Function(Map<String, dynamic> row) mapRow,
}) async {
  try {
    final rows = await client
        .from('expectation_mentions')
        .select(
          'created_at,'
          'expectations!inner('
          'id,created_at,writer_user_id,target_person_id,summary,deadline_label,'
          'deadline_at,finished_at,responsible_updated_at,published_at,seen_at,'
          'last_chatted_sender_at,last_chatted_receiver_at,update_requested_at,'
          'progress,expectation_status,expectation_health,expectation_visibility,'
          'expectation_type)',
        )
        .eq('company_id', companyId)
        .eq('mentioned_person_id', myPersonId)
        .order('created_at', ascending: false)
        .limit(100) as List<dynamic>;
    final out = <Expectation>[];
    final seen = <String>{};
    for (final raw in rows) {
      if (raw is! Map<String, dynamic>) continue;
      final expMap = _embeddedExpectationRow(raw['expectations']);
      if (expMap == null) continue;
      final id = _mentionDbString(expMap['id']);
      if (id.isEmpty || !seen.add(id)) continue;
      final type = _mentionDbInt(expMap['expectation_type']);
      final visibility = _mentionDbInt(expMap['expectation_visibility']);
      if (type == ExpectationType.topic.index) {
        if (visibility != ExpectationVisibility.echo.index) continue;
      } else if (type == ExpectationType.expectation.index) {
        if (visibility != ExpectationVisibility.echo.index) continue;
      } else {
        continue;
      }
      out.add(mapRow(expMap));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

Map<String, dynamic>? _embeddedExpectationRow(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is List && value.isNotEmpty) {
    final first = value.first;
    if (first is Map<String, dynamic>) return first;
    if (first is Map) return Map<String, dynamic>.from(first);
  }
  return null;
}

String _mentionDbString(dynamic value, {String fallback = ''}) {
  if (value == null) return fallback;
  if (value is String) return value;
  return value.toString();
}

int _mentionDbInt(dynamic value, {int fallback = 0}) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? fallback;
}

/// Activity feed rows for @mentions on talking points and co-receiver expectations.
Future<List<ExpectationActivityFeedItem>> loadTalkingPointMentionActivityFeed({
  required SupabaseClient client,
  required String companyId,
  required String readerPersonId,
  required List<Expectation> partyExpectations,
  required String Function(Expectation expectation) authorLabel,
  int limit = 40,
}) async {
  try {
    final rows = await client
        .from('expectation_mentions')
        .select(
          'id,created_at,expectation_id,'
          'expectations!inner(summary,expectation_type,expectation_visibility,writer_user_id)',
        )
        .eq('company_id', companyId)
        .eq('mentioned_person_id', readerPersonId)
        .order('created_at', ascending: false)
        .limit(100) as List<dynamic>;

    final byId = {for (final e in partyExpectations) e.id: e};
    final out = <ExpectationActivityFeedItem>[];
    for (final raw in rows) {
      if (raw is! Map<String, dynamic>) continue;
      final expId = _mentionDbString(raw['expectation_id']);
      if (expId.isEmpty) continue;
      final exp = _embeddedExpectationRow(raw['expectations']);
      if (exp == null) continue;
      final type = _mentionDbInt(exp['expectation_type']);
      final visibility = _mentionDbInt(exp['expectation_visibility']);
      if (visibility != ExpectationVisibility.echo.index) continue;
      final e = byId[expId];
      if (e == null) continue;
      final summary = _mentionDbString(exp['summary'], fallback: e.summary);
      final created =
          DateTime.tryParse(_mentionDbString(raw['created_at'])) ?? e.createdAt;
      final isTopic = type == ExpectationType.topic.index;
      out.add(
        ExpectationActivityFeedItem(
          messageId: 'mention_${_mentionDbString(raw['id'])}',
          expectationId: expId,
          senderPersonId: '',
          senderLabel: authorLabel(e),
          messageText: isTopic
              ? 'You were mentioned in a public talking point'
              : 'You were added as a receiver on an expectation',
          createdAt: created,
          expectationSummarySnippet: activityFeedEllipsis(summary, 52),
          kindLabel: isTopic ? 'Talking point' : 'Expectation',
          hashtags: activityFeedHashtagsFromSummary(summary),
        ),
      );
      if (out.length >= limit) break;
    }
    return out;
  } catch (_) {
    return const [];
  }
}

List<Expectation> mergePartyExpectationsWithMentions({
  required List<Expectation> party,
  required List<Expectation> mentioned,
}) {
  final byId = {for (final e in party) e.id: e};
  final merged = List<Expectation>.from(party);
  for (final e in mentioned) {
    if (!byId.containsKey(e.id)) {
      merged.add(e);
      byId[e.id] = e;
    }
  }
  return merged;
}
