import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/crypto/key_store.dart';
import '../../core/crypto/qr_payload.dart';
import '../../core/crypto/safety_number.dart';
import '../../core/database/daos/contact_dao.dart';
import '../../core/theme/colors.dart';
import '../../models/contact.dart';
import 'qr_scanner_screen.dart';

/// Out-of-band key verification for a single contact.
///
/// Shows the 60-digit code derived from both parties' keys. If the two devices
/// display the same digits, no one is sitting between them — which is the only
/// way to rule out the relay serving substitute keys. The code can be compared
/// by reading it aloud, by copying it, or by scanning the other device's QR.
class SecurityNumberScreen extends StatefulWidget {
  final String contactUid;
  final String contactName;

  const SecurityNumberScreen({
    Key? key,
    required this.contactUid,
    required this.contactName,
  }) : super(key: key);

  @override
  State<SecurityNumberScreen> createState() => _SecurityNumberScreenState();
}

class _SecurityNumberScreenState extends State<SecurityNumberScreen> {
  bool _loading = true;
  bool _busy = false;
  String _myUid = '';
  String _myUsername = '';
  String _myIdentityKey = '';
  String _mySigningKey = '';
  Contact? _contact;
  SafetyNumber? _safetyNumber;
  String? _unavailable;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final myUid = await KeyStore.getUid() ?? '';
    final myUsername = await KeyStore.getUsername() ?? 'me';
    final myIdentityKey = await KeyStore.getPublicKey() ?? '';
    final mySigningKey = await KeyStore.getSigningPublicKey() ?? '';
    final contact = await ContactDao().getContactByUid(widget.contactUid);

    SafetyNumber? safetyNumber;
    String? unavailable;

    if (contact == null) {
      unavailable = 'This contact is no longer stored on this device.';
    } else {
      try {
        safetyNumber = await SafetyNumberCalculator.compute(
          localUid: myUid,
          localIdentityKey: myIdentityKey,
          localSigningKey: mySigningKey,
          peerUid: contact.uid,
          peerIdentityKey: contact.identityPublicKey,
          peerSigningKey: contact.signingPublicKey ?? '',
        );
      } on SafetyNumberUnavailable catch (e) {
        unavailable = _explain(e.reason);
      }
    }

