import { readFile } from "node:fs/promises";
import path from "node:path";
import { put } from "@vercel/blob";

function safeError(error) {
  return String(error?.message || error || "unknown Blob error")
    .replace(/Bearer\s+\S+/gi, "Bearer [redacted]")
    .replace(/token[=:]\s*\S+/gi, "token=[redacted]")
    .replace(/\s+/g, " ")
    .slice(0, 300);
}

async function main() {
  const filePath = process.argv[2];
  const token = process.env.BLOB_READ_WRITE_TOKEN || "";

  // The local executor must not silently select Vercel OIDC credentials.
  // OIDC tokens are environment-scoped; this project currently grants the
  // Blob store to production/preview, which makes local development fail.
  if (!filePath || !token) {
    process.stderr.write(
      "Blob uploader needs BLOB_READ_WRITE_TOKEN for local execution.\n"
    );
    process.exitCode = 2;
    return;
  }

  try {
    const bytes = await readFile(filePath);
    const result = await put(
      "reels/" + path.basename(filePath),
      bytes,
      {
        access: "public",
        addRandomSuffix: true,
        contentType: "video/mp4",
        multipart: true,
        token
      }
    );
    process.stdout.write(JSON.stringify({ url: result.url }) + "\n");
  } catch (error) {
    process.stderr.write(`Blob upload failed: ${safeError(error)}\n`);
    process.exitCode = 1;
  }
}

main();
