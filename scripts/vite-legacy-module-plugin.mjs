import fs from 'node:fs';
import path from 'node:path';

const legacyModuleSources = {
  store: {
    entry: 'js/services/index.js',
    exportCode: 'export default Store;',
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
  customer: {
    entry: 'js/customer/index.js',
    exportCode: 'export {};',
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
  electrician: {
    entry: 'js/electrician/index.js',
    exportCode: 'export default ElecApp;',
    parts: [
      'js/electrician/auth.js',
      'js/electrician/onboarding.js',
      'js/electrician/dashboard.js',
      'js/electrician/jobs.js',
      'js/electrician/payouts.js'
    ]
  },
  admin: {
    entry: 'js/admin/index.js',
    exportCode: 'export {};',
    parts: [
      'js/admin/dashboard.js',
      'js/admin/dispatch.js',
      'js/admin/electricians.js',
      'js/admin/disputes.js',
      'js/admin/jobs.js',
      'js/admin/payments.js'
    ]
  }
};

function normalizeId(id) {
  return id.split('?')[0];
}

function virtualModuleSource(moduleConfig) {
  return moduleConfig.parts
    .map((part) => fs.readFileSync(path.resolve(part), 'utf8').replace(/\s*$/, '\n'))
    .join('\n') + '\n' + moduleConfig.exportCode + '\n';
}

export function voltfriqLegacyModulesPlugin() {
  const entriesByPath = new Map(Object.values(legacyModuleSources).map((moduleConfig) => [
    path.resolve(moduleConfig.entry),
    moduleConfig
  ]));

  return {
    name: 'voltfriq-legacy-modules',
    load(id) {
      const moduleConfig = entriesByPath.get(normalizeId(id));
      return moduleConfig ? virtualModuleSource(moduleConfig) : null;
    },
    buildStart() {
      for (const moduleConfig of Object.values(legacyModuleSources)) {
        if (!fs.existsSync(path.resolve(moduleConfig.entry))) {
          throw new Error(`Missing legacy entry module ${moduleConfig.entry}.`);
        }
        for (const part of moduleConfig.parts) {
          if (!fs.existsSync(path.resolve(part))) {
            throw new Error(`Missing source module ${part} for ${moduleConfig.entry}.`);
          }
        }
      }
    }
  };
}
