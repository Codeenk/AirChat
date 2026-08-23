# Contributing to AirChat

First off — thanks for wanting to make private messaging better! 🎉

This document covers everything you need to contribute effectively.

## Code of Conduct

By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md). Be excellent to each other.

## How Can I Contribute?

### 🐛 Reporting bugs

Open a [Bug Report](../../issues/new?template=bug_report.md) and include:

- Device / platform (Android version, or Web browser)
- Steps to reproduce (minimal is best)
- Expected vs actual behavior
- Logs if available (`flutter logs`, worker `wrangler tail` output)

**Never share private keys, QR payloads, or message content in issues.**

### 💡 Suggesting features

Open a [Feature Request](../../issues/new?template=feature_request.md). Explain the *problem* you're facing, not just the solution — privacy-preserving design often has multiple valid approaches.

### 🔀 Pull requests

1. **Fork & branch**: `git checkout -b feat/my-feature` from `main`.
2. **Follow the checklists below** before pushing.
3. Keep PRs focused — one feature/fix per PR.
4. Reference the issue: `Fixes #123`.
5. Ensure CI passes (analyze + tests + build).

#### Commit style — [Conventional Commits](https://www.conventionalcommits.org)

```
feat: add voice notes playback speed control
fix(worker): expire queued packets on DO alarm reset
docs: update backend deployment steps
refactor!: rename CryptoPayload fields (BREAKING CHANGE)
chore: bump flutter_local_notifications to 17.2.4
```

Types: `feat` · `fix` · `docs` · `style` · `refactor` · `perf` · `test` · `build` · `ci` · `chore`

## Developer Checklists

### ✅ Flutter client (`frontend-flutter/`)

- [ ] `flutter analyze` — zero errors (warnings should be explained or fixed)
- [ ] `flutter test` — all tests pass; add tests for new business logic
- [ ] No new dependencies without justification (crypto/privacy surface area matters)
- [ ] Secrets stay out of code — no keys, tokens, or Firebase configs hardcoded
- [ ] New UI works in dark theme (the app is dark-only) and respects the monochrome palette in `lib/core/theme/colors.dart`
- [ ] Anything touching crypto has a clear doc comment explaining the threat model

### ✅ Backend worker (`backend-worker/`)

- [ ] `npm run typecheck` passes
- [ ] Zero-knowledge principle preserved: **the server must never be able to read user content**
- [ ] New endpoints are stateless, rate-limit-friendly, and documented here or in code
- [ ] Data retention stays minimal — ephemeral by default, TTLs on everything
- [ ] Tested locally with `npm run dev` against a real client

### ✅ Security-sensitive changes

Anything affecting key handling, encryption, identity, or storage requires:

- [ ] Explicit threat-model notes in the PR description
- [ ] No weakening of forward secrecy guarantees
- [ ] Backwards-compatibility strategy for existing identities/chats
- [ ] Tag a maintainer for review — these PRs always need two approvals

## Project Structure

```
frontend-flutter/lib/
├── core/
│   ├── crypto/          # KeyStore, X25519 engine, QR payload codec
│   ├── database/        # SQLCipher DB + DAOs
│   ├── network/         # WS tunnel, REST client, FCM push, notifications
│   └── theme/           # Monochrome design system
├── models/              # Contact, ChatThread, Message payloads
├── state/               # Riverpod providers, MessageRouter
└── ui/screens|widgets/  # Screens & reusable widgets

backend-worker/src/
├── durable-objects/     # ConnectionRelay — WS mesh + offline queue
├── routes/              # /api/identity/* handlers
└── db/                  # D1 schema
```

## Local Development Tips

```bash
# Client with hot reload
cd frontend-flutter && flutter run --dart-define=RELAY_URL=http://localhost:8787

# Worker dev server
cd backend-worker && npm run dev
```

## Questions?

Open a [Discussion](../../discussions) or ping maintainers on an issue. Thanks for contributing! ✈️
