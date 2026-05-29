#!/usr/bin/env node
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

loadEnvFile('.env.local');

if (process.env.RUN_ADMIN_FLOW_SMOKE !== '1') {
  console.log('Admin approval/assignment smoke skipped. Set RUN_ADMIN_FLOW_SMOKE=1 to run it.');
  process.exit(0);
}

if (!process.env.ADMIN_FLOW_SMOKE_TARGET) {
  console.error('Set ADMIN_FLOW_SMOKE_TARGET to staging, production, or local before running admin flow smoke.');
  process.exit(1);
}

const smokeTarget = normalizeSmokeTarget(process.env.ADMIN_FLOW_SMOKE_TARGET);
if (smokeTarget === 'production' && process.env.CONFIRM_PRODUCTION_ADMIN_FLOW_SMOKE !== '1') {
  console.error('Production admin flow smoke requires CONFIRM_PRODUCTION_ADMIN_FLOW_SMOKE=1.');
  process.exit(1);
}

const requiredEnv = ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY'];
const missingEnv = requiredEnv.filter((key) => !process.env[key]);
if (missingEnv.length) {
  console.error('Missing required environment variables for ' + smokeTarget + ' admin flow smoke: ' + missingEnv.join(', '));
  process.exit(1);
}

const supabaseUrl = process.env.SUPABASE_URL;
const anonKey = process.env.SUPABASE_ANON_KEY;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

const service = createClient(supabaseUrl, serviceRoleKey, {
  auth: {
    autoRefreshToken: false,
    persistSession: false
  }
});

const suffix = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
const password = `Smoke-${suffix}!VoltFriq`;
const createdUserIds = [];
const createdJobIds = [];
let primaryError = null;
let cleanupError = null;
let smokeTicket = '';

console.log('Running admin approval/assignment smoke against ' + smokeTarget + '.');

try {
  await runSmoke();
} catch (error) {
  primaryError = error;
} finally {
  cleanupError = await cleanup();
}

if (primaryError) {
  console.error('Admin approval/assignment smoke failed:', primaryError.message || primaryError);
  process.exit(1);
}

if (cleanupError) {
  console.error('Admin approval/assignment smoke cleanup failed:', cleanupError.message || cleanupError);
  process.exit(1);
}

console.log('Admin approval/assignment smoke passed. Temporary ticket ' + smokeTicket + ' cleaned up.');

function normalizeSmokeTarget(value) {
  const target = String(value || '').trim().toLowerCase();
  if (['staging', 'production', 'local'].includes(target)) return target;
  console.error('Invalid ADMIN_FLOW_SMOKE_TARGET "' + value + '". Expected staging, production, or local.');
  process.exit(1);
}

function loadEnvFile(filename) {
  const envPath = path.join(root, filename);
  if (!existsSync(envPath)) return;

  const lines = readFileSync(envPath, 'utf8').split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) continue;
    const [, key, rawValue] = match;
    if (process.env[key]) continue;
    process.env[key] = rawValue.replace(/^['"]|['"]$/g, '');
  }
}

function anonClient() {
  return createClient(supabaseUrl, anonKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false
    }
  });
}

async function runSmoke() {
  const adminEmail = `codex-admin-${suffix}@example.com`;
  const customerEmail = `codex-customer-${suffix}@example.com`;
  const electricianAEmail = `codex-elec-a-${suffix}@example.com`;
  const electricianBEmail = `codex-elec-b-${suffix}@example.com`;

  const admin = await createAuthUser(adminEmail, {
    full_name: 'Codex Smoke Admin'
  });
  await upsertProfile(admin.id, adminEmail, 'admin', 'Codex Smoke Admin');

  const customer = await createAuthUser(customerEmail, {
    requested_role: 'customer',
    role: 'customer',
    full_name: 'Codex Smoke Customer',
    phone: '+2348000000001',
    primary_service_area: 'Niger'
  });
  await upsertProfile(customer.id, customerEmail, 'customer', 'Codex Smoke Customer');
  await upsertCustomer(customer.id);

  const electricianA = await createAuthUser(electricianAEmail, electricianMetadata('Codex Smoke Electrician A', '+2348000000002'));
  const electricianB = await createAuthUser(electricianBEmail, electricianMetadata('Codex Smoke Electrician B', '+2348000000003'));

  const pendingElectricians = await readElectriciansForProfiles([electricianA.id, electricianB.id]);
  assert(pendingElectricians.length === 2, 'Electrician signup did not create both pending rows.');
  assert(pendingElectricians.every((row) => row.status === 'pending'), 'Electrician signup rows must start as pending.');

  const [pendingA, pendingB] = pendingElectricians;
  const adminClient = await signIn(adminEmail);
  const approvedA = await approveElectrician(adminClient, pendingA.id);
  const approvedB = await approveElectrician(adminClient, pendingB.id);
  assert(approvedA.status === 'approved' && approvedA.availability_status === 'available', 'First electrician was not approved and available.');
  assert(approvedB.status === 'approved' && approvedB.availability_status === 'available', 'Second electrician was not approved and available.');

  const customerClient = await signIn(customerEmail);
  const createdJob = await createCustomerJob(customerClient);
  createdJobIds.push(createdJob.id);
  smokeTicket = createdJob.ticket;

  const initialAssignment = await assignElectrician(adminClient, createdJob.id, approvedA.id, true);
  assert(initialAssignment.assigned_electrician_id === approvedA.id, 'Initial admin assignment did not assign the first electrician.');

  const blockedAssignment = await adminClient.rpc('admin_assign_electrician_to_job', {
    p_job_id: createdJob.id,
    p_electrician_id: approvedB.id,
    p_force: false
  });
  assert(blockedAssignment.error && /active assignment/i.test(blockedAssignment.error.message || ''), 'Non-force reassignment should be blocked during an active offer.');

  const forcedAssignment = await assignElectrician(adminClient, createdJob.id, approvedB.id, true);
  assert(forcedAssignment.assigned_electrician_id === approvedB.id, 'Force assignment did not move the job to the second electrician.');
}

