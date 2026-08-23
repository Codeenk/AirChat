import { verifyEd25519Signature } from "../utils/crypto-verify";

export async function handleRegister(request: Request, env: any): Promise<Response> {
  try {
    const body = await request.json() as any;
    if (!body.uid || !body.username || !body.identityPublicKey) {
      return new Response(JSON.stringify({ error: "Missing required identity fields: uid, username, identityPublicKey" }), {
        status: 400,
        headers: { "Content-Type": "application/json" }
      });
    }

    if (body.signingPublicKey && body.signingSignature) {
      const messageToVerify = body.identityPublicKey;
      const isValid = await verifyEd25519Signature(
        body.signingPublicKey,
        body.signingSignature,
        messageToVerify
      );

      if (!isValid) {
        return new Response(JSON.stringify({ error: "Invalid identity signature" }), {
          status: 403,
          headers: { "Content-Type": "application/json" }
        });
      }
    }

    try {
      await env.DB.prepare(
        "INSERT INTO users (uid, username, identity_public_key, signing_public_key, signing_signature, signed_prekey, prekey_signature, fcm_token, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
      ).bind(
        body.uid,
        body.username,
        body.identityPublicKey,
        body.signingPublicKey || "",
        body.signingSignature || "",
        body.signedPrekey || "",
        body.prekeySignature || "",
        body.fcmToken || null,
        Date.now()
      ).run();
    } catch {
      await env.DB.prepare(
        "UPDATE users SET username = ?, identity_public_key = ?, signing_public_key = ?, signing_signature = ?, signed_prekey = ?, prekey_signature = ?, fcm_token = COALESCE(?, fcm_token) WHERE uid = ?"
      ).bind(
        body.username,
        body.identityPublicKey,
        body.signingPublicKey || "",
        body.signingSignature || "",
        body.signedPrekey || "",
        body.prekeySignature || "",
        body.fcmToken || null,
        body.uid,
      ).run();
    }

    return new Response(JSON.stringify({ success: true, uid: body.uid }), {
      headers: { "Content-Type": "application/json" }
    });
  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message || "Registration failed" }), {
      status: 500,
      headers: { "Content-Type": "application/json" }
    });
  }
}

export async function handleUpdateFcmToken(request: Request, env: any): Promise<Response> {
  try {
    const body = await request.json() as any;
    if (!body.uid || !body.fcmToken) {
      return new Response(JSON.stringify({ error: "Missing uid or fcmToken" }), {
        status: 400,
        headers: { "Content-Type": "application/json" }
      });
    }

    await env.DB.prepare(
      "UPDATE users SET fcm_token = ? WHERE uid = ?"
    ).bind(body.fcmToken, body.uid).run();

    return new Response(JSON.stringify({ success: true }), {
      headers: { "Content-Type": "application/json" }
    });
  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message || "FCM token update failed" }), {
      status: 500,
      headers: { "Content-Type": "application/json" }
    });
  }
}
