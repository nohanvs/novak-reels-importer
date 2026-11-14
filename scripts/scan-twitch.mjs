const baseUrl = (process.env.NOVAK_API_BASE_URL || "").replace(/\/$/, "");
const token = process.env.NOVAK_IMPORTER_TOKEN || "";

if (!baseUrl || token.length < 32) {
  process.stderr.write("Monitor da Twitch sem configuração do executor.\n");
  process.exitCode = 1;
} else {
  try {
    const response = await fetch(`${baseUrl}/api/worker/twitch/scan`, { headers: { Authorization: `Bearer ${token}` } });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
    if (payload.queued) console.log(`Monitor da Twitch: ${payload.queued} melhor(es) clip(s) de ${payload.day} entrou/entraram na fila.`);
    else if (payload.alreadySelected) console.log(`Monitor da Twitch: os melhores clips de ${payload.day} já foram selecionados.`);
    else console.log(`Monitor da Twitch: nenhum clip elegível encontrado para ${payload.day}.`);
  } catch (error) {
    process.stderr.write(`Monitor da Twitch falhou: ${String(error.message || error).slice(0, 300)}\n`);
    process.exitCode = 1;
  }
}
