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
- Ephemeral key material per message where forward secrecy is intended

The message payload is encrypted client-side before it is sent through the
relay. The relay only sees opaque ciphertext and the metadata needed for
routing/delivery.

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

Important security property:
- group secrecy depends on the group key remaining confined to current members
- membership changes must be handled carefully so removed members do not retain
  access and new members do not automatically learn unrelated history
- group control actions should be authenticated where possible

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
