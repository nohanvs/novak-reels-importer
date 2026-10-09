import { readFile } from "node:fs/promises";
import path from "node:path";
import { put } from "@vercel/blob";

async function main() {
  const filePath = process.argv[2];
  const token = process.env.BLOB_READ_WRITE_TOKEN || "";
  if (!filePath || !token) {
    process.stderr.write("Blob uploader is not configured.\n");
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
        token,
        addRandomSuffix: true,
        contentType: "video/mp4",
        multipart: true
      }
    );
    process.stdout.write(JSON.stringify({ url: result.url }) + "\n");
  } catch {
    process.stderr.write("Blob upload failed.\n");
    process.exitCode = 1;
  }
}

main();
