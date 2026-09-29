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
  - This covers protocol constructions too, not just primitives: no hand-rolled
    ratchets, key schedules or group key agreement. Group key agreement is
    delegated to **OpenMLS** via the `openmls` package (RFC 9420), pinned to
    ciphersuite `0x0003` — `mls128DhkemX25519Chacha20Poly1305Sha256Ed25519`,
    exactly the primitives listed above. See `SECURITY_GROUP_CRYPTO.md` §7.
  - Any new third-party crypto must be named here, with the exact configuration
    pinned in code, before it is wired into a message path.
- Never commit secrets (`FCM_SERVICE_ACCOUNT_JSON`, keystores, tokens).
