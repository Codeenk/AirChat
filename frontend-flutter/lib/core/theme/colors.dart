import 'package:flutter/material.dart';

/// AirChat · Black & Off-white monochrome system.
/// One idea, executed everywhere: pure black canvas, warm off-white ink,
/// gray for hierarchy. No hue anywhere — contrast does all the work.
class AirColors {
  // Canvas
  static const Color background = Color(0xFF000000); // pure black
  static const Color surface = Color(0xFF0D0D0D); // app bars / sheets
  static const Color surfaceLight = Color(0xFF1A1A1A); // input field / tiles
  static const Color surfaceElevated = Color(0xFF242424); // hover/pressed

  // Ink
  static const Color textPrimary = Color(0xFFF2F0EA); // warm off-white
  static const Color textSecondary = Color(0xFF8A8880); // warm gray
  static const Color textFaint = Color(0xFF4A4A46);

  // Bubbles — me = off-white block with black text (inverted, unmistakable)
  static const Color bubbleMe = Color(0xFFF2F0EA);
  static const Color bubbleMeText = Color(0xFF0D0D0C);
  static const Color bubblePeer = Color(0xFF1A1A1A);

  // Signals (monochrome-compatible)
  static const Color accent = Color(0xFFF2F0EA); // "brand" accent is the ink
  static const Color tickRead = Color(0xFFF2F0EA); // read = solid off-white
  static const Color error = Color(0xFFFF5C5C); // only permitted color break

  // Lines
  static const Color divider = Color(0xFF1F1F1F);
  static const Color border = Color(0xFF2A2A2A);

  // Legacy names — kept so older widgets compile; both map to monochrome.
  static const Color emeraldAccent = accent;
  static const Color tickBlue = tickRead;
}
