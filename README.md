<div align="center">

# ✈️ AirChat

### *Zero-Knowledge Ephemeral Messaging*

**End-to-end encrypted chats that leave no trace. No phone numbers. No accounts. Just a QR code.**

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Cloudflare Workers](https://img.shields.io/badge/Cloudflare-Workers-F38020?logo=cloudflare&logoColor=white)](https://workers.cloudflare.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Android CI](https://github.com/Codeenk/AirChat/actions/workflows/android-build.yml/badge.svg)](../../actions)

</div>

---

## What is AirChat?

AirChat is a **privacy-first messenger** where the server is designed to *know nothing*. Every message is encrypted on your device with **X25519 ephemeral key exchange + ChaCha20-Poly1305** before it ever touches the network. The relay cannot read your messages, and keeps no long-term copy of message content. It does retain the minimal identity directory and group-membership records it needs to route — see [SECURITY_THREAT_MODEL.md](SECURITY_THREAT_MODEL.md) for what that does and does not reveal.

| | |
|---|---|
| 🔐 **True E2EE** | Content is encrypted on-device before it leaves. 1:1 chats created on v1.8+ run the Signal Protocol's double ratchet, and new groups run MLS (RFC 9420) — real forward secrecy, not just key freshness. The server only ever sees ciphertext. |
| 👻 **Ephemeral relay** | Offline messages queue in a Durable Object and self-destruct after 24 hours via alarms — message content never persists. The relay does keep a minimal identity directory and group-membership records for routing. |
| 📇 **Identity = QR code** | No emails or phone numbers. Scan a peer's QR to exchange keys and start chatting instantly. |
| 🏷️ **Human usernames** | Set a display name — it rides along in your QR and appears to anyone you message for the first time. |
| 🔔 **Reliable notifications** | FCM wake-up pushes + local notifications deliver messages even when the app is closed. |
| 🖼️ **Encrypted media** | Images & files are chunked, encrypted client-side, stored as opaque blobs with 24h TTL. |

## Architecture

```
┌──────────────────┐   WebSocket tunnel   ┌─────────────────────────┐
│  Flutter app     │◄────────────────────►│  Cloudflare Worker      │
│  (Android/iOS/   │                      │  ├─ ConnectionRelay DO  │
│   Web/Desktop)   │   FCM data push      │  │   • live WS routing  │
│                  │◄─────────────────────│  │   • 24h offline queue│
│  • X25519+ChaCha │   REST (register,    │  └─ D1 identity directory│
│  • SQLCipher DB  │    lookup, media)    │  └─ KV encrypted media   │
│  • Secure store  │                      │     (24h TTL)            │
└──────────────────┘                      └─────────────────────────┘
```

**Monorepo layout:**

```
AirChat/
├── frontend-flutter/    # Flutter client (Android · iOS · Web)
├── backend-worker/      # Cloudflare Worker + Durable Object relay (TypeScript)
└── .github/workflows/   # CI/CD pipelines
```

## Quick Start

### Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) ≥ 3.x (`flutter doctor`)
- [Node.js](https://nodejs.org) ≥ 18 + `npm` (backend only)
- [Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/) (backend deploy)

### 1. Run the client

```bash
cd frontend-flutter
flutter pub get
flutter run                # pick a device/emulator
```

> The app auto-generates a fresh cryptographic identity on first launch — no signup needed.

### 2. Deploy the backend (optional — a public relay already exists)

```bash
cd backend-worker
npm install
npx wrangler login
npx wrangler d1 create airchat-identity        # note the id → wrangler.toml
npx wrangler deploy
```

Secrets required by the worker:

```bash
npx wrangler secret put FCM_PROJECT_ID
npx wrangler secret put FCM_SERVICE_ACCOUNT_JSON   # service-account JSON for FCM v1
```

### 3. Chat

1. Tap the QR icon → share your code (or copy it).
2. Peer scans it → contact added, keys exchanged.
3. Message. Everything after this point is invisible to the server.

## Building from source

```bash
# Android APK (release)
cd frontend-flutter && flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk

# Web
flutter build web
```

Or just push a tag — GitHub Actions builds signed artifacts automatically (see below).

## CI/CD

| Workflow | Trigger | What it does |
|---|---|---|
| `android-build.yml` | push / PR touching `frontend-flutter/**`, or manual | Format check → Analyze → Test → build the release APKs (split-per-abi, obfuscated) → upload them as a **build artifact** (dev build; publishes nothing) |
| `release.yml` | pushing a `v*` tag, or manual | Format check → Analyze → Test → verify the tag matches `pubspec.yaml` → require signing secrets → build **signed** release APKs → publish a GitHub Release with `SHA256SUMS.txt` and debug symbols |

Only `release.yml` creates a GitHub Release, and only for a signed build. To cut a release: bump `version:` in `frontend-flutter/pubspec.yaml`, then push a matching tag (for example `v1.6.5`). The tag's version must equal the pubspec version *before* its `+` build number.

Download the latest dev build from **Actions → Android CI → artifacts**, or published builds from **Releases**.

## Security Model

- **1:1 messages**: a chat created against a peer that publishes a libsignal prekey bundle runs **X3DH/PQXDH + the Double Ratchet** (`libsignal`), so a compromised key covers one message and the ratchet heals after a compromise. Chats created before that stay on X25519 ECDH with a fresh ephemeral sender key **per message** — key freshness, not forward secrecy against long-term key compromise. Which one a chat uses is recorded on the chat and never rewritten mid-conversation.
- **Group messages**: a group created when every invited member publishes an MLS KeyPackage is keyed by **MLS (RFC 9420)** via OpenMLS — the TreeKEM ratchet gives per-message forward secrecy, post-compromise security, and revocation that actually removes a removed member's ability to read. Groups created before MLS, or with any member that cannot take it, use one 32-byte symmetric key shared by all members (ChaCha20-Poly1305), distributed pairwise over the 1:1 channel and rotated whenever membership changes — *key rotation on membership change*, **not** per-message forward secrecy. Senders are individually authenticated with Ed25519 either way. See [SECURITY_GROUP_CRYPTO.md](SECURITY_GROUP_CRYPTO.md).
- **Storage**: SQLCipher-encrypted local database; key material in platform secure storage (Keystore / Keychain).
- **Server**: sees uid, ciphertext blobs, public identity keys, and the group-membership records it needs for routing. It never sees a group key or any message plaintext. Registration and message signatures use Ed25519.
- **Media**: encrypted client-side before upload; decryption keys travel only inside E2EE messages.

⚠️ **Status**: AirChat is under active development. The crypto design follows well-reviewed primitives, but the implementation has **not yet undergone an independent security audit**. Treat it accordingly, and read [SECURITY_THREAT_MODEL.md](SECURITY_THREAT_MODEL.md) for what this app explicitly does *not* protect against.

## Roadmap

Shipped:

- [x] Per-message Ed25519 signing (sender authentication) — 1:1 and group messages are signed over `packetId|text|chatId` and verified on receipt, so a hostile relay cannot synthesize a message "from" a contact.
- [x] Voice notes — record, encrypt, send, play.
- [x] Safety numbers — a 60-digit code derived from both parties' keys, compared in person or by QR, so a hostile relay cannot quietly substitute keys and read along. A verified contact whose keys later change raises a visible warning. See [SECURITY_DESIGN.md](SECURITY_DESIGN.md) §3.4.

Open:

- [x] A ratchet (X3DH + Double Ratchet) for 1:1 chats, via `libsignal`. **New chats only**: an existing chat keeps the scheme it used for its messages, so a peer on a released build never receives something it cannot read. [SECURITY_DESIGN.md](SECURITY_DESIGN.md) §3.1 states the exact per-chat guarantee.
- [x] Group chats on an MLS ratchet (RFC 9420), wired end to end: KeyPackages published and fetched through the relay, Welcome delivered over the 1:1 channel, commits on the group channel, and `cryptoVersion` gating so a group is only ever MLS when every member can read it. [SECURITY_GROUP_CRYPTO.md](SECURITY_GROUP_CRYPTO.md) §6–§8.
- [ ] Harden MLS against concurrent membership changes: the relay is unordered, so two simultaneous commits from different members are not yet reconciled (§6 step 7).
- [ ] Local hardening: app lock, lock-screen preview suppression, `FLAG_SECURE` — deferred, on the basis that the OS-level app lock covers it.
- [ ] Notification preview control. Message text is rendered locally and is visible on the lock screen unless previews are restricted in Android settings.
- [ ] Voice calls.
- [ ] iOS App Store release.
- [ ] Independent security audit.

## Contributing

Contributions are welcome! Read [CONTRIBUTING.md](CONTRIBUTING.md) to get started, and please note our [Code of Conduct](CODE_OF_CONDUCT.md). Good first issues are labeled `good first issue`.

## License

Released under the [MIT License](LICENSE).

---

<div align="center">
<sub>Built with Flutter · Cloudflare Workers · Durable Objects · D1 · KV · FCM</sub>
</div>
