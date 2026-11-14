import { randomUUID } from "node:crypto";
import { IMPORT_QUEUE, redis, saveJob, workerAuthorized } from "../../../lib/queue.js";

const CHANNEL = "facada";
const DAILY_LIMIT = 3;
const SEEN_TTL_SECONDS = "7776000";
const TOKEN_KEY = "facada:twitch:app-token";

function brazilDate(value = Date.now()) {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: "America/Sao_Paulo", year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(value));
  const get = (type) => parts.find((part) => part.type === type)?.value || "";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

function previousDayWindow() {
  const today = brazilDate();
  const yesterday = brazilDate(Date.now() - 24 * 60 * 60 * 1000);
  // Brazil is UTC-3. Twitch expects RFC3339 in UTC.
  return { day: yesterday, start: `${yesterday}T03:00:00.000Z`, end: `${today}T03:00:00.000Z` };
}

function textForClip(clip) {
  const raw = String(clip.title || "").replace(/\s+/g, " ").trim();
  const usefulTitle = raw.length >= 8 && raw.length <= 80 && !/^(.)\1+$/.test(raw);
  const headline = usefulTitle ? raw : "MOMENTO INSANO NA LIVE";
  const caption = usefulTitle
    ? `🚨 ${raw}\n\n🔥 Os melhores momentos do Facada estão aqui.\n\n#facadarp #twitchbrasil #reelsbrasil`
    : "🚨 Esse momento na live do Facada foi insano! 👀\n\n🔥 Acompanhe os melhores momentos.\n\n#facadarp #twitchbrasil #reelsbrasil";
  return { headline: headline.slice(0, 90), caption: caption.slice(0, 500) };
}

async function appToken(clientId, clientSecret) {
  const cached = await redis(["GET", TOKEN_KEY]);
  if (typeof cached === "string") {
    try {
      const value = JSON.parse(cached);
      if (typeof value.accessToken === "string" && Number(value.expiresAt) > Date.now() + 60000) return value.accessToken;
    } catch { /* refresh invalid cache */ }
  }
  const body = new URLSearchParams({ client_id: clientId, client_secret: clientSecret, grant_type: "client_credentials" });
  const response = await fetch("https://id.twitch.tv/oauth2/token", { method: "POST", body, signal: AbortSignal.timeout(15000) });
  const payload = await response.json().catch(() => null);
  if (!response.ok || !payload?.access_token) throw new Error("Não foi possível autenticar na API da Twitch.");
  const ttl = Math.max(60, Math.min(Number(payload.expires_in || 3600) - 120, 7 * 24 * 60 * 60));
  await redis(["SET", TOKEN_KEY, JSON.stringify({ accessToken: payload.access_token, expiresAt: Date.now() + ttl * 1000 }), "EX", String(ttl)]);
  return payload.access_token;
}

async function twitchGet(path, token, clientId) {
  const response = await fetch(`https://api.twitch.tv/helix/${path}`, { headers: { Authorization: `Bearer ${token}`, "Client-Id": clientId }, signal: AbortSignal.timeout(15000) });
  const payload = await response.json().catch(() => null);
  if (!response.ok || !payload) throw new Error("A Twitch não retornou os clips.");
  return payload;
}

export default async function handler(request, response) {
  if (!workerAuthorized(request)) return response.status(401).json({ error: "Não autorizado." });
  if (request.method !== "GET") {
    response.setHeader("Allow", "GET");
    return response.status(405).json({ error: "Método não permitido." });
  }
  const clientId = String(process.env.TWITCH_CLIENT_ID || "").trim();
  const clientSecret = String(process.env.TWITCH_CLIENT_SECRET || "").trim();
  if (!clientId || !clientSecret) return response.status(503).json({ error: "Configure TWITCH_CLIENT_ID e TWITCH_CLIENT_SECRET no Vercel." });
  try {
    const { day, start, end } = previousDayWindow();
    const dailyKey = `facada:twitch:best-of:${day}`;
    if (await redis(["GET", dailyKey])) return response.status(200).json({ ok: true, queued: 0, alreadySelected: true, day });
    const token = await appToken(clientId, clientSecret);
    const users = await twitchGet(`users?login=${CHANNEL}`, token, clientId);
    const broadcasterId = users.data?.[0]?.id;
    if (typeof broadcasterId !== "string") throw new Error("Canal Twitch do Facada não encontrado.");
    const clips = await twitchGet(`clips?broadcaster_id=${encodeURIComponent(broadcasterId)}&started_at=${encodeURIComponent(start)}&ended_at=${encodeURIComponent(end)}&first=100`, token, clientId);
    const winners = Array.isArray(clips.data) ? clips.data
      .filter((clip) => typeof clip?.id === "string" && typeof clip?.url === "string" && Number(clip.duration) >= 10 && Number(clip.duration) <= 180)
      .sort((a, b) => Number(b.view_count || 0) - Number(a.view_count || 0))
      .slice(0, DAILY_LIMIT) : [];
    let queued = 0;
    for (const clip of winners) {
      const seen = await redis(["SET", `facada:twitch:clip:${clip.id}`, "1", "NX", "EX", SEEN_TTL_SECONDS]);
      if (seen !== "OK") continue;
      const text = textForClip(clip);
      const job = {
        id: randomUUID(), sourceUrl: clip.url, status: "queued", caption: text.caption, headline: text.headline,
        createdAt: new Date().toISOString(), rightsConfirmed: true, source: "twitch-best-of",
        twitchClipId: clip.id, twitchClipTitle: String(clip.title || "").slice(0, 160), twitchClipCreatedAt: clip.created_at || null,
        twitchClipViews: Number(clip.view_count || 0), twitchClipDurationSeconds: Number(clip.duration)
      };
      await saveJob(job);
      await redis(["LPUSH", IMPORT_QUEUE, job.id]);
      queued += 1;
    }
    await redis(["SET", dailyKey, new Date().toISOString(), "EX", SEEN_TTL_SECONDS]);
    return response.status(200).json({ ok: true, queued, day, candidates: winners.length, strategy: "best-views-yesterday" });
  } catch (error) {
    return response.status(503).json({ error: String(error?.message || "Não foi possível verificar os clips da Twitch.").slice(0, 250) });
  }
}
