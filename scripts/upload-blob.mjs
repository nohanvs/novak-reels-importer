import { readFile } from "node:fs/promises";
import path from "node:path";
import { put } from "@vercel/blob";

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

    // Vercel OIDC is preferred when both an OIDC token and store ID exist.
    // This also lets the local Windows worker use short-lived credentials
    // refreshed by "vercel env pull", without needing a permanent blob token.
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
  } catch {
    process.stderr.write("Blob upload failed. Check Blob credentials and access.\n");
    process.exitCode = 1;
  }
}

main();
