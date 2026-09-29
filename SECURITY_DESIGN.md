# AirChat — Security Design

This document explains how AirChat is built to satisfy the threat model in
`SECURITY_THREAT_MODEL.md`. It is intentionally concrete so that reviewers and
future maintainers can reason about trust boundaries, secrets, and leakage
paths.

## 1. High-level architecture

AirChat is split into two main parts:

- **Client:** Android Flutter app
- **Relay:** Cloudflare Workers + Durable Objects + D1 + KV + FCM

The guiding idea is simple: the server/relay should know as little as
possible, should keep it only as long as necessary, and should never hold
decryptable content or the keys needed to decrypt it.

## 2. Identity

Each device generates its own cryptographic identity locally on first launch.

- Identity is anchored to a locally generated key pair, not to a phone number
  or email.
- A stable local uid is derived for the device/account.
- A human-readable username can be set later and is stored locally and
  registered with the directory.

The security value here is:
- no central account password to leak or phish in the same way as a traditional
  account system
- identity material originates on the device

The tradeoff is:
- device loss or compromise can affect that identity's security on that device
- recovery/transfer is a device-secrets problem, not a password-reset problem

## 3. Cryptography

### 3.1 Messaging encryption
AirChat uses modern, well-known primitives:

- X25519 for key agreement
- ChaCha20-Poly1305 for authenticated encryption
- A fresh ephemeral X25519 key per 1:1 message

The message payload is encrypted client-side before it is sent through the
relay. The relay only sees opaque ciphertext and the metadata needed for
routing/delivery.

**What the per-message ephemeral key does and does not give.** Each 1:1 message
derives its own key from a newly generated ephemeral private key and the
recipient's long-term public key. A captured or weak ephemeral secret therefore
unlocks that one message and nothing else.

It is **not** forward secrecy in the Double-Ratchet sense, and must not be
described as such. The recipient decrypts with its long-term identity key, and
no ratchet ever advances that key. An attacker who obtains a recipient's
long-term private key once can therefore decrypt **every message ever sent to
it** — past and future — since the sender's ephemeral public key travels
alongside each ciphertext. There is likewise no post-compromise security:
compromising that key does not heal, and nothing rotates it automatically.

Reaching the standard guarantee requires replacing this with a ratchet
(X3DH + Double Ratchet), which is tracked as open work. Until it lands, the
accurate claim for 1:1 is **per-message key freshness**, not forward secrecy.

### 3.2 Sender authentication
Sender authenticity is handled with Ed25519 signatures where the design calls
for it. Signing is used to strengthen trust in:
- identity registration
- relay authentication challenges
- message attribution
- group control operations

The intent is that a relay or network observer should not be able to easily
impersonate a contact or inject authenticated actions.

### 3.3 Group cryptography
Groups use a shared symmetric key for members. That key is distributed through
encrypted channels to members and rotated when membership changes.

Honest properties of this design — full detail in `SECURITY_GROUP_CRYPTO.md`:

- It provides confidentiality against the relay and non-members, per-sender
  authenticity (Ed25519 signatures over `packetId|text|chatId`), and revocation
  once the key is rotated after a removal.
- It does **not** provide per-message forward secrecy or post-compromise
  security. Every message under one group key is protected by that same key.
  (The 1:1 path is stronger but not equivalent either — see §3.1 for why its
  per-message ephemeral key is key freshness rather than full forward secrecy.)
- Group secrecy depends on the group key remaining confined to current members.
- Membership changes must be handled carefully so removed members do not retain
  access and new members do not automatically learn unrelated history.
- Group control actions should be authenticated where possible.

Replacing the shared key with an MLS (RFC 9420) ratchet is the planned
migration; the blockers and their dependency order are recorded in
`SECURITY_GROUP_CRYPTO.md` §6.

The MLS group operations now exist in code (`lib/core/crypto/mls_group_service.dart`
on Openmls), with the ciphersuite pinned to X25519 + ChaCha20-Poly1305 +
Ed25519 and past-epoch secrets disabled, and they are tested against the real
Rust implementation — including that a removed member can no longer decrypt and
that a member who joins later cannot read earlier traffic (`SECURITY_GROUP_CRYPTO.md` §7).
**No group in the app uses it yet**: KeyPackage exchange and Welcome delivery are
not wired, and no group has a `cryptoVersion` of 2. Every existing group keeps
its shared key and behaves exactly as before. Until the transport lands and
groups actually run on MLS, group secrecy must not be described as equivalent to
1:1 secrecy.

### 3.4 Key verification (safety numbers)

Encryption alone cannot tell a user *whose* keys they are encrypting to. Peer
keys are fetched from the relay's directory, so a malicious or compromised relay
can answer a lookup with its own keys and then sit in the middle of the
conversation — decrypt, read, re-encrypt, forward. Neither endpoint can detect
that from the ciphertext, because the attacker is the one who supplied the keys.

AirChat addresses this with a safety number: a 60-digit code derived from
**both** parties' identity and signing keys (`SafetyNumberCalculator`). If two
devices show the same digits, the keys on both sides are the ones the users
compared, and no substitute key can be in play. It is compared out of band — read
aloud, copied, or by scanning the other device's QR code, which carries their
keys and is therefore an independent source of truth about them.

