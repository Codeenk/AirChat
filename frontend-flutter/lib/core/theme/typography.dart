import 'package:flutter/material.dart';
import 'colors.dart';

class AirTypography {
  static const TextStyle appTitle = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.bold,
    color: AirColors.textPrimary,
    letterSpacing: 0.5,
  );

  static const TextStyle chatTitle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AirColors.textPrimary,
  );

  static const TextStyle chatSubtitle = TextStyle(
    fontSize: 13,
    color: AirColors.textSecondary,
  );

  static const TextStyle body = TextStyle(
    fontSize: 15,
    color: AirColors.textPrimary,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 11,
    color: AirColors.textSecondary,
  );
}
