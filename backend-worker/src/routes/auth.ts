import { verifyEd25519Signature, verifyWithStoredKey } from "../utils/crypto-verify";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * Identity registration.
 *
 * The signature must cover `register|<uid>|<identityPublicKey>` and is verified
 * against the signing key the directory already holds for the uid (or, for a
 * first-time registration, against the signing key being registered). This
 * stops an attacker who knows a victim's uid from re-registering it with their
 * own keys and then authenticating as that victim on the relay.
 */
export async function handleRegister(request: Request, env: any): Promise<Response> {
  try {
    const body = await request.json() as any;
    if (!body.uid || !body.username || !body.identityPublicKey) {
      return json({ error: "Missing required identity fields: uid, username, identityPublicKey" }, 400);
    }
    if (!body.signingPublicKey || !body.signingSignature) {
      return json({ error: "Missing signingPublicKey or signingSignature" }, 403);
    }

    const messageToVerify = `register|${body.uid}|${body.identityPublicKey}`;

    const existing: any = await env.DB.prepare(
      "SELECT uid, identity_public_key, signing_public_key FROM users WHERE uid = ?"
    ).bind(body.uid).first();

    if (existing) {
      const existingKey: string = existing.signing_public_key || "";
      if (existingKey) {
        // Hard rule: the signing key is immutable. A different key claiming an
        // existing uid is treated as a takeover attempt.
        if (existingKey !== body.signingPublicKey) {
          return json({ error: "Signing key mismatch for this uid" }, 403);
        }
        const isValid = await verifyEd25519Signature(
          existingKey,
          body.signingSignature,
          messageToVerify
        );
        if (!isValid) {
          return json({ error: "Invalid identity signature" }, 403);
        }
      } else {
        // Legacy keyless identity: allow a one-time upgrade, but only when the
        // identity key is unchanged (never let the identity itself be swapped).
        if (existing.identity_public_key !== body.identityPublicKey) {
          return json({ error: "Identity key mismatch for this uid" }, 403);
        }
        const isValid = await verifyEd25519Signature(
          body.signingPublicKey,
          body.signingSignature,
          messageToVerify
        );
        if (!isValid) {
          return json({ error: "Invalid identity signature" }, 403);
        }
      }
    }

    // Username is unique across users — never let it be stolen.
    const owner: any = await env.DB.prepare(
      "SELECT uid FROM users WHERE username = ?"
    ).bind(body.username).first();
    if (owner && owner.uid !== body.uid) {
      return json({ error: "Username already taken" }, 409);
    }

    const isValidNew = await verifyEd25519Signature(
      body.signingPublicKey,
      body.signingSignature,
      messageToVerify
    );
    if (!isValidNew) {
      return json({ error: "Invalid identity signature" }, 403);
    }

    if (existing) {
      await env.DB.prepare(
        "UPDATE users SET username = ?, identity_public_key = ?, signing_public_key = ?, signing_signature = ?, signed_prekey = ?, prekey_signature = ?, fcm_token = COALESCE(?, fcm_token) WHERE uid = ?"
      ).bind(
        body.username,
        body.identityPublicKey,
        body.signingPublicKey,
        body.signingSignature,
        body.signedPrekey || "",
        body.prekeySignature || "",
        body.fcmToken || null,
        body.uid,
      ).run();
    } else {
      await env.DB.prepare(
        "INSERT INTO users (uid, username, identity_public_key, signing_public_key, signing_signature, signed_prekey, prekey_signature, fcm_token, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
      ).bind(
        body.uid,
        body.username,
        body.identityPublicKey,
        body.signingPublicKey,
        body.signingSignature,
        body.signedPrekey || "",
        body.prekeySignature || "",
        body.fcmToken || null,
        Date.now()
      ).run();
    }

    return json({ success: true, uid: body.uid });
  } catch (err: any) {
    return json({ error: err?.message || "Registration failed" }, 500);
  }
}

/**
 * FCM token update. Signed as `fcm_token|<uid>|<token>` with the caller's
 * signing key — otherwise anyone could redirect or clear a victim's pushes.
 */
export async function handleUpdateFcmToken(request: Request, env: any): Promise<Response> {
  try {
    const body = await request.json() as any;
    if (!body.uid || !body.fcmToken) {
      return json({ error: "Missing uid or fcmToken" }, 400);
    }

    const ok = await verifyWithStoredKey(
      env.DB,
      body.uid,
      `fcm_token|${body.uid}|${body.fcmToken}`,
      body.signature
    );
    if (!ok) {
      return json({ error: "Invalid or missing signature" }, 403);
    }

    await env.DB.prepare(
      "UPDATE users SET fcm_token = ? WHERE uid = ?"
    ).bind(body.fcmToken, body.uid).run();

    return json({ success: true });
  } catch (err: any) {
    return json({ error: err?.message || "FCM token update failed" }, 500);
  }
}

/**
 * Notification self-test. Signed as `test_push|<uid>` so a third party cannot
 * spam a victim's device with test pushes.
 */
export async function handleTestPush(request: Request, env: any): Promise<Response> {
  try {
    const body = await request.json() as any;
    if (!body.uid) {
      return json({ error: "Missing uid" }, 400);
    }

    const ok = await verifyWithStoredKey(env.DB, body.uid, `test_push|${body.uid}`, body.signature);
    if (!ok) {
      return json({ error: "Invalid or missing signature" }, 403);
    }

    const row: { fcm_token: string | null } | null = await env.DB.prepare(
      "SELECT fcm_token FROM users WHERE uid = ?"
    ).bind(body.uid).first();
    const fcmToken = row?.fcm_token;
    if (!fcmToken) {
      return json({ error: "No push token registered" }, 404);
    }

    const sent = await sendTestPush(env, fcmToken);
    return json({ sent }, sent ? 200 : 502);
  } catch {
    return json({ error: "Test push failed" }, 500);
  }
}

import { sendSilentWake } from "../utils/fcm";

async function sendTestPush(env: any, fcmToken: string): Promise<boolean> {
  // Reuses the wake sender with a fixed uid so the client can identify it.
  return sendSilentWake(env, fcmToken, "self_test");
}