What makes it meaningful:

- It is **symmetric**: both parties derive the same number from the same keys, so
  either can read it while the other checks.
- It covers the **Ed25519 signing key as well as the X25519 identity key**, so a
  matching code also rules out a substituted signing key.
- The two parties are ordered deterministically by uid and **every field in the
  hashed transcript is length-prefixed**, so bytes cannot be shifted across a
  field boundary to forge a match.
- Verification **records the keys as they were at the moment of comparison**. If
  either key later changes, the chat shows a "security code changed" warning
  instead of a stale green check. A change is surfaced, never silently absorbed.

Verification is per contact and entirely local. No server involvement: the relay
learns nothing about whether a code was ever compared, and cannot revoke or fake
a verification.

Limits worth stating: this only works if the user actually compares the code.
An unverified contact is protected against the relay reading ciphertext, but not
against the relay substituting keys. To keep that visible rather than hidden,
unverified contacts are labelled as such in the chat.

## 4. Server / relay design

### 4.1 Ephemeral storage
The relay stores only what is needed for delivery and only transiently:
- offline message queue with expiration
- ephemeral encrypted media blobs with expiration
- routing state needed to wake offline members

This reduces the value of:
- a relay compromise
- a server-side data leak
- long-term server retention

### 4.2 Directory
The directory supports identity lookup so peers can reach each other. It should
return only the fields needed for messaging and not gratuitous sensitive data.

### 4.3 Push integration
Push is used to wake the device, not to carry decryptable content.

- push payloads should be opaque
- notification content should be built locally when shown
- rich local notifications should be treated as a leakage surface, not as a
  free pass to expose message content

## 5. Client-side secret handling

### 5.1 Keys and secrets
Sensitive key material should be kept in platform-protected storage where
possible and should not be written to logs or ordinary app files.

The app should minimize:
- how long keys are materialized in memory
- where key material can be found on disk
- accidental duplication of secrets into caches, previews, exports, or logs

### 5.2 Local database
The local database is encrypted. This helps against casual file-level exposure,
but it is still part of the device trust environment. If an attacker has full
access to an unlocked device and the app has materialized keys, encryption alone
is not a magic shield.

The real goal is:
- reduce offline file exposure
- reduce blast radius if a file is obtained without the keys
- avoid putting plaintext where it can be scraped later

### 5.3 Memory and caches
Decrypted content should be held only as long as needed.

In practice:
- decrypted messages should be rendered and then released as soon as reasonably
  possible
- decrypted media should not linger unnecessarily
- caches should be bounded and treated as sensitive

## 6. Notification and wake design

Notifications are one of the biggest practical leakage points on Android.

The app should treat notifications as:
- a delivery signal, not a content dump
- something that can be seen on an unlocked device, by recent-app switchers,
  by other apps with permissions, and by the OS notification surface

Good security behavior here means:
- no decryptable content in push payloads
- no plaintext message content where it can be avoided in notifications
- minimal, careful notification rendering
- avoiding notification previews that would matter on an unlocked phone

**As implemented today.** The push path is clean: wake payloads carry only a
signal and opaque ids (`groupId` is a random `grp_*`), and names and text are
resolved locally, so the push provider sees no content and no social graph.

The *local* notification, however, renders the decrypted text. That text is
visible on the lock screen unless the user restricts notification previews in
Android settings. Per-chat preview suppression and an in-app lock were
considered and deliberately left to the OS for now. This is therefore a known
practical leak, not a solved one, and it is the main reason "content is private
unless the phone is unlocked" is not yet true in the everyday sense.

## 7. Background services and permissions

Background services and extra permissions expand the attack surface.

The app should only use them when they clearly serve the core messaging
reliability or security story, and should avoid using them as a convenience
trash can.

Examples of the kind of thinking this requires:
- if a foreground service exists, why is it needed and what does it protect?
- if a permission exists, what exactly uses it and what happens if it is denied?
- if a dependency talks to the network, why and what does it send?

## 8. Attack-surface discipline

Security is not only about cryptography. It is also about:
- how much code can parse untrusted input
- how much code can make network calls
- how many plugins and dependencies are in the build
- how many background paths can activate silently
- how much debugging, logging, and diagnostic plumbing exists

The app should be conservative here. Every extra moving part is a candidate for
bugs, misuse, or accidental leakage.

## 9. What the app cannot solve

Even with good design, some risks live outside the app:

- an unlocked device being used by someone else
- malware with broad Android permissions
- forensic access while the device is unlocked and keys are materialized
- user actions like screenshots, forwards, backups, and copy/paste into other
  apps
- weak lock screen or poor device hygiene

These limits are not flaws in the design document; they are the reality of
building a secret messenger that runs on a general-purpose device.

## 10. Verification and release posture

Before any security-sensitive release:
- the code should be analyzable and formatted
- existing tests should pass
- the release build should be reproducible from CI
- release artifacts should be checksummed
- security claims should match the actual implementation

This project should not market itself as magically unhackable. It should market
itself as a carefully designed Android-first secret messenger with strong
remote secrecy and a real attempt to minimize in-device leakage, plus honest
language about device-side limits.
