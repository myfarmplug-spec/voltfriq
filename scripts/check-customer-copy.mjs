import { readFile, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const scanRoots = [
  path.join(root, 'index.html'),
  path.join(root, 'js/customer')
];

const forbidden = [
  'manual assignment required',
  'admin assignment',
  'dispatch failed',
  'no electrician available'
];

async function collectFiles(target) {
  const statTarget = await stat(target);
  if (statTarget.isFile()) return [target];
  const entries = await readdir(target, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const full = path.join(target, entry.name);
    if (entry.isDirectory()) files.push(...await collectFiles(full));
    if (entry.isFile() && /\.(html|js)$/i.test(entry.name)) files.push(full);
  }
  return files;
}

const errors = [];
for (const scanRoot of scanRoots) {
  for (const file of await collectFiles(scanRoot)) {
    const source = (await readFile(file, 'utf8')).toLowerCase();
    const relative = path.relative(root, file);
    for (const phrase of forbidden) {
      if (source.includes(phrase)) {
        errors.push(`Customer-facing forbidden phrase "${phrase}" found in ${relative}`);
      }
    }
  }
}

if (errors.length) {
  console.error(errors.join('\n'));
  process.exit(1);
}

console.log('Customer copy contract passed.');
