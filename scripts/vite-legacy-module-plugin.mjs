import fs from 'node:fs';
import path from 'node:path';

const virtualModulePrefix = '\0voltfriq:';

const virtualModuleSources = {
  'virtual:voltfriq-store': {
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
  'virtual:voltfriq-customer': {
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
  'virtual:voltfriq-electrician': {
    exportCode: 'export default ElecApp;',
    parts: [
      'js/electrician/auth.js',
      'js/electrician/onboarding.js',
      'js/electrician/dashboard.js',
      'js/electrician/jobs.js',
      'js/electrician/payouts.js'
    ]
  },
  'virtual:voltfriq-admin': {
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

function virtualModuleSource(moduleConfig) {
  return moduleConfig.parts
    .map((part) => fs.readFileSync(path.resolve(part), 'utf8').replace(/\s*$/, '\n'))
    .join('\n') + '\n' + moduleConfig.exportCode + '\n';
}

export function voltfriqLegacyModulesPlugin() {
  return {
    name: 'voltfriq-legacy-modules',
    resolveId(id) {
      if (virtualModuleSources[id]) return virtualModulePrefix + id;
      return null;
    },
    load(id) {
      if (!id.startsWith(virtualModulePrefix)) return null;
      const publicId = id.slice(virtualModulePrefix.length);
      const moduleConfig = virtualModuleSources[publicId];
      return moduleConfig ? virtualModuleSource(moduleConfig) : null;
    },
    buildStart() {
      for (const [moduleId, moduleConfig] of Object.entries(virtualModuleSources)) {
        for (const part of moduleConfig.parts) {
          if (!fs.existsSync(path.resolve(part))) {
            throw new Error(`Missing source module ${part} for ${moduleId}.`);
          }
        }
      }
    }
  };
}
