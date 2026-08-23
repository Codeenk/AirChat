import 'dart:async';
import 'dart:convert';
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

  WebSocketTunnelClient({
    this.baseWsUrl = "wss://airchat-relay.malandkar-sarvesh1.workers.dev",
    required this.uid,
  });

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
      channel.ready.then((_) {
        if (_disposed || !identical(_channel, channel)) return;
        _backoffSeconds = 3; // reset backoff on success
        _setState(TunnelState.connected);
        _startPing();
        _flushOutboundQueue();
      }).catchError((_) {
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

  void sendAck({required String packetId, required String senderUid}) {
    if (_state != TunnelState.connected) return; // ACKs are best-effort
    _channel?.sink.add(jsonEncode({
      'action': 'ack',
      'packetId': packetId,
      'senderUid': senderUid,
    }));
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

    // Exponential backoff: 3s -> 6s -> 12s -> 24s (cap 30s)
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: _backoffSeconds), () {
      _backoffSeconds = (_backoffSeconds * 2).clamp(3, 30);
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
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _stateController.close();
    _messageController.close();
  }
}
