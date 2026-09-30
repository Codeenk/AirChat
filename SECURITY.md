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
  - `group_memberships` uses a sliding 30-day expiry; published key material
    (`key_packages`) uses the same TTL and is replaced, never accumulated.
- Crypto primitives: X25519, ChaCha20-Poly1305, Ed25519 only. No custom crypto.
  - This covers protocol constructions too, not just primitives: no hand-rolled
    ratchets, key schedules or group key agreement. Group key agreement is
    delegated to **OpenMLS** via the `openmls` package (RFC 9420), pinned to
    ciphersuite `0x0003` — `mls128DhkemX25519Chacha20Poly1305Sha256Ed25519`,
    exactly the primitives listed above. See `SECURITY_GROUP_CRYPTO.md` §7.
  - 1:1 forward secrecy is delegated to **libsignal** via the `libsignal`
    package — the Signal Protocol's X3DH/PQXDH handshake and double ratchet,
    from the same upstream Rust implementation the audited messengers use. It
    imports the app's existing X25519 identity key as the Signal identity, so
    the safety number a user compares is the key that authenticates the
    ratchet. See `SECURITY_DESIGN.md` §3.1.
  - Any new third-party crypto must be named here, with the exact configuration
    pinned in code, before it is wired into a message path.
- Never commit secrets (`FCM_SERVICE_ACCOUNT_JSON`, keystores, tokens).
