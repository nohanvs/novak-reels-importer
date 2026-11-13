import { IMPORT_QUEUE, readJob, redis, safeJobId, saveJob, workerAuthorized } from "../../../lib/queue.js";

export default async function handler(request, response) {
  if (!workerAuthorized(request)) return response.status(401).json({ error: "Não autorizado." });
  if (request.method !== "POST") {
    response.setHeader("Allow", "POST");
    return response.status(405).json({ error: "Método não permitido." });
  }
  const id = String(request.body?.id || "");
  if (!safeJobId(id)) return response.status(400).json({ error: "ID inválido." });
  try {
    const job = await readJob(id);
    if (!job || typeof job.sourceUrl !== "string") return response.status(404).json({ error: "Trabalho não encontrado." });
    job.status = "queued";
    delete job.error;
    delete job.failedAt;
    delete job.claimedAt;
    await saveJob(job);
    await redis(["LPUSH", IMPORT_QUEUE, id]);
    return response.status(200).json({ ok: true, id });
  } catch {
    return response.status(503).json({ error: "Não foi possível reenfileirar o vídeo." });
  }
}
