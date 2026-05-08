import { bootstrapRuntime } from './runtime.js';

await bootstrapRuntime();
window.Store = (await import('virtual:voltfriq-store')).default;
window.ElecApp = (await import('virtual:voltfriq-electrician')).default;
await import('../sw-register.js');
