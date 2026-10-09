import { randomUUID } from "node:crypto";
import {
  IMPORT_QUEUE,
  parseBody,
  redis,
  saveJob,
  secretMatches,
  validSourceUrl
} from "../lib/queue.js";

export default async function handler(request, response) {
  if (request.method !== "POST") {
    response.setHeader("Allow", "POST");
    return response.status(405).json({ error: "Método não permitido." });
  }

  const sitePassword = process.env.POST_PASSWORD || "";
  if (!sitePassword) {
    return response.status(503).json({ error: "Falta configurar POST_PASSWORD no Vercel." });
  }

  const body = parseBody(request);
  if (!secretMatches(body.password, sitePassword)) {
    return response.status(401).json({ error: "Senha de postagem incorreta." });
  }
  if (body.authorized !== true && body.authorized !== "true") {
    return response.status(400).json({ error: "Confirme que você tem autorização para publicar este vídeo." });
  }

  const sourceUrl = typeof body.sourceUrl === "string" ? body.sourceUrl.trim() : "";
  if (!validSourceUrl(sourceUrl)) {
    return response.status(400).json({ error: "Cole um link HTTPS válido de um vídeo do TikTok ou de um clip da Twitch." });
  }

  try {
    const id = randomUUID();
    const job = {
      id,
      sourceUrl,
      status: "queued",
      caption: "#facadarp",
      createdAt: new Date().toISOString(),
      rightsConfirmed: true
    };
    await saveJob(job);
    await redis(["LPUSH", IMPORT_QUEUE, id]);
    return response.status(200).json({ ok: true, id, message: "Link adicionado à fila." });
  } catch {
    return response.status(503).json({ error: "A fila não está disponível. Confira a configuração do Redis no Vercel." });
  }
}
