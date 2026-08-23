import 'dart:async';

class RefreshEvent {
  final String type; // 'messages' | 'status'
  final String? chatId;
  final String? messageId;
  final String? status;

  RefreshEvent({
    required this.type,
    this.chatId,
    this.messageId,
    this.status,
  });
}

/// Lightweight in-process broadcast bus.
/// Fired after every DB mutation so live UI surfaces update instantly.
class RefreshBus {
  final _controller = StreamController<RefreshEvent>.broadcast();

  Stream<RefreshEvent> get stream => _controller.stream;

  void fire(RefreshEvent event) {
    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  void dispose() {
    _controller.close();
  }
}
