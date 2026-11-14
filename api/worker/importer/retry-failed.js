import {
  IMPORT_PROCESSING,
  IMPORT_QUEUE,
  readJob,
  redis,
  saveJob,
  workerAuthorized
} from "../../../../lib/queue.js";

const MAX_RETRIES = 10;

async function failedTwitchJobs() {
  let cursor = "0";
  const jobs = [];
  do {
    const result = await redis(["SCAN", cursor, "MATCH", "novak:job:*", "COUNT", "100"]);
    cursor = Array.isArray(result) ? String(result[0] || "0") : "0";
    const keys = Array.isArray(result) && Array.isArray(result[1]) ? result[1] : [];
    for (const key of keys) {
      const id = String(key).replace(/^novak:job:/, "");
      const job = await readJob(id);
      if (job?.status === "failed" && job.source === "twitch-best-of") jobs.push(job);
      if (jobs.length >= MAX_RETRIES) return jobs;
    }
  } while (cursor !== "0");
  return jobs;
}

export default async function handler(request, response) {
  if (!workerAuthorized(request)) return response.status(401).json({ error: "Não autorizado." });
  if (request.method !== "POST") {
    response.setHeader("Allow", "POST");
    return response.status(405).json({ error: "Método não permitido." });
  }
  try {
    const jobs = await failedTwitchJobs();
    for (const job of jobs) {
      job.status = "queued";
      job.retriedAt = new Date().toISOString();
      delete job.error;
      delete job.failedAt;
      delete job.claimedAt;
      await saveJob(job);
      await redis(["LREM", IMPORT_PROCESSING, "0", job.id]);
      await redis(["LPUSH", IMPORT_QUEUE, job.id]);
    }
    return response.status(200).json({ ok: true, retried: jobs.length });
  } catch {
    return response.status(503).json({ error: "Não foi possível reenfileirar os clips que falharam." });
  }
}
