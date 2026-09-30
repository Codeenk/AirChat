# AirChat v1.8.0 — real forward secrecy, for new conversations

This release makes the forward-secrecy claim true, and wires the MLS group
crypto into the app instead of leaving it on the shelf. Both changes are
deliberately scoped to **conversations created from this version on**: anything
that already exists keeps the scheme it used, because a peer on a released build
cannot read the new formats at all.

Nothing the user had keeps working differently. What changes is what a *new*
chat and a *new* group are made of.

## 1. 1:1 Double Ratchet (new chats)

Previous 1:1 encrypted to the recipient's **long-term** X25519 key with a fresh
ephemeral sender key per message. That is key freshness, not forward secrecy:
one compromise of the recipient's key opened every message ever sent to it, past
and future. `SECURITY_DESIGN.md` §3.1 said so plainly, and it was the largest
remaining gap in the security story.

A new chat between two devices that both publish a prekey bundle now runs the
**Signal Protocol** — X3DH/PQXDH handshake, then a double ratchet — via
`libsignal`, the upstream Rust implementation the audited messengers use. Both
the DH ratchet and the symmetric ratchet advance per message, so a compromised
message key covers one message, and the ratchet recovers after a compromise.

The identity detail that matters: **it reuses the app's existing X25519 identity
key** as the Signal identity. That means the safety number a user compares in
person is the key that authenticates the ratchet — not a second, unverified
identity sitting next to it. If that import cannot be shown to reproduce the same
public key, the feature reports itself unavailable rather than minting a new
identity.

Two rules keep the rollout safe:

- **A chat's scheme is recorded when the chat is created and never rewritten.**
  Switching mid-conversation would make whichever messages crossed the switch
  unreadable on one side. The ratchet is used only for a chat's first message,
  and only when the peer's published bundle is present *and* its identity key
  matches the one the directory (and the safety number) holds. Without that
  check a hostile relay could serve its own bundle and own the session, because
  first-use trust would have nothing to compare against.
- **A failure never downgrades.** A message sent on the ratchet is never retried
  on the legacy path; the fallback exists only for a chat that is genuinely still
  legacy.

Storage follows the store contract the library documents: every session write
runs inside its own SQLite transaction, committed before the ciphertext is
released, and every operation for one peer is serialized under a per-address
lock. Both matter — a lost session write or two concurrent sends would reuse a
message key, which is exactly the property the ratchet is for.

## 2. MLS groups, wired end to end

The OpenMLS layer from v1.7.0 is now connected to the app:

- **KeyPackages are published and fetched through the relay**
  (`POST /api/keys/publish`, `GET /api/keys/lookup`). The payload is opaque to
  the relay — it parses nothing — and every row carries the same 30-day sliding
  TTL, so a device that stops publishing stops being pre-keyed instead of being
  retained forever.
- **A new group is MLS when every invited member has published a KeyPackage.**
  All-or-nothing on purpose: an older client cannot process an MLS epoch at all,
  so one such member keeps the whole group on the shared-key scheme that member
  can read.
- **The Welcome travels on the existing encrypted 1:1 channel** as a
  `group_invite` payload — no new relay surface. It is joined before the group
  row is written, and the group id and ciphersuite are validated first, so a
  forged or mis-addressed Welcome cannot corrupt local state.
- **Commits ride the group channel.** Adding or removing a member advances the
  epoch for everyone; the roster is then adopted from the ratchet tree, which is
  authoritative, rather than from the relay's copy.
- **Removal actually revokes.** A removed member cannot derive the new epoch's
  keys, and there is no shared key they could have kept. The member's own client
  is told it was evicted (openmls refuses to let an evicted member merge the
  commit) and drops the group, instead of holding a thread it can never read
  again.

## 3. Version gating

A new wire envelope says what a ciphertext is:
`{"v":2,"k":"sig"|"mls","t":<type>,"c":"<base64>"}`. A released client reads only
the legacy `ct`/`n`/`epk` fields, so a v2 payload presents it with an empty
ciphertext and its AEAD open fails — the message is **dropped, never misread**.
That is why a v2 message is only ever sent to a peer that published the matching
key material.

`cryptoVersion` is now advertised and preserved across every group control, and
`Group.usesMls` / `ChatCrypto.usesRatchet` are the single decision points for
sending and receiving. A control that does not name a version can never flip a
group or a chat either way.

## 4. One bug found while wiring this

Removing a member from an MLS group used to make the removed member's client
**throw** when it processed the commit that evicted it — openmls refuses to merge
a commit from a group you have been removed from. The failure was being caught
and dropped, which left that client holding a group it could never read again,
with no explanation for the silence that followed. That refusal is now reported
as `evicted` and the client drops the group.

## 5. Tests

`flutter test` is **100 passing**.

- `test/ratchet_session_test.dart` (new) — two real libsignal devices: bundle
  round-trip, session establishment, both directions, several messages each way,
  **out-of-order delivery**, republishing a bundle without rewinding the ratchet,
  refusing to encrypt with no session, and **tampered ciphertext failing closed**.
  It also asserts the ratchet identity is the app's own X25519 key.
- `test/mls_transport_test.dart` (new) — an application message and a *commit*
  through the real envelope on real OpenMLS engines, including a removed member
  being reported evicted and then unable to read the next message.
- The existing 77 tests (safety numbers, group versioning, MLS layer, storage)
  still pass unchanged.

## 6. Relay change needs a deploy

The worker gained the `key_packages` table and three routes:

```bash
cd backend-worker
npx wrangler d1 migrations apply airchat-identity --remote
npx wrangler deploy
```

`0001_group_memberships_expiry.sql` (from v1.7.0) and
`0002_key_packages.sql` only *add* tables or rebuild one that no read depended
on, so applying them before or after the deploy is safe either way. Until the
deploy lands, publishing a key package simply fails and every new conversation
stays on the legacy scheme — no breakage, just no ratchet yet.

## 7. What is still open, stated plainly

- **No external audit.** Both OpenMLS and libsignal are vetted implementations,
  which is why the "no custom crypto" rule allowed them, but AirChat's own
  wiring of them has not been audited.
- **No end-to-end two-device test of the shipped binaries.** The protocol tests
  run the real implementations, but the app-level handoff — one device on this
  build messaging another — has not been exercised outside a test harness, and
  the failure mode of a wrong wiring is a peer going quiet rather than an error.
- **Concurrent MLS commits are not reconciled.** The relay is unordered, so two
  simultaneous membership changes from different members can still diverge.
- **Local hardening is still deferred** (app lock, lock-screen preview
  suppression, `FLAG_SECURE`), on the user's explicit instruction that the
  OS-level app lock covers it.
- **The legacy paths remain in the code on purpose** — every chat and group that
  existed before this version still uses them.
