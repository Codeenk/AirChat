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