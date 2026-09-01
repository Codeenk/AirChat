import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum TunnelState { disconnected, connecting, connected }

class PacketStatusReceipt {
  final String packetId;
  final String status; // 'relayed', 'queued_ephemeral', 'delivered'

  PacketStatusReceipt({required this.packetId, required this.status});
}

class WebSocketTunnelClient {
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

  WebSocketTunnelClient({
    this.baseWsUrl = "wss://airchat-relay.malandkar-sarvesh1.workers.dev",
    required this.uid,
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
            _flushOutboundQueue();
          })
          .catchError((_) {
            if (identical(_channel, channel)) _handleDisconnect();
          });

      channel.stream.listen(
        (data) {
          try {
            final jsonMap = jsonDecode(data as String) as Map<String, dynamic>;
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

    if (_state == TunnelState.connected) {
      _channel?.sink.add(jsonEncode(packet));
    } else {
      // Never silently drop — hold for automatic flush on reconnect.
      _enqueue(packet);
      connect(); // trigger reconnect cycle if not already running
    }
  }

  /// Sends a group packet — one encrypted payload stored once in the group
  /// inbox, woken to all members by the relay.
  void sendGroupPacket({
    required String groupId,
    required String groupName,
    required String encryptedPayload,
    required String packetId,
    required String senderName,
  }) {
    final packet = {
      'action': 'send_group_packet',
      'groupId': groupId,
      'groupName': groupName,
      'encryptedPayload': encryptedPayload,
      'packetId': packetId,
      'senderName': senderName,
    };

    if (_state == TunnelState.connected) {
      _channel?.sink.add(jsonEncode(packet));
    } else {
      _enqueue(packet);
      connect();
    }
  }

  /// Acks a group packet — tells the relay to delete the cached copy.
  void ackGroupPacket({required String packetId, required String groupId}) {
    if (_state != TunnelState.connected) return;
    _channel?.sink.add(jsonEncode({
      'action': 'ack_group',
      'packetId': packetId,
      'groupId': groupId,
    }));
  }

  void sendAck({required String packetId, required String senderUid}) {
    if (_state != TunnelState.connected) return; // ACKs are best-effort
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
    if (_state != TunnelState.connected) return;
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
    _setState(TunnelState.disconnected);
    _pingTimer?.cancel();

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
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _stateController.close();
    _messageController.close();
  }
}
