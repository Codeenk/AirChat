# AirChat — Threat Model & Security Scope

This document defines what AirChat is trying to protect, for whom, and what it
does **not** claim to defeat. It is the source of truth for security-related
decisions in this repo. If a feature, patch, or marketing claim conflicts with
this document, this document wins.

## 1. Intended users

- Android users who want private 1:1 and group messaging.
- Threat focus: conversation content should remain secret from:
  - the relay/server operator
  - passive network observers
  - future adversaries who capture today's traffic or server storage
  - accidental leakage through notifications, push, clipboard, screenshots,
    cache, logs, or backups

AirChat is **not** designed as a universal anti-surveillance product for every
possible adversary. It is designed as a strong Android-first secret messenger
with a small trusted surface and honest limits.

## 2. What we aim to make infeasible

### 2.1 Server / relay secrecy
- The relay should not be able to read message content.
- The relay should store as little as possible, and only transiently.
- Ephemeral message and media storage should expire and be removed.
- Directory/lookup APIs should return only what is required for messaging.

### 2.2 Transport / network secrecy
- Message content should be encrypted before it leaves the device.
- 1:1 messages should use fresh key material, and the guarantee should be
  stated per chat rather than averaged. A chat created on v1.8+ between two
  peers that publish a prekey bundle runs the Signal Protocol's double ratchet,
  which *is* forward secrecy against long-term key compromise and heals after a
  compromise. A chat created before that still uses per-message ephemeral keys
  against a long-term recipient key, which is key freshness and **not** forward
  secrecy. See `SECURITY_DESIGN.md` §3.1.
- Authentication should be used so a relay or network adversary cannot easily
  inject or impersonate traffic.

### 2.3 Future capture resistance
- Captured traffic should not be trivially useful later if the design's forward
  secrecy and key-rotation properties hold.
- Compromise of some keys should not automatically expose everything, within
  the bounds of the chosen cryptographic model.

### 2.4 Accidental leakage reduction
The app should actively reduce common practical leaks:
- notification and push content
- clipboard remnants
- screenshot / recent-app / overview exposure where Android allows app-level
  influence
- decrypted media and plaintext lingering in memory or cache
- debug/log paths that might reveal sensitive material
- locally stored artifacts that could be extracted later by an attacker with
  access to the device filesystem

### 2.5 Key substitution by the relay

Because the relay is also the directory, it is the party that tells each device
which keys belong to a contact. A curious or compromised relay could answer with
its own keys and read everything in the middle. Encryption cannot detect this on
its own — the attacker supplied the keys.

AirChat mitigates it with safety numbers (`SECURITY_DESIGN.md` §3.4): a 60-digit
code over both parties' identity and signing keys, compared out of band, and
recorded locally so a later key change raises a visible warning instead of a
stale verification badge.

The honest bound: this defends against the relay only for contacts the user has
actually verified. For an unverified contact the relay remains able to substitute
keys, and the app says so rather than implying otherwise.

## 3. Threats this app does **not** defeat on its own

Being honest here is part of the security design.

### 3.1 The unlocked device is already a trusted environment
If the phone is unlocked and the app is open, an attacker with physical or
software access to that device may be able to see:
- the screen contents
- notifications
- clipboard contents
- accessible files or media
- in-memory content while the app is active

This is **spying on an unlocked device**, not necessarily "hacking the app."
No messenger app can fully prevent this by itself.

### 3.2 Malware and overly broad permissions
If the device is compromised, or if other installed apps have broad Android
permissions, the app cannot guarantee secrecy by itself.

### 3.3 Coercion, weak device hygiene, and user mistakes
- weak lock screen
- leaving the phone unlocked and unattended
- screenshots, forwards, backups, or pasting content into other apps
- installing questionable software

These can undermine even a well-designed messenger.

### 3.4 Metadata and operational patterns
Some metadata and behavioral patterns may still exist:
- timing of connections
- that communication happened at all
- notification delivery pathways
- contact discovery and routing needs

AirChat reduces some of these by design, but it does not claim total metadata
invisibility.

What is reduced, concretely, for **new 1:1 conversations between devices on a
current build**: the relay routes them between opaque *delivery tags* rather
than uids, its stored packets hold no sender, its acks name only a packet, its
wake payloads are empty, and it holds no table joining a tag to a person. See
`SECURITY_SEALED_SENDER.md`.

What is **not** reduced, and must not be claimed away:
- a live relay (or network observer) can still correlate two connections by IP
  address and timing; sealing removes the stored, logged, and third-party-visible
  graph, not the ability to infer a live one
- message *timing* and *size* remain observable at submission
- groups and 1:1 conversations with an older build still run the named
  transport, and a group roster is still visible to the relay
- a sealed first message from someone not already in our contacts cannot be
  attributed (`SECURITY_SEALED_SENDER.md` §7.6)

## 4. Trust boundaries

### 4.1 Device
The device is the main trust root for this app. Keys, identity, database
encryption material, and local secrets live here.

### 4.2 Platform secure storage
Platform-protected storage is used for sensitive key material where possible.
This is stronger than ordinary app files, but still part of the device trust
environment.

### 4.3 Local database
The local database is encrypted. Its security depends on the device, the
encryption key material, and the app's handling of that key material.

### 4.4 Relay
The relay is treated as potentially curious and potentially compromised. It
should only ever see opaque ciphertext/metadata needed for delivery, and only
retain it transiently.

The sealed-sender design is what makes "opaque" concrete rather than aspirational
for 1:1 traffic: the relay is assumed to be *reading its own database and logs*,
so the sender's identity is never written to either. It is still trusted for
availability — it can drop, delay, or reorder sealed traffic, and no design
without an anonymity layer can stop that.

### 4.5 Push / notification path
Push delivery is treated as an untrusted transport for content. Notifications
and wake payloads should not carry decryptable content.

## 5. Design rules

Any change to crypto, networking, notifications, storage, background services,
or permissions must satisfy these rules:

1. Content must not be exposed to the server or push path in decryptable form.
2. Sender authenticity and message binding must be treated seriously, not as
   optional cosmetics.
3. Forward secrecy and key freshness should be preserved for the paths that
   rely on them.
4. Group key material is high-value and must be handled with extra care. In an
   MLS group there is no shared key to guard: the epoch secret is what must not
   be duplicated, retained past its epoch, or left behind after this device
   leaves or is removed. `maxPastEpochs: 0` and `numberOfResumptionPsks: 0`
   enforce the retention half of that.
5. Decrypted plaintext and media should live only as long as needed.
6. Logs, debug surfaces, clipboard, and export paths must not silently leak
   sensitive content.
7. No hidden network calls, analytics, or outbound telemetry unless the user
   explicitly chooses to export something.
8. New permissions, background services, or dependencies must earn their place.
9. Security claims must match the threat model. Overclaiming is a defect.

## 6. Honest security positioning

AirChat can be a very strong Android-first secret messenger for its intended
users. It can make remote/server/network reading of content infeasible under
its design assumptions and reduce in-device leakage as much as Android allows.

It cannot make an unlocked phone immune to spying, and it does not claim to.

For the intended use case, the realistic goal is:

- strong remote secrecy
- minimal in-device leakage
- small trusted surface
- verifiable, auditable design
- honest documentation

That is the standard this project should be judged against.
