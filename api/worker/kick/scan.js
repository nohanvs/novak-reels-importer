import { randomUUID } from "node:crypto";
import { IMPORT_QUEUE, redis, saveJob, workerAuthorized } from "../../../lib/queue.js";

const CHANNEL = "luanz7";
const SEEN_TTL_SECONDS = "7776000";
const INITIALIZED_KEY = "luanz7:kick:clips:initialized";

function validClip(clip) {
  return clip && typeof clip.id === "string" && /^clip_[A-Za-z0-9]+$/.test(clip.id)
    && typeof clip.clip_url === "string"
    && /^https:\/\/clips\.kick\.com\/clips\/[a-z0-9]+\/clip_[A-Za-z0-9]+\/playlist\.m3u8$/.test(clip.clip_url);
}

export default async function handler(request, response) {
  if (!workerAuthorized(request)) return response.status(401).json({ error: "Não autorizado." });
  if (request.method !== "GET") {
    response.setHeader("Allow", "GET");
    return response.status(405).json({ error: "Método não permitido." });
  }
  try {
    const kickResponse = await fetch(`https://kick.com/api/v2/channels/${CHANNEL}/clips`, {
      headers: { Accept: "application/json", "User-Agent": "Luanz7-Reels-Monitor/1.0" },
      signal: AbortSignal.timeout(15000)
    });
    const payload = await kickResponse.json().catch(() => null);
    if (!kickResponse.ok || !payload || !Array.isArray(payload.clips)) {
      return response.status(502).json({ error: "A Kick não retornou a lista de clips." });
    }
    const clips = payload.clips.filter(validClip).filter((clip) => clip.channel?.slug?.toLowerCase() === CHANNEL);
    const initialized = await redis(["GET", INITIALIZED_KEY]);
    if (!initialized) {
      for (const clip of clips) await redis(["SET", `luanz7:kick:clip:${clip.id}`, "1", "EX", SEEN_TTL_SECONDS]);
      await redis(["SET", INITIALIZED_KEY, new Date().toISOString(), "EX", SEEN_TTL_SECONDS]);
      return response.status(200).json({ ok: true, initialized: true, queued: 0, seen: clips.length });
    }
    let queued = 0;
    for (const clip of clips) {
      const seen = await redis(["SET", `luanz7:kick:clip:${clip.id}`, "1", "NX", "EX", SEEN_TTL_SECONDS]);
      if (seen !== "OK") continue;
      const job = {
        id: randomUUID(), sourceUrl: clip.clip_url, status: "queued", caption: "#luanz7",
        createdAt: new Date().toISOString(), rightsConfirmed: true, source: "kick-auto",
        kickClipId: clip.id, kickClipTitle: String(clip.title || "").slice(0, 160), kickClipCreatedAt: clip.created_at || null
      };
      await saveJob(job);
      await redis(["LPUSH", IMPORT_QUEUE, job.id]);
      queued += 1;
    }
    return response.status(200).json({ ok: true, initialized: false, queued, scanned: clips.length });
  } catch {
    return response.status(503).json({ error: "Não foi possível verificar os clips da Kick." });
  }
}
