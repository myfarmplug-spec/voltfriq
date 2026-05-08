import { bootstrapRuntime } from './runtime.js';

await bootstrapRuntime();
window.Store = (await import('virtual:voltfriq-store')).default;
await import('virtual:voltfriq-admin');
await import('../sw-register.js');
