import { bootstrapRuntime } from './runtime.js';

await bootstrapRuntime();
await clearAdminRuntimeCache();
window.Store = (await import('../services/index.js')).default;
await import('../admin/index.js');

async function clearAdminRuntimeCache() {
  if (typeof window === 'undefined') return;

  if ('caches' in window) {
    try {
      const keys = await window.caches.keys();
      await Promise.all(keys
        .filter((key) => /^voltfriq-/i.test(key))
        .map((key) => window.caches.delete(key)));
    } catch (error) {
      console.warn('Admin cache cleanup failed', error);
    }
  }

  if ('serviceWorker' in navigator) {
    try {
      const registrations = await navigator.serviceWorker.getRegistrations();
      await Promise.all(registrations.map((registration) => registration.unregister()));
    } catch (error) {
      console.warn('Admin service worker cleanup failed', error);
    }
  }
}
