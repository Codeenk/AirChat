import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum TunnelState { disconnected, connecting, connected }

/// The sealed-sender slice of the tunnel.
///
/// Declared separately from [WebSocketTunnelClient] so the parts of sealed
/// delivery that are pure protocol — the tag registry and the send/receive
/// service — can be exercised against a fake transport. Constructing the real
/// client is not free (it binds connectivity and reconnect timers), and a test
/// that needs a socket to check a tag rotation would not be testing the tag
/// rotation.
abstract class SealedTransport {
  /// Claims [tag] on this connection, optionally with the FCM token to wake
  /// this device for mail addressed to it.
  void sealRegister({required String tag, String? fcmToken});

  /// Sends an opaque [body] to [toTag], quoting [replyTag] as the return path.
  void sendSealed({
    required String toTag,
    required String replyTag,
    required String packetId,
    required String body,
  });

  /// Confirms receipt of a packet so the relay can drop its copy.
  void sealAck({
    required String tag,
    required String packetId,
    String? replyTag,
  });

  /// Read receipt, routed by tag exactly like [sealAck].
  void sealReceipt({
    required String tag,
    required String packetId,
    String? replyTag,
  });
}

class PacketStatusReceipt {
  final String packetId;
  final String status; // 'relayed', 'queued_ephemeral', 'delivered'

  PacketStatusReceipt({required this.packetId, required this.status});
}

/// Collapses a burst of sealed packets into one delayed submission.
///
/// Submission *timing* is a metadata channel even when the bytes are opaque: a
/// message leaving this device the instant the user hits send tells a watching
/// relay roughly what the user is doing and pairs up with the arrival it causes
/// a moment later at the other end. So an outbound sealed packet is held for a
/// short random interval and flushed together with anything else composed in
/// that window, which makes submission time neither send time nor unique to one
/// message (`SECURITY_SEALED_SENDER.md` §8).
///
/// Deliberately small: this is jitter, not a mixnet. A messenger that added
/// seconds of latency to every message would not be used, and an unused
/// messenger protects nobody.
class SealedBatcher {
  SealedBatcher({
    required this.emit,
    Random? random,
    Timer Function(Duration duration, void Function() callback)? timerFactory,
  }) : _random = random ?? Random(),
       _timerFactory = timerFactory ?? ((d, f) => Timer(d, f));

  /// Called once per pending packet, in submission order, when the batch
  /// flushes. Wired to the socket by [WebSocketTunnelClient].
  final void Function(Map<String, dynamic> packet) emit;

  final Random _random;
  final Timer Function(Duration duration, void Function() callback)
  _timerFactory;

  final List<Map<String, dynamic>> _pending = [];
  Timer? _timer;

  /// Minimum hold. Long enough to overlap a second message typed right after
  /// the first, short enough that "instant" messaging still feels instant.
  static const int minDelayMs = 120;

  /// Maximum hold. Beyond this the sender would notice the lag.
  static const int maxDelayMs = 600;

  /// Pure, unit-testable: the random hold applied to one batch.
  static int delayMs(Random random) =>
      minDelayMs + random.nextInt(maxDelayMs - minDelayMs + 1);

  int get pending => _pending.length;

  void submit(Map<String, dynamic> packet) {
    _pending.add(packet);
    // One timer per batch, armed by the first packet: later arrivals join the
    // batch already in flight rather than pushing the flush back forever.
    _timer ??= _timerFactory(Duration(milliseconds: delayMs(_random)), _flush);
  }

  void flushNow() => _flush();

  void _flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    final batch = List<Map<String, dynamic>>.from(_pending);
    _pending.clear();
    for (final packet in batch) {
      emit(packet);
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }
}

class WebSocketTunnelClient implements SealedTransport {
  final String baseWsUrl;
  final String uid;

  WebSocketChannel? _channel;
  TunnelState _state = TunnelState.disconnected;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  int _backoffSeconds = 3;
  bool _disposed = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// Packets composed while offline; flushed automatically on reconnect.
  final List<Map<String, dynamic>> _outboundQueue = [];

  final StreamController<TunnelState> _stateController =
      StreamController<TunnelState>.broadcast();
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<TunnelState> get stateStream => _stateController.stream;
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  TunnelState get currentState => _state;
  int get queuedPacketCount => _outboundQueue.length;

