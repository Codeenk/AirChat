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

AirChat is a **privacy-first messenger** where the server is designed to *know nothing*. Every message is encrypted on your device with **X25519 ephemeral key exchange + ChaCha20-Poly1305** before it ever touches the network. The relay can't read, store long-term, or profile anything you do.

| | |
|---|---|
| 🔐 **True E2EE** | Per-message ephemeral keys — forward secrecy by design. The server only ever sees ciphertext `{ct, n, epk}`. |
| 👻 **Ephemeral relay** | Offline messages queue in a Durable Object and self-destruct after 24 hours via alarms. Nothing persists. |
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

Every push runs the full pipeline:

| Workflow | Trigger | What it does |
|---|---|---|
| `android-build.yml` | push / PR / tag | Analyze → Test → Build release APK → Upload artifact → attach to GitHub Releases on tags |

Download the latest dev build from **Actions → Android CI → artifacts**, or stable builds from **Releases**.

## Security Model

- **Encryption**: X25519 ECDH with per-message ephemeral sender keys, ChaCha20-Poly1305 AEAD.
- **Storage**: SQLCipher-encrypted local database; key material in platform secure storage (Keystore / Keychain).
- **Server**: sees only uid hashes of activity, ciphertext blobs, and public identity keys. Registration signatures use Ed25519.
- **Media**: AES-encrypted before upload; decryption keys travel only inside E2EE messages.

⚠️ **Status**: AirChat is under active development. The crypto design follows well-reviewed primitives, but the implementation has **not yet undergone an independent security audit**. Treat it accordingly.

## Roadmap

- [ ] Per-message Ed25519 signing (sender authentication)
- [ ] Voice notes & calls
- [ ] Group chats (MLS-style)
- [ ] iOS App Store release
- [ ] Independent security audit

## Contributing

Contributions are welcome! Read [CONTRIBUTING.md](CONTRIBUTING.md) to get started, and please note our [Code of Conduct](CODE_OF_CONDUCT.md). Good first issues are labeled `good first issue`.

## License

Released under the [MIT License](LICENSE).

---

<div align="center">
<sub>Built with Flutter · Cloudflare Workers · Durable Objects · D1 · KV · FCM</sub>
</div>
