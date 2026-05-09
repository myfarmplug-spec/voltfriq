#!/usr/bin/env node
import { createClient } from '@supabase/supabase-js';
import { mkdir, writeFile } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const EXECUTE = process.argv.includes('--execute');
const root = process.cwd();
const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
const backupDir = path.join(root, '.tmp', 'production-reset-backups', timestamp);

const NIGERIA_STATES = [
  'Abia', 'Adamawa', 'Akwa Ibom', 'Anambra', 'Bauchi', 'Bayelsa',
  'Benue', 'Borno', 'Cross River', 'Delta', 'Ebonyi', 'Edo',
  'Ekiti', 'Enugu', 'FCT', 'Gombe', 'Imo', 'Jigawa', 'Kaduna',
  'Kano', 'Katsina', 'Kebbi', 'Kogi', 'Kwara', 'Lagos', 'Nasarawa',
  'Niger', 'Ogun', 'Ondo', 'Osun', 'Oyo', 'Plateau', 'Rivers',
  'Sokoto', 'Taraba', 'Yobe', 'Zamfara'
];

const OPERATIONAL_TABLES = [
  'operational_alerts',
  'upload_failures',
  'job_state_projections',
  'job_messages',
  'job_photos',
  'quote_items',
  'job_payments',
  'ratings',
  'disputes',
  'guest_action_tokens',
  'guest_otps',
  'job_timeline',
  'notifications',
  'wallet_transactions',
  'event_replay_runs',
  'job_events',
  'job_quotes',
  'guest_booking_attempts',
  'operational_automation_runs',
  'operational_metrics',
  'system_health_snapshots',
  'operation_requests',
  'referrals',
  'customer_addresses',
  'electrician_appeals',
  'electrician_certifications',
  'electrician_documents',
  'electrician_performance_snapshots',
  'electrician_skills',
  'jobs',
  'guest_customers',
  'customers',
  'electricians'
];

const COUNT_TABLES = [
  ...OPERATIONAL_TABLES,
  'wallets',
  'profiles',
  'admin_settings',
  'expertise_categories'
];

const POST_RESET_SWEEP_TABLES = [
  'operational_alerts',
  'event_replay_runs',
  'operational_automation_runs',
  'operational_metrics',
  'system_health_snapshots',
  'operation_requests'
];

const DELETE_PREDICATE_COLUMNS = {
  job_state_projections: 'job_id'
};

function readEnvFile(filePath) {
  if (!existsSync(filePath)) return {};
  const values = {};
  for (const line of readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const match = trimmed.match(/^([A-Z0-9_]+)=(.*)$/);
    if (!match) continue;
    values[match[1]] = match[2].replace(/^['"]|['"]$/g, '');
  }
  return values;
}

const env = {
  ...readEnvFile(path.join(root, '.env.local')),
  ...process.env
};

if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY || !env.SUPABASE_ANON_KEY) {
  throw new Error('Missing SUPABASE_URL, SUPABASE_ANON_KEY, or SUPABASE_SERVICE_ROLE_KEY.');
}

const service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

async function selectAll(table, columns = '*') {
  const rows = [];
  const pageSize = 1000;
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await service.from(table).select(columns).range(from, from + pageSize - 1);
    if (error) throw new Error(`Could not read ${table}: ${error.message}`);
    rows.push(...(data || []));
    if (!data || data.length < pageSize) break;
  }
  return rows;
}

async function countRows(table) {
  const { count, error } = await service.from(table).select('*', { count: 'exact', head: true });
  if (error) return { table, error: error.message, count: null };
  return { table, count: count || 0 };
}

async function deleteAll(table) {
  const predicateColumn = DELETE_PREDICATE_COLUMNS[table] || 'id';
  const { error } = await service.from(table).delete().not(predicateColumn, 'is', null);
  if (error) throw new Error(`Could not clear ${table}: ${error.message}`);
}

async function deleteByIds(table, ids) {
  for (let index = 0; index < ids.length; index += 100) {
    const batch = ids.slice(index, index + 100);
    if (!batch.length) continue;
    const { error } = await service.from(table).delete().in('id', batch);
    if (error) throw new Error(`Could not delete ${table} batch: ${error.message}`);
  }
}

async function listAuthUsers() {
  const users = [];
  for (let page = 1; ; page += 1) {
    const { data, error } = await service.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw new Error(`Could not list auth users: ${error.message}`);
    users.push(...(data.users || []));
    if (!data.users || data.users.length < 1000) break;
  }
  return users;
}

