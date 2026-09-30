-- key_packages: published, expiring key material for asynchronous session
-- setup.
--
-- Why the relay stores this at all: both MLS and the Signal Protocol need the
-- *initiator* to have a public blob from the recipient before the first
-- message can be sent (an MLS KeyPackage; a libsignal PreKeyBundle). Both
-- users cannot be assumed online at the same time, so it has to be fetched.
--
-- Why it is shaped this way:
--   * `payload` is opaque and stored verbatim. It is public key material the
--     owner chose to publish, and the relay never parses it — so the relay
--     learns nothing about who is talking to whom, only that uid X has
--     published something of kind K.
--   * `expires_at` gives every row a TTL (SECURITY.md: "All stored data must
--     have TTLs — no permanent server-side records"). A device republishes on
--     every launch, so a live device never lapses while an abandoned one is
--     dropped instead of being pre-keyed forever.
--   * The primary key is (uid, kind), so a republish replaces rather than
--     accumulates — there is no history to retain.
CREATE TABLE IF NOT EXISTS key_packages (
    uid        TEXT NOT NULL,
    kind       TEXT NOT NULL,
    payload    TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (uid, kind)
);

CREATE INDEX IF NOT EXISTS idx_key_packages_expiry ON key_packages(expires_at);
