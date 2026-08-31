import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/crypto/key_store.dart';
import '../../core/crypto/qr_payload.dart';
import '../../core/theme/colors.dart';

class QrIdentityScreen extends StatefulWidget {
  const QrIdentityScreen({Key? key}) : super(key: key);

  @override
  State<QrIdentityScreen> createState() => _QrIdentityScreenState();
}

class _QrIdentityScreenState extends State<QrIdentityScreen> {
  String? _qrData;
  String? _uid;
  String? _username;
  String? _pubKey;

  @override
  void initState() {
    super.initState();
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    final uid = await KeyStore.getUid() ?? '';
    final username = await KeyStore.getUsername() ?? 'airchat_user';
    final pubKey = await KeyStore.getPublicKey() ?? '';

    final payload = QrContactPayload(
      uid: uid,
      username: username,
      identityPublicKey: pubKey,
    );

    setState(() {
      _uid = uid;
      _username = username;
      _pubKey = pubKey;
      _qrData = payload.encode();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isReady = _qrData != null;

    return Scaffold(
      backgroundColor: AirColors.background,
      appBar: AppBar(
        title: const Text("My Identity"),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: isReady
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: AirColors.bubbleMe,
                      ),
                      child: Text(
                        (_username != null && _username!.isNotEmpty)
                            ? _username![0].toUpperCase()
                            : 'A',
                        style: const TextStyle(
                          color: AirColors.bubbleMeText,
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      "@$_username",
                      style: const TextStyle(
                        color: AirColors.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      "Scan to add contact & start an E2EE chat",
                      style: TextStyle(
                        color: AirColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AirColors.textPrimary,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: QrImageView(
                        data: _qrData!,
                        version: QrVersions.auto,
                        size: 220.0,
                        backgroundColor: AirColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AirColors.textPrimary,
                        side: const BorderSide(color: AirColors.border),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text("Copy identity"),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _qrData!));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                "Identity copied — share it with your peer",
                              ),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    Text(
                      "UID $_uid",
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AirColors.textFaint,
                        fontSize: 11,
                      ),
                    ),
                    if (_pubKey != null && _pubKey!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        "Key ${_pubKey!.substring(0, _pubKey!.length > 24 ? 24 : _pubKey!.length)}…",
                        style: const TextStyle(
                          color: AirColors.textFaint,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ],
                )
              : const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      color: AirColors.accent,
                      strokeWidth: 2,
                    ),
                    SizedBox(height: 12),
                    Text(
                      "Loading identity…",
                      style: TextStyle(
                        color: AirColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
