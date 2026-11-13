import {
  IMPORT_PROCESSING,
  IMPORT_QUEUE,
  readJob,
  redis,
  safeJobId,
  saveJob,
  workerAuthorized
} from "../../../lib/queue.js";

export default async function handler(request, response) {
  if (!workerAuthorized(request)) return response.status(401).json({ error: "Não autorizado." });
  if (request.method !== "POST") {
    response.setHeader("Allow", "POST");
    return response.status(405).json({ error: "Método não permitido." });
  }
  try {
    const ids = await redis(["LRANGE", IMPORT_PROCESSING, "0", "-1"]);
    let recovered = 0;
    for (const id of Array.isArray(ids) ? ids : []) {
      if (!safeJobId(id)) { await redis(["LREM", IMPORT_PROCESSING, "0", id]); continue; }
      const job = await readJob(id);
      if (!job || typeof job.sourceUrl !== "string") { await redis(["LREM", IMPORT_PROCESSING, "0", id]); continue; }
      job.status = "queued";
      delete job.claimedAt;
      await saveJob(job);
      await redis(["LREM", IMPORT_PROCESSING, "0", id]);
      await redis(["LPUSH", IMPORT_QUEUE, id]);
      recovered += 1;
    }
    return response.status(200).json({ ok: true, recovered });
  } catch {
    return response.status(503).json({ error: "Não foi possível recuperar a fila de importação." });
  }
}