    if (!mounted) return;
    setState(() {
      _loading = false;
      _myUid = myUid;
      _myUsername = myUsername;
      _myIdentityKey = myIdentityKey;
      _mySigningKey = mySigningKey;
      _contact = contact;
      _safetyNumber = safetyNumber;
      _unavailable = unavailable;
    });
  }

  static String _explain(String reason) {
    if (reason.contains('signing key')) {
      return 'Their signing key has not reached this device yet, and the code covers it. Open this chat once while online, or scan their code below, then try again.';
    }
    if (reason.contains('identity key')) {
      return 'Their identity key is missing or unreadable on this device, so there is no code to compare.';
    }
    return 'A security code cannot be derived yet: $reason.';
  }

  String get _myQrData => QrContactPayload(
    uid: _myUid,
    username: _myUsername,
    identityPublicKey: _myIdentityKey,
    signingPublicKey: _mySigningKey.isEmpty ? null : _mySigningKey,
  ).encode();

  // ─── actions ───────────────────────────────────────────────────────────────

  Future<void> _copyCode() async {
    final sn = _safetyNumber;
    if (sn == null) return;
    await Clipboard.setData(ClipboardData(text: sn.display));
    _snack('Security code copied.');
  }

  Future<void> _scanToVerify() async {
    final scanned = await Navigator.push<QrContactPayload>(
      context,
      MaterialPageRoute(
        builder: (_) => QrScannerScreen(verifyContactUid: widget.contactUid),
      ),
    );
    if (scanned == null || !mounted) return;
    await _applyScanned(scanned);
  }

  Future<void> _applyScanned(QrContactPayload scanned) async {
    final contact = _contact;
    if (contact == null || _busy) return;

    if (scanned.uid != widget.contactUid) {
      _snack("That code belongs to a different contact.");
      return;
    }

    // Self-check. A code carrying a code of its own must agree with the one we
    // derive from the keys inside it; if it does not, the code was corrupted or
    // altered between their screen and our camera — refuse rather than compare a
    // value we cannot trust.
    final sn = _safetyNumber;
    if (scanned.safetyNumber != null &&
        sn != null &&
        scanned.safetyNumber != sn.digits) {
      await _notice(
        title: 'That code could not be read',
        body: 'It carries a security code that does not match its own keys, so it is damaged or was altered in transit. Ask them to show it again.',
        danger: true,
      );
      return;
    }

    final sameIdentity = scanned.identityPublicKey == contact.identityPublicKey;
    final sameSigning =
        Contact.normalizeSigningKey(scanned.signingPublicKey) ==
        contact.normalizedSigningKey;

    if (sameIdentity && sameSigning) {
      final ok = await _confirm(
        title: 'Codes match',
        body:
            'The code you scanned matches the keys this device already holds for '
            '${widget.contactName}. Mark them as verified?',
        confirmLabel: 'Mark as verified',
      );
      if (ok) await _record(contact);
      return;
    }

    // The out-of-band code disagrees with what the server handed us. That is the
    // MITM signature, and the code in front of you is the more trustworthy of the
    // two — but the call is the user's, so explain it and ask.
    final ok = await _confirm(
      title: 'Keys do not match',
      body:
          'The code you scanned shows different keys than the server gave this '
          'device.\n\nIf you are next to ${widget.contactName} and this is their '
          'screen, trust the code in front of you and replace what the server '
          'said. If you are not sure you are looking at their real device, cancel '
          'and do not verify.',
      confirmLabel: 'Use scanned keys',
      danger: true,
    );
    if (!ok) return;

    await ContactDao().insertContact(
      contact.copyWith(
        identityPublicKey: scanned.identityPublicKey,
        signingPublicKey: scanned.signingPublicKey,
      ),
    );
    final updated = await ContactDao().getContactByUid(widget.contactUid);
    if (updated != null) await _record(updated);
  }

  Future<void> _markVerifiedManually() async {
    final contact = _contact;
    if (contact == null || _busy) return;
    final ok = await _confirm(
      title: 'Mark as verified?',
      body:
          'Only do this if you compared the code above with '
          '${widget.contactName} directly — read it aloud, or looked at their '
          'screen.',
      confirmLabel: 'Mark as verified',
    );
    if (ok) await _record(contact);
  }

  Future<void> _record(Contact contact) async {
    final signing = contact.normalizedSigningKey;
    if (signing == null) {
      await _notice(
        title: 'Cannot verify yet',
        body:
            'Their signing key is still unknown to this device, and the code '
            'covers it. Rather than record a half-check, this stays unverified '
            'until both keys are known.',
        danger: false,
      );
      return;
    }
    setState(() => _busy = true);
    await ContactDao().markVerified(
      contact.uid,
      identityKey: contact.identityPublicKey,
      signingKey: signing,
    );
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    _snack('Verified.');
  }

  Future<void> _revoke() async {
    final contact = _contact;
    if (contact == null || _busy) return;
    final ok = await _confirm(
      title: 'Remove verification?',
      body:
          'This device will stop treating ${widget.contactName}\'s keys as '
          'confirmed. You can verify again at any time.',
      confirmLabel: 'Remove',
      danger: true,
    );
    if (!ok) return;
    setState(() => _busy = true);
    await ContactDao().clearVerification(contact.uid);
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  // ─── small dialogs ─────────────────────────────────────────────────────────

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AirColors.surface,
        title: Text(
          title,
          style: const TextStyle(color: AirColors.textPrimary),
        ),
        content: Text(
          body,
          style: const TextStyle(color: AirColors.textSecondary, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AirColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              confirmLabel,
              style: TextStyle(
                color: danger ? AirColors.error : AirColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _notice({
    required String title,
    required String body,
    required bool danger,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AirColors.surface,
        title: Text(
          title,
          style: TextStyle(
            color: danger ? AirColors.error : AirColors.textPrimary,
          ),
        ),
        content: Text(
          body,
          style: const TextStyle(color: AirColors.textSecondary, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Close',
              style: TextStyle(color: AirColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ─── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AirColors.background,
      appBar: AppBar(
        backgroundColor: AirColors.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('Security code'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AirColors.accent,
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildStatusCard(),
                  const SizedBox(height: 24),
                  if (_safetyNumber != null)
                    _buildNumberPanel(_safetyNumber!)
                  else
                    _buildUnavailablePanel(),
                  const SizedBox(height: 24),
                  ..._buildActions(),
                  const SizedBox(height: 28),
                  _buildMyQr(),
                ],
              ),
            ),
    );
  }

  Widget _buildStatusCard() {
    final contact = _contact;
    final changed = contact?.hasKeyChanged ?? false;
    final verified = contact?.isVerified ?? false;

    final Color border = changed
        ? AirColors.error
        : (verified ? AirColors.textPrimary : AirColors.border);
    final IconData icon = changed
        ? Icons.gpp_maybe_outlined
        : (verified ? Icons.verified_user_outlined : Icons.shield_outlined);
    final String title = changed
        ? 'Security code changed'
        : (verified ? 'Verified' : 'Not verified');
    final String body = changed
        ? 'The keys on this device no longer match the ones you confirmed. That '
              'happens if ${widget.contactName} reinstalled, or if the server is '
              'handing out different keys than the ones you checked. Verify again '
              'before trusting this chat.'
        : (verified
              ? 'You confirmed this contact\'s code'
                    '${_verifiedDateSuffix(contact)}. If their keys ever change, '
                    'this warning will come back.'
              : 'Nothing here is broken — but until you compare the code below, '
                    'this device is taking the server\'s word for who you are '
                    'talking to.');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AirColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: border),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: changed ? AirColors.error : AirColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(
                    color: AirColors.textSecondary,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _verifiedDateSuffix(Contact? contact) {
    final at = contact?.verifiedAt;
    if (at == null) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(at);
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return ' on $d.$m.${date.year}';
  }

  Widget _buildNumberPanel(SafetyNumber sn) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        color: AirColors.surfaceLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            'COMPARE WITH ${widget.contactName.toUpperCase()}',
            style: const TextStyle(
              color: AirColors.textFaint,
              fontSize: 10,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          SelectableText(
            sn.rows.join('\n'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AirColors.textPrimary,
              fontFamily: 'monospace',
              fontSize: 17,
              height: 1.7,
              letterSpacing: 1.0,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'If these 60 digits read the same on both phones, no one is sitting '
            'between you. If they differ, stop — do not send anything sensitive.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AirColors.textSecondary,
              fontSize: 11.5,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnavailablePanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AirColors.surfaceLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        _unavailable ?? 'A security code is not available for this contact.',
        style: const TextStyle(
          color: AirColors.textSecondary,
          fontSize: 12.5,
          height: 1.45,
        ),
      ),
    );
  }

  List<Widget> _buildActions() {
    final contact = _contact;
    final hasCode = _safetyNumber != null;
    final verified = contact?.isVerified ?? false;
    final recorded = contact?.isVerificationRecorded ?? false;

    return [
      FilledButton.icon(
        onPressed: _busy ? null : _scanToVerify,
        style: FilledButton.styleFrom(
          backgroundColor: AirColors.bubbleMe,
          foregroundColor: AirColors.bubbleMeText,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        icon: const Icon(Icons.qr_code_scanner, size: 18),
        label: const Text('Scan their code'),
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        onPressed: (!hasCode || _busy) ? null : _copyCode,
        style: OutlinedButton.styleFrom(
          foregroundColor: AirColors.textPrimary,
          side: const BorderSide(color: AirColors.border),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        icon: const Icon(Icons.copy_rounded, size: 18),
        label: const Text('Copy code'),
      ),
      if (hasCode && !verified) ...[
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _busy ? null : _markVerifiedManually,
          style: OutlinedButton.styleFrom(
            foregroundColor: AirColors.textPrimary,
            side: const BorderSide(color: AirColors.textFaint),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          icon: const Icon(Icons.verified_outlined, size: 18),
          label: const Text('Mark as verified'),
        ),
      ],
      if (recorded) ...[
        const SizedBox(height: 6),
        TextButton(
          onPressed: _busy ? null : _revoke,
          child: const Text(
            'Remove verification',
            style: TextStyle(color: AirColors.textFaint, fontSize: 12.5),
          ),
        ),
      ],
    ];
  }

  Widget _buildMyQr() {
    if (_myUid.isEmpty || _myIdentityKey.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        const Text(
          'YOUR CODE — LET THEM SCAN THIS',
          style: TextStyle(
            color: AirColors.textFaint,
            fontSize: 10,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AirColors.textPrimary,
            borderRadius: BorderRadius.circular(20),
          ),
          child: QrImageView(
            data: _myQrData,
            version: QrVersions.auto,
            size: 180.0,
            backgroundColor: AirColors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'UID $_myUid',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AirColors.textFaint, fontSize: 11),
        ),
      ],
    );
  }
}
