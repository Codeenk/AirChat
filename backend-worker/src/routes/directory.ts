// Public identity lookup. Returns ONLY the fields a peer needs to message you —
// never the FCM token, prekeys or signatures (previously `SELECT *` leaked the
// push token and signing material to anyone who knew a uid or username).
const PUBLIC_COLUMNS =
  "uid, username, identity_public_key, signing_public_key, created_at";

export async function handleLookup(request: Request, env: any): Promise<Response> {
  const url = new URL(request.url);
  const uid = url.searchParams.get("uid");
  const username = url.searchParams.get("username");

  if (!uid && !username) {
    return new Response(JSON.stringify({ error: "Provide either uid or username parameter" }), {
      status: 400,
      headers: { "Content-Type": "application/json" }
    });
  }

  const query = uid
    ? `SELECT ${PUBLIC_COLUMNS} FROM users WHERE uid = ?`
    : `SELECT ${PUBLIC_COLUMNS} FROM users WHERE username = ?`;
  const param = uid || username || "";

  const user = await env.DB.prepare(query).bind(param).first();
  if (!user) {
    return new Response(JSON.stringify({ error: "User identity not found" }), {
      status: 404,
      headers: { "Content-Type": "application/json" }
    });
  }

  return new Response(JSON.stringify(user), {
    headers: { "Content-Type": "application/json" }
  });
}
