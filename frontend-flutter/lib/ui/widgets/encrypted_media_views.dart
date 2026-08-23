import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../core/files/file_saver.dart';
import '../../core/network/media_uploader.dart';
import '../../core/theme/colors.dart';

/// Decrypts an ephemeral blob on demand and renders it as an image.
/// Tap for a fullscreen zoomable view.
class EncryptedImageViewer extends StatefulWidget {
  final String fileKey;
  final String secretKeyHex;
  final String nonceHex;
  final String backendUrl;

  const EncryptedImageViewer({
    Key? key,
    required this.fileKey,
    required this.secretKeyHex,
    required this.nonceHex,
    required this.backendUrl,
  }) : super(key: key);

  @override
  State<EncryptedImageViewer> createState() => _EncryptedImageViewerState();
}

class _EncryptedImageViewerState extends State<EncryptedImageViewer> {
  late final Future<Uint8List> _future = MediaPipeline.downloadAndDecrypt(
    fileKey: widget.fileKey,
    secretKeyHex: widget.secretKeyHex,
    nonceHex: widget.nonceHex,
    backendUrl: widget.backendUrl,
  );

  void _openFullscreen(Uint8List bytes) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                maxScale: 5,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 40,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Container(
            width: 220,
            height: 160,
            decoration: BoxDecoration(
              color: AirColors.surfaceLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AirColors.accent),
              ),
            ),
          );
        }
        if (snap.hasError || !snap.hasData) {
          return _fallback(Icons.broken_image, "Expired or undecryptable");
        }
        return GestureDetector(
          onTap: () => _openFullscreen(snap.data!),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240, maxHeight: 260),
              child: Image.memory(snap.data!, fit: BoxFit.cover),
            ),
          ),
        );
      },
    );
  }

  Widget _fallback(IconData icon, String label) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AirColors.surfaceLight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: AirColors.textSecondary),
            const SizedBox(height: 6),
            Text(label,
                style:
                    const TextStyle(color: AirColors.textSecondary, fontSize: 12)),
          ],
        ),
      );
}

/// Decrypt-on-tap file tile with save/download.
class EncryptedDocumentTile extends StatefulWidget {
  final String fileName;
  final String fileKey;
  final String secretKeyHex;
  final String nonceHex;
  final String backendUrl;
  final bool onLight;

  const EncryptedDocumentTile({
    Key? key,
    required this.fileName,
    required this.fileKey,
    required this.secretKeyHex,
    required this.nonceHex,
    required this.backendUrl,
    this.onLight = false,
  }) : super(key: key);

  @override
  State<EncryptedDocumentTile> createState() => _EncryptedDocumentTileState();
}

class _EncryptedDocumentTileState extends State<EncryptedDocumentTile> {
  bool _busy = false;

  Future<void> _downloadAndSave() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await MediaPipeline.downloadAndDecrypt(
        fileKey: widget.fileKey,
        secretKeyHex: widget.secretKeyHex,
        nonceHex: widget.nonceHex,
        backendUrl: widget.backendUrl,
      );
      final savedAs = await saveBytes(widget.fileName, bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Decrypted & saved: $savedAs"),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Failed to decrypt — blob may have expired"),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final light = widget.onLight;
    final fg = light ? AirColors.bubbleMeText : AirColors.textPrimary;
    final sub = light ? Colors.black54 : AirColors.textSecondary;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: _downloadAndSave,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: light ? Colors.black.withOpacity(0.06) : AirColors.surfaceLight,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: light ? Colors.black12 : AirColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: light
                    ? Colors.black.withOpacity(0.08)
                    : AirColors.surfaceElevated,
                borderRadius: BorderRadius.circular(8),
              ),
              child: _busy
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                    )
                  : Icon(Icons.insert_drive_file_outlined, size: 24, color: fg),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: fg,
                        fontSize: 14,
                        fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "Tap to decrypt & save",
                    style: TextStyle(color: sub, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
