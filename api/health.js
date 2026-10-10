import {
  redis
} from "../lib/queue.js";

export default async function handler(request, response) {
  if (request.method !== "GET") {
    response.setHeader("Allow", "GET");
    return response.status(405).json({ error: "Método não permitido." });
  }

  const missing = [];
  if (!process.env.POST_PASSWORD) missing.push("POST_PASSWORD");
  if (!process.env.NOVAK_IMPORTER_TOKEN) missing.push("NOVAK_IMPORTER_TOKEN");

  // Vercel Blob now uses OIDC by default for apps hosted on Vercel.
  // BLOB_STORE_ID means this project is connected to a store; a static
  // BLOB_READ_WRITE_TOKEN is only needed by external workers such as GitHub Actions.
  const blobConfigured = Boolean(
    process.env.BLOB_STORE_ID || process.env.BLOB_READ_WRITE_TOKEN
  );
  if (!blobConfigured) missing.push("BLOB_STORE_ID (or BLOB_READ_WRITE_TOKEN)");

  if (missing.length) {
    return response.status(503).json({
      ok: false,
      error: "Faltam variáveis de ambiente no Vercel.",
      missing
    });
  }

  try {
    const ping = await redis(["PING"]);
    if (String(ping).toUpperCase() !== "PONG") throw new Error("Redis ping failed");
    return response.status(200).json({
      ok: true,
      message: "Configuração básica do NovaK Reels está pronta.",
      storage: "connected",
      blobConfigured,
      blobAuth: process.env.BLOB_STORE_ID ? "oidc" : "token",
      credentialsConfigured: true
    });
  } catch {
    return response.status(503).json({
      ok: false,
      error: "Redis não está conectado. Verifique as variáveis UPSTASH_REDIS_REST_URL e UPSTASH_REDIS_REST_TOKEN."
    });
  }
}
