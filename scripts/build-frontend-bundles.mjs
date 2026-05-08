import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outFlagIndex = process.argv.indexOf('--out');
const outRoot = outFlagIndex === -1
  ? root
  : path.resolve(root, process.argv[outFlagIndex + 1] || '.tmp/frontend-bundles');

const bundles = [
  {
    output: 'js/store.js',
    parts: [
      'js/services/supabaseClient.js',
      'js/services/authService.js',
      'js/services/jobService.js',
      'js/services/guestService.js',
      'js/services/paymentService.js',
      'js/services/electricianService.js',
      'js/services/adminService.js'
    ]
  },
  {
    output: 'js/customer.js',
    parts: [
      'js/customer/ui.js',
      'js/customer/location.js',
      'js/customer/booking.js',
      'js/customer/review.js',
      'js/customer/tracking.js',
      'js/customer/payment.js',
      'js/customer/dashboard.js'
    ]
  },
  {
    output: 'js/electrician.js',
    parts: [
      'js/electrician/auth.js',
      'js/electrician/onboarding.js',
      'js/electrician/dashboard.js',
      'js/electrician/jobs.js',
      'js/electrician/payouts.js'
    ]
  },
  {
    output: 'js/admin.js',
    parts: [
      'js/admin/dashboard.js',
      'js/admin/dispatch.js',
      'js/admin/electricians.js',
      'js/admin/disputes.js',
      'js/admin/jobs.js',
      'js/admin/payments.js'
    ]
  }
];

async function readPart(part) {
  const source = await readFile(path.join(root, part), 'utf8');
  return source.replace(/\s*$/, '\n');
}

for (const bundle of bundles) {
  const body = (await Promise.all(bundle.parts.map(readPart))).join('\n');
  const outputPath = path.join(outRoot, bundle.output);
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, body);
}