  /// Pure, unit-testable backoff calculation: doubles until 30s, then applies
  /// ±20% jitter so many clients don't thunder-herd on the relay.
  static int nextBackoffSeconds(int current) {
    final doubled = (current * 2).clamp(3, 30);
    final jitter = (doubled * 0.2 * (Random().nextDouble() * 2 - 1)).round();
    return (doubled + jitter).clamp(3, 30);
  }

  /// Signs the server auth challenge (nonce). Set by the app layer from
  /// KeyStore signing keys — works in the main isolate AND the FCM
  /// background isolate (pure Dart, no plugins needed).
  final Future<String?> Function(String nonce)? signChallenge;

  /// Fired when the relay rejects our auth (socket closed after a challenge
  /// without auth_ok). The app layer should re-register its signing key,
  /// then let the normal reconnect cycle retry. Cooldown enforced by caller.
  final Future<void> Function()? onAuthFailure;

  /// Fired once per successful authentication (challenge or legacy handshake).
  ///
  /// This is where the device re-claims its sealed-sender delivery tags: the
  /// relay holds a tag only for the lifetime of the row, and a tag claim is
  /// self-healing *because* every connect re-registers, so a registered socket
  /// is a prerequisite for being reachable at all.
  final Future<void> Function()? onAuthenticated;

  /// True once the relay has accepted our auth. Sends are held until authed
  /// so nothing is lost to the 10s unauthenticated window.
  bool _authed = false;
  bool get isAuthed => _authed;
  bool _sawAuthChallenge = false;
  Timer? _legacyRelayTimer;

  DateTime? _connectStartedAt;

