import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../core/crypto/key_store.dart';
import '../../core/database/daos/chat_dao.dart';
import '../../core/database/daos/contact_dao.dart';
import '../../core/network/api_client.dart';
import '../../core/battery/battery_opt_helper.dart';
import '../../core/theme/colors.dart';
import '../../core/update/update_checker.dart';
import '../../models/contact.dart';
import '../../models/chat_thread.dart';
import '../../state/chat_provider.dart';
import 'chat_room_screen.dart';
import 'qr_identity_screen.dart';
import 'qr_scanner_screen.dart';
import 'notification_health_screen.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _onLaunch();
      if (mounted) await BatteryOptHelper.maybePromptOnFirstLaunch(context);
    });
  }

  /// On launch: if an update exists → prompt (every launch until updated).
  /// If already latest → show "What's new" exactly once per version, then
  /// never again until the next release.
  Future<void> _onLaunch() async {
    final packageInfo = await PackageInfo.fromPlatform();

    final update = await UpdateChecker.checkForUpdate();
    if (!mounted) return;
    if (update != null) {
      _showUpdateDialog(update);
      return;
    }

    // Up to date: one-time what's-new per version.
    final firstRun =
        await UpdateChecker.isFirstRunOfVersion(packageInfo.version);
    if (firstRun && mounted) {
      _showWhatsNew(packageInfo.version);
    }
  }

  Future<void> _checkForUpdates({required bool silent}) async {
    final update = await UpdateChecker.checkForUpdate();
    if (!mounted) return;
    if (update == null) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Already on the latest version')));
      }
      return;
    }
    _showUpdateDialog(update);
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => _UpdateDialog(info: info),
    );
  }

  void _showWhatsNew(String version) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AirColors.surface,
        title: Text("What's new in v$version",
            style: const TextStyle(
                color: AirColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        content: const Text(
          "You're on the latest version of AirChat. Check the release notes "
          "on GitHub for everything that changed.",
          style: TextStyle(color: AirColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('OK', style: TextStyle(color: AirColors.accent)),
          ),
        ],
      ),
    );
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
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: AirColors.textPrimary),
            onSelected: (v) {
              if (v == 'update') _checkForUpdates(silent: false);
              if (v == 'health') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const NotificationHealthScreen()),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'update', child: Text('Check for updates')),
              PopupMenuItem(
                  value: 'health', child: Text('Notification health')),
            ],
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

    // Contact username is pre-loaded via JOIN query — no FutureBuilder needed.
    final displayName = thread.contactUsername.isNotEmpty
        ? thread.contactUsername
        : "Peer";
    final leading = _Avatar(
      letter: displayName.isNotEmpty ? displayName[0].toUpperCase() : 'P',
    );

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
        child: Row(
          children: [
            Expanded(
              child: Text(
                thread.lastMessage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AirColors.textSecondary, fontSize: 14),
              ),
            ),
            if (thread.unreadCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AirColors.accent,
                  borderRadius: BorderRadius.circular(12),
                ),
                constraints: const BoxConstraints(minWidth: 22),
                alignment: Alignment.center,
                child: Text(
                  thread.unreadCount > 99 ? '99+' : '${thread.unreadCount}',
                  style: const TextStyle(
                    color: AirColors.background,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
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
        ).then((_) async {
          // Opening the chat clears its unread badge.
          final myUid = await KeyStore.getUid();
          if (myUid != null) {
            await ChatDao().resetUnread(buildChatId(myUid, thread.contactUid));
          }
        });
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

/// Update dialog with in-app download progress, then auto-triggers the
/// Android package installer.
class _UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateDialog({required this.info});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double _progress = 0;
  bool _downloading = false;
  bool _failed = false;

  Future<void> _downloadAndInstall() async {
    setState(() {
      _downloading = true;
      _failed = false;
      _progress = 0;
    });
    final ok = await UpdateChecker.downloadAndInstall(
      widget.info,
      (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _downloading = false;
        _failed = true;
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AirColors.surface,
      title: Text('Update available — ${widget.info.latestTag}',
          style: const TextStyle(
              color: AirColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Text(
                widget.info.body.isEmpty
                    ? 'A new version of AirChat is available.'
                    : widget.info.body.split('\n').take(8).join('\n'),
                style: const TextStyle(
                    color: AirColors.textSecondary, fontSize: 13),
              ),
            ),
          ),
          if (_downloading) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              backgroundColor: AirColors.surfaceLight,
              color: AirColors.accent,
            ),
            const SizedBox(height: 6),
            Text(
              _progress > 0
                  ? 'Downloading… ${(_progress * 100).toStringAsFixed(0)}%'
                  : 'Downloading…',
              style:
                  const TextStyle(color: AirColors.textSecondary, fontSize: 12),
            ),
          ],
          if (_failed) ...[
            const SizedBox(height: 12),
            const Text('Download failed — check your connection and retry.',
                style: TextStyle(color: AirColors.error, fontSize: 12)),
          ],
        ],
      ),
      actions: [
        if (!_downloading)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                const Text('Later', style: TextStyle(color: AirColors.textSecondary)),
          ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: AirColors.accent,
              foregroundColor: AirColors.background),
          onPressed: _downloading ? null : _downloadAndInstall,
          child: Text(_downloading ? 'Installing…' : 'Download & Install'),
        ),
      ],
    );
  }
}
