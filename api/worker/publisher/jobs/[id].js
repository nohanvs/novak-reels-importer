import {
  PUBLISH_PROCESSING,
  PUBLISH_QUEUE,
  readJob,
  redis,
  safeJobId,
  saveJob,
  parseBody,
  workerAuthorized
} from "../../../../lib/queue.js";

export default async function handler(request, response) {
  if (!workerAuthorized(request)) return response.status(401).json({ error: "Não autorizado." });
  if (request.method !== "PATCH") {
    response.setHeader("Allow", "PATCH");
    return response.status(405).json({ error: "Método não permitido." });
  }

  const id = String(request.query?.id || "");
  if (!safeJobId(id)) return response.status(400).json({ error: "ID de trabalho inválido." });
  const body = parseBody(request);
  if (!["published", "failed", "rate_limited"].includes(body.status)) {
    return response.status(400).json({ error: "Status de publicação inválido." });
  }

  try {
    const job = await readJob(id);
    if (!job) return response.status(404).json({ error: "Trabalho não encontrado." });
    job.status = body.status;
    const publishedAccounts = Array.isArray(body.publishedAccounts)
      ? [...new Set(body.publishedAccounts.filter((value) => typeof value === "string" && value.length <= 160))]
      : [];
    if (publishedAccounts.length) job.publishedAccounts = publishedAccounts;
    if (body.status === "published") {
      job.instagramMediaIds = body.mediaIds && typeof body.mediaIds === "object" ? body.mediaIds : {};
      job.publishedAt = new Date().toISOString();
    } else if (body.status === "rate_limited") {
      job.status = "queued_for_publish";
      job.error = String(body.error || "Limite temporário da Meta.").replace(/[\u0000-\u001f]/g, " ").slice(0, 300);
      job.rateLimitedAt = new Date().toISOString();
      await saveJob(job);
      await redis(["LREM", PUBLISH_PROCESSING, "0", id]);
      await redis(["LPUSH", PUBLISH_QUEUE, id]);
      return response.status(200).json({ ok: true, status: job.status, rateLimited: true });
    } else {
      job.error = String(body.error || "Falha na publicação do Instagram.").replace(/[\u0000-\u001f]/g, " ").slice(0, 300);
      job.failedAt = new Date().toISOString();
    }
    await saveJob(job);
    await redis(["LREM", PUBLISH_PROCESSING, "0", id]);
    return response.status(200).json({ ok: true, status: job.status });
  } catch {
    return response.status(503).json({ error: "Não foi possível atualizar a fila de publicação." });
  }
}
