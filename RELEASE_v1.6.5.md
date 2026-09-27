# AirChat v1.6.5 — security documentation accuracy

This release contains **no cryptography, protocol, or wire-format changes**.
Existing clients, existing groups, and existing message history keep working
unchanged. It exists to make the project's security claims match what the code
actually does — the rule `SECURITY_THREAT_MODEL.md` §5.9 sets out: *"Security
claims must match the threat model. Overclaiming is a defect."*

## Corrected documentation drift

- **README roadmap was stale.** It listed *per-message Ed25519 signing* and
  *voice notes & calls* as not-yet-done, but message signing (1:1 and group,
  over `packetId|text|chatId`) and voice notes both shipped. The roadmap now
  separates shipped from open work and no longer marks real features as TODO.
- **README CI table credited the wrong workflow.** It said
  `android-build.yml` attaches builds to GitHub Releases on tags. It does not —
  it uploads a build artifact. `release.yml` is what verifies the tag against
  `pubspec.yaml`, requires signing secrets, builds the signed APKs, and
  publishes the release. Both workflows are now described accurately, including
  how to cut a release.
- **"Nothing persists" was too strong.** The relay keeps no long-term copy of
  *message content*, but it does retain a persistent identity directory and
  group-membership records used for routing. README now says that, instead of
  implying the relay stores nothing at all.

## Group secrecy stated honestly

- **New `SECURITY_GROUP_CRYPTO.md`.** Groups use one rotated shared symmetric
  key, not an MLS ratchet. The document states plainly what that gives
  (relay-blindness, sender authentication, revocation on removal) and what it
  does not (no per-message forward secrecy, no post-compromise security for
  groups — a current member's key decrypts every message sent under it).
- **`SECURITY_DESIGN.md` §3.3** now carries the same distinction instead of
  implying group secrecy is equivalent to 1:1.
- The document also records the **MLS (RFC 9420) migration plan** — target
  implementation (`openmls`), and the seven real blockers in dependency order
  (commit ordering, key packages, MLS state storage, lifecycle mapping,
  migrating existing groups, interop/version gating, verification).

## Why the group crypto was not rewritten here

Two constraints, both of them the project's own rules:

1. `SECURITY.md` forbids custom cryptography. A hand-rolled ratchet would be
   exactly the unvetted construction that rule prohibits — it would look more
   secure while being less trustworthy.
2. Any change to group encryption breaks interoperability with already-released
   clients, because there is no in-band negotiation today.

So this release corrects the record and creates the migration artefact rather
than faking a fix.

## Related finding (reported, not fixed here)

`backend-worker`'s D1 `group_memberships` table is permanent (no TTL, no delete
path), which conflicts with `SECURITY.md`'s "all stored data must have TTLs".
It also stores group names in plaintext even though **no query ever reads
`group_name`** — it is written and never used. Remediation requires a worker
deploy and is deliberately left for a separate, deployable change. Details and
the recommended fix are in `SECURITY_GROUP_CRYPTO.md` §5.
