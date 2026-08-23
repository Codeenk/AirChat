import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/crypto/key_store.dart';
import '../../core/network/api_client.dart';
import '../../core/network/media_uploader.dart';
import '../../core/network/websocket_client.dart';
import '../../core/theme/colors.dart';
import '../../state/chat_provider.dart';
import '../../state/connection_provider.dart';
import '../widgets/attachment_bottom_sheet.dart';
import '../widgets/chat_bubble.dart';

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

  @override
  void initState() {
    super.initState();
    _initAsync();
  }

  Future<void> _initAsync() async {
    final uid = await KeyStore.getUid();
    if (uid != null) {
      setState(() => _myUid = uid);
    }
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty || _myUid == null) return;

    final chatId = buildChatId(_myUid!, widget.contactUid);
    ref.read(activeChatMessagesProvider(chatId).notifier).sendTextMessage(
      recipientUid: widget.contactUid,
      recipientPublicKeyBase64: widget.contactPublicKey,
      text: text,
    );
    _textController.clear();
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
      );
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
    final ok = source == ImageSource.camera
        ? await _ensurePermission(
            Permission.camera, 'Camera access is disabled. Enable it in Settings.')
        : await _ensurePermission(
            Permission.photos, 'Photo access is disabled. Enable it in Settings.');
    if (!ok) return;
    try {
      final picked =
          await ImagePicker().pickImage(source: source, imageQuality: 85);
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

  Future<void> _pickAndSendDocument() async {
    try {
      final result = await FilePicker.platform.pickFiles(withData: true);
      final file = result?.files.single;
      if (file == null) return;
      final bytes = file.bytes;
      if (bytes == null) return;
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
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      return ChatBubble(
                        text: msg.text,
                        isMe: msg.isMe,
                        timestamp: msg.timestamp,
                        status: msg.status,
                        type: msg.type,
                        mediaKey: msg.mediaKey,
                        secretKeyHex: msg.secretKeyHex,
                        nonceHex: msg.nonceHex,
                        backendUrl: ApiClient.defaultBaseUrl,
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
                      );
                    },
                  ),
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
            IconButton(
              icon: const Icon(Icons.add_circle_outline,
                  color: AirColors.textSecondary, size: 26),
              onPressed: _openAttachmentSheet,
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
            GestureDetector(
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
