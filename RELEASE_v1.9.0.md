# AirChat v1.9.0

Sealed sender, client side. This is the release that makes the relay stop
knowing who talks to whom.

## What changed

v1.8.1 put sealed delivery in the relay and noted, honestly, that it was
dormant: no client spoke the protocol, so every real conversation still ran the
legacy named transport and the relay still held the social graph. This release
wires the client, so the feature is live.

1. **Delivery tags** (`lib/core/crypto/delivery_tag.dart`). A device is
   addressed by 32 random bytes, base64url, generated on the device and
   **rotated daily**, with a 7-day grace window so mail addressed to a tag that
   was just retired still arrives. Every active tag is re-claimed on every
   connect, which makes a tag claim self-healing rather than a one-shot
   registration.
2. **Sealed send** (`lib/core/crypto/sealed_sender.dart`,
   `lib/state/chat_provider.dart`). A 1:1 message is addressed to the peer's tag
   with our own tag as the return path. No uid is sent in either direction, so
   there is nothing for the relay to record.
3. **Attribution by decryption** (`lib/state/connection_provider.dart`). The
   relay no longer says who sent a message, so the recipient works it out: the
   peer whose ratchet session opens the payload *is* the sender. For the first
   message of a pair there is no session yet, so the identity key inside the
   pre-key envelope is matched against contacts whose keys we already hold.
4. **Acks and read receipts without an edge** — routed by tag, naming only the
   opaque packet, never a person.
5. **Timing defences, client half** — each sealed packet is held for a random
   120–600 ms and batched with anything composed in that window, so submission
   time is not send time. The relay already shuffles and batches on its side.
6. **Uid-free wake** — `sealed_wake` carries literally nothing, and the
   notification it raises is generic ("AirChat — You have a new message") rather
   than naming a sender.
7. **Schema v13** — `messages.reply_tag`, the return tag of an inbound sealed
   message. Needed so a read receipt sent later can still find its author.

## The one input this release does not seal

**The first message of any pair still names its sender.**

Sealing is gated on one condition: we hold a tag that arrived inside a payload
we successfully decrypted. That single fact carries two guarantees — the peer
holds our identity key, so they can attribute a sealed message from us, and
their tag is current. Sealing to a tag learned from a peer's *published bundle*
would skip both checks, and the failure mode is not a leak but a **message that
expires unread** because its recipient could not say who sent it.

The case that matters is the ordinary one: you scan someone's QR code, they
never added you back, so they hold no identity key for you. Sealing to them
would silently lose the message. So the first message goes out named, the reply
comes back sealed, and everything after is sealed in both directions.

Cost: one edge per conversation, visible to the relay. Benefit: this feature
cannot lose a message. `SECURITY_SEALED_SENDER.md` §6.1 and §7.6 record both.

Also unchanged and still named: **group messages**. The relay accepts sealed
group traffic and self-subscribed membership, but no client speaks it yet, so a
group message still names its sender and group, and group membership is still
visible to the relay. That is the next piece of work.

## What this does not claim

- A relay that terminates both connections can still correlate the two ends by
  IP address and timing. Sealing removes the relay's **stored, logged and
  third-party-visible** graph; it does not defeat a live adversary correlating
  in real time.
- Message **timing and size** remain observable at submission.
- **No device-to-device test has been run.** See below.

## Verification

- `flutter analyze` — 0 errors, 0 warnings (77 pre-existing infos, unchanged).
- `flutter test` — **129 passing** (was 100). 28 of them are
  `test/sealed_sender_test.dart`, which runs the real libsignal implementation:
  tag shape and rotation, the send gate, the timing batcher, and a full sealed
  round trip between two simulated devices including attribution and reply.
- `dart format --output=none --set-exit-if-changed lib test` — clean.
- **Live against the deployed relay**, driving the client's exact packet shapes
  from a script: anonymous sockets (no `?uid=`) register and get
  `seal_registered`; `seal` returns `relayed` and delivers
  `{type,to,packetId,body,hint,timestamp}` with **no `senderUid` and no `reply`**;
  `seal_ack` routes `seal_status delivered` back to the sender; `seal_receipt`
  routes `seal_read`; an unregistered tag gets a generic failure; legacy `?uid=`
  sockets still receive their auth challenge.

Two properties the tests pin down, because both are silent failures if they
ever regress:

- A pre-key message opens under **any** address label we hand libsignal, so an
  unfiltered trial decrypt would let the first contact in the list claim any
  message. Attribution filters candidates by identity key, and a test pins that
  down.
- An unattributable packet is **not** acked. It stays on the relay until its
  24h TTL rather than being destroyed by a reader that could not read it.

## Known gaps

`SECURITY_SEALED_SENDER.md` §7 and §11 list them in full. In order of
importance: group sealed delivery, cover traffic, and a rich sealed wake (which
needs notification content gated behind an app lock first — otherwise a preview
just moves the lock-screen leak this release closes). A sealed first message
from someone not already in your contacts cannot be attributed at all; it is
left queued rather than misattributed, and §7.6 explains why there is no cheap
fix.
