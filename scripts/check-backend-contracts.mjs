#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const migrationsDir = path.join(root, 'supabase', 'migrations');
const schemaPath = path.join(root, 'supabase', 'schema.sql');

function readJsCorpus(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  return entries.map((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return readJsCorpus(full);
    if (!entry.name.endsWith('.js')) return '';
    return fs.readFileSync(full, 'utf8');
  }).join('\n');
}

const storeSource = readJsCorpus(path.join(root, 'js', 'services'));
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
  'job_events',
  'electrician_appeals',
  'guest_customers',
  'guest_action_tokens',
  'guest_otps',
  'job_state_projections',
  'operational_alerts',
  'operational_automation_runs',
  'electrician_performance_snapshots',
  'upload_failures'
];

const missingRpcs = uniqueRpcNames.filter((name) => {
  const pattern = new RegExp(`function\\s+public\\.${name}\\b|function\\s+${name}\\b`, 'i');
  return !pattern.test(sqlCorpus);
});

const missingTables = requiredTables.filter((name) => {
  const pattern = new RegExp(`create\\s+table(?:\\s+if\\s+not\\s+exists)?\\s+public\\.${name}\\b`, 'i');
  return !pattern.test(sqlCorpus);
});

const duplicateTargets = [
  'wallets',
  'wallet_transactions',
  'referrals',
  'disputes',
  'customer_addresses'
];

const duplicateFunctions = [
  'verify_job_payment',
  'create_guest_customer_job',
  'update_guest_job_status',
  'submit_guest_payment_proof',
  'create_guest_dispute'
];

const duplicateTableHits = duplicateTargets.filter((name) => {
  const pattern = new RegExp(`create\\s+table(?:\\s+if\\s+not\\s+exists)?\\s+public\\.${name}\\b`, 'ig');
  const hits = schemaSource.match(pattern);
  return (hits || []).length > 1;
});

const duplicateFunctionHits = duplicateFunctions.filter((name) => {
  const pattern = new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\b`, 'ig');
  const hits = schemaSource.match(pattern);
  return (hits || []).length > 1;
});

if (missingRpcs.length || missingTables.length || duplicateTableHits.length || duplicateFunctionHits.length) {
  if (missingRpcs.length) {
    console.error('Missing RPC definitions:\n- ' + missingRpcs.join('\n- '));
  }
  if (missingTables.length) {
    console.error('Missing required tables:\n- ' + missingTables.join('\n- '));
  }
  if (duplicateTableHits.length) {
    console.error('Duplicate table definitions in schema.sql:\n- ' + duplicateTableHits.join('\n- '));
  }
  if (duplicateFunctionHits.length) {
    console.error('Duplicate function definitions in schema.sql:\n- ' + duplicateFunctionHits.join('\n- '));
  }
  process.exit(1);
}

console.log(`Backend contract check passed (${uniqueRpcNames.length} RPCs, ${requiredTables.length} tables).`);
