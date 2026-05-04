import 'package:flutter/material.dart';
import 'package:inled/screens/ledger_console_screen.dart';
import 'package:inled/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'inled',
      theme: _variant.themeData,
      home: LedgerConsoleScreen(
        onThemeVariantChanged: (v) => setState(() => _variant = v),
      ),
    );
  }
}
