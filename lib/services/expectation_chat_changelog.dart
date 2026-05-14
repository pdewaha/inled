import 'package:supabase_flutter/supabase_flutter.dart';

/// Stored on [expectation_messages.type]; chat vs activity/changelog rows.
const int kExpectationMessageTypeChat = 0;

/// Chat row that includes at least one file attachment ([message_text] may be empty).
/// Excluded from changelog watermarks and the cross-expectation activity feed like [kExpectationMessageTypeChat].
const int kExpectationMessageTypeChatWithAttachment = 2;

/// Legacy and plain one-line changelog ([message_text] is human-readable prose).
const int kExpectationMessageTypeChangelogPlain = 1;

/// Structured changelog: [message_text] is JSON (see [expectation_changelog_payload.dart]).
const int kExpectationMessageTypeChangelogDescription = 10;
const int kExpectationMessageTypeChangelogDeadline = 11;
const int kExpectationMessageTypeChangelogFields = 12;
const int kExpectationMessageTypeChangelogVisibility = 13;
const int kExpectationMessageTypeChangelogPublished = 14;
const int kExpectationMessageTypeChangelogUpdateRequested = 15;

/// Backwards-compatible name for [kExpectationMessageTypeChangelogPlain].
const int kExpectationMessageTypeChangelog = kExpectationMessageTypeChangelogPlain;

/// Types that are normal conversation (not expectation activity / structured changelog).
bool expectationMessageTypeIsChatRow(int type) =>
    type == kExpectationMessageTypeChat ||
    type == kExpectationMessageTypeChatWithAttachment;

/// Values for [PostgrestFilterBuilder.not] `in` — rows that must **not** count as changelog.
List<int> expectationMessageTypeChatRowsForPostgrestNotIn() => const [
  kExpectationMessageTypeChat,
  kExpectationMessageTypeChatWithAttachment,
];

/// Every row that is not a chat variant is treated as changelog for watermarks, unread, and activity feed.
bool expectationMessageTypeIsChangelog(int type) => !expectationMessageTypeIsChatRow(type);

String expectationChangelogActorLabel({
  String? displayName,
  String? handle,
}) {
  final dn = (displayName ?? '').trim();
  if (dn.isNotEmpty) return dn;
  final h = (handle ?? '').trim();
  if (h.isNotEmpty) return '@$h';
  return 'Someone';
}

class ExpectationChangelogActorContext {
  const ExpectationChangelogActorContext({
    required this.personId,
    required this.companyId,
    required this.actorLabel,
  });

  final String personId;
  final String companyId;
  final String actorLabel;
}

Future<ExpectationChangelogActorContext?> fetchExpectationChangelogActorContext(
  SupabaseClient client,
) async {
  final user = client.auth.currentUser;
  if (user == null) return null;
  final meRows = await client
      .from('people')
      .select('id,company_id,display_name,handle')
      .eq('auth_user_id', user.id)
      .limit(1);
  if ((meRows as List).isEmpty) return null;
  final me = meRows.first as Map<String, dynamic>;
  return ExpectationChangelogActorContext(
    personId: me['id'] as String,
    companyId: me['company_id'] as String,
    actorLabel: expectationChangelogActorLabel(
      displayName: me['display_name'] as String?,
      handle: me['handle'] as String?,
    ),
  );
}

/// Inserts a message row. Requires deployed [expectation_messages.type] (migration 001).
Future<String> insertExpectationAppMessage({
  required SupabaseClient client,
  required String companyId,
  required String expectationId,
  required String senderPersonId,
  required String messageText,
  required int type,
}) async {
  final inserted = await client
      .from('expectation_messages')
      .insert({
        'company_id': companyId,
        'expectation_id': expectationId,
        'sender_person_id': senderPersonId,
        'type': type,
        'message_text': messageText,
      })
      .select('id')
      .single();
  return inserted['id'] as String;
}

Future<void> touchExpectationChatActivityForAuthUser({
  required SupabaseClient client,
  required String expectationId,
  required String? expectationWriterUserId,
}) async {
  final uid = client.auth.currentUser?.id;
  if (uid == null) return;
  final nowIso = DateTime.now().toUtc().toIso8601String();
  final isWriter =
      expectationWriterUserId != null && expectationWriterUserId == uid;
  await client.from('expectations').update({
    if (isWriter) 'last_chatted_sender_at': nowIso,
    if (!isWriter) 'last_chatted_receiver_at': nowIso,
  }).eq('id', expectationId);
}

/// Best-effort: logs should not roll back core expectation writes.
Future<void> appendExpectationChangelogForSignedInUser({
  required SupabaseClient client,
  required String expectationId,
  required String? expectationWriterUserId,
  required String Function(String actorLabel) messageBuilder,
}) async {
  final ctx = await fetchExpectationChangelogActorContext(client);
  if (ctx == null) return;
  final text = messageBuilder(ctx.actorLabel);
  try {
    await insertExpectationAppMessage(
      client: client,
      companyId: ctx.companyId,
      expectationId: expectationId,
      senderPersonId: ctx.personId,
      messageText: text,
      type: kExpectationMessageTypeChangelog,
    );
    await touchExpectationChatActivityForAuthUser(
      client: client,
      expectationId: expectationId,
      expectationWriterUserId: expectationWriterUserId,
    );
  } catch (_) {}
}

/// Marks chat messages sent by the counterparty as read by [viewerPersonId] (opening the thread).
/// Idempotent. Deploy [expectation_message_reads] + RLS for this to succeed.
Future<void> markExpectationPeerChatMessagesRead({
  required SupabaseClient client,
  required String companyId,
  required String viewerPersonId,
  required List<String> peerMessageIds,
}) async {
  final ids = peerMessageIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
  if (ids.isEmpty) return;
  final now = DateTime.now().toUtc().toIso8601String();
  final rows = ids
      .map(
        (id) => <String, dynamic>{
          'company_id': companyId,
          'message_id': id,
          'reader_person_id': viewerPersonId,
          'read_at': now,
        },
      )
      .toList();
  try {
    await client.from('expectation_message_reads').upsert(
          rows,
          onConflict: 'message_id,reader_person_id',
          ignoreDuplicates: true,
        );
  } on PostgrestException {
    // Table or policy not deployed yet.
  }
}
