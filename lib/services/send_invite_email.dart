import 'package:supabase_flutter/supabase_flutter.dart';

/// Sends the invite email via [send-invite-email] edge function.
/// Returns false if the invite row was created but email delivery failed.
Future<bool> sendInviteEmailForInviteId({
  required SupabaseClient client,
  required String inviteId,
}) async {
  try {
    final res = await client.functions.invoke(
      'send-invite-email',
      body: {'invite_id': inviteId},
    );
    final data = res.data;
    if (data is Map && data['sent'] == true) return true;
    return false;
  } on FunctionException {
    return false;
  } catch (_) {
    return false;
  }
}
