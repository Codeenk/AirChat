import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';

class AttachmentBottomSheet extends StatelessWidget {
  final Function(String type) onOptionSelected;

  const AttachmentBottomSheet({Key? key, required this.onOptionSelected})
    : super(key: key);

  Widget _buildItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AirColors.surfaceLight,
                shape: BoxShape.circle,
                border: Border.all(color: AirColors.border),
              ),
              child: Icon(icon, color: AirColors.textPrimary, size: 24),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(
                color: AirColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: const BoxDecoration(
        color: AirColors.surface,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: AirColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildItem(
                icon: Icons.camera_alt_outlined,
                label: "Camera",
                onTap: () {
                  Navigator.pop(context);
                  onOptionSelected("camera");
                },
              ),
              _buildItem(
                icon: Icons.photo_outlined,
                label: "Gallery",
                onTap: () {
                  Navigator.pop(context);
                  onOptionSelected("gallery");
                },
              ),
              _buildItem(
                icon: Icons.insert_drive_file_outlined,
                label: "Document",
                onTap: () {
                  Navigator.pop(context);
                  onOptionSelected("document");
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildItem(
                icon: Icons.headphones_outlined,
                label: "Audio",
                onTap: () {
                  Navigator.pop(context);
                  onOptionSelected("audio");
                },
              ),
              _buildItem(
                icon: Icons.location_on_outlined,
                label: "Location",
                onTap: () {
                  Navigator.pop(context);
                  onOptionSelected("location");
                },
              ),
              _buildItem(
                icon: Icons.person_outline,
                label: "Contact",
                onTap: () {
                  Navigator.pop(context);
                  onOptionSelected("contact");
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
