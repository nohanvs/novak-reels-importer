import {
  IMPORT_PROCESSING,
  IMPORT_QUEUE,
  PUBLISH_PROCESSING,
  PUBLISH_QUEUE,
  readJob,
  redis,
  safeJobId,
  workerAuthorized
} from "../../lib/queue.js";

const queues = {
  importQueued: IMPORT_QUEUE,
  importProcessing: IMPORT_PROCESSING,
  publishQueued: PUBLISH_QUEUE,
  publishProcessing: PUBLISH_PROCESSING
};

function safeSummary(job) {
  return {
    id: job.id,
    status: job.status,
    source: job.source,
    createdAt: job.createdAt,
    claimedAt: job.claimedAt,
    processedAt: job.processedAt,
    failedAt: job.failedAt,
    publishedAt: job.publishedAt,
    error: job.error
  };
}

export default async function handler(request, response) {
  if (!workerAuthorized(request)) return response.status(401).json({ error: "Não autorizado." });
  if (request.method !== "GET") {
    response.setHeader("Allow", "GET");
    return response.status(405).json({ error: "Método não permitido." });
  }
  try {
    const requestedId = String(request.query?.id || "");
    if (requestedId) {
      if (!safeJobId(requestedId)) return response.status(400).json({ error: "ID de trabalho inválido." });
      const job = await readJob(requestedId);
      return job
        ? response.status(200).json({ ok: true, job: safeSummary(job) })
        : response.status(404).json({ error: "Trabalho não encontrado." });
    }
    const result = {};
    for (const [name, key] of Object.entries(queues)) {
      const ids = await redis(["LRANGE", key, "0", "19"]);
      const jobs = [];
      for (const id of Array.isArray(ids) ? ids : []) {
        if (!safeJobId(id)) continue;
        const job = await readJob(id);
        if (job) jobs.push(safeSummary(job));
      }
      result[name] = jobs;
    }
    return response.status(200).json({ ok: true, queues: result });
  } catch {
    return response.status(503).json({ error: "Não foi possível consultar o estado da fila." });
  }
}
