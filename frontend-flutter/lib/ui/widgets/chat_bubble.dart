import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/theme/colors.dart';
import 'encrypted_media_views.dart';
import 'voice_note_player.dart';

class ChatBubble extends StatefulWidget {
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

  // Quoted-reply snapshot (rendered inside the bubble).
  final String? replyToId;
  final String? replyText;
  final String? replyType;
  final bool? replyIsMe;

  final String peerName;
  final String? groupSenderName;

  // Swipe-right-to-reply + tap-quote-to-jump wiring.
  final VoidCallback? onSwipeReply;
  final VoidCallback? onTapQuote;

  /// Delete-for-self (local only)
  final VoidCallback? onDeleteForMe;

  /// Briefly true after jumping to this message from a quote tap.
  final bool highlighted;

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
    this.replyToId,
    this.replyText,
    this.replyType,
    this.replyIsMe,
    this.peerName = '',
    this.groupSenderName,
    this.onSwipeReply,
    this.onTapQuote,
    this.onDeleteForMe,
    this.highlighted = false,
  }) : super(key: key);

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble> {
  static const double _swipeThreshold = 64;
  double _dragDx = 0;
  bool _firedHaptic = false;
  bool _expanded = false;

  bool get _hasMedia =>
      widget.mediaKey != null &&
      widget.mediaKey!.isNotEmpty &&
      widget.secretKeyHex != null &&
      widget.nonceHex != null;

  bool get _hasReply =>
      widget.replyToId != null && widget.replyToId!.isNotEmpty;

  String get _quotePreview {
    switch (widget.replyType) {
      case 'image':
        return '\u{1F4F7} Photo';
      case 'document':
        return '\u{1F4CE} ${widget.replyText?.isEmpty ?? true ? 'Document' : widget.replyText}';
      case 'voice':
        return '\u{1F3A4} Voice note';
      default:
        return widget.replyText ?? '';
    }
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (widget.onSwipeReply == null) return;
    setState(() {
      _dragDx = (_dragDx + d.delta.dx).clamp(0.0, _swipeThreshold * 1.35);
    });
    if (!_firedHaptic && _dragDx >= _swipeThreshold) {
      _firedHaptic = true;
      HapticFeedback.mediumImpact();
    }
  }

  void _onDragEnd(DragEndDetails details) {
    if (widget.onSwipeReply == null) return;
    final fastFlick = (details.primaryVelocity ?? 0) > 450;
    final shouldReply =
        _dragDx >= _swipeThreshold || (fastFlick && _dragDx > 12);
    if (shouldReply) widget.onSwipeReply!();
    setState(() => _dragDx = 0);
    _firedHaptic = false;
  }

  Widget _buildStatusIcon() {
    if (!widget.isMe) return const SizedBox.shrink();
    final onLight = Colors.black54;

    switch (widget.status) {
      case 'failed':
      case 'expired':
        return const Icon(
          Icons.error_outline,
          size: 14,
          color: Color(0xFFB3261E),
        );
      case 'sending':
        return Icon(Icons.access_time, size: 13, color: onLight);
      case 'sent':
        return Icon(Icons.done, size: 14, color: onLight);
      case 'delivered':
        return Icon(Icons.done_all, size: 14, color: onLight);
      case 'read':
      default:
        return const Icon(
          Icons.done_all,
          size: 14,
          color: AirColors.bubbleMeText,
        );
    }
  }

  bool get _isUndelivered =>
      widget.isMe && (widget.status == 'failed' || widget.status == 'expired');

  Widget _buildContent() {
    switch (widget.type) {
      case 'image':
        if (_hasMedia) {
          return EncryptedImageViewer(
            fileKey: widget.mediaKey!,
            secretKeyHex: widget.secretKeyHex!,
            nonceHex: widget.nonceHex!,
            backendUrl: widget.backendUrl,
          );
        }
        return _mediaPlaceholder(Icons.image_outlined);

      case 'document':
        if (_hasMedia) {
          return EncryptedDocumentTile(
            fileName: widget.text.isEmpty ? "document" : widget.text,
            fileKey: widget.mediaKey!,
            secretKeyHex: widget.secretKeyHex!,
            nonceHex: widget.nonceHex!,
            backendUrl: widget.backendUrl,
            onLight: widget.isMe,
          );
        }
        return _mediaPlaceholder(Icons.insert_drive_file);

      case 'voice':
        return VoiceNotePlayer(
          duration: widget.text.isEmpty ? '0:00' : widget.text,
          mediaKey: widget.mediaKey,
          secretKeyHex: widget.secretKeyHex,
          nonceHex: widget.nonceHex,
          backendUrl: widget.backendUrl,
          isMe: widget.isMe,
        );

      case 'text':
      default:
        final isLong =
            widget.text.length > 400 || '\n'.allMatches(widget.text).length > 7;
        if (!isLong) {
          return Text(
            widget.text,
            style: TextStyle(
              color: widget.isMe
                  ? AirColors.bubbleMeText
                  : AirColors.textPrimary,
              fontSize: 15,
              height: 1.35,
              letterSpacing: -0.1,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              maxLines: _expanded ? null : 6,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: TextStyle(
                color: widget.isMe
                    ? AirColors.bubbleMeText
                    : AirColors.textPrimary,
                fontSize: 15,
                height: 1.35,
                letterSpacing: -0.1,
              ),
            ),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(
                _expanded ? 'Show less' : 'Read more',
                style: TextStyle(
                  color: widget.isMe ? Colors.black54 : AirColors.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
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
        child: Text(
          widget.text,
          style: const TextStyle(
            color: AirColors.textPrimary,
            fontSize: 15,
            height: 1.25,
          ),
        ),
      ),
    ],
  );

  /// Quoted original message pinned above the bubble content.
  Widget _buildQuoteBlock(Color metaColor) {
    final quoteAuthor = (widget.replyIsMe ?? false) ? 'You' : widget.peerName;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: widget.onTapQuote,
        child: Container(
          constraints: const BoxConstraints(maxWidth: double.infinity),
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(widget.isMe ? 0.06 : 0.22),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 3,
                height: 30,
                decoration: BoxDecoration(
                  color: widget.isMe ? Colors.black45 : AirColors.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      quoteAuthor.isEmpty ? 'Message' : quoteAuthor,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: metaColor,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.1,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _quotePreview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: metaColor,
                        fontSize: 12.5,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    HapticFeedback.mediumImpact();
    final time = DateFormat('MMM d, h:mm a')
        .format(DateTime.fromMillisecondsSinceEpoch(widget.timestamp));
    showModalBottomSheet(
      context: context,
      backgroundColor: AirColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AirColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.copy_rounded,
                color: AirColors.textPrimary,
                size: 20,
              ),
              title: const Text(
                'Copy',
                style: TextStyle(color: AirColors.textPrimary),
              ),
              onTap: () {
                Clipboard.setData(ClipboardData(text: widget.text));
                Navigator.pop(context);
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Copied')));
              },
            ),
            if (widget.onSwipeReply != null)
              ListTile(
                leading: const Icon(
                  Icons.reply,
                  color: AirColors.textPrimary,
                  size: 20,
                ),
                title: const Text(
                  'Reply',
                  style: TextStyle(color: AirColors.textPrimary),
                ),
                onTap: () {
                  Navigator.pop(context);
                  widget.onSwipeReply!.call();
                },
              ),
            if (widget.onDeleteForMe != null)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AirColors.error,
                  size: 20,
                ),
                title: const Text(
                  'Delete for me',
                  style: TextStyle(color: AirColors.error),
                ),
                onTap: () {
                  Navigator.pop(context);
                  widget.onDeleteForMe!.call();
                },
              ),
            ListTile(
              leading: const Icon(
                Icons.schedule,
                color: AirColors.textSecondary,
                size: 20,
              ),
              title: Text(
                time,
                style: const TextStyle(
                  color: AirColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final formattedTime = DateFormat('h:mm a')
        .format(DateTime.fromMillisecondsSinceEpoch(widget.timestamp));

    final isFailed = _isUndelivered;

    // Me = off-white block with black ink (inverted). Peer = dark gray.
    final bubbleColor = isFailed
        ? const Color(0xFF2A1515)
        : (widget.isMe ? AirColors.bubbleMe : AirColors.bubblePeer);
    final metaColor = widget.isMe ? Colors.black54 : AirColors.textSecondary;

    // Use plain Container — no AnimatedContainer overhead for non-highlighted
    // bubbles (the vast majority). Highlight border change is instant, which
    // is fine for a 1.4s flash effect.
    final bubble = Container(
      margin: EdgeInsets.only(
        top: 3,
        bottom: 3,
        left: widget.isMe ? 48 : 12,
        right: widget.isMe ? 12 : 48,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.78,
      ),
      decoration: BoxDecoration(
        color: bubbleColor,
        border: Border.all(
          color: widget.highlighted
              ? AirColors.accent
              : (isFailed
                    ? AirColors.error
                    : (widget.isMe ? Colors.transparent : AirColors.border)),
          width: widget.highlighted || isFailed ? 1.4 : 1,
        ),
        borderRadius: BorderRadius.circular(widget.isMe ? 18 : 18).copyWith(
          bottomLeft: widget.isMe
              ? const Radius.circular(18)
              : const Radius.circular(4),
          bottomRight: widget.isMe
              ? const Radius.circular(4)
              : const Radius.circular(18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isFailed)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                widget.status == 'expired'
                    ? "Expired after 24h — recipient was offline. Tap to resend"
                    : "Not delivered — tap to retry",
                style: const TextStyle(color: AirColors.error, fontSize: 11),
              ),
            ),
          if (widget.groupSenderName != null &&
              widget.groupSenderName!.isNotEmpty &&
              !widget.isMe)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.groupSenderName!,
                  style: const TextStyle(
                    color: AirColors.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          if (_hasReply) _buildQuoteBlock(metaColor),
          _buildContent(),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.type != 'text') ...[
                Icon(Icons.lock, size: 10, color: metaColor),
                const SizedBox(width: 3),
              ],
              Text(
                formattedTime,
                style: TextStyle(color: metaColor, fontSize: 11),
              ),
              if (widget.isMe) ...[
                const SizedBox(width: 4),
                _buildStatusIcon(),
              ],
            ],
          ),
        ],
      ),
    );

    // RepaintBoundary isolates each bubble's paint from siblings — prevents
    // swipe-to-reply gesture from repainting the entire ListView.
    return RepaintBoundary(
      child: Align(
        alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Stack(
          alignment: widget.isMe ? Alignment.centerLeft : Alignment.centerRight,
          children: [
            // Reply arrow revealed behind the bubble while swiping right.
            Opacity(
              opacity: (_dragDx / _swipeThreshold).clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 0.7 + 0.3 * (_dragDx / _swipeThreshold).clamp(0.0, 1.0),
                child: const Icon(
                  Icons.reply,
                  size: 22,
                  color: AirColors.textFaint,
                ),
              ),
            ),
            GestureDetector(
              onTap: isFailed ? widget.onRetryFailed : null,
              onLongPress: () => _showActions(context),
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              child: Semantics(
                label:
                    '${widget.isMe ? 'You' : widget.peerName}: ${widget.text.isEmpty ? widget.type : widget.text}',
                child: Transform.translate(
                  offset: Offset(_dragDx * 0.55, 0),
                  child: bubble,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
