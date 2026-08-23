// Ephemeral encrypted media storage on Workers KV.
// - Blobs are client-side encrypted; server never holds keys.
// - expirationTtl (24h) makes every blob self-destruct automatically.
const TTL_SECONDS = 24 * 60 * 60;

export async function handleMediaUpload(request: Request, env: any, fileKey: string): Promise<Response> {
  if (!env.MEDIA_KV) {
    return new Response(JSON.stringify({
      error: "Media storage not yet activated on this server"
    }), { status: 503, headers: { "Content-Type": "application/json" } });
  }

  const uploadTimestamp = Date.now().toString();
  const body = await request.arrayBuffer();

  if (body.byteLength === 0) {
    return new Response(JSON.stringify({ error: "Empty upload" }), {
      status: 400, headers: { "Content-Type": "application/json" }
    });
  }

  // KV value limit is 25 MiB
  if (body.byteLength > 25 * 1024 * 1024) {
    return new Response(JSON.stringify({ error: "File exceeds 25MB ephemeral limit" }), {
      status: 413, headers: { "Content-Type": "application/json" }
    });
  }

  await env.MEDIA_KV.put(fileKey, body, {
    metadata: {
      uploadTime: uploadTimestamp,
      encrypted: "true",
      size: body.byteLength,
    },
    expirationTtl: TTL_SECONDS,
  });

  return new Response(JSON.stringify({
    success: true,
    fileKey,
    uploadTime: uploadTimestamp,
    expiresInSeconds: TTL_SECONDS
  }), { status: 200, headers: { "Content-Type": "application/json" } });
}

export async function handleMediaDownload(request: Request, env: any, fileKey: string): Promise<Response> {
  if (!env.MEDIA_KV) {
    return new Response("Media storage not yet activated on this server", { status: 503 });
  }

  const value = await env.MEDIA_KV.get(fileKey, { type: "arrayBuffer", cacheTtl: 60 });
  if (value === null) {
    return new Response("File not found or expired from 24h ephemeral buffer", { status: 404 });
  }

  return new Response(value, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Cache-Control": "private, no-store, max-age=0",
    },
  });
}