  WebSocketTunnelClient({
    this.baseWsUrl = "wss://airchat-relay.malandkar-sarvesh1.workers.dev",
    required this.uid,
    this.signChallenge,
    this.onAuthFailure,
    this.onAuthenticated,
  }) {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNet = results.any(
        (r) =>
            r == ConnectivityResult.mobile ||
            r == ConnectivityResult.wifi ||
            r == ConnectivityResult.ethernet ||
            r == ConnectivityResult.vpn,
      );
      if (hasNet && _state == TunnelState.disconnected && !_disposed) {
        _backoffSeconds = 3;
        connect();
      }
    });
  }

  void connect() {
    if (_disposed) return;
    if (_state == TunnelState.connected || _state == TunnelState.connecting) {
      return;
    }

    _setState(TunnelState.connecting);
    _connectStartedAt = DateTime.now();
    final url = Uri.parse("$baseWsUrl/tunnel?uid=$uid");

    try {
      _channel = WebSocketChannel.connect(url);
      final channel = _channel!; // capture: stale-socket events must be ignored

      // Mark connected ONLY when the handshake actually completes.
      // Fixes the stale-'connected'-event race for late UI subscribers.
      channel.ready
          .then((_) {
            if (_disposed || !identical(_channel, channel)) return;
            _backoffSeconds = 3; // reset backoff on success
            _setState(TunnelState.connected);
            _startPing();
            // Legacy relay compat: old relays never send auth_challenge and
            // flush on connect. If no challenge arrives in 5s, assume legacy
            // and release held sends. (New relays challenge immediately.)
            _legacyRelayTimer?.cancel();
            _legacyRelayTimer = Timer(const Duration(seconds: 5), () {
              if (!identical(_channel, channel) || _disposed) return;
              if (!_sawAuthChallenge && !_authed) {
                _setAuthed(true);
              }
            });
            if (_authed) _flushOutboundQueue();
          })
          .catchError((_) {
            if (identical(_channel, channel)) _handleDisconnect();
          });

      channel.stream.listen(
        (data) {
          try {
            final jsonMap = jsonDecode(data as String) as Map<String, dynamic>;

            // Auth challenge: sign nonce+uid, then flush anything held.
            if (jsonMap['type'] == 'auth_challenge') {
              _sawAuthChallenge = true;
              _legacyRelayTimer?.cancel();
              _handleAuthChallenge(jsonMap['nonce'] as String?);
              return;
            }
            if (jsonMap['type'] == 'auth_ok') {
              _setAuthed(true);
              return;
            }
            // Relay closed us for failed auth — reconnect will retry with keys.
            if (jsonMap['type'] == 'error' &&
                (jsonMap['message'] as String? ?? '').contains('auth')) {
              return;
            }

            _messageController.add(jsonMap);

            // Auto ACK incoming direct messages
            if (jsonMap['type'] == 'direct_message') {
              final packetId = jsonMap['packetId'];
              final senderUid = jsonMap['senderUid'];
              if (packetId != null && senderUid != null) {
                sendAck(packetId: packetId, senderUid: senderUid);
              }
            }
          } catch (_) {}
        },
        onDone: () {
          if (identical(_channel, channel)) _handleDisconnect();
        },
        onError: (_) {
          if (identical(_channel, channel)) _handleDisconnect();
        },
      );
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_state == TunnelState.connected) {
        _channel?.sink.add(jsonEncode({'action': 'ping'}));
      }
    });
  }

  void _enqueue(Map<String, dynamic> packet) {
    _outboundQueue.add(packet);
    // Bound the queue — drop oldest beyond 200 pending packets
    if (_outboundQueue.length > 200) {
      _outboundQueue.removeAt(0);
    }
  }

  void sendPing() {
    if (_state == TunnelState.connected) {
      _channel?.sink.add(jsonEncode({'action': 'ping'}));
    }
  }

  Future<void> _handleAuthChallenge(String? nonce) async {
    if (nonce == null || nonce.isEmpty) return;
    try {
      final signature = await signChallenge?.call(nonce);
      if (signature == null || signature.isEmpty) return;
      _channel?.sink.add(
        jsonEncode({'action': 'auth', 'signature': signature}),
      );
    } catch (_) {}
  }

  /// Called when the relay accepts our auth (server sends no explicit
  /// auth_ok today — we treat first flushable moment as authed). External
  /// callers should not need this; kept for tests.
  void markAuthedForTest() {
    _authed = true;
    _flushOutboundQueue();
  }

  bool _authNotified = false;

  void _setAuthed(bool value) {
    _authed = value;
    if (!value) return;
    _flushOutboundQueue();
    if (_authNotified) return;
    _authNotified = true;
    try {
      onAuthenticated?.call();
    } catch (_) {}
  }

  // ─── sealed sender ───

  late final SealedBatcher _sealedBatcher = SealedBatcher(emit: _writeSealed);

  /// Packets held by the timing batch — exposed so a test can assert the hold
  /// actually happens rather than measuring wall-clock timing.
  int get pendingSealedCount => _sealedBatcher.pending;

  /// Test seam: submit the current batch without waiting out the jitter.
  void flushSealedForTest() => _sealedBatcher.flushNow();

  /// Claims a delivery tag on this socket.
  ///
  /// Sent immediately rather than batched — it is addressability, not traffic,
  /// and a batch delay would just widen the window in which mail addressed to
  /// this device has nowhere to land. Not authenticated: a tag confers no
  /// privilege, it only means "deliver what is addressed to this tag"
  /// (`SECURITY_SEALED_SENDER.md` §4.1).
  @override
  void sealRegister({required String tag, String? fcmToken}) {
    final packet = {
      'action': 'seal_register',
      'tag': tag,
      if (fcmToken != null && fcmToken.isNotEmpty) 'fcm': fcmToken,
    };
    _writeSealed(packet);
  }

  /// Sends a sealed packet: addressed to the recipient's tag, with our own tag
  /// as the return path, and no uid in either direction.
  @override
  void sendSealed({
    required String toTag,
    required String replyTag,
    required String packetId,
    required String body,
  }) {
    _sealedBatcher.submit({
      'action': 'seal',
      'to': toTag,
      'reply': replyTag,
      'packetId': packetId,
      'body': body,
    });
  }

  /// Acknowledges a sealed packet, which lets the relay drop its copy.
  ///
  /// No identity is asserted — only the opaque packet and the tag it arrived
  /// on — so this needs no auth and grants no power over anyone else's mail.
  @override
  void sealAck({
    required String tag,
    required String packetId,
    String? replyTag,
  }) {
    _writeControl({
      'action': 'seal_ack',
      'tag': tag,
      'packetId': packetId,
      'reply': ?replyTag,
    });
  }

  /// Read receipt on the sealed path, routed by tag like [sealAck].
  @override
  void sealReceipt({
    required String tag,
    required String packetId,
    String? replyTag,
  }) {
    _writeControl({
      'action': 'seal_receipt',
      'tag': tag,
      'packetId': packetId,
      'reply': ?replyTag,
    });
  }

  /// Writes one packet out, or holds it for the reconnect flush.
  void _writeSealed(Map<String, dynamic> packet) {
    if (_state == TunnelState.connected && _authed) {
      _channel?.sink.add(jsonEncode(packet));
    } else {
      _enqueue(packet);
      connect();
    }
  }

  /// Best-effort control write: acks and receipts are worthless late, and a
  /// queued ack replayed after a reconnect would delete mail we already have.
  void _writeControl(Map<String, dynamic> packet) {
    if (_state != TunnelState.connected || !_authed) return;
    _channel?.sink.add(jsonEncode(packet));
  }

  void sendPacket({
    required String recipientUid,
    required String encryptedPayload,
    required String packetId,
  }) {
    final packet = {
      'action': 'send_packet',
      'recipientUid': recipientUid,
      'encryptedPayload': encryptedPayload,
      'packetId': packetId,
    };

    // Hold until authenticated — the relay drops unauthenticated sends.
    if (_state == TunnelState.connected && _authed) {
      _channel?.sink.add(jsonEncode(packet));
    } else {
      // Never silently drop — hold for automatic flush on reconnect+auth.
      _enqueue(packet);
      connect(); // trigger reconnect cycle if not already running
    }
  }

  /// Sends a group packet — one encrypted payload stored once in the group
  /// inbox, woken to all members by the relay.
  ///
  /// No group name: the relay only routes the packet, and every recipient
  /// resolves the name from their own local state.
  void sendGroupPacket({
    required String groupId,
    required String encryptedPayload,
    required String packetId,
    required String senderName,
  }) {
    final packet = {
      'action': 'send_group_packet',
      'groupId': groupId,
      'encryptedPayload': encryptedPayload,
      'packetId': packetId,
      'senderName': senderName,
    };

    if (_state == TunnelState.connected && _authed) {
      _channel?.sink.add(jsonEncode(packet));
    } else {
      _enqueue(packet);
      connect();
    }
  }

  /// Acks a group packet — tells the relay to delete the cached copy.
  void ackGroupPacket({required String packetId, required String groupId}) {
    if (_state != TunnelState.connected) return;
    _channel?.sink.add(
      jsonEncode({
        'action': 'ack_group',
        'packetId': packetId,
        'groupId': groupId,
      }),
    );
  }

  void sendAck({required String packetId, required String senderUid}) {
    if (_state != TunnelState.connected || !_authed) {
      return; // ACKs are best-effort
    }
    _channel?.sink.add(
      jsonEncode({
        'action': 'ack',
        'packetId': packetId,
        'senderUid': senderUid,
      }),
    );
  }

  /// Best-effort read receipt: tells the original sender their message
  /// was seen. Only sent while the tunnel is connected.
  void sendReadReceipt({required String packetId, required String senderUid}) {
    if (_state != TunnelState.connected || !_authed) return;
    _channel?.sink.add(
      jsonEncode({
        'action': 'read_receipt',
        'packetId': packetId,
        'senderUid': senderUid,
      }),
    );
  }

  void _flushOutboundQueue() {
    if (_outboundQueue.isEmpty) return;
    for (final packet in _outboundQueue) {
      _channel?.sink.add(jsonEncode(packet));
    }
    _outboundQueue.clear();
  }

  void _handleDisconnect() {
    if (_disposed) return;
    // Auth rejected us (challenged but never accepted, socket died fast):
    // our signing key is likely missing/stale server-side. Ask the app
    // layer to re-register, then reconnect heals on the next cycle.
    final challenged = _sawAuthChallenge;
    final wasAuthed = _authed;
    final startedAt = _connectStartedAt;
    _authed = false;
    _authNotified = false;
    _sawAuthChallenge = false;
    _legacyRelayTimer?.cancel();
    _setState(TunnelState.disconnected);
    _pingTimer?.cancel();
    if (challenged &&
        !wasAuthed &&
        startedAt != null &&
        DateTime.now().difference(startedAt).inSeconds < 20) {
      try {
        onAuthFailure?.call();
      } catch (_) {}
    }

    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    // Exponential backoff: 3s -> 6s -> 12s -> 24s (cap 30s) with jitter
    _reconnectTimer?.cancel();
    final delay = Duration(seconds: _backoffSeconds);
    _reconnectTimer = Timer(delay, () {
      _backoffSeconds = nextBackoffSeconds(_backoffSeconds);
      connect();
    });
  }

  void _setState(TunnelState state) {
    if (_state == state) return;
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  void dispose() {
    _disposed = true;
    _connectivitySub?.cancel();
    _legacyRelayTimer?.cancel();
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _sealedBatcher.dispose();
    _channel?.sink.close();
    _stateController.close();
    _messageController.close();
  }
}
