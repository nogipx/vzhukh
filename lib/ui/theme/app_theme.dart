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

/// Corner radii. Few and small: the look is flat and quiet.
abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
}

/// Focus presentation for D-pad navigation.
///
/// On a TV the focused element has to be obvious from across the room. A
/// solid ring does that without glow or zoom; it is always painted, only its
/// colour changes, so gaining focus never reflows layout.
abstract final class AppFocus {
  static const double ringWidth = 3;

  /// Between the element and its ring.
  static const double gap = 3;
  static const Duration duration = Duration(milliseconds: 120);
  static const Curve curve = Curves.easeOut;
}

/// Televisions crop roughly 5% of the panel. At the 960x540dp that a 1080p
/// set typically reports, that is ~48x27dp of unusable edge.
abstract final class TvInsets {
  static const EdgeInsets overscan =
      EdgeInsets.symmetric(horizontal: 48, vertical: 27);
}

/// Colours with a meaning, beyond the Material scheme. Widgets take colour
/// from here or from the scheme, never from [Colors].
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.success,
    required this.warning,
    required this.danger,
    required this.muted,
    required this.info,
  });

  final Color success;
  final Color warning;
  final Color danger;
  final Color muted;

  /// Neutral highlights, such as traffic that goes direct.
  final Color info;

  static AppColors of(BuildContext context) => Theme.of(context).extension<AppColors>()!;

  @override
  AppColors copyWith({Color? success, Color? warning, Color? danger, Color? muted, Color? info}) =>
      AppColors(
        success: success ?? this.success,
        warning: warning ?? this.warning,
        danger: danger ?? this.danger,
        muted: muted ?? this.muted,
        info: info ?? this.info,
      );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      info: Color.lerp(info, other.info, t)!,
    );
  }
}

/// The yellow of the app icon (assets/branding).
const Color _accent = Color(0xFFFFC93D);

/// Builds the app theme for the given form factor.
///
/// One accent on neutral greys, flat surfaces, no shadows. The TV variant
/// enlarges type for ten-foot viewing and strips the ink splash, which
/// signals nothing when there is no pointer.
ThemeData buildAppTheme({required bool tv}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: _accent,
    brightness: Brightness.dark,
  ).copyWith(
    // The seed alone gives a pale khaki primary in a dark scheme; the brand
    // yellow is set as is, with dark ink on it.
    primary: _accent,
    onPrimary: const Color(0xFF1A1A1F),
    surface: const Color(0xFF111315),
    surfaceContainerLowest: const Color(0xFF0C0D0F),
    surfaceContainerLow: const Color(0xFF16181B),
    surfaceContainer: const Color(0xFF1A1D20),
    surfaceContainerHigh: const Color(0xFF212428),
    surfaceContainerHighest: const Color(0xFF292D31),
    outlineVariant: const Color(0xFF2E3236),
    surfaceTint: Colors.transparent,
  );
  final colors = AppColors(
    success: const Color(0xFF7BC99A),
    // Orange, not amber: amber would read as the yellow accent.
    warning: const Color(0xFFFF8A4C),
    danger: scheme.error,
    muted: scheme.onSurfaceVariant,
    info: const Color(0xFF8FB3E0),
  );
  const md = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)));

  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    extensions: [colors],
  );
  final textTheme = tv ? _tvTextTheme(base.textTheme) : base.textTheme;

  return base.copyWith(
    textTheme: textTheme,
    splashFactory: tv ? NoSplash.splashFactory : InkRipple.splashFactory,
    highlightColor: tv ? Colors.transparent : null,
    // Material screens a TV opens (devices, app sets) show D-pad focus with
    // this tint; on a phone focus rarely shows at all.
    focusColor: tv ? scheme.primary.withValues(alpha: 0.22) : null,
    appBarTheme: AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleMedium?.copyWith(color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: md,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      selectedColor: scheme.primary,
      shape: md,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(elevation: 0, shape: md),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: md,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: md)),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.lg))),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.md))),
      enabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      elevation: 0,
      backgroundColor: scheme.surfaceContainer,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.lg))),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      elevation: 0,
      modalElevation: 0,
      backgroundColor: scheme.surfaceContainer,
      modalBackgroundColor: scheme.surfaceContainer,
      dragHandleColor: scheme.outline,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      height: 64,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primary.withValues(alpha: 0.16),
    ),
    // Floating and on the surface colour, in both shells. On a TV it also
    // stays out of the region the set crops.
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      backgroundColor: scheme.surfaceContainerHighest,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
      insetPadding: tv ? TvInsets.overscan : null,
      shape: md,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.sm)),
      ),
      textStyle: textTheme.bodySmall?.copyWith(color: scheme.onSurface),
    ),
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
