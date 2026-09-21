import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';

/// Send button with instant press-down feedback (scale on pointer down,
/// ~100ms release) so the tap feels alive before the message lands.
/// Also meets the 44×44 minimum tap target.
class SendButton extends StatefulWidget {
  final VoidCallback onSend;
  const SendButton({super.key, required this.onSend});

  @override
  State<SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<SendButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return GestureDetector(
      onTap: widget.onSend,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1.0,
        duration: Duration(milliseconds: reducedMotion ? 0 : 100),
        curve: Curves.easeOut,
        child: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: AirColors.bubbleMe,
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.arrow_upward,
            color: AirColors.bubbleMeText,
            size: 20,
          ),
        ),
      ),
    );
  }
}
