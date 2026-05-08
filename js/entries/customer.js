import { bootstrapRuntime } from './runtime.js';

await bootstrapRuntime();
window.Store = (await import('../services/index.js')).default;
await import('../customer/index.js');
await import('../sw-register.js');
