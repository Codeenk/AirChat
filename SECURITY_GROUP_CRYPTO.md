# AirChat — Group Cryptography: current design, limits, and the MLS path

This document exists because of the project's own rule in
`SECURITY_THREAT_MODEL.md` §5.9: **"Security claims must match the threat model.
Overclaiming is a defect."** Group messaging is the one place where AirChat's
claims are currently weaker than a reader would assume, so it is written down
here explicitly instead of being left implied.

## 1. What group messaging does today

Implemented in `lib/core/crypto/sodium_engine.dart` (`encryptGroupMessage` /
`decryptGroupMessage`) and `lib/state/group_provider.dart`.

- A group has **one 32-byte symmetric key**, generated randomly when the group
  is created (`_generateGroupKey`).
- That key is delivered to each member **inside a normal 1:1 E2EE message**
  (`group_invite` / `group_add`), so the relay never sees it.
- Every group message is encrypted with `ChaCha20-Poly1305` under that shared
  key, with a fresh random 12-byte nonce. The ciphertext envelope is `{ct, n}`
  — there is no `epk`, because there is no per-message key agreement.
- Each message additionally carries an **Ed25519 signature** over
  `packetId|text|chatId` from the sender's identity key. Receivers verify it, so
  the relay (or another member) cannot forge a message "from" someone else.
- On a **kick or a voluntary leave**, survivors rotate the key: exactly one
  rotator is elected (the surviving member with the lexicographically smallest
  uid), generates a new key, and re-broadcasts it as a `group_add`. The
  `rekey` bus event drives this, and the rotation runs even with no chat screen
  open.

## 2. What that actually gives you

- The **relay cannot read** group content or recover the group key.
- **Sender authenticity**: a forged group message is rejected.
- **Removal revocation**: once the key is rotated, a removed member's copy no
  longer decrypts new messages.
- **Confidentiality against non-members** who never held the key.

## 3. What it does **not** give you

This is the honest part.

- **No per-message forward secrecy for groups.** Unlike 1:1 chats (which use a
  fresh ephemeral X25519 key per message), every group message under a given
  key is encrypted with *that same key*. Anyone who obtains the current group
  key decrypts **every earlier message still in the local history** that was
  sent under it, not just messages from that point on.
- **No post-compromise security.** There is no Diffie-Hellman ratchet. Once a
  member's device is compromised, the attacker can read group traffic until the
  key is rotated — and rotation only happens on a *membership change*, which may
  never occur.
- **Any current member can read all group history** encrypted under the live
  key, including messages sent before they joined if they are given the same
  key. New members do not automatically receive old ciphertext, but nothing in
  the design *prevents* a member from re-sharing the key with a third party.
- **Group metadata is not hidden from the relay.** See §5 below.

For 1:1 messaging, none of this applies — those chats derive a fresh key per
message.

## 4. Why this was not "just fixed" in v1.6.5

Two hard constraints, both of which are the project's own rules:

1. **`SECURITY.md` says: "Crypto primitives: X25519, ChaCha20-Poly1305, Ed25519
   only. No custom crypto."** A hand-rolled "ratchet" — deriving a message key
   from the group key with a home-made chain — would be exactly the custom,
   unvetted construction that rule forbids. A made-up ratchet is not obviously
   stronger than a shared key, and it would give a false sense of assurance.
2. **Any change to group encryption breaks interoperability with already
   released clients.** There is no in-band negotiation today, so the moment a
   new client encrypts with a derived key, every v1.6.0-and-earlier client in
   that group fails to decrypt. That is a user-visible break, not a refactor.

Doing either of those "quickly" would have made the code *look* more secure
while making it actually less trustworthy. So v1.6.5 corrects the
**documentation** and this file records the real migration.

## 5. Related finding: group metadata retained by the relay

While reviewing this, a separate issue surfaced in the backend worker that is
worth recording here because it is also a group-secrecy question.

`backend-worker/src/db/schema.sql` defines a **permanent** D1 table:

```sql
CREATE TABLE IF NOT EXISTS group_memberships (
    group_id     TEXT NOT NULL,
    member_uid   TEXT NOT NULL,
    group_name   TEXT NOT NULL DEFAULT '',
    created_at   INTEGER NOT NULL,
    PRIMARY KEY (group_id, member_uid)
);
```

There is **no TTL and no delete path** — records are written with
`INSERT OR REPLACE` and only ever read back. Two problems:

- It is a **persistent group membership graph** (who is in which group),
  which `SECURITY.md` ("All stored data must have TTLs — no permanent
  server-side records") and `SECURITY_DESIGN.md` §4.1 both say should not
  exist.
- `group_name` is stored **in plaintext**. Every read in the worker
  (`ConnectionRelay.ts`) selects only `member_uid` or `group_id` — **`group_name`
  is written but never read**, so it is gratuitous retention of sensitive
  metadata.

Recommended remediation (not done here — it requires a worker deploy, which is
a production change outside this release):

1. Stop writing `group_name` (drop it from the schema and both insert sites).
2. Give membership rows an expiry, or treat membership as transient routing
   state rather than a durable table.

## 6. Migration plan: MLS (RFC 9420)

**Target:** replace the shared group key with an MLS group so groups get the
same per-message forward secrecy and post-compromise security that 1:1 chats
already have.

**Implementation, not invention.** Use a vetted MLS implementation rather than
writing one. `openmls` (pub.dev) is a Dart binding to **OpenMLS**, the Rust
implementation of RFC 9420 — which satisfies the "no custom crypto" rule in a
way a hand-rolled ratchet cannot.

The work is a protocol project, not a patch. Real blockers, in dependency
order:

1. **Ordering.** MLS advances by *Commits* that must be applied in a consistent
   order per epoch. The relay today is a best-effort tunnel with no global
   ordering (relay packets can arrive out of order, and `group_packet` fan-out
   is unordered). This needs an epoch/generation discipline on the client plus
   idempotent commit delivery before any of the rest is meaningful.
2. **Key packages.** Each device must publish an MLS KeyPackage through the
   directory (replacing the current `signed_prekey` role), and joins need
   Welcome messages. That is a relay + directory change.
3. **State storage.** MLS group state (ratchet tree, epoch secrets) must be
   persisted in the SQLCipher database, replacing `groups.groupKey`.
4. **Lifecycle mapping.** `group_invite` / `group_add` / `group_kick` become
   Add / Remove commits; `rotateGroupKey` disappears because the ratchet
   replaces it.
5. **Migrating existing groups.** A shared key cannot be converted into an MLS
   epoch. Either groups are recreated (user-visible), or a `cryptoVersion` is
   added to group state and groups migrate lazily on their next membership
   change. Lazy migration is the better UX but means operating both paths for a
   while.
6. **Interop / version gating.** Add `cryptoVersion` to group state and control
   messages, detect older clients, and never send MLS commits to a member that
   has not advertised support. Without this step the rollout breaks groups.
7. **Verification.** Cross-client interop tests, epoch-divergence and
   out-of-order-commit tests — and, per `SECURITY_THREAT_MODEL.md`, an external
   audit before group secrecy is claimed at the same level as 1:1.

Until steps 1–7 are done, the accurate statement is the one in README.md:
groups use a rotated shared key, and 1:1 secrecy is stronger than group secrecy.
