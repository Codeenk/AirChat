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

  const query = uid ? "SELECT * FROM users WHERE uid = ?" : "SELECT * FROM users WHERE username = ?";
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
