/// Normalizes a relay `packet_status` value into the app's message-status
/// vocabulary. Kept pure so it can be unit-tested without a socket.
///
/// The relay only ever emits `relayed` (handed live to the recipient's wire)
/// or `queued_ephemeral` (stored for the recipient's next connection). Neither
/// means "read" — the previous code fell through to the default branch and
/// rendered an off-white double-tick (i.e. read) for both.
String? mapRelayStatus(String raw) {
  switch (raw) {
    case 'relayed':
      return 'delivered';
    case 'queued_ephemeral':
      return 'sent';
    case 'sent':
    case 'delivered':
    case 'read':
    case 'failed':
    case 'expired':
      return raw;
    default:
      return null;
  }
}
