import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:inled/screens/auth_welcome_screen.dart';
import 'package:inled/screens/company_onboarding_gate.dart';
import 'package:inled/supabase_config.dart';
import 'package:inled/theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: supabaseUrl,
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNjEzMTQyMDcxLCJleHAiOjE5Mjg3MTMyNzF9.NC1GLG2-Ae8_vpynii0-Omd8qnQRlnZOd7ZWRsYoCE8',
  );
  runApp(const InledApp());
}

class InledApp extends StatefulWidget {
  const InledApp({super.key});

  @override
  State<InledApp> createState() => _InledAppState();
}

class _InledAppState extends State<InledApp> {
  AppThemeVariant _variant = AppThemeVariant.dark;

  @override
  Widget build(BuildContext context) {
    final auth = Supabase.instance.client.auth;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'inled',
      theme: _variant.themeData,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [
        Locale('en'),
        Locale('en', 'GB'),
        Locale('en', 'US'),
        Locale('de'),
        Locale('de', 'AT'),
        Locale('de', 'CH'),
        Locale('fr'),
        Locale('fr', 'CH'),
        Locale('nl'),
        Locale('nl', 'BE'),
        Locale('es'),
        Locale('it'),
        Locale('pt'),
        Locale('pl'),
        Locale('sv'),
        Locale('da'),
        Locale('nb', 'NO'),
        Locale('fi'),
        Locale('cs'),
        Locale('sk'),
        Locale('ro'),
        Locale('hu'),
        Locale('el'),
        Locale('uk'),
        Locale('ru'),
        Locale('tr'),
        Locale('ja'),
        Locale('ko'),
        Locale('zh'),
        Locale('zh', 'TW'),
      ],
      home: StreamBuilder<AuthState>(
        stream: auth.onAuthStateChange,
        initialData: AuthState(AuthChangeEvent.initialSession, auth.currentSession),
        builder: (context, snapshot) {
          final session = snapshot.data?.session ?? auth.currentSession;
          if (session == null) {
            return AuthWelcomeScreen(
              onThemeVariantChanged: (v) => setState(() => _variant = v),
            );
          }
          return CompanyOnboardingGate(
            onThemeVariantChanged: (v) => setState(() => _variant = v),
          );
        },
      ),
    );
  }
}
