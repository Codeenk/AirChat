// Published key material (MLS KeyPackages and libsignal prekey bundles).
//
// Writes are signed and authenticated as the uid, so knowing someone's uid is
// not enough to replace their published bundle and silently redirect new
// sessions into a key the attacker holds. Reads are unauthenticated on
// purpose: the payload is public key material that the owner asked to
// publish, and requiring a signature on the fetch would force the fetcher to
// reveal its own identifier to get it.
import {
  deleteKeyPackages,
  getKeyPackage,
  isKeyPackageKind,
  MAX_KEY_PACKAGE_BYTES,
  pruneExpiredKeyPackages,
  publishKeyPackage,
} from "../db/key_packages";
import { verifyWithStoredKey } from "../utils/crypto-verify";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * POST /api/keys/publish
 *
 * Body: { uid, kind, payload, signature }
 * Signature covers `key_publish|<uid>|<kind>|<payload>`.
 *
 * Publishing is idempotent and resets the TTL, so a client can re-publish on
 * every launch and a live device never lapses. `kind` is checked against a
 * fixed allow-list and the payload is size-capped, so this route cannot be
 * used as general-purpose storage.
 */
export async function handlePublishKey(
  request: Request,
  env: any,
): Promise<Response> {
  try {
    const body = (await request.json()) as {
      uid?: string;
      kind?: string;
      payload?: string;
      signature?: string;
    };

    if (!body.uid || !isKeyPackageKind(body.kind) || !body.payload) {
      return json({ error: "Missing or invalid uid, kind or payload" }, 400);
    }
    if (body.payload.length > MAX_KEY_PACKAGE_BYTES) {
      return json({ error: "Payload too large" }, 413);
    }

    const signatureOk = await verifyWithStoredKey(
      env.DB,
      body.uid,
      `key_publish|${body.uid}|${body.kind}|${body.payload}`,
      body.signature,
    );
    if (!signatureOk) {
      return json({ error: "Invalid or missing signature" }, 403);
    }

    await publishKeyPackage(env.DB, body.uid, body.kind, body.payload);
    await pruneExpiredKeyPackages(env.DB);

    return json({ ok: true, kind: body.kind });
  } catch (e: any) {
    return json({ error: e?.message || "Failed to publish" }, 500);
  }
}

/**
 * GET /api/keys/lookup?uid=...&kind=mls|signal
 *
 * Returns the live payload, or 404 when the uid has published nothing of that
 * kind (or it has expired). A 404 is the signal a client uses to decide a peer
 * cannot speak the new protocol yet — it is not an error.
 */
export async function handleFetchKey(
  request: Request,
  env: any,
): Promise<Response> {
  try {
    const url = new URL(request.url);
    const uid = url.searchParams.get("uid");
    const kind = url.searchParams.get("kind");

    if (!uid || !isKeyPackageKind(kind)) {
      return json({ error: "Provide uid and a valid kind" }, 400);
    }

    const found = await getKeyPackage(env.DB, uid, kind);
    if (!found) {
      return json({ error: "No published key material for that uid" }, 404);
    }

    return json({
      uid,
      kind,
      payload: found.payload,
      expires_at: found.expiresAt,
    });
  } catch (e: any) {
    return json({ error: e?.message || "Failed to fetch" }, 500);
  }
}

/**
 * POST /api/keys/revoke
 *
 * Body: { uid, signature } with signature over `key_revoke|<uid>`.
 *
 * Lets a device withdraw its own published material — the user uninstalled the
 * app, is rotating identity, or wants to stop being pre-keyed. Scoped to the
 * caller's own uid by the signature, so it cannot be used to erase someone
 * else's bundle.
 */
export async function handleRevokeKeys(
  request: Request,
  env: any,
): Promise<Response> {
  try {
    const body = (await request.json()) as {
      uid?: string;
      signature?: string;
    };
    if (!body.uid) {
      return json({ error: "Missing uid" }, 400);
    }
    const signatureOk = await verifyWithStoredKey(
      env.DB,
      body.uid,
      `key_revoke|${body.uid}`,
      body.signature,
    );
    if (!signatureOk) {
      return json({ error: "Invalid or missing signature" }, 403);
    }
    await deleteKeyPackages(env.DB, body.uid);
    return json({ ok: true });
  } catch (e: any) {
    return json({ error: e?.message || "Failed to revoke" }, 500);
  }
}
