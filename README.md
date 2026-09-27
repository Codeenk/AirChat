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
| 🔐 **True E2EE** | Content is encrypted on-device before it leaves. 1:1 chats use a fresh ephemeral key per message — forward secrecy by design. The server only ever sees ciphertext. |
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

- **1:1 messages**: X25519 ECDH with a fresh ephemeral sender key **per message**, ChaCha20-Poly1305 AEAD — forward secrecy by design.
- **Group messages**: one 32-byte symmetric key shared by all members (ChaCha20-Poly1305), distributed pairwise over the 1:1 channel and rotated whenever membership changes. Senders are individually authenticated with Ed25519, so the relay or a member cannot forge another member's message. This gives *key rotation on membership change* — it is **not** per-message forward secrecy or post-compromise security. A current member's key decrypts every message sent under that key. See [SECURITY_GROUP_CRYPTO.md](SECURITY_GROUP_CRYPTO.md).
- **Storage**: SQLCipher-encrypted local database; key material in platform secure storage (Keystore / Keychain).
- **Server**: sees uid, ciphertext blobs, public identity keys, and the group-membership records it needs for routing. It never sees a group key or any message plaintext. Registration and message signatures use Ed25519.
- **Media**: encrypted client-side before upload; decryption keys travel only inside E2EE messages.

⚠️ **Status**: AirChat is under active development. The crypto design follows well-reviewed primitives, but the implementation has **not yet undergone an independent security audit**. Treat it accordingly, and read [SECURITY_THREAT_MODEL.md](SECURITY_THREAT_MODEL.md) for what this app explicitly does *not* protect against.

## Roadmap

Shipped:

- [x] Per-message Ed25519 signing (sender authentication) — 1:1 and group messages are signed over `packetId|text|chatId` and verified on receipt, so a hostile relay cannot synthesize a message "from" a contact.
- [x] Voice notes — record, encrypt, send, play.

Open:

- [ ] Group chats on an MLS-style ratchet (RFC 9420). Today's groups use a rotated shared key; the migration design note lives in [SECURITY_GROUP_CRYPTO.md](SECURITY_GROUP_CRYPTO.md).
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
