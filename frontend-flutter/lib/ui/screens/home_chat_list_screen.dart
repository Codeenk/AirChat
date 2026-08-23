import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/database/daos/contact_dao.dart';
import '../../core/network/api_client.dart';
import '../../core/theme/colors.dart';
import '../../models/contact.dart';
import '../../models/chat_thread.dart';
import '../../state/chat_provider.dart';
import 'chat_room_screen.dart';
import 'qr_identity_screen.dart';
import 'qr_scanner_screen.dart';
import 'username_settings_screen.dart';
import '../widgets/airchat_logo.dart';

class HomeChatListScreen extends ConsumerStatefulWidget {
  const HomeChatListScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<HomeChatListScreen> createState() => _HomeChatListScreenState();
}

class _HomeChatListScreenState extends ConsumerState<HomeChatListScreen> {
  @override
  void initState() {
    super.initState();
    _refreshAfterInteraction();
  }

  void _refreshAfterInteraction() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(chatThreadsProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final asyncThreads = ref.watch(chatThreadsProvider);

    return Scaffold(
      backgroundColor: AirColors.background,
      appBar: AppBar(
        elevation: 0,
        title: const AirChatLogo(fontSize: 20),
        actions: [
          IconButton(
            icon: const Icon(Icons.badge_outlined, color: AirColors.textPrimary),
            tooltip: "Display name",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const UsernameSettingsScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_2, color: AirColors.textPrimary),
            tooltip: "My QR Code",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const QrIdentityScreen()),
              );
            },
          ),
        ],
      ),
      body: asyncThreads.when(
        loading: () => const Center(child: CircularProgressIndicator(color: AirColors.accent, strokeWidth: 2)),
        error: (err, _) => Center(
          child: Text("Error: $err", style: const TextStyle(color: AirColors.textSecondary)),
        ),
        data: (threads) => threads.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.lock_outline, size: 44, color: AirColors.textFaint),
                    const SizedBox(height: 16),
                    const Text(
                      "No chats yet",
                      style: TextStyle(color: AirColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      "Scan a peer's QR code to start an\nend-to-end encrypted conversation.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AirColors.textSecondary, fontSize: 13, height: 1.4),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const QrScannerScreen()),
                        );
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: AirColors.bubbleMe,
                        foregroundColor: AirColors.bubbleMeText,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                      ),
                      icon: const Icon(Icons.qr_code_scanner, size: 18),
                      label: const Text("Scan Contact QR"),
                    ),
                  ],
                ),
              )
            : ListView.separated(
                itemCount: threads.length,
                separatorBuilder: (_, __) => const Divider(color: AirColors.divider, height: 1, indent: 76),
                itemBuilder: (context, index) {
                  final thread = threads[index];
                  return _buildChatTile(context, thread);
                },
              ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AirColors.bubbleMe,
        foregroundColor: AirColors.bubbleMeText,
        shape: const CircleBorder(),
        child: const Icon(Icons.qr_code_scanner),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const QrScannerScreen()),
          );
        },
      ),
    );
  }

  Widget _buildChatTile(BuildContext context, ChatThread thread) {
    final timeStr = DateFormat('h:mm a').format(
      DateTime.fromMillisecondsSinceEpoch(thread.lastMessageTime),
    );

    String displayName = "Peer";
    Widget leading = _Avatar(letter: thread.contactUid.isNotEmpty ? thread.contactUid[0].toUpperCase() : 'P');

    return FutureBuilder(
      future: ContactDao().getContactByUid(thread.contactUid),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null) {
          final contact = snapshot.data!;
          displayName = contact.username;
          leading = _Avatar(letter: contact.username.isNotEmpty ? contact.username[0].toUpperCase() : 'P');
        }
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: leading,
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  displayName,
                  style: const TextStyle(
                    color: AirColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              Text(
                timeStr,
                style: const TextStyle(color: AirColors.textFaint, fontSize: 12),
              ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Text(
              thread.lastMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AirColors.textSecondary, fontSize: 14),
            ),
          ),
          onTap: () async {
            var contact = await ContactDao().getContactByUid(thread.contactUid);

            // Self-heal: missing or keyless contact gets resolved from directory
            if (contact == null || contact.identityPublicKey.isEmpty) {
              try {
                final info = await const ApiClient()
                    .lookupIdentity(uid: thread.contactUid);
                if (info != null) {
                  contact = Contact(
                    uid: thread.contactUid,
                    username: (info['username'] as String?) ?? 'Peer',
                    identityPublicKey:
                        (info['identity_public_key'] as String?) ?? '',
                    createdAt: DateTime.now().millisecondsSinceEpoch,
                  );
                  await ContactDao().insertContact(contact);
                }
              } catch (_) {}
            }

            if (contact == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Contact unavailable")),
              );
              return;
            }
            final resolved = Contact(
              uid: contact.uid,
              username: contact.username,
              identityPublicKey: contact.identityPublicKey,
              createdAt: contact.createdAt,
            );
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatRoomScreen(
                  contactName: resolved.username,
                  contactUid: resolved.uid,
                  contactPublicKey: resolved.identityPublicKey,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Avatar extends StatelessWidget {
  final String letter;
  const _Avatar({Key? key, required this.letter}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
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
          fontSize: 18,
        ),
      ),
    );
  }
}
