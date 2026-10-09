import {
  PUBLISH_PROCESSING,
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
  if (!["published", "failed"].includes(body.status)) {
    return response.status(400).json({ error: "Status de publicação inválido." });
  }

  try {
    const job = await readJob(id);
    if (!job) return response.status(404).json({ error: "Trabalho não encontrado." });
    job.status = body.status;
    if (body.status === "published") {
      job.instagramMediaId = String(body.mediaId || "").slice(0, 160);
      job.publishedAt = new Date().toISOString();
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
