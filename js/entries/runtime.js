import { createClient } from '@supabase/supabase-js';

export async function bootstrapRuntime() {
  window.supabase = window.supabase || { createClient };
  await loadRuntimeEnv();
  await import('../config.js');
  const navigation = await import('../navigation.js');
  const Chat = (await import('../chat.js')).default;
  window.Chat = Chat;
  return navigation;
}

function loadRuntimeEnv() {
  if (window.VOLTFRIQ_ENV) return Promise.resolve();
  return import(/* @vite-ignore */ '/api/env.js?v=20260508-production-checklist')
    .catch(() => {
      throw new Error('VoltFriq runtime configuration could not load.');
    });
}
