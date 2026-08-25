import { ConnectionRelay } from "./durable-objects/ConnectionRelay";
import { handleRegister, handleUpdateFcmToken } from "./routes/auth";
import { handleLookup } from "./routes/directory";
import { handleMediaUpload, handleMediaDownload } from "./routes/media";

export { ConnectionRelay };

export interface Env {
  RELAY_DO: DurableObjectNamespace;
  DB: D1Database;
  MEDIA_KV?: KVNamespace;
  FCM_SERVICE_ACCOUNT_JSON?: string;
  FCM_PROJECT_ID?: string;
}

// Apply CORS headers to every outgoing response (preflight AND actual).
function withCors(response: Response): Response {
  const res = new Response(response.body, response);
  res.headers.set("Access-Control-Allow-Origin", "*");
  res.headers.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
  res.headers.set("Access-Control-Allow-Headers", "*");
  res.headers.set("Access-Control-Max-Age", "86400");
  return res;
}

async function handleRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);

  // CORS preflight
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204 });
  }

  // 1. WebSocket Tunnel Upgrade to Durable Object
  if (url.pathname === "/tunnel" || url.pathname === "/ws") {
    const id = env.RELAY_DO.idFromName("global_mesh_relay");
    const obj = env.RELAY_DO.get(id);
    return obj.fetch(request);
  }

  // 2. Public Key Identity Register
  if (url.pathname === "/api/identity/register" && request.method === "POST") {
    return handleRegister(request, env);
  }

  // 3. Public Key Identity Directory Lookup
  if (url.pathname === "/api/identity/lookup" && request.method === "GET") {
    return handleLookup(request, env);
  }

  // 3b. Update FCM Token for Silent Push Wake
  if (url.pathname === "/api/identity/fcm-token" && request.method === "POST") {
    return handleUpdateFcmToken(request, env);
  }

  // 3c. Notification self-test: send a data-only push to the caller's own
  // registered token so the client can verify end-to-end delivery health.
  if (url.pathname === "/api/identity/test-push" && request.method === "POST") {
    return handleTestPush(request, env);
  }

  // 4. Ephemeral Encrypted Media Upload (KV, auto-expires in 24h)
  if (url.pathname.startsWith("/api/media/upload/") && request.method === "PUT") {
    const fileKey = url.pathname.replace("/api/media/upload/", "");
    return handleMediaUpload(request, env, fileKey);
  }

  // 5. Ephemeral Encrypted Media Download (KV)
  if (url.pathname.startsWith("/api/media/download/") && request.method === "GET") {
    const fileKey = url.pathname.replace("/api/media/download/", "");
    return handleMediaDownload(request, env, fileKey);
  }

  return new Response(JSON.stringify({
    status: "AirChat Ephemeral Relay Operational",
    zeroKnowledge: true,
    e2ee: "Libsodium/X25519"
  }), {
    status: 200,
    headers: { "Content-Type": "application/json" }
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return withCors(await handleRequest(request, env));
    } catch (err: any) {
      return withCors(new Response(JSON.stringify({ error: err?.message || "Internal error" }), {
        status: 500,
        headers: { "Content-Type": "application/json" }
      }));
    }
  }
};

// Notification self-test handler: pushes type=self_test to the caller's own
// FCM token. The client confirms receipt locally (never through this API —
// the round-trip is device → FCM → device).
async function handleTestPush(request: any, env: any): Promise<Response> {
  try {
    const body = (await request.json()) as { uid?: string };
    const uid = body.uid;
    if (!uid) {
      return new Response(JSON.stringify({ error: "Missing uid" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }
    const row: { fcm_token: string | null } | null = await env.DB.prepare(
      "SELECT fcm_token FROM users WHERE uid = ?"
    )
      .bind(uid)
      .first();
    const fcmToken = row?.fcm_token;
    if (!fcmToken) {
      return new Response(JSON.stringify({ error: "No push token registered" }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      });
    }
    const ok = await sendTestPush(env, fcmToken);
    return new Response(JSON.stringify({ sent: ok }), {
      status: ok ? 200 : 502,
      headers: { "Content-Type": "application/json" },
    });
  } catch {
    return new Response(JSON.stringify({ error: "Test push failed" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
}

import { sendSilentWake } from "./utils/fcm";

async function sendTestPush(env: any, fcmToken: string): Promise<boolean> {
  // Reuses the wake sender with a fixed uid so the client can identify it.
  return sendSilentWake(env, fcmToken, "self_test", "AirChat");
}
