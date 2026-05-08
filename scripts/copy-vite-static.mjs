import { cp, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dist = path.join(root, 'dist');

const entries = [
  'assets',
  'css',
  'vendor',
  'manifest.json',
  'sw.js',
  'style.css'
];

const runtimeJsFiles = [
  'config.js',
  'navigation.js',
  'chat.js',
  'sw-register.js'
];

await mkdir(dist, { recursive: true });

for (const entry of entries) {
  await cp(path.join(root, entry), path.join(dist, entry), {
    recursive: true,
    force: true
  });
}

await mkdir(path.join(dist, 'js'), { recursive: true });
for (const file of runtimeJsFiles) {
  await cp(path.join(root, 'js', file), path.join(dist, 'js', file), {
    force: true
  });
}
