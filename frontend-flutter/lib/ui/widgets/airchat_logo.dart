import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/colors.dart';

/// AirChat wordmark: "Air" in a stylish cursive, "Chat" in the standard
/// sans-serif. Used in the app bar and splash surfaces.
class AirChatLogo extends StatelessWidget {
  final double fontSize;
  const AirChatLogo({Key? key, this.fontSize = 22}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          'Air',
          style: GoogleFonts.dancingScript(
            color: AirColors.accent,
            fontSize: fontSize * 1.35,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 3),
        Text(
          'Chat',
          style: TextStyle(
            color: AirColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: fontSize,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }
}
