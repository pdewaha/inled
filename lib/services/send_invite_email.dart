import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

const Duration inviteEmailInvokeTimeout = Duration(seconds: 20);

/// Sends the invite email via [send-invite-email] edge function.
/// Returns false if delivery failed or timed out — never blocks indefinitely.
Future<bool> sendInviteEmailForInviteId({
  required SupabaseClient client,
  required String inviteId,
}) async {
  try {
    final res = await client.functions
        .invoke(
          'send-invite-email',
          body: {'invite_id': inviteId},
        )
        .timeout(inviteEmailInvokeTimeout);
    final data = res.data;
    if (data is Map && data['sent'] == true) return true;
    return false;
  } on TimeoutException {
    return false;
  } on FunctionException {
    return false;
  } catch (_) {
    return false;
  }
}
