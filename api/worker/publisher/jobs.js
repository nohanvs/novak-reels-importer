import {
  PUBLISH_PROCESSING,
  PUBLISH_QUEUE,
  readJob,
  redis,
  safeJobId,
  saveJob,
  workerAuthorized
} from "../../../lib/queue.js";

export default async function handler(request, response) {
  if (!workerAuthorized(request)) return response.status(401).json({ error: "Não autorizado." });
  if (request.method !== "GET") {
    response.setHeader("Allow", "GET");
    return response.status(405).json({ error: "Método não permitido." });
  }
  try {
    const id = await redis(["RPOPLPUSH", PUBLISH_QUEUE, PUBLISH_PROCESSING]);
    if (!safeJobId(id)) return response.status(200).json({ jobs: [] });
    const job = await readJob(id);
    if (!job || typeof job.videoUrl !== "string") {
      await redis(["LREM", PUBLISH_PROCESSING, "0", id]);
      return response.status(200).json({ jobs: [] });
    }
    job.status = "publishing";
    job.publishClaimedAt = new Date().toISOString();
    await saveJob(job);
    return response.status(200).json({
      jobs: [{ id: job.id, videoUrl: job.videoUrl, caption: job.caption || "#facadarp" }]
    });
  } catch {
    return response.status(503).json({ error: "A fila de publicação está indisponível." });
  }
}
