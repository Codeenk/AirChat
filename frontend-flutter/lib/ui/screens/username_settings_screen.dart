import 'package:flutter/material.dart';
import '../../core/crypto/key_store.dart';
import '../../core/network/api_client.dart';
import '../../core/theme/colors.dart';

class UsernameSettingsScreen extends StatefulWidget {
  const UsernameSettingsScreen({Key? key}) : super(key: key);

  @override
  State<UsernameSettingsScreen> createState() => _UsernameSettingsScreenState();
}

class _UsernameSettingsScreenState extends State<UsernameSettingsScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _currentUid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final username = await KeyStore.getUsername() ?? '';
    final uid = await KeyStore.getUid() ?? '';
    setState(() {
      _controller.text = username;
      _currentUid = uid;
      _loading = false;
    });
  }

  String? _validate(String value) {
    if (value.isEmpty) return 'Username cannot be empty';
    if (value.length < 3) return 'At least 3 characters';
    if (value.length > 24) return 'At most 24 characters';
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(value)) {
      return 'Only letters, numbers and underscores';
    }
    return null;
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    final error = _validate(value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      // Check availability first for a friendly message — the server enforces
      // uniqueness anyway.
      final existing = await const ApiClient().lookupIdentity(username: value);
      final uid = await KeyStore.getUid() ?? '';
      if (existing != null && existing['uid'] != uid) {
        setState(() {
          _saving = false;
          _error = 'That username is taken';
        });
        return;
      }

      await KeyStore.setUsername(value);

      // Re-register so directory lookups (auto-contact naming, QR scans)
      // resolve to the new username immediately. Server does an upsert.
      final pubKey = await KeyStore.getPublicKey() ?? '';
      var registered = false;
      if (pubKey.isNotEmpty) {
        final client = const ApiClient();
        for (int attempt = 1; attempt <= 3 && !registered; attempt++) {
          registered = await client.registerIdentity(
            uid: uid,
            username: value,
            identityPublicKey: pubKey,
            signingPublicKey: await KeyStore.getSigningPublicKey(),
            signingSignature: await KeyStore.getSigningSignature(),
          );
          if (!registered) {
            await Future.delayed(Duration(seconds: 2 * attempt));
          }
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(registered
            ? 'Username updated'
            : 'Saved locally — will sync when online'),
      ));
      Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong')),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AirColors.background,
      appBar: AppBar(title: const Text("Display name")),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AirColors.bubbleMe,
                    ),
                    child: Text(
                      _controller.text.isNotEmpty
                          ? _controller.text[0].toUpperCase()
                          : 'A',
                      style: const TextStyle(
                        color: AirColors.bubbleMeText,
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'This name is shown to people who scan your QR code and '
                    'to anyone you message for the first time.',
                    style: TextStyle(color: AirColors.textSecondary, fontSize: 13, height: 1.5),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _controller,
                    focusNode: _focus,
                    maxLength: 24,
                    enabled: !_saving,
                    autofocus: true,
                    style: const TextStyle(color: AirColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: 'Username',
                      labelStyle: const TextStyle(color: AirColors.textSecondary),
                      prefixText: '@',
                      prefixStyle: const TextStyle(color: AirColors.textFaint),
                      filled: true,
                      fillColor: AirColors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: AirColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: AirColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: AirColors.accent),
                      ),
                      errorText: _error,
                      counterStyle: const TextStyle(color: AirColors.textFaint),
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _save(),
                  ),
                  if (_currentUid != null && _currentUid!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'UID $_currentUid',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AirColors.textFaint, fontSize: 11),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AirColors.bubbleMe,
                      foregroundColor: AirColors.bubbleMeText,
                      disabledBackgroundColor: AirColors.surfaceLight,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
    );
  }
}
