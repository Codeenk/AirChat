import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';

class MediaPreviewScreen extends StatelessWidget {
  final String fileName;
  final String? imagePath;

  const MediaPreviewScreen({Key? key, required this.fileName, this.imagePath})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        surfaceTintColor: Colors.transparent,
        title: Text(fileName),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.lock_outline,
              size: 44,
              color: AirColors.textFaint,
            ),
            const SizedBox(height: 12),
            const Text(
              "Decrypted end-to-end encrypted media",
              style: TextStyle(color: AirColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 24),
            Container(
              height: 300,
              width: 300,
              decoration: BoxDecoration(
                color: AirColors.surfaceLight,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AirColors.border),
              ),
              child: const Center(
                child: Icon(
                  Icons.image_outlined,
                  size: 72,
                  color: AirColors.textFaint,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
