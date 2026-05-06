export default async function handler(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.status(405).send('Method not allowed');
    return;
  }

  const payload = {
    SUPABASE_URL: process.env.SUPABASE_URL || '',
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY || '',
    PUBLIC_SITE_URL: process.env.PUBLIC_SITE_URL || 'https://www.voltfriq.com'
  };

  res.setHeader('Content-Type', 'application/javascript; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.status(200).send(
    'window.VOLTFRIQ_ENV = Object.assign({}, window.VOLTFRIQ_ENV, ' +
      JSON.stringify(payload) +
      ');'
  );
}
