import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/key_store.dart';
import '../../core/crypto/signing_engine.dart';
import '../../core/database/daos/contact_dao.dart';
import '../../core/database/daos/message_dao.dart';
import '../../core/device/device_info_helper.dart';
import '../../core/network/api_client.dart';
import '../../core/network/media_uploader.dart';
import '../../core/theme/colors.dart';
import '../../state/refresh_bus.dart';
import '../../core/database/daos/group_dao.dart';
import '../../models/group.dart';
import '../../models/message_payload.dart';
import '../../state/chat_provider.dart';
import '../../state/connection_provider.dart';
import '../widgets/attachment_bottom_sheet.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/send_button.dart';
import '../widgets/voice_note_recorder.dart';
import 'group_info_screen.dart';

class GroupChatScreen extends ConsumerStatefulWidget {
  final Group group;
  const GroupChatScreen({Key? key, required this.group}) : super(key: key);
  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends ConsumerState<GroupChatScreen>
    with WidgetsBindingObserver {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  String? _myUid;
  ChatMessage? _replyTo;
  String? _highlightedMessageId;
  final Map<String, GlobalKey> _messageKeys = {};
  Timer? _highlightTimer;
  bool _showFab = false;
  bool _userScrolling = false;
  bool _initialDone = false;
  bool _isMediaBusy = false;

  @override
  void initState() {
    super.initState();
    // No text listener setState — mic/send swap uses ValueListenableBuilder.
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _initAsync();
  }

  @override
  void didChangeMetrics() {
    // Keyboard open/close resizes the list: re-pin if user was at bottom.
    // Never while the finger is down.
    if (!_scrollController.hasClients || _userScrolling) return;
    final max = _scrollController.position.maxScrollExtent;
    final pixels = _scrollController.position.pixels;
    if (max - pixels < 200) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _initAsync() async {
    final uid = await KeyStore.getUid();
    if (mounted && uid != null) setState(() => _myUid = uid);
    MessageRouter.openChatId = widget.group.id;
    await GroupDao().resetUnread(widget.group.id);
  }

  static const int _maxMessageKeys = 200;

  bool _loadingMore = false;

  void _onScroll() {
    if (!_scrollController.hasClients || _myUid == null) return;
    final nearBottom =
        _scrollController.position.maxScrollExtent -
            _scrollController.position.pixels <
        400;
    if (nearBottom != !_showFab) setState(() => _showFab = !nearBottom);
    if (_scrollController.position.pixels < 200 && !_loadingMore) {
      // Single-flight: overlapping loadMore→jumpTo corrections used to fight
      // the fling's momentum, teleporting the list by pages per swipe.
      _loadingMore = true;
      final beforeMax = _scrollController.position.maxScrollExtent;
      final beforePixels = _scrollController.position.pixels;
      final beforeCount =
          ref.read(activeChatMessagesProvider(widget.group.id)).length;
      ref
          .read(activeChatMessagesProvider(widget.group.id).notifier)
          .loadMore()
          .then((_) {
            _loadingMore = false;
            if (!_scrollController.hasClients || !mounted) return;
            final afterCount =
                ref.read(activeChatMessagesProvider(widget.group.id)).length;
            // Correct the offset only if content actually grew above;
            // otherwise leave the fling's momentum untouched.
            if (afterCount > beforeCount) {
              final afterMax = _scrollController.position.maxScrollExtent;
              _scrollController.jumpTo(afterMax - beforeMax + beforePixels);
            }
          });
    }
    _evictStaleKeys();
  }

  /// Cap the GlobalKey map so long-lived group chats don't grow unbounded.
  void _evictStaleKeys() {
    if (_messageKeys.length <= _maxMessageKeys) return;
    final messages = ref.read(activeChatMessagesProvider(widget.group.id));
    final visibleIds = messages.take(_maxMessageKeys).map((m) => m.id).toSet();
    _messageKeys.keys
        .where((id) => !visibleIds.contains(id))
        .toList()
        .forEach(_messageKeys.remove);
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

  void _jumpToMessage(String id) {
    final key = _messageKeys[id];
    final ctx = key?.currentContext;
    if (ctx != null)
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.35,
      );
    _highlightTimer?.cancel();
    setState(() => _highlightedMessageId = id);
    _highlightTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  Future<void> _fanOut({
    required String text,
    required String type,
    String? mediaKey,
    String? secretKeyHex,
    String? nonceHex,
    ChatMessage? replyTo,
  }) async {
    if (_myUid == null) return;
    final myUid = _myUid!;
    final group = widget.group;
    final fresh = await GroupDao().getGroupById(group.id);
    if (fresh == null || !fresh.memberUids.contains(myUid)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('You left this group')));
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
      return;
    }
    final packetId = const Uuid().v4();
    final ts = DateTime.now().millisecondsSinceEpoch;

    // Resolve sender display name for the notification.
    final senderName = await _resolveMyDisplayName(myUid);

    // Capture the reply BEFORE any await — the caller clears `_replyTo`
    // synchronously right after this call.
    final msg = ChatMessage(
      id: packetId,
      chatId: group.id,
      senderUid: myUid,
      recipientUid: group.id,
      text: text,
      type: type,
      mediaKey: mediaKey,
      secretKeyHex: secretKeyHex,
      nonceHex: nonceHex,
      timestamp: ts,
      isMe: true,
      status: 'sending',
      replyToId: replyTo?.id,
      replyText: replyTo?.text ?? '',
      replyType: replyTo?.type ?? 'text',
      replyIsMe: replyTo?.isMe,
      groupId: group.id,
      groupSenderName: senderName,
    );
    await MessageDao().insertMessage(msg);
    // Targeted event: appends the new row + refreshes the home preview without
    // re-reading the page (which would reset pagination and jump the scroll).
    ref
        .read(refreshBusProvider)
        .fire(RefreshEvent(type: 'messages', chatId: group.id));

    await _dispatchGroupPayload(
      packetId: packetId,
      text: text,
      type: type,
      mediaKey: mediaKey,
      secretKeyHex: secretKeyHex,
      nonceHex: nonceHex,
      replyId: replyTo?.id,
      replyText: replyTo?.text,
      replyType: replyTo?.type,
      replyIsMe: replyTo?.isMe,
      group: fresh,
      myUid: myUid,
      senderName: senderName,
    );
    _scheduleGroupSendTimeout(packetId);
  }

  /// Retries a group message that never reached the relay.
  Future<void> _resendGroupMessage(ChatMessage msg) async {
    final groupId = msg.groupId ?? widget.group.id;
    final group = await GroupDao().getGroupById(groupId);
    if (group == null) return;
    await MessageDao().updateMessageStatus(msg.id, 'sending');
    ref
        .read(refreshBusProvider)
        .fire(
          RefreshEvent(type: 'status', messageId: msg.id, status: 'sending'),
        );
    final senderName = await _resolveMyDisplayName(msg.senderUid);
    await _dispatchGroupPayload(
      packetId: msg.id,
      text: msg.text,
      type: msg.type,
      mediaKey: msg.mediaKey,
      secretKeyHex: msg.secretKeyHex,
      nonceHex: msg.nonceHex,
      replyId: msg.replyToId,
      replyText: msg.replyText,
      replyType: msg.replyType,
      replyIsMe: msg.replyIsMe,
      group: group,
      myUid: msg.senderUid,
      senderName: senderName,
    );
    _scheduleGroupSendTimeout(msg.id);
  }

  /// Marks a group message failed if the relay never acknowledges it.
  void _scheduleGroupSendTimeout(String packetId) {
    Timer(const Duration(seconds: 12), () async {
      final stored = await MessageDao().getMessageById(packetId);
      if (stored == null || stored.status != 'sending') return;
      await MessageDao().updateMessageStatus(packetId, 'failed');
      // The DB flip above is the source of truth; only the live UI patch
      // needs a mounted screen.
      if (!mounted) return;
      ref
          .read(refreshBusProvider)
          .fire(
            RefreshEvent(type: 'status', messageId: packetId, status: 'failed'),
          );
    });
  }

  /// Encrypts once with the shared group key and sends a single packet, or
  /// falls back to per-member fan-out for legacy groups with no key.
  Future<void> _dispatchGroupPayload({
    required String packetId,
    required String text,
    required String type,
    String? mediaKey,
    String? secretKeyHex,
    String? nonceHex,
    String? replyId,
    String? replyText,
    String? replyType,
    bool? replyIsMe,
    required Group group,
    required String myUid,
    required String senderName,
  }) async {
    final groupKey = group.groupKey;
    if (groupKey == null || groupKey.isEmpty) {
      // Fallback: no groupKey yet (stale local record) — use legacy N-send.
      await _legacyFanOut(
        text: text,
        type: type,
        mediaKey: mediaKey,
        secretKeyHex: secretKeyHex,
        nonceHex: nonceHex,
        replyId: replyId,
        replyText: replyText,
        replyType: replyType,
        replyIsMe: replyIsMe,
        group: group,
        myUid: myUid,
        packetId: packetId,
      );
      return;
    }

    final engine = ref.read(sodiumEngineProvider);

    // Sign the message so receivers can verify it came from a member
    // (not the relay or an outsider). Missing key = unsigned (compat).
    String msgSig = '';
    try {
      final signingKp = await KeyStore.getSigningKeyPair();
      if (signingKp != null) {
        msgSig = await SigningEngine().signHex(
          '$packetId|$text|${group.id}',
          signingKp,
        );
      }
    } catch (_) {}

    // Build the plaintext payload that all members will see after decryption.
    final payload = jsonEncode({
      'text': text,
      'type': type,
      if (mediaKey != null) 'mediaKey': mediaKey,
      if (secretKeyHex != null) 'secretKeyHex': secretKeyHex,
      if (nonceHex != null) 'nonceHex': nonceHex,
      'groupId': group.id,
      'groupName': group.name,
      'senderUid': myUid,
      'senderName': senderName,
      if (msgSig.isNotEmpty) 'sig': msgSig,
      if (replyId != null)
        'replyTo': {
          'id': replyId,
          'text': replyText ?? '',
          'type': replyType ?? 'text',
          'isMe': replyIsMe,
        },
    });

    try {
      final enc = await engine.encryptGroupMessage(
        plainText: payload,
        groupKeyBase64: groupKey,
      );
      ref
          .read(websocketClientProvider(myUid))
          .sendGroupPacket(
            groupId: group.id,
            groupName: group.name,
            encryptedPayload: enc.encode(),
            packetId: packetId,
            senderName: senderName,
          );
    } catch (e) {
      debugPrint('[AirChat] group send failed: $e');
      // Fallback to legacy N-send if symmetric encryption fails.
      await _legacyFanOut(
        text: text,
        type: type,
        mediaKey: mediaKey,
        secretKeyHex: secretKeyHex,
        nonceHex: nonceHex,
        replyId: replyId,
        replyText: replyText,
        replyType: replyType,
        replyIsMe: replyIsMe,
        group: group,
        myUid: myUid,
        packetId: packetId,
      );
    }
  }

  /// Legacy fallback: encrypt individually for each member via X25519.
  /// Used when groupKey is unavailable (e.g. pre-migration groups).
  Future<void> _legacyFanOut({
    required String text,
    required String type,
    String? mediaKey,
    String? secretKeyHex,
    String? nonceHex,
    String? replyId,
    String? replyText,
    String? replyType,
    bool? replyIsMe,
    required Group group,
    required String myUid,
    required String packetId,
  }) async {
    final engine = ref.read(sodiumEngineProvider);
    final kp = await KeyStore.getKeyPair();
    if (kp == null) return;
    for (final uid in group.memberUids) {
      if (uid == myUid) continue;
      try {
        final contact = await ContactDao().getContactByUid(uid);
        final pub = contact?.identityPublicKey;
        if (pub == null || pub.isEmpty) continue;
        final recipientPub = await engine.importPublicKey(pub);
        final payload = jsonEncode({
          'text': text,
          'type': type,
          if (mediaKey != null) 'mediaKey': mediaKey,
          if (secretKeyHex != null) 'secretKeyHex': secretKeyHex,
          if (nonceHex != null) 'nonceHex': nonceHex,
          'groupId': group.id,
          'groupName': group.name,
          'senderUid': myUid,
          if (replyId != null)
            'replyTo': {
              'id': replyId,
              'text': replyText ?? '',
              'type': replyType ?? 'text',
              'isMe': replyIsMe,
            },
        });
        final enc = await engine.encryptMessage(
          plainText: payload,
          recipientPublicKey: recipientPub,
          senderKeyPair: kp,
        );
        ref
            .read(websocketClientProvider(myUid))
            .sendPacket(
              recipientUid: uid,
              encryptedPayload: enc.encode(),
              packetId: packetId,
            );
      } catch (_) {}
    }
  }

  Future<String> _resolveMyDisplayName(String uid) async {
    // 1. Primary: use the real registered username from secure storage.
    try {
      final storedName = await KeyStore.getUsername();
      if (storedName != null && storedName.isNotEmpty) return storedName;
    } catch (_) {}
    // 2. Fallback: look up in contacts DB.
    try {
      final contact = await ContactDao().getContactByUid(uid);
      if (contact != null && contact.username.isNotEmpty)
        return contact.username;
    } catch (_) {}
    return 'You';
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _fanOut(text: text, type: 'text', replyTo: _replyTo);
    _textController.clear();
    setState(() => _replyTo = null);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      // Never fight the finger: if the user is mid-drag, skip this cycle.
      // The next message (or drag end) will re-pin.
      if (_userScrolling) return;
      if (!_initialDone) {
        _initialDone = true;
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      } else {
        final nearBottom =
            _scrollController.position.maxScrollExtent -
                _scrollController.position.pixels <
            120;
        if (nearBottom) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  Future<void> _sendEncryptedMedia({
    required Uint8List bytes,
    required String fileName,
    required String messageType,
  }) async {
    if (_isMediaBusy) return;
    _isMediaBusy = true;
    // Capture the reply now — the upload below can take seconds and the user
    // may have dismissed the reply bar by then.
    final pendingReply = _replyTo;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Encrypting & uploading…'),
        duration: Duration(seconds: 1),
      ),
    );
    try {
      final result = await MediaPipeline.encryptAndUploadBytes(
        bytes: bytes,
        backendUrl: ApiClient.defaultBaseUrl,
      );
      await _fanOut(
        text: fileName,
        type: messageType,
        mediaKey: result.fileKey,
        secretKeyHex: result.secretKeyHex,
        nonceHex: result.nonceHex,
        replyTo: pendingReply,
      );
      if (mounted) setState(() => _replyTo = null);
      _scrollToBottom();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload failed: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
    } finally {
      _isMediaBusy = false;
    }
  }

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

  Future<bool> _ensurePermission(Permission p, String msg) async {
    var s = await p.status;
    if (s.isGranted || s.isLimited) return true;
    s = await p.request();
    if (s.isGranted || s.isLimited) return true;
    if (s.isPermanentlyDenied && mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: () => openAppSettings(),
          ),
        ),
      );
    return false;
  }

  Future<void> _pickAndSendImage({required ImageSource source}) async {
    if (source == ImageSource.camera) {
      if (!await _ensurePermission(
        Permission.camera,
        'Camera access disabled.',
      ))
        return;
    } else if (!kIsWeb && Platform.isAndroid) {
      final sdk = int.tryParse(await DeviceInfoHelper.androidSdkInt()) ?? 33;
      if (sdk < 33 &&
          !await _ensurePermission(
            Permission.storage,
            'Storage access disabled.',
          ))
        return;
    }
    try {
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
        fileName: 'Photo',
        messageType: 'image',
      );
    } catch (e) {
      debugPrint('[AirChat] image pick failed: $e');
    }
  }

  Future<void> _pickAndSendDocument() async {
    try {
      final files = await FilePicker.pickFiles();
      final file = files.isNotEmpty ? files.single : null;
      if (file == null) return;
      if (await file.length() > 25 * 1024 * 1024) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('File too large — max 25 MB'),
              backgroundColor: Colors.red,
            ),
          );
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
      builder: (_) => AttachmentBottomSheet(
        onOptionSelected: (type) {
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
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('$type coming soon')));
          }
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _highlightTimer?.cancel();
    _scrollController.dispose();
    _textController.dispose();
    MessageRouter.openChatId = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_myUid == null) {
      return Scaffold(
        backgroundColor: AirColors.background,
        appBar: AppBar(title: Text(widget.group.name)),
        body: const Center(
          child: CircularProgressIndicator(
            color: AirColors.accent,
            strokeWidth: 2,
          ),
        ),
      );
    }
    ref.listen(activeChatMessagesProvider(widget.group.id), (prev, next) {
      if (next.length > (prev?.length ?? 0)) _scrollToBottom();
    });
    final messages = ref.watch(activeChatMessagesProvider(widget.group.id));
    // Built once per list build so per-item reply checks stay O(1).
    final _messageIds = messages.map((m) => m.id).toSet();
    return Scaffold(
      backgroundColor: AirColors.background,
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GroupInfoScreen(group: widget.group),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AirColors.surfaceLight,
                  border: Border.all(color: AirColors.border),
                ),
                child: Text(
                  widget.group.name.isNotEmpty
                      ? widget.group.name[0].toUpperCase()
                      : 'G',
                  style: const TextStyle(
                    color: AirColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.group.name,
                    style: const TextStyle(
                      fontSize: 16,
                      color: AirColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${widget.group.memberUids.length} members',
                    style: const TextStyle(
                      color: AirColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline, color: AirColors.textPrimary),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => GroupInfoScreen(group: widget.group),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: AnimatedScale(
        scale: _showFab ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutBack,
        child: FloatingActionButton.small(
          backgroundColor: AirColors.surfaceElevated,
          foregroundColor: _showFab ? AirColors.textPrimary : Colors.transparent,
          onPressed: _showFab ? _scrollToBottom : null,
          child: const Icon(Icons.arrow_downward, size: 18),
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
                        Icon(
                          Icons.lock_outline,
                          size: 40,
                          color: AirColors.textFaint,
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'No messages yet',
                          style: TextStyle(
                            color: AirColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Everything you send is end-to-end encrypted.',
                          style: TextStyle(
                            color: AirColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n is ScrollStartNotification) {
                        _userScrolling = true;
                      } else if (n is ScrollEndNotification) {
                        _userScrolling = false;
                      }
                      return false;
                    },
                    child: ListView.builder(
                      controller: _scrollController,
                      // Large enough that flings don't outrun layout (which
                      // caused extent jumps mid-scroll).
                      cacheExtent: 800,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 12,
                      ),
                      itemCount: messages.length,
                      itemBuilder: (_, index) {
                        final msg = messages[index];
                        final showDateDivider =
                            index == 0 ||
                            !_isSameDay(
                              messages[index - 1].timestamp,
                              msg.timestamp,
                            );
                        final effectiveReplyText =
                            msg.hasReply && !_messageIds.contains(msg.replyToId)
                            ? 'Message deleted'
                            : msg.replyText;
                        final msgKey = _messageKeys.putIfAbsent(
                          msg.id,
                          () => GlobalKey(),
                        );
                        return Column(
                          children: [
                            if (showDateDivider)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AirColors.surfaceLight,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    _dateLabel(msg.timestamp),
                                    style: const TextStyle(
                                      color: AirColors.textSecondary,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ),
                            ChatBubble(
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
                              peerName: msg.groupSenderName ?? '',
                              groupSenderName: msg.groupSenderName,
                              replyToId: msg.replyToId,
                              replyText: effectiveReplyText,
                              replyType: effectiveReplyText == 'Message deleted'
                                  ? 'text'
                                  : msg.replyType,
                              replyIsMe: msg.replyIsMe,
                              highlighted: _highlightedMessageId == msg.id,
                              onSwipeReply: () =>
                                  setState(() => _replyTo = msg),
                              onTapQuote: msg.hasReply
                                  ? () => _jumpToMessage(msg.replyToId!)
                                  : null,
                              onRetryFailed:
                                  msg.isMe &&
                                      (msg.status == 'failed' ||
                                          msg.status == 'expired')
                                  ? () => _resendGroupMessage(msg)
                                  : null,
                              onDeleteForMe: () async {
                                await MessageDao().deleteMessage(msg.id);
                                _messageKeys.remove(msg.id);
                                if (!mounted) return;
                                ref
                                    .read(
                                      activeChatMessagesProvider(
                                        widget.group.id,
                                      ).notifier,
                                    )
                                    .removeLocalMessage(msg.id);
                                ref
                                    .read(refreshBusProvider)
                                    .fire(
                                      RefreshEvent(
                                        type: 'messages',
                                        chatId: widget.group.id,
                                      ),
                                    );
                              },
                            ),
                          ],
                        );
                      },
                    ),
                  ),
          ),
          if (_replyTo != null)
            Container(
              color: AirColors.background,
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
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
                            _replyTo!.isMe
                                ? 'Replying to yourself'
                                : 'Replying to ${_replyTo!.groupSenderName ?? 'peer'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AirColors.accent,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _replyTo!.text.isEmpty
                                ? _replyTo!.type
                                : _replyTo!.text,
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
                    icon: const Icon(
                      Icons.close,
                      size: 20,
                      color: AirColors.textSecondary,
                    ),
                    onPressed: () => setState(() => _replyTo = null),
                  ),
                ],
              ),
            ),
          Container(
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
                    icon: const Icon(
                      Icons.add_circle_outline,
                      color: AirColors.textSecondary,
                      size: 26,
                    ),
                    onPressed: _openAttachmentSheet,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      style: const TextStyle(
                        color: AirColors.textPrimary,
                        fontSize: 15,
                      ),
                      cursorColor: AirColors.accent,
                      decoration: InputDecoration(
                        hintText: 'Message',
                        hintStyle: const TextStyle(color: AirColors.textFaint),
                        filled: true,
                        fillColor: AirColors.surfaceLight,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 11,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _textController,
                    builder: (context, value, _) {
                      if (value.text.isEmpty) {
                        return VoiceNoteRecorder(
                          onComplete: (r) => _sendVoiceNote(r.path, r.duration),
                        );
                      }
                      return SendButton(onSend: _sendMessage);
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
