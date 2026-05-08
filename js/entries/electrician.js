import { bootstrapRuntime } from './runtime.js';

await bootstrapRuntime();
window.Store = (await import('../services/index.js')).default;
window.ElecApp = (await import('../electrician/index.js')).default;
await import('../sw-register.js');
