import { timingSafeEqual } from "node:crypto";

export const IMPORT_QUEUE = "novak:queue:import";
export const IMPORT_PROCESSING = "novak:processing:import";
export const PUBLISH_QUEUE = "novak:queue:publish";
export const PUBLISH_PROCESSING = "novak:processing:publish";
const JOB_TTL_SECONDS = "2592000";

export async function redis(command) {
  const url = (process.env.UPSTASH_REDIS_REST_URL || "").replace(/\/$/, "");
  const token = process.env.UPSTASH_REDIS_REST_TOKEN || "";
  if (!url || !token) throw new Error("Queue storage is not configured");
  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: "Bearer " + token,
      "Content-Type": "application/json",
      Accept: "application/json"
    },
    body: JSON.stringify(command)
  });
  let payload;
  try { payload = await response.json(); } catch { throw new Error("Queue storage returned invalid data"); }
  if (!response.ok || payload.error) throw new Error("Queue storage request failed");
  return payload.result;
}

export async function readJob(id) {
  const raw = await redis(["GET", "novak:job:" + id]);
  if (typeof raw !== "string") return null;
  try {
    const job = JSON.parse(raw);
    return job && typeof job === "object" ? job : null;
  } catch {
    return null;
  }
}

export async function saveJob(job) {
  await redis(["SET", "novak:job:" + job.id, JSON.stringify(job), "EX", JOB_TTL_SECONDS]);
}

export function safeJobId(value) {
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(value);
}

function constantTimeEqual(left, right) {
  const a = Buffer.from(String(left || ""), "utf8");
  const b = Buffer.from(String(right || ""), "utf8");
  return a.length === b.length && a.length > 0 && timingSafeEqual(a, b);
}

export function workerAuthorized(request) {
  const expected = process.env.NOVAK_IMPORTER_TOKEN || "";
  const header = request.headers?.authorization || "";
  const match = /^Bearer (.+)$/i.exec(header);
  return !!expected && !!match && constantTimeEqual(match[1], expected);
}

export function secretMatches(actual, expected) {
  return constantTimeEqual(actual, expected);
}

export function parseBody(request) {
  let body = request.body;
  if (body && typeof body === "object" && !Buffer.isBuffer(body)) return body;
  if (Buffer.isBuffer(body)) body = body.toString("utf8");
  if (typeof body !== "string") return {};
  try {
    const value = JSON.parse(body);
    return value && typeof value === "object" ? value : {};
  } catch {
    const contentType = String(request.headers?.["content-type"] || "");
    if (contentType.includes("application/x-www-form-urlencoded")) {
      return Object.fromEntries(new URLSearchParams(body));
    }
    return {};
  }
}

export function validSourceUrl(value) {
  if (typeof value !== "string" || value.length > 2048) return false;
  let parsed;
  try { parsed = new URL(value); } catch { return false; }
  if (parsed.protocol !== "https:" || parsed.username || parsed.password) return false;
  const hostname = parsed.hostname.toLowerCase().replace(/\.$/, "");
  const isTikTok = hostname === "tiktok.com" || hostname.endsWith(".tiktok.com");
  const isTwitch = hostname === "twitch.tv" || hostname.endsWith(".twitch.tv");
  if (isTikTok) return parsed.pathname.length > 1;
  if (isTwitch) {
    if (hostname === "clips.twitch.tv") return parsed.pathname.length > 1;
    return /(?:^|\/)clip\/[^/]+\/?$/i.test(parsed.pathname);
  }
  return false;
}

export function validPublicVideoUrl(value) {
  try {
    const parsed = new URL(value);
    return parsed.protocol === "https:" &&
      parsed.hostname.toLowerCase().endsWith(".public.blob.vercel-storage.com") &&
      !parsed.username && !parsed.password;
  } catch {
    return false;
  }
}
