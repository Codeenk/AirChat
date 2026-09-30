# AirChat v1.8.1

Maintenance release on top of v1.8.0.

## What this release is (and is not)

**This is a relay-side release. There is no user-visible change in the app.**

The Android artifacts here are functionally equivalent to v1.8.0 — the only
client change is the addition of an optional `deliveryTag` field to
`RatchetBundle`, which is inert: no client reads or sends it yet, and bundles
without it still decode exactly as before. The version bump exists so the
released artifact's version number is honest about what it contains.

## Relay changes now live in production

Worker version `175da1aa`, database migrations `0001`–`0003` applied.

1. **`group_name` is gone.** `group_memberships` was rebuilt without the
   plaintext group-name column, which no query ever read. Existing rows were
   preserved with a fresh 30-day window. This was the last permanent,
   plaintext, sensitive record in the database.
2. **TTLs everywhere.** `group_memberships` and `key_packages` now carry
   `expires_at` and every read filters on it, satisfying `SECURITY.md`'s "no
   permanent server-side records" rule. Expired rows are swept opportunistically
   rather than needing a scheduled job.
3. **New key-material endpoints** — `POST /api/keys/publish`,
   `GET /api/keys/lookup`, `POST /api/keys/revoke` — so two devices that are
   never online together can still start an MLS or libsignal session. Payloads
   are opaque to the relay; it stores and returns them without parsing them.
4. **Sealed sender, server side** (`SECURITY_SEALED_SENDER.md`). The relay can
   now deliver a message without learning who sent it: devices are addressed by
   opaque rotating tags, stored packets carry no sender field, acknowledgements
   name only the packet consumed, wakes carry nothing at all, and group
   membership is self-subscribed so no roster is ever uploaded. A mixing batch
   holds sealed traffic briefly and delivers it shuffled, so timing carries less
   signal.

**No client uses sealed sender yet**, so points 1–3 are live while point 4 is
dormant: every conversation still runs the legacy named transport, and the
relay still learns who talks to whom for all real traffic. Wiring the client is
the next release.

## Migration note

Migrations must be applied **before** the worker that reads the new schema is
deployed. The previous relay wrote `group_name` on group registration, so
applying `0001` first leaves a short window where group registration fails until
the deploy completes. This ordering is load-bearing — do not reverse it.

## Verification

- `flutter analyze` clean, `flutter test` 100 passing, `dart format` clean.
- Relay: `tsc --noEmit` clean, bundles at 88.79 KiB.
- Sealed path exercised against production over a real WebSocket: two tag-only
  sockets registered with no uid, sealed delivery landed inside the mixing
  window, the delivered payload contained no `senderUid`, an ack routed back to
  the sender's tag, and a third device was refused when it tried to consume
  another tag's queue. Legacy `?uid=` sockets still receive their auth challenge.

## Known gaps

Recorded in full in `SECURITY_SEALED_SENDER.md` §7. The headline one: a relay
that terminates both peers' connections can still correlate them by IP address
and timing. Sealed sender removes the relay's stored, logged and
third-party-visible graph; it does not defeat a live adversary actively
correlating.
