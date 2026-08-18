import 'package:flutter/material.dart';

abstract final class SboxColors {
  static const background = Color(0xFF07111D);
  static const backgroundDeep = Color(0xFF050C15);
  static const sidebar = Color(0xFF091522);
  static const panel = Color(0xFF111E2C);
  static const panelRaised = Color(0xFF152433);
  static const panelSoft = Color(0xFF0D1926);
  static const border = Color(0xFF2A3B4D);
  static const borderSoft = Color(0xFF1E3041);
  static const accent = Color(0xFF2FD5B4);
  static const accentStrong = Color(0xFF16AF96);
  static const accentDark = Color(0xFF0D6F64);
  static const text = Color(0xFFF1F6FA);
  static const textMuted = Color(0xFF99AABC);
  static const textDim = Color(0xFF6F8295);
  static const warning = Color(0xFFFFB74A);
  static const danger = Color(0xFFFF6978);
  static const success = Color(0xFF50D890);
  static const info = Color(0xFF61A8FF);
}

ThemeData buildSboxTheme() {
  const scheme = ColorScheme.dark(
    primary: SboxColors.accent,
    onPrimary: Color(0xFF03211D),
    secondary: SboxColors.info,
    surface: SboxColors.panel,
    onSurface: SboxColors.text,
    error: SboxColors.danger,
    onError: Colors.white,
  );
  final base = ThemeData(
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: 'NotoSansSC',
    fontFamilyFallback: const <String>['sans-serif'],
    scaffoldBackgroundColor: SboxColors.background,
    useMaterial3: true,
    splashFactory: InkRipple.splashFactory,
  );
  final text = base.textTheme
      .copyWith(
        displaySmall: const TextStyle(
          color: SboxColors.text,
          fontSize: 38,
          height: 1.12,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.8,
        ),
        headlineLarge: const TextStyle(
          color: SboxColors.text,
          fontSize: 30,
          height: 1.18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        headlineMedium: const TextStyle(
          color: SboxColors.text,
          fontSize: 24,
          height: 1.22,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: const TextStyle(
          color: SboxColors.text,
          fontSize: 18,
          height: 1.35,
          fontWeight: FontWeight.w700,
        ),
        titleMedium: const TextStyle(
          color: SboxColors.text,
          fontSize: 15,
          height: 1.4,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: const TextStyle(
          color: SboxColors.text,
          fontSize: 15,
          height: 1.55,
        ),
        bodyMedium: const TextStyle(
          color: SboxColors.textMuted,
          fontSize: 13,
          height: 1.5,
        ),
        labelLarge: const TextStyle(
          color: SboxColors.text,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      )
      .apply(fontFamily: 'NotoSansSC');
  const border = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(10)),
    borderSide: BorderSide(color: SboxColors.border),
  );
  return base.copyWith(
    textTheme: text,
    dividerColor: SboxColors.borderSoft,
    focusColor: SboxColors.accent.withValues(alpha: 0.16),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: SboxColors.panelSoft,
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: SboxColors.accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: SboxColors.danger),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: TextStyle(color: SboxColors.textMuted),
      hintStyle: TextStyle(color: SboxColors.textDim),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(44, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        backgroundColor: SboxColors.accent,
        foregroundColor: const Color(0xFF03211D),
        disabledBackgroundColor: SboxColors.border,
        disabledForegroundColor: SboxColors.textDim,
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
        foregroundColor: SboxColors.accent,
        side: const BorderSide(color: SboxColors.accent, width: 1.2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 44),
        foregroundColor: SboxColors.accent,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? SboxColors.accent
            : SboxColors.panelSoft,
      ),
      checkColor: const WidgetStatePropertyAll(Color(0xFF03211D)),
      side: const BorderSide(color: SboxColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : SboxColors.textDim,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? SboxColors.accent
            : SboxColors.borderSoft,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: SboxColors.panelRaised,
      contentTextStyle: TextStyle(color: SboxColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: SboxColors.panelRaised,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      textStyle: TextStyle(color: SboxColors.text),
    ),
  );
}
