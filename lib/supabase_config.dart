import 'package:flutter/foundation.dart';

/// Debug runs (e.g. Cursor / IDE F5) use the staging host; profile & release use production.
///
/// Use **https** and **no trailing slash** so the client does not produce `//auth/v1/...`
/// and browsers are not blocked by mixed-content / insecure requests.
String get supabaseUrl =>
    kDebugMode ? 'https://leam.tauworks.org' : 'https://exled-be.tauworks.org';

/// True when talking to the leam staging stack (show "exled · dev" in the shell AppBar).
bool get supabaseIsLeamDevHost {
  final host = Uri.tryParse(supabaseUrl)?.host.toLowerCase() ?? '';
  return host == 'leam.tauworks.org';
}
