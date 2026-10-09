export default async function handler(request, response) {
  if (request.method !== 'POST') {
    return response.status(405).json({ error: 'Method not allowed' });
  }

  const baseUrl = (process.env.NOVAK_API_BASE_URL || '').replace(/\/$/, '');
  const token = process.env.NOVAK_IMPORTER_TOKEN || '';
  if (!baseUrl || !token) {
    return response.status(500).json({ error: 'NovaK API is not configured on Vercel.' });
  }

  let body;
  try {
    body = typeof request.body === 'string' ? JSON.parse(request.body) : request.body;
  } catch {
    return response.status(400).json({ error: 'Invalid JSON.' });
  }

  const sourceUrl = typeof body?.sourceUrl === 'string' ? body.sourceUrl.trim() : '';
  if (!sourceUrl || !/^https:\/\//i.test(sourceUrl)) {
    return response.status(400).json({ error: 'Cole um link HTTPS válido.' });
  }

  try {
    const upstream = await fetch(`${baseUrl}/api/publisher/jobs`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify({ sourceUrl }),
    });

    const text = await upstream.text();
    let data = {};
    try { data = JSON.parse(text); } catch {}

    if (!upstream.ok) {
      return response.status(upstream.status).json({
        error: data.error || 'A API NovaK recusou o vídeo.',
      });
    }

    return response.status(200).json({ ok: true, ...data });
  } catch (error) {
    return response.status(502).json({ error: 'Não foi possível conectar à API NovaK.' });
  }
}
