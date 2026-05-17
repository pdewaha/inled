import 'package:flutter/foundation.dart';

/// Override at build/run time, e.g.:
/// `flutter run -d chrome --dart-define=SUPABASE_URL=https://exled-be.tauworks.org`
const _supabaseUrlOverride = String.fromEnvironment('SUPABASE_URL');

/// Debug runs (e.g. Cursor / IDE F5) use the staging host; profile & release use production.
///
/// Use **https** and **no trailing slash** so the client does not produce `//auth/v1/...`
/// and browsers are not blocked by mixed-content / insecure requests.
///
/// **Web on localhost:** the API host must allow your origin in CORS (Kong / GoTrue /
/// Supabase Auth URL settings), e.g. `http://localhost:8080`. Otherwise use
/// `--dart-define=SUPABASE_URL=...` to point at a backend that does, or run `-d windows`.
String get supabaseUrl {
  if (_supabaseUrlOverride.isNotEmpty) {
    return _supabaseUrlOverride.replaceAll(RegExp(r'/+$'), '');
  }
  return kDebugMode ? 'https://leam.tauworks.org' : 'https://exled-be.tauworks.org';
}

/// True when talking to the leam staging stack (show "exled · dev" in the shell AppBar).
bool get supabaseIsLeamDevHost {
  final host = Uri.tryParse(supabaseUrl)?.host.toLowerCase() ?? '';
  return host == 'leam.tauworks.org';
}
