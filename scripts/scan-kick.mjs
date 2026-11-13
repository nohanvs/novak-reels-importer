const baseUrl = (process.env.NOVAK_API_BASE_URL || "").replace(/\/$/, "");
const token = process.env.NOVAK_IMPORTER_TOKEN || "";

if (!baseUrl || token.length < 32) {
  process.stderr.write("Monitor da Kick sem configuração do executor.\n");
  process.exitCode = 1;
} else {
  try {
    const response = await fetch(`${baseUrl}/api/worker/kick/scan`, { headers: { Authorization: `Bearer ${token}` } });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
    if (payload.initialized) console.log(`Monitor da Kick pronto: ${payload.seen} clips atuais marcados; os próximos serão automáticos.`);
    else if (payload.queued) console.log(`Monitor da Kick: ${payload.queued} clip(s) novo(s) entraram na fila.`);
  } catch (error) {
    process.stderr.write(`Monitor da Kick falhou: ${String(error.message || error).slice(0, 300)}\n`);
    process.exitCode = 1;
  }
}
