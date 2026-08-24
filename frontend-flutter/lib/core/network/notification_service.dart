import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../quick_reply/quick_reply_sender.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// No local notifications on web (no plugin implementation) — calls become
  /// harmless no-ops.
  bool get _supported => !kIsWeb;

  /// Tracks whether the Flutter UI is currently visible. The MessageRouter
  /// only shows local notifications when this is false.
  static bool isAppForeground = false;

  /// Per-sender notification ids so messages from one person stack in a
  /// single notification (MessagingStyle) instead of spamming the shade.
  static int notificationIdFor(String senderUid) {
    // Stable positive 31-bit hash per sender.
    return senderUid.hashCode & 0x7fffffff;
  }

  /// In-memory history of shown lines per sender, so stacked notifications
  /// grow into a conversation. Cleared when the chat's notification is
  /// cancelled (user opened the chat).
  static final Map<String, List<MessageLine>> _shownLines = {};

  Future<void> initialize() async {
    if (_initialized || !_supported) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    // Create the channel explicitly — required for reliable delivery and
    // user-controlled importance on Android 8+.
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(const AndroidNotificationChannel(
      'airchat_messages',
      'Messages',
      description: 'New end-to-end encrypted messages',
      importance: Importance.high,
    ));

    await _plugin.initialize(
      settings: const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: _onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: _onBackgroundNotificationResponse,
    );
    _initialized = true;
  }

  void _onNotificationResponse(NotificationResponse r) {
    if (r.actionId == 'reply_action' && (r.input?.isNotEmpty ?? false)) {
      final senderUid = r.payload ?? '';
      final text = r.input!.trim();
      if (senderUid.isEmpty || text.isEmpty) return;
      // Foreground: stash for the open chat screen to consume.
      _pendingQuickReplies[senderUid] = text;
    }
  }

  @pragma('vm:entry-point')
  static void _onBackgroundNotificationResponse(NotificationResponse r) {
    if (r.actionId == 'reply_action' && (r.input?.isNotEmpty ?? false)) {
      final senderUid = r.payload ?? '';
      final text = r.input!.trim();
      if (senderUid.isEmpty || text.isEmpty) return;
      // Background isolate (action tapped while app killed): send directly.
      // Fire-and-forget; the handler must return promptly.
      unawaited(QuickReplySender.send(recipientUid: senderUid, text: text));
    }
  }

  static final Map<String, String> _pendingQuickReplies = {};

  static String? consumePendingReply(String senderUid) =>
      _pendingQuickReplies.remove(senderUid);

  Future<bool> requestPermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final granted = await android.requestNotificationsPermission();
      return granted ?? false;
    }
    return true;
  }

  /// Shows (or stacks onto) a per-sender message notification.
  Future<void> showMessageNotification({
    required String title,
    required String body,
    String? senderUid,
  }) async {
    if (!_supported) return;
    if (!_initialized) await initialize();

    final person = Person(name: title, key: senderUid ?? title, important: true);
    final history = (senderUid != null ? _shownLines[senderUid] : null) ?? const [];
    final styleInformation = MessagingStyleInformation(
      person,
      groupConversation: false,
      conversationTitle: title,
      messages: [
        ...history.map((l) => Message(l.text, DateTime.fromMillisecondsSinceEpoch(l.timestamp), person)),
        Message(body, DateTime.now(), person),
      ],
    );

    final androidDetails = AndroidNotificationDetails(
      'airchat_messages',
      'Messages',
      channelDescription: 'New end-to-end encrypted messages',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      showWhen: true,
      styleInformation: styleInformation,
      number: history.length + 1,
      // Replace by sender tag so re-shows update in place (no duplicates).
      tag: senderUid,
      autoCancel: true,
      actions: [
        AndroidNotificationAction(
          'reply_action',
          'Reply',
          inputs: [AndroidNotificationActionInput(label: 'Reply')],
          allowGeneratedReplies: true,
        ),
      ],
    );
    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      id: senderUid != null
          ? notificationIdFor(senderUid)
          : DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff),
      title: title,
      body: body,
      notificationDetails: details,
      payload: senderUid,
    );

    if (senderUid != null) {
      // Dedupe: cancel the OS-displayed FCM notification (id 0 + tag =
      // senderUid) so it doesn't stack alongside this richer local one.
      try {
        await _plugin.cancel(id: 0, tag: senderUid);
      } catch (_) {}
      final list = _shownLines.putIfAbsent(senderUid, () => []);
      list.add(MessageLine(text: body, timestamp: DateTime.now().millisecondsSinceEpoch));
      if (list.length > 8) list.removeRange(0, list.length - 8);
    }
  }

  /// Clears the notification for one chat (sender).
  Future<void> cancelForChat(String senderUid) async {
    if (!_supported) return;
    _shownLines.remove(senderUid);
    // Tagged notifications must be cancelled by (tag, id) pair.
    await _plugin.cancel(id: notificationIdFor(senderUid), tag: senderUid);
  }

  /// Clears everything (app resumed → all notifications are stale).
  Future<void> clearAll() async {
    if (!_supported) return;
    _shownLines.clear();
    await _plugin.cancelAll();
  }
}

/// A previously-shown message line, kept in memory so stacked notifications
/// retain conversation history.
class MessageLine {
  final String text;
  final int timestamp;
  const MessageLine({required this.text, required this.timestamp});
}
