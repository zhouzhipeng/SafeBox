import 'package:flutter/material.dart';

@immutable
final class SboxThemeColors extends ThemeExtension<SboxThemeColors> {
  const SboxThemeColors({
    required this.background,
    required this.backgroundDeep,
    required this.sidebar,
    required this.panel,
    required this.panelRaised,
    required this.panelSoft,
    required this.border,
    required this.borderSoft,
    required this.accent,
    required this.accentStrong,
    required this.accentDark,
    required this.text,
    required this.textMuted,
    required this.textDim,
    required this.warning,
    required this.danger,
    required this.success,
    required this.info,
  });

  static const dark = SboxThemeColors(
    background: Color(0xFF07111D),
    backgroundDeep: Color(0xFF050C15),
    sidebar: Color(0xFF091522),
    panel: Color(0xFF111E2C),
    panelRaised: Color(0xFF152433),
    panelSoft: Color(0xFF0D1926),
    border: Color(0xFF2A3B4D),
    borderSoft: Color(0xFF1E3041),
    accent: Color(0xFF2FD5B4),
    accentStrong: Color(0xFF16AF96),
    accentDark: Color(0xFF0D6F64),
    text: Color(0xFFF1F6FA),
    textMuted: Color(0xFF99AABC),
    textDim: Color(0xFF6F8295),
    warning: Color(0xFFFFB74A),
    danger: Color(0xFFFF6978),
    success: Color(0xFF50D890),
    info: Color(0xFF61A8FF),
  );

  static const light = SboxThemeColors(
    background: Color(0xFFF4F7FA),
    backgroundDeep: Color(0xFFE8EEF3),
    sidebar: Color(0xFFEDF2F6),
    panel: Colors.white,
    panelRaised: Colors.white,
    panelSoft: Color(0xFFF8FAFC),
    border: Color(0xFFC8D4DE),
    borderSoft: Color(0xFFDCE5EC),
    accent: Color(0xFF0A9B84),
    accentStrong: Color(0xFF087865),
    accentDark: Color(0xFF075F54),
    text: Color(0xFF16222D),
    textMuted: Color(0xFF607182),
    textDim: Color(0xFF8897A5),
    warning: Color(0xFFB86A06),
    danger: Color(0xFFC33D4B),
    success: Color(0xFF18804F),
    info: Color(0xFF2E73C7),
  );

  final Color background;
  final Color backgroundDeep;
  final Color sidebar;
  final Color panel;
  final Color panelRaised;
  final Color panelSoft;
  final Color border;
  final Color borderSoft;
  final Color accent;
  final Color accentStrong;
  final Color accentDark;
  final Color text;
  final Color textMuted;
  final Color textDim;
  final Color warning;
  final Color danger;
  final Color success;
  final Color info;

  static SboxThemeColors of(BuildContext context) {
    return Theme.of(context).extension<SboxThemeColors>() ?? dark;
  }

  @override
  SboxThemeColors copyWith({
    Color? background,
    Color? backgroundDeep,
    Color? sidebar,
    Color? panel,
    Color? panelRaised,
    Color? panelSoft,
    Color? border,
    Color? borderSoft,
    Color? accent,
    Color? accentStrong,
    Color? accentDark,
    Color? text,
    Color? textMuted,
    Color? textDim,
    Color? warning,
    Color? danger,
    Color? success,
    Color? info,
  }) {
    return SboxThemeColors(
      background: background ?? this.background,
      backgroundDeep: backgroundDeep ?? this.backgroundDeep,
      sidebar: sidebar ?? this.sidebar,
      panel: panel ?? this.panel,
      panelRaised: panelRaised ?? this.panelRaised,
      panelSoft: panelSoft ?? this.panelSoft,
      border: border ?? this.border,
      borderSoft: borderSoft ?? this.borderSoft,
      accent: accent ?? this.accent,
      accentStrong: accentStrong ?? this.accentStrong,
      accentDark: accentDark ?? this.accentDark,
      text: text ?? this.text,
      textMuted: textMuted ?? this.textMuted,
      textDim: textDim ?? this.textDim,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      success: success ?? this.success,
      info: info ?? this.info,
    );
  }

