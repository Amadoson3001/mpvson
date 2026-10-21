import 'package:flutter/material.dart';

/// Theme tokens and typography specifications for the Library UI.
abstract final class LibraryTheme {
  // Theme color tokens
  static const Color background = Color(0xFF0B1220);
  static const Color surface = Color(0xFF111A2C);
  static const Color raisedSurface = Color(0xFF182238);
  static const Color hover = Color(0xFF223052);
  static const Color border = Color(0xFF2C3A55);
  static const Color primaryText = Color(0xFFF2F5FA);
  static const Color accent = Color(0xFF60CDFF);
  static const Color secondaryText = Color(0xFFC3CCDD);
  static const Color mutedText = Color(0xFF7E8AA0);
  static const Color danger = Color(0xFFF87171);
  static const Color warning = Color(0xFFFBBF24);
  static const Color success = Color(0xFF34D399);

  // Typography tokens
  static const TextStyle pageTitle = TextStyle(
    color: primaryText,
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.2,
  );

  static const TextStyle albumTitle = TextStyle(
    color: primaryText,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.25,
  );

  static const TextStyle sectionTitle = TextStyle(
    color: primaryText,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.3,
  );

  static const TextStyle rowPrimary = TextStyle(
    color: primaryText,
    fontSize: 13.5,
    fontWeight: FontWeight.w500,
    height: 1.3,
  );

  static const TextStyle rowSecondary = TextStyle(
    color: secondaryText,
    fontSize: 12,
    fontWeight: FontWeight.normal,
    height: 1.3,
  );

  static const TextStyle metadata = TextStyle(
    color: mutedText,
    fontSize: 12,
    fontWeight: FontWeight.normal,
    height: 1.3,
  );

  static const TextStyle badge = TextStyle(
    color: primaryText,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
  );
}