function electricianMetadata(fullName, phone) {
  return {
    requested_role: 'electrician',
    role: 'electrician',
    full_name: fullName,
    phone,
    service_areas: ['Niger'],
    availability_status: 'available',
    years_experience: 3
  };
}

async function createAuthUser(email, metadata) {
  const result = await service.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: metadata
  });
  if (result.error) throw result.error;
  createdUserIds.push(result.data.user.id);

  const syncResult = await service.rpc('sync_app_account_for_auth_user', {
    p_user_id: result.data.user.id
  });
  if (syncResult.error) throw syncResult.error;
  return result.data.user;
}

async function upsertProfile(id, email, role, fullName) {
  const result = await service.from('profiles').upsert({
    id,
    email,
    role,
    full_name: fullName,
    phone: '+2348000000000'
  });
  if (result.error) throw result.error;
}

async function upsertCustomer(profileId) {
  const result = await service.from('customers').upsert({
    profile_id: profileId,
    phone: '+2348000000001',
    primary_service_area: 'Niger',
    location_label: 'Niger smoke test'
  }, { onConflict: 'profile_id' });
  if (result.error) throw result.error;
}

async function readElectriciansForProfiles(profileIds) {
  const result = await service
    .from('electricians')
    .select('id,profile_id,status,availability_status')
    .in('profile_id', profileIds)
    .order('created_at', { ascending: true });
  if (result.error) throw result.error;
  return result.data || [];
}

async function signIn(email) {
  const client = anonClient();
  const result = await client.auth.signInWithPassword({ email, password });
  if (result.error) throw result.error;
  return client;
}

async function approveElectrician(client, electricianId) {
  const result = await client.rpc('admin_set_electrician_status', {
    p_electrician_id: electricianId,
    p_status: 'approved',
    p_reason: null
  });
  if (result.error) throw result.error;
  return result.data;
}

async function createCustomerJob(client) {
  const result = await client.rpc('create_customer_job', {
    p_service_area: 'Niger',
    p_location_label: 'Niger smoke test',
    p_latitude: null,
    p_longitude: null,
    p_issue_category: 'Wiring issue',
    p_urgency: 'today',
    p_customer_note: 'Codex smoke test order - delete',
    p_requires_assessment: false,
    p_material_handling: 'customer_supplied',
    p_photo_paths: []
  });
  if (result.error) throw result.error;
  return result.data;
}

async function assignElectrician(client, jobId, electricianId, force) {
  const result = await client.rpc('admin_assign_electrician_to_job', {
    p_job_id: jobId,
    p_electrician_id: electricianId,
    p_force: force
  });
  if (result.error) throw result.error;
  return result.data;
}

async function cleanup() {
  const cleanupErrors = [];

  for (const jobId of createdJobIds) {
    const result = await service.from('jobs').delete().eq('id', jobId);
    if (result.error) cleanupErrors.push(result.error);
  }

  for (const userId of createdUserIds.reverse()) {
    const result = await service.auth.admin.deleteUser(userId);
    if (result.error) cleanupErrors.push(result.error);
  }

  if (cleanupErrors.length) {
    return new Error('Smoke cleanup had ' + cleanupErrors.length + ' error(s): ' + cleanupErrors.map((error) => error.message || String(error)).join('; '));
  }
  return null;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
