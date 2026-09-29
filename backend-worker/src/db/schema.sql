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