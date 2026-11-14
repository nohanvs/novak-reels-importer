import {
  IMPORT_PROCESSING,
  PUBLISH_QUEUE,
  readJob,
  redis,
  safeJobId,
  saveJob,
  parseBody,
  validPublicVideoUrl,
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

  try {
    const job = await readJob(id);
    if (!job) return response.status(404).json({ error: "Trabalho não encontrado." });

    if (body.status === "processed") {
      if (!validPublicVideoUrl(body.videoUrl)) {
        return response.status(400).json({ error: "URL de vídeo público inválida." });
      }
      if (job.status === "queued_for_publish" || job.status === "published") {
        return response.status(200).json({ accepted: true, duplicate: true });
      }
      job.status = "queued_for_publish";
      job.videoUrl = body.videoUrl;
      job.caption = typeof body.caption === "string" && body.caption.trim() ? body.caption.trim() : "#facadarp";
      job.processedAt = new Date().toISOString();
      await saveJob(job);
      await redis(["LPUSH", PUBLISH_QUEUE, id]);
      await redis(["LREM", IMPORT_PROCESSING, "0", id]);
      return response.status(200).json({ accepted: true, id });
    }

    const error = typeof body.error === "string" ? body.error.replace(/[\u0000-\u001f]/g, " ").slice(0, 300) : "Falha ao processar o vídeo.";
    job.status = "failed";
    job.error = error;
    job.failedAt = new Date().toISOString();
    await saveJob(job);
    await redis(["LREM", IMPORT_PROCESSING, "0", id]);
    return response.status(200).json({ accepted: true, status: "failed" });
  } catch {
    return response.status(503).json({ error: "Não foi possível atualizar a fila de importação." });
  }
}
