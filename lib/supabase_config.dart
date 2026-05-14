import 'package:flutter/foundation.dart';

/// Debug runs (e.g. Cursor / IDE F5) use the staging host; profile & release use production.
String get supabaseUrl =>
    kDebugMode ? 'http://leam.tauworks.org/' : 'http://exled.tauworks.org/';

/// True when talking to the leam staging stack (show "ExLed - dev" in the shell AppBar).
bool get supabaseIsLeamDevHost {
  final host = Uri.tryParse(supabaseUrl)?.host.toLowerCase() ?? '';
  return host == 'leam.tauworks.org';
}
