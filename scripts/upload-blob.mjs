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
  const oidcToken = process.env.VERCEL_OIDC_TOKEN || "";
  const storeId = process.env.BLOB_STORE_ID || "";
  const useOidc = Boolean(oidcToken && storeId);

  if (!filePath || (!token && !useOidc)) {
    process.stderr.write(
      "Blob uploader needs BLOB_READ_WRITE_TOKEN or VERCEL_OIDC_TOKEN plus BLOB_STORE_ID.\n"
    );
    process.exitCode = 2;
    return;
  }

  try {
    const bytes = await readFile(filePath);
    const options = {
      access: "public",
      addRandomSuffix: true,
      contentType: "video/mp4",
      multipart: true
    };

    if (useOidc) {
      options.oidcToken = oidcToken;
      options.storeId = storeId;
    } else {
      options.token = token;
    }

    const result = await put(
      "reels/" + path.basename(filePath),
      bytes,
      options
    );
    process.stdout.write(JSON.stringify({ url: result.url }) + "\n");
  } catch (error) {
    process.stderr.write(`Blob upload failed: ${safeError(error)}\n`);
    process.exitCode = 1;
  }
}

main();
