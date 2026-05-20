import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Override at build/run time, e.g.:
/// `flutter run -d chrome --dart-define=SUPABASE_URL=https://be.exled.app`
const _supabaseUrlOverride = String.fromEnvironment('SUPABASE_URL');

const String supabaseDevUrl = 'https://leam.tauworks.org';
const String supabaseProdUrl = 'https://be.exled.app';

const String supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNjEzMTQyMDcxLCJleHAiOjE5Mjg3MTMyNzF9.NC1GLG2-Ae8_vpynii0-Omd8qnQRlnZOd7ZWRsYoCE8';

const _debugBackendPrefsKey = 'debug_supabase_backend';

/// Staging (leam) vs production API host — debug-only runtime toggle.
enum SupabaseBackend { dev, prod }

/// Bumped after a debug backend switch so the app shell rebuilds on the new client.
final ValueNotifier<int> supabaseEnvironmentRevision = ValueNotifier(0);

SupabaseBackend? _debugBackend;

/// True when `--dart-define=SUPABASE_URL=...` pins the backend (hide debug switch).
bool get supabaseUrlOverrideLocked => _supabaseUrlOverride.isNotEmpty;

/// Debug runs may toggle dev/prod in the AppBar unless the URL is build-pinned.
bool get debugSupabaseBackendSwitchEnabled =>
    kDebugMode && !supabaseUrlOverrideLocked;

SupabaseBackend get debugSupabaseBackend {
  if (_debugBackend != null) return _debugBackend!;
  return kDebugMode ? SupabaseBackend.dev : SupabaseBackend.prod;
}

/// Load saved debug backend before [Supabase.initialize] in `main`.
Future<void> loadDebugSupabaseBackendPreference() async {
  if (!kDebugMode || supabaseUrlOverrideLocked) return;
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString(_debugBackendPrefsKey);
  _debugBackend = saved == 'prod' ? SupabaseBackend.prod : SupabaseBackend.dev;
}

/// Debug runs (e.g. Cursor / IDE F5) default to staging unless toggled to prod.
///
/// Use **https** and **no trailing slash** so the client does not produce `//auth/v1/...`
/// and browsers are not blocked by mixed-content / insecure requests.
String get supabaseUrl {
  if (_supabaseUrlOverride.isNotEmpty) {
    return _supabaseUrlOverride.replaceAll(RegExp(r'/+$'), '');
  }
  if (kDebugMode) {
    return debugSupabaseBackend == SupabaseBackend.dev
        ? supabaseDevUrl
        : supabaseProdUrl;
  }
  return supabaseProdUrl;
}

/// True when talking to the leam staging stack (show "exled · dev" in the shell AppBar).
bool get supabaseIsLeamDevHost {
  final host = Uri.tryParse(supabaseUrl)?.host.toLowerCase() ?? '';
  return host == 'leam.tauworks.org';
}

String supabaseBackendShortLabel(SupabaseBackend backend) =>
    backend == SupabaseBackend.dev ? 'Dev' : 'Prod';

/// Reconnect to another Supabase host (debug only). Signs out and re-initializes the client.
Future<void> switchDebugSupabaseBackend(SupabaseBackend backend) async {
  if (!debugSupabaseBackendSwitchEnabled) return;
  if (debugSupabaseBackend == backend) return;

  if (Supabase.instance.isInitialized) {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}
    await Supabase.instance.dispose();
  }

  _debugBackend = backend;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _debugBackendPrefsKey,
    backend == SupabaseBackend.prod ? 'prod' : 'dev',
  );

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  supabaseEnvironmentRevision.value++;
}
