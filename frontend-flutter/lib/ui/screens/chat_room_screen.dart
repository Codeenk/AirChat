import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/crypto/key_store.dart';
import '../../core/device/device_info_helper.dart';
import '../../core/network/api_client.dart';
import '../../core/network/media_uploader.dart';
import '../../core/network/notification_service.dart';
import '../../core/network/websocket_client.dart';
import '../../core/theme/colors.dart';
import '../../models/message_payload.dart';
import '../../state/chat_provider.dart';
import '../../state/connection_provider.dart';
import '../widgets/attachment_bottom_sheet.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/voice_note_recorder.dart';

class ChatRoomScreen extends ConsumerStatefulWidget {
  final String contactName;
  final String contactUid;
  final String contactPublicKey;

  const ChatRoomScreen({
    Key? key,
    required this.contactName,
    required this.contactUid,
    required this.contactPublicKey,
  }) : super(key: key);

  @override
  ConsumerState<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends ConsumerState<ChatRoomScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String? _myUid;
  ChatMessage? _replyTo;
  String? _highlightedMessageId;
  final Map<String, GlobalKey> _messageKeys = {};
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onTextChanged);
    _initAsync();
    _scrollController.addListener(_onScroll);
  }

  void _onTextChanged() {
    if (mounted) setState(() {}); // swap mic <-> send button live
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _textController.dispose();
    MessageRouter.openChatId = null;
    super.dispose();
  }

  static const int _maxMessageKeys = 200;

  bool _showFab = false;

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final nearBottom = _scrollController.position.maxScrollExtent -
            _scrollController.position.pixels <
        400;
    if (nearBottom != !_showFab) {
      // invert: show when NOT near bottom
      if (mounted) setState(() => _showFab = !nearBottom);
    }
    if (_scrollController.position.pixels < 200 && _myUid != null) {
      final chatId = buildChatId(_myUid!, widget.contactUid);
      ref.read(activeChatMessagesProvider(chatId).notifier).loadMore();
    }
    _evictStaleKeys();
  }

  String _dateLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${d.day}/${d.month}/${d.year}';
  }

  bool _isSameDay(int a, int b) {
    final da = DateTime.fromMillisecondsSinceEpoch(a);
    final db = DateTime.fromMillisecondsSinceEpoch(b);
    return da.year == db.year && da.month == db.month && da.day == db.day;
  }

  /// Cap GlobalKey map at 200 entries to prevent unbounded memory growth.
  /// Removes keys for messages that are far from the current scroll position.
  void _evictStaleKeys() {
    if (_messageKeys.length <= _maxMessageKeys) return;
    final messages = ref.read(activeChatMessagesProvider(
      buildChatId(_myUid!, widget.contactUid),
    ));
    final visibleIds = messages.take(200).map((m) => m.id).toSet();
    _messageKeys.keys
        .where((id) => !visibleIds.contains(id))
        .toList()
        .forEach(_messageKeys.remove);
  }

  Future<void> _initAsync() async {
    final uid = await KeyStore.getUid();
    if (uid != null) {
      setState(() => _myUid = uid);
      final chatId = buildChatId(uid, widget.contactUid);
      MessageRouter.openChatId = chatId;
      await NotificationService.instance.cancelForChat(widget.contactUid);
      // Quick reply typed on the notification card while app was alive.
      final pendingReply = NotificationService.consumePendingReply(widget.contactUid);
      if (pendingReply != null && pendingReply.isNotEmpty) {
        ref.read(activeChatMessagesProvider(chatId).notifier).sendTextMessage(
          recipientUid: widget.contactUid,
          recipientPublicKeyBase64: widget.contactPublicKey,
          text: pendingReply,
        );
      }
      // Existing delivered messages become read once this chat is open.
      await ref
          .read(activeChatMessagesProvider(chatId).notifier)
          .markIncomingAsRead();
    }
  }

  void _startReply(ChatMessage msg) {
    setState(() => _replyTo = msg);
    FocusScope.of(context).unfocus();
  }

  void _cancelReply() {
    if (mounted) setState(() => _replyTo = null);
  }

  /// Jump to the original message when its quote is tapped.
  void _jumpToMessage(String messageId) {
    final key = _messageKeys[messageId];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.35,
      );
    }
    _highlightTimer?.cancel();
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty || _myUid == null) return;

    final chatId = buildChatId(_myUid!, widget.contactUid);
    ref.read(activeChatMessagesProvider(chatId).notifier).sendTextMessage(
      recipientUid: widget.contactUid,
      recipientPublicKeyBase64: widget.contactPublicKey,
      text: text,
      replyTo: _replyTo,
    );
    _textController.clear();
    _cancelReply();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---------- Encrypted media sending ----------

  bool _isMediaBusy = false;

  Future<void> _sendEncryptedMedia({
    required Uint8List bytes,
    required String fileName,
    required String messageType,
  }) async {
    if (_isMediaBusy || _myUid == null) return;
    _isMediaBusy = true;

    final chatId = buildChatId(_myUid!, widget.contactUid);
    final notifier = ref.read(activeChatMessagesProvider(chatId).notifier);

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text("Encrypting & uploading…"),
      duration: Duration(seconds: 1),
    ));

    try {
      final result = await MediaPipeline.encryptAndUploadBytes(
        bytes: bytes,
        backendUrl: ApiClient.defaultBaseUrl,
      );

      await notifier.sendMessage(
        recipientUid: widget.contactUid,
        recipientPublicKeyBase64: widget.contactPublicKey,
        text: fileName,
        type: messageType,
        mediaKey: result.fileKey,
        secretKeyHex: result.secretKeyHex,
        nonceHex: result.nonceHex,
        replyTo: _replyTo,
      );
      _cancelReply();
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Upload failed: $e"),
          backgroundColor: Colors.red.shade700,
        ));
      }
    } finally {
      _isMediaBusy = false;
    }
  }

  /// Encrypt + upload a recorded voice note. Duration label rides in the
  /// encrypted text field so the recipient's player shows the right length.
  Future<void> _sendVoiceNote(String path, Duration duration) async {
    try {
      final bytes = await File(path).readAsBytes();
      final m = duration.inMinutes.remainder(60).toString();
      final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
      await _sendEncryptedMedia(
        bytes: bytes,
        fileName: '$m:$s',
        messageType: 'voice',
      );
    } catch (_) {}
  }

  Future<bool> _ensurePermission(Permission permission, String deniedMsg) async {
    var status = await permission.status;
    if (status.isGranted || status.isLimited) return true;
    status = await permission.request();
    if (status.isGranted || status.isLimited) return true;
    if (status.isPermanentlyDenied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(deniedMsg),
        action: SnackBarAction(
          label: 'Settings',
          onPressed: () => openAppSettings(),
        ),
      ));
    }
    return false;
  }

  Future<void> _pickAndSendImage({required ImageSource source}) async {
    if (source == ImageSource.camera) {
      final ok = await _ensurePermission(
          Permission.camera, 'Camera access is disabled. Enable it in Settings.');
      if (!ok) return;
    } else {
      // Gallery: Permission.photos only exists on Android 13+. On older
      // devices requesting it always fails and blocks the picker entirely.
      // The system photo picker itself needs no permission; only legacy
      // Android (<13) may need READ_EXTERNAL_STORAGE.
      if (!kIsWeb && Platform.isAndroid) {
        final sdk = int.tryParse(await DeviceInfoHelper.androidSdkInt()) ?? 33;
        if (sdk < 33) {
          final ok = await _ensurePermission(
              Permission.storage,
              'Storage access is disabled. Enable it in Settings.');
          if (!ok) return;
        }
      }
    }
    try {
      // Downscale to 1080p max before encryption — reduces encrypt/upload
      // time by ~80% vs 108MP originals and prevents OOM on large sensors.
      final picked = await ImagePicker().pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1080,
        maxHeight: 1080,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      await _sendEncryptedMedia(
        bytes: bytes,
        fileName: "Photo",
        messageType: 'image',
      );
    } catch (e) {
      debugPrint('[AirChat] image pick failed: $e');
    }
  }

  static const int _maxFileSizeBytes = 25 * 1024 * 1024; // 25 MB server limit

  Future<void> _pickAndSendDocument() async {
    try {
      final files = await FilePicker.pickFiles();
      final file = files.isNotEmpty ? files.single : null;
      if (file == null) return;

      // Reject files over 25 MB before loading into memory — prevents OOM.
      final fileSize = await file.length();
      if (fileSize > _maxFileSizeBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("File too large — maximum is 25 MB"),
            backgroundColor: Colors.red,
          ));
        }
        return;
      }

      final bytes = await file.readAsBytes();
      await _sendEncryptedMedia(
        bytes: bytes,
        fileName: file.name,
        messageType: 'document',
      );
    } catch (_) {}
  }

  void _openAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => AttachmentBottomSheet(
        onOptionSelected: (type) {
          // Sheet pops itself before invoking this callback.
          switch (type) {
            case 'camera':
              _pickAndSendImage(source: ImageSource.camera);
              break;
            case 'gallery':
              _pickAndSendImage(source: ImageSource.gallery);
              break;
            case 'document':
              _pickAndSendDocument();
              break;
            default:
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('$type coming soon')),
              );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_myUid == null) {
      return Scaffold(
        backgroundColor: AirColors.background,
        appBar: AppBar(
          title: Text(widget.contactName),
        ),
        body: const Center(child: CircularProgressIndicator(color: AirColors.accent, strokeWidth: 2)),
      );
    }

    final chatId = buildChatId(_myUid!, widget.contactUid);

    // Auto-scroll to bottom whenever a new message lands (incoming or outgoing)
    ref.listen(activeChatMessagesProvider(chatId), (prev, next) {
      if (next.length > (prev?.length ?? 0)) {
        _scrollToBottom();
        // Chat is open → new incoming messages are instantly read.
        ref
            .read(activeChatMessagesProvider(chatId).notifier)
            .markIncomingAsRead();
      }
    });

    final messages = ref.watch(activeChatMessagesProvider(chatId));

    return Scaffold(
      backgroundColor: AirColors.background,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            _MonogramAvatar(name: widget.contactName),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.contactName,
                  style: const TextStyle(fontSize: 16, color: AirColors.textPrimary, fontWeight: FontWeight.w600, letterSpacing: -0.2),
                ),
                const SizedBox(height: 1),
                ConnectionBadge(uid: _myUid!),
              ],
            ),
          ],
        ),
      ),
      floatingActionButton: _showFab
          ? FloatingActionButton.small(
              backgroundColor: AirColors.surfaceElevated,
              foregroundColor: AirColors.textPrimary,
              onPressed: _scrollToBottom,
              child: const Icon(Icons.arrow_downward, size: 18),
            )
          : null,
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.lock_outline, size: 40, color: AirColors.textFaint),
                        const SizedBox(height: 14),
                        const Text(
                          "No messages yet",
                          style: TextStyle(color: AirColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          "Everything you send is end-to-end encrypted.",
                          style: TextStyle(color: AirColors.textSecondary, fontSize: 13),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    cacheExtent: 300,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      final showDateDivider = index == 0 ||
                          !_isSameDay(messages[index - 1].timestamp, msg.timestamp);
                      final msgKey = _messageKeys.putIfAbsent(
                          msg.id, () => GlobalKey());
                      return Column(
                        children: [
                          if (showDateDivider)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AirColors.surfaceLight,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  _dateLabel(msg.timestamp),
                                  style: const TextStyle(
                                      color: AirColors.textSecondary, fontSize: 11),
                                ),
                              ),
                            ),
                          Container(
                            key: ValueKey('slot_${msg.id}'),
                            child: ChatBubble(
                              key: msgKey,
                              text: msg.text,
                              isMe: msg.isMe,
                              timestamp: msg.timestamp,
                              status: msg.status,
                              type: msg.type,
                              mediaKey: msg.mediaKey,
                              secretKeyHex: msg.secretKeyHex,
                              nonceHex: msg.nonceHex,
                              backendUrl: ApiClient.defaultBaseUrl,
                              peerName: widget.contactName,
                              replyToId: msg.replyToId,
                              replyText: msg.replyText,
                              replyType: msg.replyType,
                              replyIsMe: msg.replyIsMe,
                              highlighted:
                                  _highlightedMessageId == msg.id,
                              onSwipeReply: () => _startReply(msg),
                              onTapQuote: msg.hasReply
                                  ? () => _jumpToMessage(msg.replyToId!)
                                  : null,
                              onRetryFailed: msg.isMe && msg.status == 'failed'
                                  ? () => ref
                                      .read(activeChatMessagesProvider(chatId)
                                          .notifier)
                                      .resendMessage(
                                        msg,
                                        recipientPublicKeyBase64:
                                            widget.contactPublicKey,
                                      )
                                  : null,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          if (_replyTo != null)
            ReplyPreviewBar(
              message: _replyTo!,
              peerName: widget.contactName,
              onCancel: _cancelReply,
              onTap: () => _jumpToMessage(_replyTo!.id),
            ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: const BoxDecoration(
        color: AirColors.background,
        border: Border(top: BorderSide(color: AirColors.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Semantics(
              label: 'Attach media',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.add_circle_outline,
                    color: AirColors.textSecondary, size: 26),
                onPressed: _openAttachmentSheet,
              ),
            ),
            Expanded(
              child: TextField(
                controller: _textController,
                style: const TextStyle(color: AirColors.textPrimary, fontSize: 15),
                cursorColor: AirColors.accent,
                decoration: InputDecoration(
                  hintText: "Message",
                  hintStyle: const TextStyle(color: AirColors.textFaint),
                  filled: true,
                  fillColor: AirColors.surfaceLight,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 8),
            // Mic when the field is empty, send arrow otherwise.
            _textController.text.isEmpty
                ? VoiceNoteRecorder(
                    onComplete: (recording) =>
                        _sendVoiceNote(recording.path, recording.duration),
                    onPermissionDenied: () {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content:
                            Text("Microphone access is disabled. Enable it in Settings."),
                      ));
                    },
                  )
                : GestureDetector(
                    onTap: _sendMessage,
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                        color: AirColors.bubbleMe,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.arrow_upward,
                          color: AirColors.bubbleMeText, size: 20),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

/// Quoted-message strip shown above the input bar while composing a reply.
class ReplyPreviewBar extends StatelessWidget {
  final ChatMessage message;
  final String peerName;
  final VoidCallback onCancel;
  final VoidCallback onTap;

  const ReplyPreviewBar({
    Key? key,
    required this.message,
    required this.peerName,
    required this.onCancel,
    required this.onTap,
  }) : super(key: key);

  String get _preview {
    switch (message.type) {
      case 'image':
        return '\u{1F4F7} Photo';
      case 'document':
        return '\u{1F4CE} ${message.text.isEmpty ? 'Document' : message.text}';
      case 'voice':
        return '\u{1F3A4} Voice note';
      default:
        return message.text;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AirColors.background,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AirColors.divider)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AirColors.surfaceLight,
                    border: const Border(
                      left: BorderSide(color: AirColors.accent, width: 3),
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        message.isMe ? 'Replying to yourself' : 'Replying to $peerName',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AirColors.accent,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AirColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20, color: AirColors.textSecondary),
                onPressed: onCancel,
                splashRadius: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MonogramAvatar extends StatelessWidget {
  final String name;
  const _MonogramAvatar({Key? key, required this.name}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final letter =
        name.isNotEmpty ? name[0].toUpperCase() : 'P';
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AirColors.surfaceLight,
        border: Border.all(color: AirColors.border),
      ),
      child: Text(
        letter,
        style: const TextStyle(
          color: AirColors.textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
    );
  }
}

class ConnectionBadge extends ConsumerWidget {
  final String uid;

  const ConnectionBadge({Key? key, required this.uid}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(tunnelStateProvider(uid));
    final state = asyncState.asData?.value ?? TunnelState.connecting;
    final isConnected = state == TunnelState.connected;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isConnected ? AirColors.textPrimary : AirColors.textFaint,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          isConnected ? "Online" : "Connecting…",
          style: TextStyle(
            color: isConnected ? AirColors.textSecondary : AirColors.textFaint,
            fontSize: 11,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}
