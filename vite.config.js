import { defineConfig, loadEnv } from 'vite';
import fs from 'node:fs';
import path from 'node:path';

const htmlInputs = {
  main: path.resolve('index.html'),
  admin: path.resolve('admin.html'),
  electrician: path.resolve('electrician.html'),
  terms: path.resolve('terms.html'),
  privacy: path.resolve('privacy.html'),
  offline: path.resolve('offline.html')
};

const frontendBundles = {
  '/js/store.js': [
    'js/services/supabaseClient.js',
    'js/services/authService.js',
    'js/services/jobService.js',
    'js/services/guestService.js',
    'js/services/paymentService.js',
    'js/services/electricianService.js',
    'js/services/adminService.js'
  ],
  '/js/customer.js': [
    'js/customer/ui.js',
    'js/customer/location.js',
    'js/customer/booking.js',
    'js/customer/review.js',
    'js/customer/tracking.js',
    'js/customer/payment.js',
    'js/customer/dashboard.js'
  ],
  '/js/electrician.js': [
    'js/electrician/auth.js',
    'js/electrician/onboarding.js',
    'js/electrician/dashboard.js',
    'js/electrician/jobs.js',
    'js/electrician/payouts.js'
  ],
  '/js/admin.js': [
    'js/admin/dashboard.js',
    'js/admin/dispatch.js',
    'js/admin/electricians.js',
    'js/admin/disputes.js',
    'js/admin/jobs.js',
    'js/admin/payments.js'
  ]
};

function frontendBundle(pathname) {
  const parts = frontendBundles[pathname];
  if (!parts) return null;
  return parts.map((part) => fs.readFileSync(path.resolve(part), 'utf8').replace(/\s*$/, '\n')).join('\n');
}

function normalizeSiteUrl(value) {
  const clean = String(value || '').trim().replace(/\/+$/, '');
  if (!clean) return '';
  if (/^https?:\/\//i.test(clean)) return clean;
  if (/^(localhost|127\.0\.0\.1|0\.0\.0\.0)(:|\/|$)/i.test(clean)) return `http://${clean}`;
  return `https://${clean}`;
}

function envPayload(mode) {
  const loaded = loadEnv(mode, process.cwd(), '');
  return {
    SUPABASE_URL: process.env.SUPABASE_URL || loaded.SUPABASE_URL || '',
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY || loaded.SUPABASE_ANON_KEY || '',
    PUBLIC_SITE_URL: normalizeSiteUrl(process.env.PUBLIC_SITE_URL || loaded.PUBLIC_SITE_URL) || ''
  };
}

function sendEnv(res, mode, origin) {
  const payload = envPayload(mode);
  payload.PUBLIC_SITE_URL = payload.PUBLIC_SITE_URL || origin || 'http://localhost:5173';
  res.statusCode = 200;
  res.setHeader('Content-Type', 'application/javascript; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.end('window.VOLTFRIQ_ENV = Object.assign({}, window.VOLTFRIQ_ENV, ' + JSON.stringify(payload) + ');');
}

function voltfriqRoutesPlugin() {
  const rewrite = (req, res, next) => {
    const url = new URL(req.url || '/', 'http://localhost');
    const pathname = url.pathname.replace(/\/+$/, '') || '/';
    if (pathname === '/api/env.js') {
      const host = req.headers.host ? `http://${req.headers.host}` : '';
      sendEnv(res, process.env.NODE_ENV || 'development', host);
      return;
    }
    const bundle = frontendBundle(pathname);
    if (bundle) {
      res.statusCode = 200;
      res.setHeader('Content-Type', 'application/javascript; charset=utf-8');
      res.setHeader('Cache-Control', 'no-store, max-age=0');
      res.end(bundle);
      return;
    }
    if (pathname === '/admin' || pathname.startsWith('/admin/')) {
      req.url = '/admin.html' + url.search;
    } else if (
      pathname === '/electricians' ||
      pathname.startsWith('/electricians/') ||
      pathname === '/electric' ||
      pathname.startsWith('/electric/') ||
      pathname === '/electrician' ||
      pathname.startsWith('/electrician/')
    ) {
      req.url = '/electrician.html' + url.search;
    } else if (
      pathname.startsWith('/book') ||
      pathname === '/login' ||
      pathname === '/signup' ||
      pathname === '/dashboard' ||
      pathname.startsWith('/dashboard/') ||
      pathname === '/track' ||
      pathname.startsWith('/track/') ||
      pathname === '/pricing' ||
      pathname === '/report-issue'
    ) {
      req.url = '/index.html' + url.search;
    } else if (pathname === '/terms') {
      req.url = '/terms.html' + url.search;
    } else if (pathname === '/privacy') {
      req.url = '/privacy.html' + url.search;
    }
    next();
  };
  return {
    name: 'voltfriq-routes',
    configureServer(server) {
      server.middlewares.use(rewrite);
    },
    configurePreviewServer(server) {
      server.middlewares.use(rewrite);
    }
  };
}

function generatedBundlesPlugin() {
  return {
    name: 'voltfriq-generated-bundles',
    buildStart() {
      for (const [bundle, parts] of Object.entries(frontendBundles)) {
        for (const part of parts) {
          if (!fs.existsSync(path.resolve(part))) {
            throw new Error(`Missing source module ${part} for ${bundle}.`);
          }
        }
      }
    }
  };
}

export default defineConfig({
  appType: 'mpa',
  publicDir: false,
  plugins: [voltfriqRoutesPlugin(), generatedBundlesPlugin()],
  build: {
    rollupOptions: {
      input: htmlInputs
    }
  }
});
