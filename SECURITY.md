# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| main branch | ✅ active development |
| tagged releases | ✅ latest tag only |

## Reporting a Vulnerability

**Do NOT open a public issue for security vulnerabilities.**

Email **malandkar.sarvesh@gmail.com** with:

- Description of the vulnerability
- Steps / proof-of-concept to reproduce
- Affected components (client crypto, relay worker, storage, notifications)
- Your assessment of impact

You will receive an acknowledgment within 72 hours. We ask for up to 90 days
for coordinated disclosure before public release.

## Security Expectations for Contributors

- The relay must remain zero-knowledge: never add server-side features that
  require plaintext access to message content.
- All stored data must have TTLs — no permanent server-side records.
- Crypto primitives: X25519, ChaCha20-Poly1305, Ed25519 only. No custom crypto.
- Never commit secrets (`FCM_SERVICE_ACCOUNT_JSON`, keystores, tokens).
