import 'package:flutter/material.dart';

/// Spacing scale shared by both shells.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

/// Focus presentation for D-pad navigation.
///
/// On a TV the focused element has to be obvious from across the room, so it
/// gets a bright ring, a soft glow and a slight scale-up. The ring is always
/// painted — only its colour changes — so gaining focus never reflows layout.
abstract final class AppFocus {
  static const Color ring = Color(0xFF4DD0E1);
  static const double ringWidth = 3;
  static const double scale = 1.04;
  static const Duration duration = Duration(milliseconds: 140);
  static const Curve curve = Curves.easeOut;
}

/// Televisions crop roughly 5% of the panel. At the 960x540dp that a 1080p
/// set typically reports, that is ~48x27dp of unusable edge.
abstract final class TvInsets {
  static const EdgeInsets overscan =
      EdgeInsets.symmetric(horizontal: 48, vertical: 27);
  static const double railWidth = 208;
}

const Color _seed = Color(0xFF00BCD4);
const Color _background = Color(0xFF07171C);

/// Builds the app theme for the given form factor.
///
/// The TV variant enlarges type for ten-foot viewing and strips the ink
/// splash, which signals nothing when there is no pointer.
ThemeData buildAppTheme({required bool tv}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: Brightness.dark,
  );

  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: _background,
  );

  if (!tv) return base;

  return base.copyWith(
    textTheme: _tvTextTheme(base.textTheme),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
  );
}

/// Type scale for ten-foot viewing.
///
/// Sizes are set explicitly rather than scaled with [TextTheme.apply], which
/// asserts on any style whose `fontSize` is null — several of the Material
/// defaults are. Setting each size also keeps the ramp deliberate instead of
/// uniformly multiplying a scale designed for a phone held at arm's length.
TextTheme _tvTextTheme(TextTheme base) => base.copyWith(
      displayLarge: base.displayLarge?.copyWith(fontSize: 72),
      displayMedium: base.displayMedium?.copyWith(fontSize: 56),
      displaySmall: base.displaySmall?.copyWith(fontSize: 44),
      headlineLarge: base.headlineLarge?.copyWith(fontSize: 40),
      headlineMedium: base.headlineMedium?.copyWith(fontSize: 34),
      headlineSmall: base.headlineSmall?.copyWith(fontSize: 30),
      titleLarge: base.titleLarge?.copyWith(fontSize: 28),
      titleMedium: base.titleMedium?.copyWith(fontSize: 22),
      titleSmall: base.titleSmall?.copyWith(fontSize: 18),
      bodyLarge: base.bodyLarge?.copyWith(fontSize: 20),
      bodyMedium: base.bodyMedium?.copyWith(fontSize: 18),
      bodySmall: base.bodySmall?.copyWith(fontSize: 16),
      labelLarge: base.labelLarge?.copyWith(fontSize: 18),
      labelMedium: base.labelMedium?.copyWith(fontSize: 16),
      labelSmall: base.labelSmall?.copyWith(fontSize: 14),
    );
