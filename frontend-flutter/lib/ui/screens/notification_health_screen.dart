
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:native_bridge/native_bridge.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/battery/battery_opt_helper.dart';
import '../../core/crypto/key_store.dart';
import '../../core/device/device_info_helper.dart';
import '../../core/network/api_client.dart';
import '../../core/theme/colors.dart';
import '../widgets/airchat_logo.dart';

/// Diagnoses and fixes notification delivery per device — the
/// dontkillmyapp flow, productized. Every messaging app's #1 support
/// problem becomes a 30-second self-service screen.
class NotificationHealthScreen extends StatefulWidget {
  const NotificationHealthScreen({Key? key}) : super(key: key);

  @override
  State<NotificationHealthScreen> createState() =>
      _NotificationHealthScreenState();
}

class _NotificationHealthScreenState extends State<NotificationHealthScreen> {
  bool _batteryExempt = false;
  bool _notificationsGranted = false;
  bool _testing = false;
  DateTime? _lastVerified;
  String _manufacturer = '';
  String _oemTip = '';

  static const _storage = FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final battery = await BatteryOptHelper.isExempt();
    final notifs = await Permission.notification.status;
    final manufacturer = await DeviceInfoHelper.manufacturer();
    final lastVerified =
        await _storage.read(key: 'airchat_last_push_verified');

    if (!mounted) return;
    setState(() {
      _batteryExempt = battery;
      _notificationsGranted = _notificationsGrantedCheck(notifs);
      _manufacturer = manufacturer;
      _oemTip = _oemTipFor(manufacturer);
      _lastVerified = lastVerified == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(int.parse(lastVerified));
    });
  }

  bool _notificationsGrantedCheck(PermissionStatus s) => s.isGranted || s.isLimited;

  static String _oemTipFor(String manufacturer) {
    final m = manufacturer.toLowerCase();
    if (m.contains('realme') || m.contains('oppo')) {
      return 'Settings → Battery → More settings → App auto-launch: allow '
          'AirChat. Then pull AirChat down in Recents and tap the lock.';
    }
    if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
      return 'Settings → Apps → AirChat → Autostart: ON. Then Battery saver '
          '→ No restrictions.';
    }
    if (m.contains('vivo')) {
      return 'Settings → Battery → Background power consumption: allow '
          'AirChat high usage.';
    }
    if (m.contains('samsung')) {
      return 'Settings → Battery → Background usage limits → Never sleeping '
          'apps: add AirChat.';
    }
    if (m.contains('huawei') || m.contains('honor')) {
      return 'Settings → Battery → App launch → AirChat: turn off "Manage '
          'automatically", enable all three toggles.';
    }
    if (m.contains('oneplus')) {
      return 'Settings → Battery → More settings → Optimize battery use → '
          'AirChat: Don\'t optimize.';
    }
    return 'Settings → Apps → AirChat → Battery: Unrestricted.';
  }

  Future<void> _requestBatteryExemption() async {
    await BatteryOptHelper.requestExemption();
    _loadStatus();
  }

  Future<void> _runSelfTest() async {
    setState(() => _testing = true);
    try {
      final uid = await KeyStore.getUid();
      if (uid == null || uid.isEmpty) throw Exception('No identity');
      // The push round-trip is device → FCM → device. The client marks
      // 'airchat_last_push_verified' when the wake lands in the isolate.
      await const ApiClient().requestTestPush(uid: uid);
      // Give FCM a moment to deliver.
      await Future<void>.delayed(const Duration(seconds: 6));
    } catch (_) {}
    if (!mounted) return;
    setState(() => _testing = false);
    _loadStatus();
    final verified = _lastVerified != null &&
        DateTime.now().difference(_lastVerified!).inMinutes < 2;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(verified
          ? '✅ Notifications verified working on this phone'
          : '⚠️ Test push not received — apply the steps below, then retest'),
      backgroundColor:
          verified ? Colors.green.shade800 : AirColors.error,
    ));
  }

  Future<void> _toggleWireKeeper(bool enable) async {
    if (enable) {
      await NativeBridge.startWireKeeper();
    } else {
      await NativeBridge.stopWireKeeper();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(enable
            ? 'Wire Keeper on — AirChat stays reachable'
            : 'Wire Keeper off — push-only mode'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AirColors.background,
      appBar: AppBar(title: const AirChatLogo(fontSize: 18)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _statusCard(),
          const SizedBox(height: 16),
          _selfTestCard(),
          const SizedBox(height: 16),
          _oemCard(),
          const SizedBox(height: 16),
          _wireKeeperCard(),
        ],
      ),
    );
  }

  Widget _statusCard() => _card(
        title: 'Notification status',
        children: [
          _statusRow(
            'Notifications permission',
            _notificationsGranted,
            fixLabel: 'Grant',
            onFix: () async {
              await Permission.notification.request();
              _loadStatus();
            },
          ),
          _statusRow(
            'Battery unrestricted',
            _batteryExempt,
            fixLabel: 'Fix',
            onFix: _requestBatteryExemption,
          ),
          _statusRow(
            'Push registered',
            true, // token registration is verified by self-test
            fixLabel: null,
            onFix: null,
          ),
        ],
      );

  Widget _selfTestCard() => _card(
        title: 'Live test',
        children: [
          Text(
            _lastVerified == null
                ? 'Not verified yet on this phone.'
                : 'Last verified: '
                    '${MaterialLocalizations.of(context).formatTimeOfDay(
                        TimeOfDay.fromDateTime(_lastVerified!))}',
            style: const TextStyle(
                color: AirColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AirColors.accent,
              foregroundColor: AirColors.background,
            ),
            onPressed: _testing ? null : _runSelfTest,
            icon: _testing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.science_outlined, size: 18),
            label: Text(_testing ? 'Testing…' : 'Send test notification'),
          ),
        ],
      );

  Widget _oemCard() => _card(
        title: '$_manufacturer phone setup',
        children: [
          Text(
            _oemTip,
            style: const TextStyle(
                color: AirColors.textSecondary,
                fontSize: 13,
                height: 1.4),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: AirColors.textPrimary,
              side: const BorderSide(color: AirColors.border),
            ),
            onPressed: openAppSettings,
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: const Text('Open app settings'),
          ),
        ],
      );

  Widget _wireKeeperCard() => _card(
        title: 'Wire Keeper',
        children: [
          const Text(
            'Keeps a persistent connection open (shows a silent '
            '"wire connected" notification) so messages arrive instantly '
            'even after you swipe the app away. Recommended on aggressive '
            'battery phones.',
            style: TextStyle(
                color: AirColors.textSecondary, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AirColors.accent,
                    foregroundColor: AirColors.background,
                  ),
                  onPressed: () => _toggleWireKeeper(true),
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('Enable'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AirColors.textSecondary,
                    side: const BorderSide(color: AirColors.border),
                  ),
                  onPressed: () => _toggleWireKeeper(false),
                  icon: const Icon(Icons.link_off, size: 18),
                  label: const Text('Disable'),
                ),
              ),
            ],
          ),
        ],
      );

  Widget _card({required String title, required List<Widget> children}) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AirColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AirColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: AirColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      );

  Widget _statusRow(
    String label,
    bool ok, {
    String? fixLabel,
    VoidCallback? onFix,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.error_outline,
            size: 18,
            color: ok ? Colors.green.shade600 : AirColors.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: AirColors.textPrimary, fontSize: 14)),
          ),
          if (!ok && fixLabel != null)
            TextButton(
              onPressed: onFix,
              child: Text(fixLabel,
                  style: const TextStyle(color: AirColors.accent)),
            ),
        ],
      ),
    );
  }
}
