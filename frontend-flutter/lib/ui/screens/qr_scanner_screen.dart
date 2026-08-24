import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/crypto/key_store.dart';
import '../../core/crypto/qr_payload.dart';
import '../../core/database/daos/chat_dao.dart';
import '../../core/database/daos/contact_dao.dart';
import '../../core/theme/colors.dart';
import '../../models/chat_thread.dart';
import '../../models/contact.dart';
import '../../state/chat_provider.dart';
import 'chat_room_screen.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({Key? key}) : super(key: key);

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

/// Correct mobile_scanner usage (per package guidance):
/// 1. Request camera permission BEFORE creating/starting the controller.
/// 2. Controller created with `autoStart: false`, started manually.
/// 3. Lifecycle handled via WidgetsBindingObserver — re-check permission on
///    resume (returning from Settings), stop on inactive.
/// 4. errorBuilder surfaces any failure instead of a silent black screen.
class _QrScannerScreenState extends State<QrScannerScreen>
    with WidgetsBindingObserver {
  bool _isHandled = false;
  bool _hasCameraPermission = false;
  bool _starting = false;
  bool _screenDisposed = false;
  MobileScannerController? _controller;
  StreamSubscription<Object?>? _subscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestCameraPermissionAndStart();
  }

  @override
  void dispose() {
    _screenDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null) return;
    switch (state) {
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        return;
      case AppLifecycleState.resumed:
        _resumeScannerIfPermitted();
        break;
      case AppLifecycleState.inactive:
        unawaited(_subscription?.cancel());
        _subscription = null;
        unawaited(controller.stop());
        break;
    }
  }

  Future<void> _resumeScannerIfPermitted() async {
    // Returning from Settings after granting: controller state may still say
    // "denied" because only start() updates it — check with permission_handler.
    // Skip while a start is already in flight (permission-dialog race).
    if (_starting) return;
    final granted =
        await Permission.camera.status.isGranted ||
            await Permission.camera.status.isLimited;
    if (!mounted || !granted) return;
    if (!_hasCameraPermission) setState(() => _hasCameraPermission = true);
    await _startScanner();
  }

  Future<void> _requestCameraPermissionAndStart() async {
    var status = await Permission.camera.status;
    if (!status.isGranted && !status.isLimited) {
      status = await Permission.camera.request();
    }
    if (!mounted) return;
    final granted = status.isGranted || status.isLimited;
    setState(() => _hasCameraPermission = granted);
    if (granted) await _startScanner();
  }

  Future<void> _startScanner() async {
    // Serialize: the permission-dialog resume path and the original request
    // await can both land here — creating two controllers concurrently
    // leaves the camera dead (black preview, unrecoverable until restart).
    if (_starting) return;
    _starting = true;
    try {
      await _subscription?.cancel();
      _subscription = null;
      var controller = _controller;
      if (controller != null) {
        _controller = null;
        try {
          await controller.stop();
        } catch (_) {}
        await controller.dispose();
      }
      controller = MobileScannerController(autoStart: false);
      _controller = controller;
      _subscription = controller.barcodes.listen(_onDetect);
      try {
        await controller.start();
      } catch (e) {
        debugPrint('[AirChat] scanner start failed: $e');
      }
      if (_screenDisposed) {
        try { await controller.dispose(); } catch (_) {}
        return;
      }
      if (mounted) setState(() {});
    } finally {
      _starting = false;
    }
  }

  void _onDetect(BarcodeCapture capture) => _handleBarcodes(capture);

  void _handleBarcodes(BarcodeCapture capture) {
    if (_isHandled) return;
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue == null) continue;
      final payload = QrContactPayload.parse(rawValue);
      if (payload != null) {
        _isHandled = true;
        _addContactAndOpenChat(payload);
        break;
      }
    }
  }

  Future<void> _pasteIdentity() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      _showSnack("Clipboard is empty");
      return;
    }
    final payload = QrContactPayload.parse(text);
    if (payload == null) {
      _showSnack("Not a valid AirChat identity");
      return;
    }
    _addContactAndOpenChat(payload);
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addContactAndOpenChat(QrContactPayload payload) async {
    final myUid = await KeyStore.getUid() ?? '';
    final chatId = buildChatId(myUid, payload.uid);

    await ContactDao().insertContact(Contact(
      uid: payload.uid,
      username: payload.username,
      identityPublicKey: payload.identityPublicKey,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));

    await ChatDao().insertOrUpdateChat(ChatThread(
      id: chatId,
      contactUid: payload.uid,
      lastMessage: '',
      lastMessageTime: DateTime.now().millisecondsSinceEpoch,
    ));

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          contactName: payload.username,
          contactUid: payload.uid,
          contactPublicKey: payload.identityPublicKey,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text("Scan Contact QR Code"),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: !_hasCameraPermission ? _buildPermissionDenied() : _buildScanner(),
    );
  }

  Widget _buildPermissionDenied() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.videocam_off_outlined,
                size: 44, color: AirColors.textFaint),
            const SizedBox(height: 16),
            const Text(
              "Camera access needed",
              style: TextStyle(
                  color: AirColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              "Allow camera access to scan a peer's\nQR code.",
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AirColors.textSecondary, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                final s = await Permission.camera.status;
                if (s.isPermanentlyDenied || s.isRestricted) {
                  await openAppSettings();
                } else {
                  await _requestCameraPermissionAndStart();
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: AirColors.bubbleMe,
                foregroundColor: AirColors.bubbleMeText,
              ),
              icon: const Icon(Icons.camera_alt_outlined, size: 18),
              label: const Text("Allow Camera"),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pasteIdentity,
              style: OutlinedButton.styleFrom(
                foregroundColor: AirColors.textPrimary,
                side: const BorderSide(color: AirColors.border),
              ),
              icon: const Icon(Icons.content_paste, size: 18),
              label: const Text("Paste identity instead"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanner() {
    final controller = _controller;
    return Stack(
      children: [
        if (controller != null)
          MobileScanner(
            controller: controller,
            onDetect: _onDetect,
            fit: BoxFit.cover,
            errorBuilder: (context, error) {
              return _buildScannerError(error);
            },
          )
        else
          const Center(
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AirColors.accent),
          ),
        // Dimmed mask around the scan window
        ColorFiltered(
          colorFilter: ColorFilter.mode(
            Colors.black.withOpacity(0.6),
            BlendMode.srcOut,
          ),
          child: Stack(
            children: [
              Container(
                decoration: const BoxDecoration(
                  color: Colors.black,
                ),
              ),
              Center(
                child: Container(
                  width: 260,
                  height: 260,
                  margin: const EdgeInsets.only(bottom: 60),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ],
          ),
        ),
        Center(
          child: Container(
            width: 260,
            height: 260,
            margin: const EdgeInsets.only(bottom: 60),
            decoration: BoxDecoration(
              border: Border.all(color: AirColors.textPrimary, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        Positioned(
          bottom: 130,
          left: 0,
          right: 0,
          child: Center(
            child: Text(
              "Align peer QR code inside the frame",
              style: TextStyle(
                  color: AirColors.textPrimary.withOpacity(0.9), fontSize: 14),
            ),
          ),
        ),
        Positioned(
          bottom: 24,
          left: 24,
          right: 24,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: AirColors.textPrimary,
              backgroundColor: Colors.black54,
              side: const BorderSide(color: AirColors.border),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            icon: const Icon(Icons.content_paste, size: 18),
            label: const Text("Paste identity instead"),
            onPressed: _pasteIdentity,
          ),
        ),
      ],
    );
  }

  Widget _buildScannerError(MobileScannerException error) {
    final permanentlyDenied =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline,
                size: 44, color: AirColors.textFaint),
            const SizedBox(height: 16),
            Text(
              permanentlyDenied
                  ? "Camera permission was denied"
                  : "Scanner failed to start",
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AirColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              permanentlyDenied
                  ? "Enable it in app settings, then come back."
                  : error.errorDetails?.toString() ??
                      "Pull back and try again.",
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AirColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () async {
                if (permanentlyDenied) {
                  await openAppSettings();
                } else {
                  await _startScanner();
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: AirColors.bubbleMe,
                foregroundColor: AirColors.bubbleMeText,
              ),
              child: Text(permanentlyDenied ? "Open Settings" : "Retry"),
            ),
          ],
        ),
      ),
    );
  }
}
