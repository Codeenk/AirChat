import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';

import 'core/crash/crash_reporter.dart';
import 'core/crypto/key_store.dart';
import 'core/crypto/signing_engine.dart';
import 'core/crypto/sodium_engine.dart';
import 'core/database/daos/contact_dao.dart';
import 'core/database/daos/message_dao.dart';
import 'core/network/api_client.dart';
import 'core/network/notification_service.dart';
import 'core/network/push_service.dart';
import 'core/network/websocket_client.dart';
import 'core/theme/colors.dart';
import 'state/connection_provider.dart';
import 'state/group_provider.dart';
import 'ui/screens/home_chat_list_screen.dart';

void main() async {
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        CrashReporter.recordError(
          error: details.exception,
          stackTrace: details.stack,
          source: 'flutter',
        );
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        CrashReporter.recordError(
          error: error,
          stackTrace: stack,
          source: 'platform',
        );
        return true;
      };

      await CrashReporter.initialize();

      final container = ProviderContainer();

      // Bring Firebase up, then register the FCM background handler BEFORE
      // runApp — the killed-state background isolate depends on this being
      // registered during startup. Both steps are best-effort: a device
      // without Firebase config still gets a fully working app (WS + DB).
      try {
        await container.read(firebaseInitializerProvider.future);
      } catch (_) {}
      registerFirebaseBackgroundHandler();

      final uid = await _loadLocalIdentity(container);

      runApp(ProviderScope(parent: container, child: const AirChatApp()));

      unawaited(_preloadFonts());

      unawaited(
        _initializeServices(container, uid).catchError((e, s) {
          CrashReporter.recordError(
            error: e,
            stackTrace: s,
            source: 'startup-services',
          );
        }),
      );
    },
    (error, stack) {
      CrashReporter.recordError(
        error: error,
        stackTrace: stack,
        source: 'zone',
      );
    },
  );
}

/// Warm the display font so the wordmark renders without a visible swap on
/// first launch. Best-effort: offline simply falls back to the platform font.
Future<void> _preloadFonts() async {
  try {
    await GoogleFonts.pendingFonts([GoogleFonts.dancingScript()]);
  } catch (_) {}
}

Future<String> _loadLocalIdentity(ProviderContainer container) async {
  final uid = await KeyStore.getUid();

  if (uid == null || uid.isEmpty) {
    final engine = SodiumEngine();
    final keyPair = await engine.generateIdentityKeyPair();

    final signingEngine = SigningEngine();
    final signingKeyPair = await signingEngine.generateSigningKeyPair();
    final signingPublicKeyHex = await signingEngine.exportSigningPublicKeyHex(
      signingKeyPair,
    );

    final newUid =
        'usr_${const Uuid().v4().replaceAll('-', '').substring(0, 20)}';
    final username = 'airchat_${newUid.substring(newUid.length - 8)}';

    final identityPublicKey = await engine.exportPublicKey(keyPair);
    final signingSignature = await signingEngine.signHex(
      'register|$newUid|$identityPublicKey',
      signingKeyPair,
    );

    await KeyStore.saveUserIdentity(
      uid: newUid,
      username: username,
      keyPair: keyPair,
      signingPublicKeyHex: signingPublicKeyHex,
      signingSignatureHex: signingSignature,
    );

    await KeyStore.saveSigningKeyPair(signingKeyPair);
    await KeyStore.getOrCreateDatabaseMasterKey();
    container.read(currentUidProvider.notifier).state = newUid;
    return newUid;
  }

  // Migration: identities created before signing keys existed can't pass
  // WS auth. Generate + persist; _initializeServices re-registers the
  // public halves with the directory.
  try {
    if (await KeyStore.getSigningKeyPair() == null) {
      final signingEngine = SigningEngine();
      final signingKeyPair = await signingEngine.generateSigningKeyPair();
      await KeyStore.saveSigningKeyPair(signingKeyPair);
      final pubKey = await KeyStore.getPublicKey() ?? '';
      if (pubKey.isNotEmpty) {
        await const ApiClient().registerIdentity(
          uid: uid,
          username: await KeyStore.getUsername() ?? '',
          identityPublicKey: pubKey,
        );
      }
    }
  } catch (_) {}

  await KeyStore.getOrCreateDatabaseMasterKey();
  container.read(currentUidProvider.notifier).state = uid;
  return uid;
}

Future<void> _initializeServices(
  ProviderContainer container,
  String uid,
) async {
  if (uid.isEmpty) return;

  // 1. Ensure this identity exists in the directory FIRST — the signed
  //    fcm-token update below is a no-op until the user row exists, and WS
  //    auth needs the signing key on file.
  try {
    final pubKey = await KeyStore.getPublicKey() ?? '';
    if (pubKey.isNotEmpty) {
      final client = const ApiClient();
      for (int attempt = 1; attempt <= 3; attempt++) {
        final ok = await client.registerIdentity(
          uid: uid,
          username: await KeyStore.getUsername() ?? '',
          identityPublicKey: pubKey,
        );
        if (ok) break;
        await Future.delayed(Duration(seconds: 2 * attempt));
      }
    }
  } catch (_) {}

  // 2. Local notification support must work even when Firebase/push config is
  //    missing, so set it up independently of the FCM path below.
  try {
    await NotificationService.instance.initialize();
  } catch (_) {}

  try {
    await container.read(firebaseInitializerProvider.future);
    final pushService = container.read(pushServiceProvider);
    await pushService.initialize();
  } catch (_) {}

  // 3. Start the wire + group re-key watcher.
  container.read(messageRouterProvider(uid));
  container.read(groupRekeyWatcherProvider);

  unawaited(
    Future.delayed(
      const Duration(seconds: 2),
      () => _requeuePending(container, uid),
    ),
  );
}

