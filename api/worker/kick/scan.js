import { randomUUID } from "node:crypto";
import { IMPORT_QUEUE, redis, saveJob, workerAuthorized } from "../../../lib/queue.js";

const CHANNEL = "luanz7";
const SEEN_TTL_SECONDS = "7776000";
const DAILY_LIMIT = 3;

function brazilDay(value = Date.now()) {
  const instant = new Date(value);
  if (Number.isNaN(instant.getTime())) return "";
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: "America/Sao_Paulo", year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(instant);
  const get = (type) => parts.find((part) => part.type === type)?.value || "";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

function textForClip(clip) {
  const raw = String(clip.title || "").replace(/\s+/g, " ").trim();
  const usefulTitle = raw.length >= 8 && raw.length <= 80 && !/^(.)\1+$/.test(raw);
  const headline = usefulTitle ? raw : "MOMENTO INSANO NA LIVE";
  const caption = usefulTitle
    ? `🚨 ${raw}\n\n🔥 Os melhores momentos do LuanZ7 estão aqui.\n\n#luanz7 #kickbrasil #reelsbrasil`
    : "🚨 Esse momento na live do LuanZ7 foi insano! 👀\n\n🔥 Acompanhe os melhores momentos.\n\n#luanz7 #kickbrasil #reelsbrasil";
  return { headline: headline.slice(0, 90), caption: caption.slice(0, 500) };
}

function validClip(clip) {
  return clip && typeof clip.id === "string" && /^clip_[A-Za-z0-9]+$/.test(clip.id)
    && typeof clip.clip_url === "string"
    && Number.isFinite(Number(clip.duration)) && Number(clip.duration) >= 10 && Number(clip.duration) <= 180
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
    const yesterday = brazilDay(Date.now() - 24 * 60 * 60 * 1000);
    const dailyKey = `luanz7:kick:best-of:${yesterday}`;
    if (await redis(["GET", dailyKey])) {
      return response.status(200).json({ ok: true, queued: 0, alreadySelected: true, day: yesterday });
    }
    const clips = payload.clips
      .filter(validClip)
      .filter((clip) => clip.channel?.slug?.toLowerCase() === CHANNEL)
      .filter((clip) => brazilDay(clip.created_at) === yesterday)
      .sort((left, right) => Number(right.view_count ?? right.views ?? 0) - Number(left.view_count ?? left.views ?? 0))
      .slice(0, DAILY_LIMIT);
    let queued = 0;
    for (const clip of clips) {
      const seen = await redis(["SET", `luanz7:kick:clip:${clip.id}`, "1", "NX", "EX", SEEN_TTL_SECONDS]);
      if (seen !== "OK") continue;
      const text = textForClip(clip);
      const job = {
        id: randomUUID(), sourceUrl: clip.clip_url, status: "queued", caption: text.caption, headline: text.headline,
        createdAt: new Date().toISOString(), rightsConfirmed: true, source: "kick-auto",
        kickClipId: clip.id, kickClipTitle: String(clip.title || "").slice(0, 160), kickClipCreatedAt: clip.created_at || null,
        kickClipDurationSeconds: Number(clip.duration)
      };
      await saveJob(job);
      await redis(["LPUSH", IMPORT_QUEUE, job.id]);
      queued += 1;
    }
    // A daily key avoids reposting the same winners when the local executor restarts.
    await redis(["SET", dailyKey, new Date().toISOString(), "EX", SEEN_TTL_SECONDS]);
    return response.status(200).json({ ok: true, queued, day: yesterday, candidates: clips.length, strategy: "best-views-yesterday" });
  } catch {
    return response.status(503).json({ error: "Não foi possível verificar os clips da Kick." });
  }
}
