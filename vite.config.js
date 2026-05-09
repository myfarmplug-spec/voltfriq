import { defineConfig, loadEnv } from 'vite';
import path from 'node:path';
import guestPhotoUploadHandler from './api/guest-photo-upload.js';
import { voltfriqLegacyModulesPlugin } from './scripts/vite-legacy-module-plugin.mjs';

const htmlInputs = {
  main: path.resolve('index.html'),
  admin: path.resolve('admin.html'),
  electrician: path.resolve('electrician.html'),
  terms: path.resolve('terms.html'),
  privacy: path.resolve('privacy.html'),
  offline: path.resolve('offline.html')
};

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

function applyLocalApiEnv(mode) {
  const loaded = loadEnv(mode, process.cwd(), '');
  ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'PUBLIC_SITE_URL'].forEach((key) => {
    if (!process.env[key] && loaded[key]) process.env[key] = loaded[key];
  });
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > 8 * 1024 * 1024) {
        reject(new Error('Request body too large'));
        req.destroy();
      }
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (error) {
        reject(error);
      }
    });
    req.on('error', reject);
  });
}

function createApiResponse(res) {
  const apiRes = {
    status(code) {
      res.statusCode = code;
      return apiRes;
    },
    setHeader(name, value) {
      res.setHeader(name, value);
      return apiRes;
    },
    json(payload) {
      if (!res.headersSent) res.setHeader('Content-Type', 'application/json; charset=utf-8');
      res.end(JSON.stringify(payload));
      return apiRes;
    },
    send(payload) {
      res.end(payload);
      return apiRes;
    }
  };
  return apiRes;
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
    if (pathname === '/api/guest-photo-upload') {
      applyLocalApiEnv(process.env.NODE_ENV || 'development');
      readRequestBody(req)
        .then((body) => {
          req.body = body;
          return guestPhotoUploadHandler(req, createApiResponse(res));
        })
        .catch((error) => {
          res.statusCode = 400;
          res.setHeader('Content-Type', 'application/json; charset=utf-8');
          res.end(JSON.stringify({ ok: false, error: error.message || 'Invalid request body' }));
        });
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

export default defineConfig({
  appType: 'mpa',
  publicDir: false,
  plugins: [voltfriqRoutesPlugin(), voltfriqLegacyModulesPlugin()],
  build: {
    rollupOptions: {
      input: htmlInputs,
      output: {
        manualChunks(id) {
          if (id.includes('/node_modules/@supabase/')) return 'supabase';
          if (id.includes('/js/admin/')) return 'admin';
          if (id.includes('/js/electrician/')) return 'electrician';
          if (id.includes('/js/customer/')) return 'customer';
          if (id.includes('/js/services/')) return 'services';
          if (id.includes('/js/chat.js')) return 'chat';
          if (id.includes('/js/navigation.js') || id.includes('/js/network.js') || id.includes('/js/config.js')) return 'runtime';
          return undefined;
        }
      }
    }
  }
});