  @override
  SboxThemeColors lerp(
    covariant ThemeExtension<SboxThemeColors>? other,
    double t,
  ) {
    if (other is! SboxThemeColors) return this;
    return SboxThemeColors(
      background: Color.lerp(background, other.background, t)!,
      backgroundDeep: Color.lerp(backgroundDeep, other.backgroundDeep, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      panelRaised: Color.lerp(panelRaised, other.panelRaised, t)!,
      panelSoft: Color.lerp(panelSoft, other.panelSoft, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderSoft: Color.lerp(borderSoft, other.borderSoft, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentStrong: Color.lerp(accentStrong, other.accentStrong, t)!,
      accentDark: Color.lerp(accentDark, other.accentDark, t)!,
      text: Color.lerp(text, other.text, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      success: Color.lerp(success, other.success, t)!,
      info: Color.lerp(info, other.info, t)!,
    );
  }
}

extension SboxThemeBuildContext on BuildContext {
  SboxThemeColors get sboxColors => SboxThemeColors.of(this);
}

ThemeData buildSboxTheme({Brightness brightness = Brightness.dark}) {
  final colors = brightness == Brightness.light
      ? SboxThemeColors.light
      : SboxThemeColors.dark;
  final scheme = brightness == Brightness.light
      ? ColorScheme.light(
          primary: colors.accent,
          onPrimary: Colors.white,
          secondary: colors.info,
          surface: colors.panel,
          onSurface: colors.text,
          error: colors.danger,
          onError: Colors.white,
        )
      : ColorScheme.dark(
          primary: colors.accent,
          onPrimary: const Color(0xFF03211D),
          secondary: colors.info,
          surface: colors.panel,
          onSurface: colors.text,
          error: colors.danger,
          onError: Colors.white,
        );
  final base = ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'NotoSansSC',
    fontFamilyFallback: const <String>['sans-serif'],
    scaffoldBackgroundColor: colors.background,
    canvasColor: colors.background,
    useMaterial3: true,
    splashFactory: InkRipple.splashFactory,
    extensions: <ThemeExtension<SboxThemeColors>>[colors],
  );
  final text = base.textTheme
      .copyWith(
        displaySmall: TextStyle(
          color: colors.text,
          fontSize: 38,
          height: 1.12,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.8,
        ),
        headlineLarge: TextStyle(
          color: colors.text,
          fontSize: 30,
          height: 1.18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        headlineMedium: TextStyle(
          color: colors.text,
          fontSize: 24,
          height: 1.22,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: TextStyle(
          color: colors.text,
          fontSize: 18,
          height: 1.35,
          fontWeight: FontWeight.w700,
        ),
        titleMedium: TextStyle(
          color: colors.text,
          fontSize: 15,
          height: 1.4,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(color: colors.text, fontSize: 15, height: 1.55),
        bodyMedium: TextStyle(
          color: colors.textMuted,
          fontSize: 13,
          height: 1.5,
        ),
        labelLarge: TextStyle(
          color: colors.text,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      )
      .apply(fontFamily: 'NotoSansSC');
  final border = OutlineInputBorder(
    borderRadius: const BorderRadius.all(Radius.circular(10)),
    borderSide: BorderSide(color: colors.border),
  );
  return base.copyWith(
    textTheme: text,
    dividerColor: colors.borderSoft,
    focusColor: colors.accent.withValues(alpha: 0.16),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.panelSoft,
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: colors.accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: colors.danger),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: TextStyle(color: colors.textMuted),
      hintStyle: TextStyle(color: colors.textDim),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(44, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        backgroundColor: colors.accent,
        foregroundColor: brightness == Brightness.light
            ? Colors.white
            : const Color(0xFF03211D),
        disabledBackgroundColor: colors.border,
        disabledForegroundColor: colors.textDim,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        textStyle: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 46),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        foregroundColor: colors.accent,
        side: BorderSide(color: colors.accent, width: 1.2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 44),
        foregroundColor: colors.accent,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.accent
            : colors.panelSoft,
      ),
      checkColor: WidgetStatePropertyAll(
        brightness == Brightness.light ? Colors.white : const Color(0xFF03211D),
      ),
      side: BorderSide(color: colors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : colors.textDim,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.accent
            : colors.borderSoft,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: colors.panelRaised,
      contentTextStyle: TextStyle(color: colors.text),
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: colors.panelRaised,
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
      textStyle: TextStyle(color: colors.text),
    ),
  );
}
