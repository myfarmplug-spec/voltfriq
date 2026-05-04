#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const storePath = path.join(root, 'js', 'store.js');
const migrationsDir = path.join(root, 'supabase', 'migrations');
const schemaPath = path.join(root, 'supabase', 'schema.sql');

const storeSource = fs.readFileSync(storePath, 'utf8');
const schemaSource = fs.existsSync(schemaPath) ? fs.readFileSync(schemaPath, 'utf8') : '';
const migrationFiles = fs.readdirSync(migrationsDir)
  .filter((file) => file.endsWith('.sql'))
  .sort();
const migrationSource = migrationFiles.map((file) => fs.readFileSync(path.join(migrationsDir, file), 'utf8')).join('\n');
const sqlCorpus = `${migrationSource}\n${schemaSource}`;

const rpcNames = [...storeSource.matchAll(/\.rpc\('([^']+)'/g)].map((match) => match[1]);
const uniqueRpcNames = [...new Set(rpcNames)].sort();

const requiredTables = [
  'customer_addresses',
  'wallets',
  'wallet_transactions',
  'referrals',
  'disputes',
  'electrician_appeals',
  'guest_customers'
];

const missingRpcs = uniqueRpcNames.filter((name) => {
  const pattern = new RegExp(`function\\s+public\\.${name}\\b|function\\s+${name}\\b`, 'i');
  return !pattern.test(sqlCorpus);
});

const missingTables = requiredTables.filter((name) => {
  const pattern = new RegExp(`create\\s+table(?:\\s+if\\s+not\\s+exists)?\\s+public\\.${name}\\b`, 'i');
  return !pattern.test(sqlCorpus);
});

if (missingRpcs.length || missingTables.length) {
  if (missingRpcs.length) {
    console.error('Missing RPC definitions:\n- ' + missingRpcs.join('\n- '));
  }
  if (missingTables.length) {
    console.error('Missing required tables:\n- ' + missingTables.join('\n- '));
  }
  process.exit(1);
}

console.log(`Backend contract check passed (${uniqueRpcNames.length} RPCs, ${requiredTables.length} tables).`);
