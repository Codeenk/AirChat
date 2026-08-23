import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'core/crypto/key_store.dart';
import 'core/crypto/sodium_engine.dart';
import 'core/crypto/signing_engine.dart';
import 'core/network/api_client.dart';
import 'core/network/notification_service.dart';
import 'core/theme/colors.dart';
import 'state/connection_provider.dart';
import 'ui/screens/home_chat_list_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();
  final uid = await _initializeIdentity(container);

  if (uid.isNotEmpty) {
    try {
      await container.read(firebaseInitializerProvider.future);
      final pushService = container.read(pushServiceProvider);
      await pushService.initialize();
    } catch (_) {
      // Push unavailable (missing platform config) — messaging still works online
    }
    container.read(messageRouterProvider(uid));
  }

  runApp(
    ProviderScope(
      parent: container,
      child: const AirChatApp(),
    ),
  );
}

Future<String> _initializeIdentity(ProviderContainer container) async {
  final hasId = await KeyStore.hasIdentity();
  if (!hasId) {
    final engine = SodiumEngine();
    final keyPair = await engine.generateIdentityKeyPair();

    final signingEngine = SigningEngine();
    final signingKeyPair = await signingEngine.generateSigningKeyPair();
    final signingPublicKeyHex = await signingEngine.exportSigningPublicKeyHex(signingKeyPair);

    final uid = 'usr_${const Uuid().v4().replaceAll('-', '').substring(0, 20)}';
    final username = 'airchat_${uid.substring(uid.length - 8)}';

    final identityPublicKey = await engine.exportPublicKey(keyPair);
    final signingSignature = await signingEngine.signHex(identityPublicKey, signingKeyPair);

    await KeyStore.saveUserIdentity(
      uid: uid,
      username: username,
      keyPair: keyPair,
      signingPublicKeyHex: signingPublicKeyHex,
      signingSignatureHex: signingSignature,
    );

    await KeyStore.saveSigningKeyPair(signingKeyPair);

    await const ApiClient().registerIdentity(
      uid: uid,
      username: username,
      identityPublicKey: identityPublicKey,
      signingPublicKey: signingPublicKeyHex,
      signingSignature: signingSignature,
    );
  }

  final uid = await KeyStore.getUid() ?? '';

  // ALWAYS (re)register on launch — server does an upsert, so this heals
  // identities whose initial registration silently failed. Without this,
  // peers' directory lookups for us return 404 and auto-contact breaks.
  if (uid.isNotEmpty) {
    final pubKey = await KeyStore.getPublicKey() ?? '';
    debugPrint('[AirChat] identity uid=$uid pubKeyLen=${pubKey.length}');
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
        debugPrint('[AirChat] register attempt $attempt -> $ok');
        if (ok) break;
        await Future.delayed(Duration(seconds: 2 * attempt));
      }
    } else {
      debugPrint('[AirChat] WARNING: identity has empty public key!');
    }
  }

  if (uid.isNotEmpty) {
    container.read(currentUidProvider.notifier).state = uid;
  }

  await KeyStore.getOrCreateDatabaseMasterKey();

  return uid;
}

class AirChatApp extends StatefulWidget {
  const AirChatApp({Key? key}) : super(key: key);

  @override
  State<AirChatApp> createState() => _AirChatAppState();
}

class _AirChatAppState extends State<AirChatApp> with WidgetsBindingObserver {
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
    // Notifications are only shown when the UI is not visible.
    NotificationService.isAppForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      FlutterLocalNotificationsPlugin().cancelAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Air Chat',
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
      home: const HomeChatListScreen(),
    );
  }
}