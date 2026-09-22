import { ConnectionRelay } from "./durable-objects/ConnectionRelay";
import {
  handleRegister,
  handleUpdateFcmToken,
  handleTestPush,
} from "./routes/auth";
import { handleLookup } from "./routes/directory";
import { handleMediaUpload, handleMediaDownload } from "./routes/media";
import { verifyWithStoredKey } from "./utils/crypto-verify";

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

  // 3d. Register group membership — relay stores groupId→memberUids in D1
  // so it can route group_packet wakes to all members.
  if (url.pathname === "/api/group/register" && request.method === "POST") {
    return handleRegisterGroup(request, env);
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

// Register group membership in D1 — the relay uses this to know which
// members to wake for group_packet sends. Called by the group creator
// whenever the group is created, members are added, or a member leaves.
//
// Signed as `group_register|<uid>|<groupId>|<members>` so a third party
// cannot inject arbitrary members into a group they are not part of.
async function handleRegisterGroup(request: any, env: Env): Promise<Response> {
  try {
    const body = (await request.json()) as {
      uid?: string;
      groupId?: string;
      groupName?: string;
      memberUids?: string[];
      signature?: string;
    };
    if (!body.uid || !body.groupId || !Array.isArray(body.memberUids) || body.memberUids.length === 0) {
      return new Response(JSON.stringify({ error: "Missing uid, groupId or memberUids" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    const signatureOk = await verifyWithStoredKey(
      env.DB,
      body.uid,
      `group_register|${body.uid}|${body.groupId}|${body.memberUids.join(",")}`,
      body.signature,
    );
    if (!signatureOk) {
      return new Response(JSON.stringify({ error: "Invalid or missing signature" }), {
        status: 403,
        headers: { "Content-Type": "application/json" },
      });
    }

    const now = Date.now();
    const stmts = body.memberUids.map((uid: string) =>
      env.DB.prepare(
        `INSERT OR REPLACE INTO group_memberships (group_id, member_uid, group_name, created_at)
         VALUES (?, ?, ?, ?)`
      ).bind(body.groupId!, uid, body.groupName || "", now)
    );
    await env.DB.batch(stmts);

    return new Response(JSON.stringify({ ok: true, members: body.memberUids.length }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message || "Failed" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
}
