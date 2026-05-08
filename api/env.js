export default async function handler(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.status(405).send('Method not allowed');
    return;
  }

  const headerValue = (value) => Array.isArray(value) ? value[0] : value;
  const normalizeSiteUrl = (value) => {
    const clean = String(value || '').trim().replace(/\/+$/, '');
    if (!clean) return '';
    if (/^https?:\/\//i.test(clean)) return clean;
    if (/^(localhost|127\.0\.0\.1|0\.0\.0\.0)(:|\/|$)/i.test(clean)) return `http://${clean}`;
    return `https://${clean}`;
  };

  const host = headerValue(req.headers['x-forwarded-host']) || headerValue(req.headers.host) || '';
  const proto = headerValue(req.headers['x-forwarded-proto']) || 'https';
  const requestOrigin = host ? `${proto}://${host}` : '';
  const configuredSiteUrl = normalizeSiteUrl(process.env.PUBLIC_SITE_URL);
  const configuredIsLocal = /^https?:\/\/(localhost|127\.0\.0\.1|0\.0\.0\.0)(:|\/|$)/i.test(configuredSiteUrl);
  const requestIsLocal = /^https?:\/\/(localhost|127\.0\.0\.1|0\.0\.0\.0)(:|\/|$)/i.test(requestOrigin);

  const payload = {
    SUPABASE_URL: process.env.SUPABASE_URL || '',
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY || '',
    PUBLIC_SITE_URL: configuredIsLocal && requestOrigin && !requestIsLocal
      ? requestOrigin
      : configuredSiteUrl || requestOrigin || 'https://www.voltfriq.com'
  };

  res.setHeader('Content-Type', 'application/javascript; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.status(200).send(
    'window.VOLTFRIQ_ENV = Object.assign({}, window.VOLTFRIQ_ENV, ' +
      JSON.stringify(payload) +
      ');'
  );
}