/// Re-sends messages that were composed but never acknowledged, preserving
/// every field (media keys, replies) and re-signing so the recipient can
/// still verify authenticity.
Future<void> _requeuePending(ProviderContainer container, String uid) async {
  try {
    final pending = await MessageDao().getPendingMessages();
    if (pending.isEmpty) return;
    final keyPair = await KeyStore.getKeyPair();
    if (keyPair == null) return;
    final signingKeyPair = await KeyStore.getSigningKeyPair();
    final engine = SodiumEngine();
    for (final msg in pending) {
      final contact = await ContactDao().getContactByUid(msg.recipientUid);
      final pubKey = contact?.identityPublicKey;
      if (pubKey == null || pubKey.isEmpty) {
        // No key — can't ever deliver; surface as failed instead of a
        // spinner that spins forever.
        await MessageDao().updateMessageStatus(msg.id, 'failed');
        continue;
      }
      try {
        final recipientPub = await engine.importPublicKey(pubKey);
        final chatId = ([uid, msg.recipientUid]..sort()).join('_');
        String sig = '';
        if (signingKeyPair != null) {
          try {
            sig = await SigningEngine().signHex(
              '${msg.id}|${msg.text}|$chatId',
              signingKeyPair,
            );
          } catch (_) {}
        }
        // Preserve ALL fields — a bare {text,type} resend would corrupt
        // media messages (missing keys) and replies (missing quote).
        final payload = await engine.encryptMessage(
          plainText: jsonEncode({
            'text': msg.text,
            'type': msg.type,
            if (msg.mediaKey != null) 'mediaKey': msg.mediaKey,
            if (msg.secretKeyHex != null) 'secretKeyHex': msg.secretKeyHex,
            if (msg.nonceHex != null) 'nonceHex': msg.nonceHex,
            if (sig.isNotEmpty) 'sig': sig,
            if (msg.hasReply)
              'replyTo': {
                'id': msg.replyToId,
                'text': msg.replyText,
                'type': msg.replyType,
                'isMe': msg.replyIsMe,
              },
          }),
          recipientPublicKey: recipientPub,
          senderKeyPair: keyPair,
        );
        final ws = container.read(websocketClientProvider(uid));
        ws.sendPacket(
          recipientUid: msg.recipientUid,
          encryptedPayload: payload.encode(),
          packetId: msg.id,
        );
        // If no ack arrives, flip to failed so the UI shows retry instead
        // of an endless spinner.
        Future.delayed(const Duration(seconds: 12), () async {
          final m = await MessageDao().getPendingMessages();
          if (m.any((x) => x.id == msg.id)) {
            await MessageDao().updateMessageStatus(msg.id, 'failed');
          }
        });
      } catch (_) {
        await MessageDao().updateMessageStatus(msg.id, 'failed');
      }
    }
  } catch (_) {}
}

class AirChatApp extends ConsumerStatefulWidget {
  const AirChatApp({Key? key}) : super(key: key);

  @override
  ConsumerState<AirChatApp> createState() => _AirChatAppState();
}

class _AirChatAppState extends ConsumerState<AirChatApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.isAppForeground = true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    NotificationService.isAppForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      NotificationService.instance.clearAll();
    } else {
      // No chat can be "open" while the app is backgrounded — otherwise
      // incoming messages would be treated as read and never badge.
      MessageRouter.openChatId = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AirChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: AirColors.background,
        primaryColor: AirColors.accent,
        colorScheme: const ColorScheme.dark(
          primary: AirColors.accent,
          onPrimary: AirColors.background,
          surface: AirColors.surface,
          onSurface: AirColors.textPrimary,
          background: AirColors.background,
          onBackground: AirColors.textPrimary,
          error: AirColors.error,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AirColors.background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: AirColors.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
          iconTheme: IconThemeData(color: AirColors.textPrimary),
        ),
        dividerTheme: const DividerThemeData(
          color: AirColors.divider,
          thickness: 1,
          space: 1,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: AirColors.surfaceElevated,
          contentTextStyle: const TextStyle(color: AirColors.textPrimary),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AirColors.border),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: AirColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
      builder: (context, child) => Stack(
        children: [child ?? const SizedBox.shrink(), const _ReconnectBanner()],
      ),
      home: const HomeChatListScreen(),
    );
  }
}

class _ReconnectBanner extends ConsumerWidget {
  const _ReconnectBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(currentUidProvider);
    if (uid.isEmpty) return const SizedBox.shrink();
    final asyncState = ref.watch(tunnelStateProvider(uid));
    final state = asyncState.asData?.value ?? TunnelState.connecting;
    if (state == TunnelState.connected) return const SizedBox.shrink();
    return Positioned(
      top: MediaQuery.of(context).padding.top,
      left: 0,
      right: 0,
      child: Material(
        color: AirColors.surfaceElevated,
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: AirColors.textSecondary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                state == TunnelState.connecting
                    ? 'Connecting…'
                    : 'Reconnecting…',
                style: const TextStyle(
                  color: AirColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
