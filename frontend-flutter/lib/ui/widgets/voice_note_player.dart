import 'package:flutter/material.dart';
import '../../core/theme/colors.dart';

class VoiceNotePlayer extends StatefulWidget {
  final String duration;
  final bool isMe;

  const VoiceNotePlayer({
    Key? key,
    this.duration = "0:14",
    this.isMe = false,
  }) : super(key: key);

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  bool isPlaying = false;
  double progress = 0.3;

  @override
  Widget build(BuildContext context) {
    final light = widget.isMe;
    final playBg = light ? AirColors.bubbleMeText : AirColors.surfaceElevated;
    final playFg = light ? AirColors.bubbleMe : AirColors.textPrimary;

    return Container(
      width: 230,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: playBg,
            radius: 20,
            child: IconButton(
              icon: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: playFg,
                size: 24,
              ),
              onPressed: () {
                setState(() {
                  isPlaying = !isPlaying;
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                    activeTrackColor:
                        light ? AirColors.bubbleMeText : AirColors.textPrimary,
                    inactiveTrackColor: light
                        ? Colors.black.withOpacity(0.2)
                        : AirColors.textFaint.withOpacity(0.5),
                    thumbColor:
                        light ? AirColors.bubbleMeText : AirColors.textPrimary,
                  ),
                  child: Slider(
                    value: progress,
                    onChanged: (v) {
                      setState(() {
                        progress = v;
                      });
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: Text(
                    widget.duration,
                    style: TextStyle(
                        fontSize: 11,
                        color: light ? Colors.black54 : AirColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
