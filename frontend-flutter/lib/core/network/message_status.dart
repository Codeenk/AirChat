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

/// The seeded path's *failure* vocabulary, which the named transport does not
/// have.
///
/// The relay answers a sealed send it cannot route with one of these instead of
/// accepting it. None of them is a reason to keep the bubble in `sending`: the
/// recipient's tag was unknown, expired, or the request was malformed, so the
/// message will not deliver by waiting. `failed` is honest and offers retry.
///
/// The relay answers generically on purpose — `unknown_recipient` covers both
/// "never existed" and "expired", so a client cannot probe for valid tags.
String? mapSealedFailure(String raw) {
  switch (raw) {
    case 'unknown_recipient':
    case 'not_registered':
    case 'invalid_request':
    case 'unavailable':
      return 'failed';
    default:
      return null;
  }
}
