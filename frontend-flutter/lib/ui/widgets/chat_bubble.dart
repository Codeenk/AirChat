import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/theme/colors.dart';
import 'encrypted_media_views.dart';
import 'voice_note_player.dart';

class ChatBubble extends StatelessWidget {
  final String text;
  final bool isMe;
  final int timestamp;
  final String status;
  final String type;
  final String? mediaKey;
  final String? secretKeyHex;
  final String? nonceHex;
  final String backendUrl;
  final VoidCallback? onRetryFailed;

  const ChatBubble({
    Key? key,
    required this.text,
    required this.isMe,
    required this.timestamp,
    required this.status,
    this.type = 'text',
    this.mediaKey,
    this.secretKeyHex,
    this.nonceHex,
    this.backendUrl = '',
    this.onRetryFailed,
  }) : super(key: key);

  bool get _hasMedia =>
      mediaKey != null &&
      mediaKey!.isNotEmpty &&
      secretKeyHex != null &&
      nonceHex != null;

  Widget _buildStatusIcon() {
    if (!isMe) return const SizedBox.shrink();
    final onLight = Colors.black54;

    switch (status) {
      case 'failed':
        return const Icon(Icons.error_outline, size: 14, color: Color(0xFFB3261E));
      case 'sending':
        return Icon(Icons.access_time, size: 13, color: onLight);
      case 'sent':
        return Icon(Icons.done, size: 14, color: onLight);
      case 'delivered':
        return Icon(Icons.done_all, size: 14, color: onLight);
      case 'read':
      default:
        return const Icon(Icons.done_all, size: 14, color: AirColors.bubbleMeText);
    }
  }

  Widget _buildContent() {
    switch (type) {
      case 'image':
        if (_hasMedia) {
          return EncryptedImageViewer(
            fileKey: mediaKey!,
            secretKeyHex: secretKeyHex!,
            nonceHex: nonceHex!,
            backendUrl: backendUrl,
          );
        }
        return _mediaPlaceholder(Icons.image_outlined);

      case 'document':
        if (_hasMedia) {
          return EncryptedDocumentTile(
            fileName: text.isEmpty ? "document" : text,
            fileKey: mediaKey!,
            secretKeyHex: secretKeyHex!,
            nonceHex: nonceHex!,
            backendUrl: backendUrl,
            onLight: isMe,
          );
        }
        return _mediaPlaceholder(Icons.insert_drive_file);

      case 'voice':
        return VoiceNotePlayer(duration: "0:32", isMe: isMe);

      case 'text':
      default:
        return Text(
          text,
          style: TextStyle(
            color: isMe ? AirColors.bubbleMeText : AirColors.textPrimary,
            fontSize: 15,
            height: 1.35,
            letterSpacing: -0.1,
          ),
        );
    }
  }

  Widget _mediaPlaceholder(IconData icon) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AirColors.surfaceLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 24, color: AirColors.textSecondary),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(text,
                style: const TextStyle(
                    color: AirColors.textPrimary, fontSize: 15, height: 1.25)),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final formattedTime = DateFormat('h:mm a').format(
      DateTime.fromMillisecondsSinceEpoch(timestamp),
    );

    final isFailed = isMe && status == 'failed';

    // Me = off-white block with black ink (inverted). Peer = dark gray.
    final bubbleColor = isFailed
        ? const Color(0xFF2A1515)
        : (isMe ? AirColors.bubbleMe : AirColors.bubblePeer);
    final metaColor =
        isMe ? Colors.black54 : AirColors.textSecondary;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: isFailed ? onRetryFailed : null,
        child: Container(
          margin: EdgeInsets.only(
            top: 3, bottom: 3,
            left: isMe ? 48 : 12,
            right: isMe ? 12 : 48,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          decoration: BoxDecoration(
            color: bubbleColor,
            border: isFailed
                ? Border.all(color: AirColors.error, width: 1)
                : (isMe ? null : Border.all(color: AirColors.border)),
            borderRadius: BorderRadius.circular(isMe ? 18 : 18).copyWith(
              bottomLeft: isMe ? const Radius.circular(18) : const Radius.circular(4),
              bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isFailed)
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text(
                    "Not delivered — tap to retry",
                    style: TextStyle(color: AirColors.error, fontSize: 11),
                  ),
                ),
              _buildContent(),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (type != 'text') ...[
                    Icon(Icons.lock, size: 10, color: metaColor),
                    const SizedBox(width: 3),
                  ],
                  Text(
                    formattedTime,
                    style: TextStyle(color: metaColor, fontSize: 11),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    _buildStatusIcon(),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
