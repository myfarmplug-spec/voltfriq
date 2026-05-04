export default async function handler(req, res) {
  if (req.method !== 'GET' && req.method !== 'POST') {
    res.status(405).json({ ok: false, error: 'Method not allowed' });
    return;
  }

  const expectedSecret = process.env.CRON_SECRET;
  if (!expectedSecret) {
    res.status(500).json({ ok: false, error: 'Missing cron secret' });
    return;
  }
  const authHeader = req.headers.authorization || '';
  const token = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (token !== expectedSecret) {
    res.status(401).json({ ok: false, error: 'Unauthorized' });
    return;
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !serviceRoleKey) {
    res.status(500).json({ ok: false, error: 'Missing dispatch environment variables' });
    return;
  }

  try {
    const response = await fetch(`${supabaseUrl}/rest/v1/rpc/process_dispatch_queue`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`
      },
      body: JSON.stringify({})
    });

    if (!response.ok) {
      const detail = await response.text();
      res.status(response.status).json({ ok: false, error: 'Dispatch heartbeat failed', detail });
      return;
    }

    const data = await response.json();
    res.status(200).json({
      ok: true,
      processed: Number(data || 0)
    });
  } catch (error) {
    res.status(500).json({
      ok: false,
      error: error && error.message ? error.message : 'Unexpected dispatch heartbeat failure'
    });
  }
}
