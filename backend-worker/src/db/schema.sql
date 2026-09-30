-- Users table with Ed25519 identity verification support
CREATE TABLE IF NOT EXISTS users (
    uid TEXT PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    identity_public_key TEXT NOT NULL,
    signing_public_key TEXT NOT NULL DEFAULT '',
    signing_signature TEXT NOT NULL DEFAULT '',
    signed_prekey TEXT NOT NULL,
    prekey_signature TEXT NOT NULL,
    fcm_token TEXT,
    created_at INTEGER NOT NULL
);

-- Indexes for fast lookups
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_signing_key ON users(signing_public_key);

-- Migration: add signing columns if they don't exist (for existing databases)
-- Run these if upgrading from an older schema:
/*
ALTER TABLE users ADD COLUMN signing_public_key TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN signing_signature TEXT NOT NULL DEFAULT '';
*/

-- Group memberships: maps groupId to member UIDs for group inbox routing.
-- The relay uses this to know which FCM tokens to wake for group messages.
--
-- This is transient ROUTING state, not durable history:
--   * no group key — only the client knows it (E2EE)
--   * no group name — the relay routes packets, it does not label them, and
--     the client resolves names on-device from the E2EE payload
--   * `expires_at` gives every row a TTL (SECURITY.md: "All stored data must
--     have TTLs — no permanent server-side records"). Rows are refreshed on
--     register and on every group send, so active groups never lapse.
CREATE TABLE IF NOT EXISTS group_memberships (
    group_id TEXT NOT NULL,
    member_uid TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (group_id, member_uid)
);

CREATE INDEX IF NOT EXISTS idx_group_memberships_member ON group_memberships(member_uid);
CREATE INDEX IF NOT EXISTS idx_group_memberships_group ON group_memberships(group_id);
CREATE INDEX IF NOT EXISTS idx_group_memberships_expiry ON group_memberships(expires_at);

-- Published key material for asynchronous session setup: an RFC 9420 MLS
-- KeyPackage (`kind = 'mls'`) or a libsignal PreKeyBundle (`kind = 'signal'`).
--
-- `payload` is opaque to the relay: it is public key material the owner chose
-- to publish, stored verbatim and never parsed, so the relay learns nothing
-- about who talks to whom. `expires_at` gives every row a TTL (SECURITY.md:
-- "All stored data must have TTLs — no permanent server-side records") and a
-- republish replaces the row, so there is no history to retain.
CREATE TABLE IF NOT EXISTS key_packages (
    uid        TEXT NOT NULL,
    kind       TEXT NOT NULL,
    payload    TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (uid, kind)
);

CREATE INDEX IF NOT EXISTS idx_key_packages_expiry ON key_packages(expires_at);

-- Sealed sender: opaque device addressing. Neither table has a uid column, so
-- the relay's persisted state contains no tag<->person join and therefore no
-- social graph. See SECURITY_SEALED_SENDER.md.
CREATE TABLE IF NOT EXISTS device_tags (
    tag        TEXT PRIMARY KEY,
    fcm_token  TEXT,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_device_tags_expiry ON device_tags(expires_at);

-- Group membership, self-subscribed: a member registers only its own
-- (group_tag, member_tag) pair, so no client ever hands the relay a roster.
CREATE TABLE IF NOT EXISTS group_subscriptions (
    group_tag  TEXT NOT NULL,
    member_tag TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (group_tag, member_tag)
);

CREATE INDEX IF NOT EXISTS idx_group_subscriptions_group ON group_subscriptions(group_tag);
CREATE INDEX IF NOT EXISTS idx_group_subscriptions_member ON group_subscriptions(member_tag);
CREATE INDEX IF NOT EXISTS idx_group_subscriptions_expiry ON group_subscriptions(expires_at);