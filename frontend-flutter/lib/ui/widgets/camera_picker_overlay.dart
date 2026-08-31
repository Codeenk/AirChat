import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';

class CameraPickerOverlay extends StatelessWidget {
  final VoidCallback onCapture;

  const CameraPickerOverlay({Key? key, required this.onCapture})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          const Center(
            child: Icon(
              Icons.camera_front,
              size: 90,
              color: AirColors.textFaint,
            ),
          ),
          Positioned(
            top: 40,
            left: 16,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: () {
                  onCapture();
                  Navigator.pop(context);
                },
                child: Container(
                  height: 75,
                  width: 75,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                    color: AirColors.bubbleMe,
                  ),
                  child: const Icon(
                    Icons.camera,
                    color: AirColors.bubbleMeText,
                    size: 34,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