function parseStoragePath(bucket, value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  if (!/^https?:\/\//i.test(raw)) return raw;
  const marker = `/storage/v1/object/public/${bucket}/`;
  const markerIndex = raw.indexOf(marker);
  if (markerIndex !== -1) return decodeURIComponent(raw.slice(markerIndex + marker.length).split('?')[0]);
  const signedMarker = `/storage/v1/object/sign/${bucket}/`;
  const signedIndex = raw.indexOf(signedMarker);
  if (signedIndex !== -1) return decodeURIComponent(raw.slice(signedIndex + signedMarker.length).split('?')[0]);
  return '';
}

async function listBucketObjects(bucket, prefix = '') {
  const all = [];
  const pageSize = 1000;
  for (let offset = 0; ; offset += pageSize) {
    const { data, error } = await service.storage.from(bucket).list(prefix, {
      limit: pageSize,
      offset,
      sortBy: { column: 'name', order: 'asc' }
    });
    if (error) {
      if (/not found/i.test(error.message || '')) return all;
      throw new Error(`Could not list bucket ${bucket}: ${error.message}`);
    }
    for (const item of data || []) {
      const objectPath = prefix ? `${prefix}/${item.name}` : item.name;
      if (item.id) all.push(objectPath);
      else all.push(...await listBucketObjects(bucket, objectPath));
    }
    if (!data || data.length < pageSize) break;
  }
  return all;
}

async function removeStorageObjects(bucket, paths) {
  const uniquePaths = Array.from(new Set(paths.filter(Boolean)));
  let removed = 0;
  for (let index = 0; index < uniquePaths.length; index += 100) {
    const batch = uniquePaths.slice(index, index + 100);
    const { error } = await service.storage.from(bucket).remove(batch);
    if (error) throw new Error(`Could not clean storage bucket ${bucket}: ${error.message}`);
    removed += batch.length;
  }
  return removed;
}

async function dumpDatabase() {
  const file = path.join(backupDir, 'supabase-data.sql');
  if (!env.SUPABASE_DATABASE_PASSWORD) {
    await writeFile(path.join(backupDir, 'supabase-data-dump-skipped.txt'), 'SUPABASE_DATABASE_PASSWORD was not available, so CLI data dump was skipped.\n');
    return null;
  }
  const result = spawnSync('supabase', ['db', 'dump', '--data-only', '--file', file, '--password', env.SUPABASE_DATABASE_PASSWORD], {
    cwd: root,
    encoding: 'utf8'
  });
  if (result.status !== 0) {
    await writeFile(path.join(backupDir, 'supabase-data-dump-error.txt'), `${result.stdout || ''}\n${result.stderr || ''}`);
    console.warn('Supabase CLI data dump failed; continuing with REST JSON table export backup.');
    return null;
  }
  return file;
}

async function exportTableJsons() {
  const tableBackupDir = path.join(backupDir, 'tables');
  await mkdir(tableBackupDir, { recursive: true });
  const exported = [];
  for (const table of COUNT_TABLES) {
    const rows = await selectAll(table, '*').catch((error) => {
      exported.push({ table, error: error.message, rows: null });
      return null;
    });
    if (!rows) continue;
    await writeFile(path.join(tableBackupDir, `${table}.json`), JSON.stringify(rows, null, 2));
    exported.push({ table, rows: rows.length });
  }
  await writeFile(path.join(backupDir, 'table-export-summary.json'), JSON.stringify(exported, null, 2));
  return exported;
}

async function updateNigeriaWideSettings() {
  const rows = await selectAll('admin_settings', '*');
  const latest = rows.sort((a, b) => new Date(b.updated_at || b.created_at || 0) - new Date(a.updated_at || a.created_at || 0))[0];
  const payload = {
    service_areas: NIGERIA_STATES,
    supported_states: NIGERIA_STATES,
    supported_cities: latest && Array.isArray(latest.supported_cities) ? latest.supported_cities : [],
    launch_cities: latest && Array.isArray(latest.launch_cities) ? latest.launch_cities : [],
    disabled_service_areas: [],
    updated_at: new Date().toISOString()
  };
  const query = latest
    ? service.from('admin_settings').update(payload).eq('id', latest.id).select('*').single()
    : service.from('admin_settings').insert(payload).select('*').single();
  const { data, error } = await query;
  if (error) throw new Error(`Could not update Nigeria-wide settings: ${error.message}`);
  return data;
}

async function main() {
  await mkdir(backupDir, { recursive: true });

  const [profiles, authUsers] = await Promise.all([
    selectAll('profiles', 'id,email,role,full_name,avatar_url'),
    listAuthUsers()
  ]);

  const adminProfiles = profiles.filter((profile) => profile.role === 'admin');
  const adminIds = new Set(adminProfiles.map((profile) => profile.id));
  const adminEmails = new Set(adminProfiles.map((profile) => String(profile.email || '').toLowerCase()).filter(Boolean));
  const adminAuthUsers = authUsers.filter((user) => (
    adminIds.has(user.id) ||
    adminEmails.has(String(user.email || '').toLowerCase()) ||
    String(user.app_metadata?.role || user.user_metadata?.role || '').toLowerCase() === 'admin'
  ));

  if (!adminProfiles.length || !adminAuthUsers.length) {
    throw new Error('No admin profile/auth user was confirmed. Reset aborted.');
  }

  const countsBefore = await Promise.all(COUNT_TABLES.map(countRows));
  const backup = {
    createdAt: new Date().toISOString(),
    execute: EXECUTE,
    adminProfiles,
    adminAuthUsers: adminAuthUsers.map((user) => ({ id: user.id, email: user.email, created_at: user.created_at })),
    countsBefore
  };

  const tableExport = await exportTableJsons();
  const sqlDumpFile = await dumpDatabase();
  backup.tableExport = tableExport;
  backup.sqlDumpFile = sqlDumpFile;
  await writeFile(path.join(backupDir, 'reset-manifest-before.json'), JSON.stringify(backup, null, 2));

  console.log('Confirmed admin accounts to preserve:');
  adminAuthUsers.forEach((user) => console.log(`- ${user.email || '(no email)'} ${user.id}`));
  console.log(`Backup directory: ${backupDir}`);

  if (!EXECUTE) {
    console.log('Dry run only. Re-run with --execute to clear production test data.');
    return;
  }

  const [jobPhotos, payments, documents, nonAdminProfiles] = await Promise.all([
    selectAll('job_photos', 'file_path'),
    selectAll('job_payments', 'proof_path'),
    selectAll('electrician_documents', 'file_path'),
    profiles.filter((profile) => profile.role !== 'admin')
  ]);

  const storageManifest = {
    'job-photos': await listBucketObjects('job-photos'),
    'payment-proofs': await listBucketObjects('payment-proofs'),
    'electrician-documents': await listBucketObjects('electrician-documents'),
    avatars: await listBucketObjects('avatars')
  };
  await writeFile(path.join(backupDir, 'storage-manifest-before.json'), JSON.stringify(storageManifest, null, 2));

  const storageRemoved = {};
  storageRemoved['job-photos'] = await removeStorageObjects('job-photos', storageManifest['job-photos']);
  storageRemoved['payment-proofs'] = await removeStorageObjects('payment-proofs', storageManifest['payment-proofs']);
  storageRemoved['electrician-documents'] = await removeStorageObjects('electrician-documents', storageManifest['electrician-documents']);

  const nonAdminAvatarPaths = nonAdminProfiles
    .map((profile) => parseStoragePath('avatars', profile.avatar_url))
    .filter(Boolean)
    .filter((avatarPath) => !Array.from(adminIds).some((adminId) => avatarPath.includes(adminId)));
  storageRemoved.avatars = await removeStorageObjects('avatars', nonAdminAvatarPaths);

  await service.from('jobs').update({ current_assignment_event_id: null, current_quote_id: null }).not('id', 'is', null);

  for (const table of OPERATIONAL_TABLES) {
    await deleteAll(table);
  }

  const walletRows = await selectAll('wallets', 'id,profile_id');
  await deleteByIds('wallets', walletRows.filter((wallet) => !adminIds.has(wallet.profile_id)).map((wallet) => wallet.id));

  await deleteByIds('profiles', nonAdminProfiles.map((profile) => profile.id));

  const nonAdminUsers = authUsers.filter((user) => !adminIds.has(user.id) && !adminEmails.has(String(user.email || '').toLowerCase()));
  for (const user of nonAdminUsers) {
    const { error } = await service.auth.admin.deleteUser(user.id);
    if (error && !/not found/i.test(error.message || '')) {
      throw new Error(`Could not delete auth user ${user.email || user.id}: ${error.message}`);
    }
  }

  const settings = await updateNigeriaWideSettings();
  for (const table of POST_RESET_SWEEP_TABLES) {
    await deleteAll(table);
  }

  const countsAfter = await Promise.all(COUNT_TABLES.map(countRows));
  const authUsersAfter = await listAuthUsers();

  const after = {
    finishedAt: new Date().toISOString(),
    preservedAdminProfiles: adminProfiles,
    preservedAdminAuthUsers: adminAuthUsers.map((user) => ({ id: user.id, email: user.email })),
    deletedAuthUsers: nonAdminUsers.map((user) => ({ id: user.id, email: user.email })),
    storageRemoved,
    nigeriaWideSettings: {
      id: settings.id,
      service_areas: settings.service_areas,
      supported_states: settings.supported_states,
      supported_cities: settings.supported_cities,
      launch_cities: settings.launch_cities
    },
    countsAfter,
    authUsersAfter: authUsersAfter.map((user) => ({ id: user.id, email: user.email }))
  };
  await writeFile(path.join(backupDir, 'reset-manifest-after.json'), JSON.stringify(after, null, 2));

  console.log('Production reset complete.');
  console.log(`Deleted auth users: ${nonAdminUsers.length}`);
  console.log(`Storage removed: ${JSON.stringify(storageRemoved)}`);
  console.log(`Backup and manifests: ${backupDir}`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
