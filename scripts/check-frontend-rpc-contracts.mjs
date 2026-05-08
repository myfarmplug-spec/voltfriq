import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const schemaPath = path.join(root, 'supabase/schema.sql');

const serviceRoleOnly = new Set([
  'append_job_timeline',
  'attach_guest_job_photos',
  'create_notification',
  'guest_job_payload',
  'process_dispatch_queue'
]);

const anonAllowed = new Set([
  'create_guest_customer_job',
  'get_guest_job',
  'submit_guest_payment_proof',
  'update_guest_job_status'
]);

const internalOrAuthenticatedOnly = new Set([
  'admin_set_electrician_status',
  'admin_set_electrician_watchlist',
  'append_job_timeline',
  'attach_guest_job_photos',
  'create_dispute',
  'create_notification',
  'dispatch_job',
  'electrician_accept_job',
  'electrician_reject_job',
  'ensure_app_account_for_current_user',
  'ensure_profile_for_current_user',
  'link_referral_code',
  'resolve_dispute',
  'resolve_electrician_appeal',
  'reward_completed_referral',
  'set_job_status',
  'submit_customer_review',
  'submit_electrician_appeal',
  'submit_job_quote',
  'submit_payment_proof',
  'submit_rating',
  'verify_job_payment'
]);

async function collectJsFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'vendor') continue;
      files.push(...await collectJsFiles(full));
    } else if (entry.name.endsWith('.js')) {
      files.push(full);
    }
  }
  return files;
}

function schemaFunctionNames(schema) {
  const names = new Set();
  const patterns = [
    /\bCREATE(?:\s+OR\s+REPLACE)?\s+FUNCTION\s+"public"\."([^"]+)"/gi,
    /\bcreate\s+or\s+replace\s+function\s+public\.([a-zA-Z0-9_]+)/g,
    /\bCREATE(?:\s+OR\s+REPLACE)?\s+FUNCTION\s+public\.([a-zA-Z0-9_]+)/gi
  ];
  for (const pattern of patterns) {
    for (const match of schema.matchAll(pattern)) {
      names.add(match[1]);
    }
  }
  return names;
}

function anonGrantedRpcNames(schema) {
  const names = new Set();
  for (const statement of schema.split(';')) {
    if (!/\bgrant\s+execute\s+on\s+function\b/i.test(statement)) continue;
    if (!/\bto\s+"?anon"?\b/i.test(statement)) continue;
    const quoted = statement.match(/\bfunction\s+"public"\."([^"]+)"/i);
    if (quoted) {
      names.add(quoted[1]);
      continue;
    }
    const plain = statement.match(/\bfunction\s+public\.([a-zA-Z0-9_]+)/i);
    if (plain) {
      names.add(plain[1]);
    }
  }
  return names;
}

const schema = await readFile(schemaPath, 'utf8');
const functions = schemaFunctionNames(schema);
const anonGrants = anonGrantedRpcNames(schema);
const frontendFiles = await collectJsFiles(path.join(root, 'js'));
const rpcCalls = new Map();

for (const file of frontendFiles) {
  const source = await readFile(file, 'utf8');
  const relative = path.relative(root, file);
  for (const match of source.matchAll(/\.rpc\(\s*['"]([a-zA-Z0-9_]+)['"]/g)) {
    if (!rpcCalls.has(match[1])) rpcCalls.set(match[1], new Set());
    rpcCalls.get(match[1]).add(relative);
  }
}

const errors = [];

for (const [rpcName, files] of rpcCalls) {
  if (!functions.has(rpcName)) {
    errors.push(`Frontend calls missing RPC ${rpcName} in ${Array.from(files).join(', ')}`);
  }
  if (serviceRoleOnly.has(rpcName)) {
    errors.push(`Frontend calls service-role-only RPC ${rpcName} in ${Array.from(files).join(', ')}`);
  }
}

for (const rpcName of internalOrAuthenticatedOnly) {
  if (anonAllowed.has(rpcName)) continue;
  if (anonGrants.has(rpcName)) {
    errors.push(`Internal RPC ${rpcName} is granted to anon in schema.sql`);
  }
}

for (const rpcName of anonGrants) {
  if (!anonAllowed.has(rpcName)) {
    errors.push(`Unexpected anon RPC grant: ${rpcName}`);
  }
}

if (errors.length) {
  console.error(errors.join('\n'));
  process.exit(1);
}

console.log(`Frontend RPC contract check passed (${rpcCalls.size} frontend RPCs, ${anonGrants.size} anon RPC grants).`);
