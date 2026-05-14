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
    final seeded = ColorScheme.fromSeed(
      seedColor: AppColors.lightSeed,
      brightness: Brightness.light,
    );
    // Material seed alone tends toward very pale containers and low-contrast
    // secondary buttons; nudge surfaces and primaries for clearer hierarchy.
    final scheme = seeded.copyWith(
      surface: const Color(0xFFFBFCFE),
      onSurface: const Color(0xFF131920),
      onSurfaceVariant: const Color(0xFF4A5563),
      primary: const Color(0xFF0B5C9E),
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFC5DFF4),
      onPrimaryContainer: const Color(0xFF001E36),
      secondary: const Color(0xFF3E566B),
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFD4E3F0),
      onSecondaryContainer: const Color(0xFF0F2533),
      tertiary: const Color(0xFF4A5F71),
      tertiaryContainer: const Color(0xFFDDE6EE),
      onTertiaryContainer: const Color(0xFF1A2832),
      outline: const Color(0xFF8A95A3),
      outlineVariant: const Color(0xFFC8D0DA),
      surfaceContainerLowest: const Color(0xFFF5F7FA),
      surfaceContainerLow: const Color(0xFFEFF2F6),
      surfaceContainer: const Color(0xFFE8EDF3),
      surfaceContainerHigh: const Color(0xFFE1E7EF),
      surfaceContainerHighest: const Color(0xFFD7DEE8),
    );
    return _base(scheme).copyWith(
      scaffoldBackgroundColor: scheme.surfaceContainerLowest,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 0,
        elevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
    );
  }

  /// Dark console: charcoal scaffold, lifted surfaces, muted primaries (less neon on #121212).
  static ThemeData get dark {
    final scheme = ColorScheme.dark(
      brightness: Brightness.dark,
      surface: const Color(0xFF1C1F26),
      onSurface: const Color(0xFFE8ECF2),
      onSurfaceVariant: const Color(0xFF9DA8B8),
      primary: const Color(0xFF7EB3E8),
      onPrimary: const Color(0xFF0B1624),
      primaryContainer: const Color(0xFF2A3A4D),
      onPrimaryContainer: const Color(0xFFD0E4FA),
      secondary: const Color(0xFF4A5563),
      onSecondary: const Color(0xFFE8EBF0),
      secondaryContainer: const Color(0xFF343D4A),
      onSecondaryContainer: const Color(0xFFD0D6E0),
      tertiary: const Color(0xFF3D4A42),
      onTertiary: const Color(0xFFE6F5EC),
      tertiaryContainer: const Color(0xFF1E3329),
      onTertiaryContainer: const Color(0xFFB8E8D0),
      outline: const Color(0xFF5A6570),
      outlineVariant: const Color(0xFF3E4752),
      error: const Color(0xFFFFB4AB),
      onError: const Color(0xFF690005),
      errorContainer: const Color(0xFF93000A),
      onErrorContainer: const Color(0xFFFFDAD6),
      surfaceContainerLowest: AppColors.charcoal,
      surfaceContainerLow: const Color(0xFF14171D),
      surfaceContainer: const Color(0xFF1A1E26),
      surfaceContainerHigh: const Color(0xFF232830),
      surfaceContainerHighest: const Color(0xFF2C323C),
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
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh.withValues(alpha: 0.55),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
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
        surfaceTintColor: Colors.transparent,
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
        fillColor: scheme.brightness == Brightness.light
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
            : null,
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
