import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'core/crash/crash_reporter.dart';
import 'core/crypto/key_store.dart';
import 'core/crypto/signing_engine.dart';
import 'core/crypto/sodium_engine.dart';
import 'core/database/daos/contact_dao.dart';
import 'core/database/daos/message_dao.dart';
import 'core/network/api_client.dart';
import 'core/network/notification_service.dart';
import 'core/network/websocket_client.dart';
import 'core/theme/colors.dart';
import 'state/connection_provider.dart';
import 'ui/screens/home_chat_list_screen.dart';

void main() async {
  await runZonedGuarded<Future<void>>(() async {
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
      CrashReporter.recordError(error: error, stackTrace: stack, source: 'platform');
      return true;
    };

    await CrashReporter.initialize();

    final container = ProviderContainer();

    final uid = await _loadLocalIdentity(container);

    runApp(
      ProviderScope(
        parent: container,
        child: const AirChatApp(),
      ),
    );

    unawaited(
      _initializeServices(container, uid).catchError((e, s) {
        CrashReporter.recordError(error: e, stackTrace: s, source: 'startup-services');
      }),
    );
  }, (error, stack) {
    CrashReporter.recordError(error: error, stackTrace: stack, source: 'zone');
  });
}

Future<String> _loadLocalIdentity(ProviderContainer container) async {
  final uid = await KeyStore.getUid();

  if (uid == null || uid.isEmpty) {
    final engine = SodiumEngine();
    final keyPair = await engine.generateIdentityKeyPair();

    final signingEngine = SigningEngine();
    final signingKeyPair = await signingEngine.generateSigningKeyPair();
    final signingPublicKeyHex =
        await signingEngine.exportSigningPublicKeyHex(signingKeyPair);

    final newUid =
        'usr_${const Uuid().v4().replaceAll('-', '').substring(0, 20)}';
    final username = 'airchat_${newUid.substring(newUid.length - 8)}';

    final identityPublicKey = await engine.exportPublicKey(keyPair);
    final signingSignature =
        await signingEngine.signHex(identityPublicKey, signingKeyPair);

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

  await KeyStore.getOrCreateDatabaseMasterKey();
  container.read(currentUidProvider.notifier).state = uid;
  return uid;
}

Future<void> _initializeServices(
    ProviderContainer container, String uid) async {
  if (uid.isEmpty) return;

  try {
    await container.read(firebaseInitializerProvider.future);
    final pushService = container.read(pushServiceProvider);
    await pushService.initialize();
  } catch (_) {}

  container.read(messageRouterProvider(uid));

  unawaited(Future.delayed(const Duration(seconds: 2), () => _requeuePending(container, uid)));

  try {
    final pubKey = await KeyStore.getPublicKey() ?? '';
    if (pubKey.isNotEmpty) {
      final client = const ApiClient();
      for (int attempt = 1; attempt <= 3; attempt++) {
        final ok = await client.registerIdentity(
          uid: uid,
          username: await KeyStore.getUsername() ?? '',
          identityPublicKey: pubKey,
          signingPublicKey: await KeyStore.getSigningPublicKey(),
          signingSignature: await KeyStore.getSigningSignature(),
        );
        if (ok) break;
        await Future.delayed(Duration(seconds: 2 * attempt));
      }
    }
  } catch (_) {}
}

Future<void> _requeuePending(ProviderContainer container, String uid) async {
  try {
    final pending = await MessageDao().getPendingMessages();
    if (pending.isEmpty) return;
    final keyPair = await KeyStore.getKeyPair();
    if (keyPair == null) return;
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
        // Preserve ALL fields — a bare {text,type} resend would corrupt
        // media messages (missing keys) and replies (missing quote).
        final payload = await engine.encryptMessage(
          plainText: jsonEncode({
            'text': msg.text,
            'type': msg.type,
            if (msg.mediaKey != null) 'mediaKey': msg.mediaKey,
            if (msg.secretKeyHex != null) 'secretKeyHex': msg.secretKeyHex,
            if (msg.nonceHex != null) 'nonceHex': msg.nonceHex,
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

class _AirChatAppState extends ConsumerState<AirChatApp> with WidgetsBindingObserver {
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
        dividerTheme: const DividerThemeData(color: AirColors.divider, thickness: 1, space: 1),
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
      ),
      builder: (context, child) => Stack(
        children: [
          child ?? const SizedBox.shrink(),
          const _ReconnectBanner(),
        ],
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
                    strokeWidth: 1.6, color: AirColors.textSecondary),
              ),
              const SizedBox(width: 8),
              Text(
                state == TunnelState.connecting ? 'Connecting…' : 'Reconnecting…',
                style: const TextStyle(color: AirColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
