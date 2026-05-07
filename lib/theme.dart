import 'package:flutter/material.dart';

/// Command console — deep charcoal, high contrast (see [AppTheme.dark]).
abstract final class AppColors {
  static const Color charcoal = Color(0xFF121212);
  static const Color glassBorder = Color(0x33FFFFFF);
  static const Color lightSeed = Color(0xFF1565C0);
  static const Color darkSeed = Color(0xFF90CAF9);
}

abstract final class AppTheme {
  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.lightSeed,
      brightness: Brightness.light,
    );
    return _base(scheme).copyWith(
      scaffoldBackgroundColor: scheme.surfaceContainerLowest,
    );
  }

  /// Primary command-console look: #121212, readable grey text, minimal chrome.
  static ThemeData get dark {
    const surface = Color(0xFF1A1A1A);
    final scheme = ColorScheme.dark(
      surface: surface,
      onSurface: Color(0xFFE8E8E8),
      onSurfaceVariant: Color(0xFFB0B0B0),
      primary: AppColors.darkSeed,
      onPrimary: Color(0xFF0D0D0D),
      secondary: Color(0xFF3D3D3D),
      onSecondary: Color(0xFFE0E0E0),
      tertiary: Color(0xFF2A2A2A),
      tertiaryContainer: Color(0xFF1E3A2F),
      onTertiaryContainer: Color(0xFFB8F5DC),
      outline: Color(0xFF4A4A4A),
      outlineVariant: Color(0xFF383838),
      error: Color(0xFFFFB4AB),
      onError: Color(0xFF690005),
      errorContainer: Color(0xFF93000A),
      onErrorContainer: Color(0xFFFFDAD6),
      surfaceContainerLow: Color(0xFF161616),
      surfaceContainerHigh: Color(0xFF242424),
      surfaceContainerHighest: Color(0xFF2C2C2C),
    );
    return _base(scheme).copyWith(
      scaffoldBackgroundColor: AppColors.charcoal,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 0,
        elevation: 0,
        backgroundColor: AppColors.charcoal,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.glassBorder),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: Color(0xFF161616),
        surfaceTintColor: Colors.transparent,
      ),
    );
  }

  static ThemeData _base(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        indicatorColor: scheme.secondaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

enum AppThemeVariant {
  light,
  dark,
}

extension AppThemeVariantX on AppThemeVariant {
  ThemeData get themeData => switch (this) {
        AppThemeVariant.light => AppTheme.light,
        AppThemeVariant.dark => AppTheme.dark,
      };
}
