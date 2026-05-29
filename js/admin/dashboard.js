/* ─── VOLTFRIQ — ADMIN PORTAL ──────────────────────────────────── */

(() => {
  'use strict';

  let currentJobs = [];
  let currentCustomers = [];
  let currentElectricians = [];
  let currentPayments = [];
  let currentNotifications = [];
  let currentDisputes = [];
  let currentAppeals = [];
  let currentOperationalSummary = null;
  let currentOperationalQueues = null;
  let currentAdminDataWarnings = [];
  let adminDataFailuresByKey = {};
  let selectedJob = null;
  let selectedElectrician = null;
  let portalSubscription = null;
  let realtimeRefreshTimer = null;
  let pendingAdminRoute = null;
  let adminReconnectBound = false;
  let adminReconnectRefreshTimer = null;
  let adminDataRefreshTimer = null;
  let adminOperationalRefreshTimer = null;

  function wantsPasswordReset() {
    const query = new URLSearchParams(window.location.search || '');
    const hash = new URLSearchParams(String(window.location.hash || '').replace(/^#/, ''));
    return query.get('reset') === '1' || hash.get('type') === 'recovery';
  }

  const ADMIN_ROUTE_TITLES = {
    'admin-login': 'VoltFriq Admin | Login',
    'admin-dashboard': 'VoltFriq Admin | Dashboard',
    'admin-requests': 'VoltFriq Admin | Dispatch',
    'admin-request-detail': 'VoltFriq Admin | Dispatch Detail',
    'admin-electricians': 'VoltFriq Admin | Electricians',
    'admin-elec-detail': 'VoltFriq Admin | Electrician Profile',
    'admin-jobs': 'VoltFriq Admin | Jobs',
    'admin-job-detail': 'VoltFriq Admin | Job Detail',
    'admin-materials': 'VoltFriq Admin | Materials',
    'admin-finance': 'VoltFriq Admin | Finance',
    'admin-disputes': 'VoltFriq Admin | Disputes',
    'admin-trust': 'VoltFriq Admin | Trust',
    'admin-settings': 'VoltFriq Admin | Settings',
    'admin-expertise': 'VoltFriq Admin | Expertise',
    'admin-prices': 'VoltFriq Admin | Prices',
    'admin-chats': 'VoltFriq Admin | Chats'
  };

  const currentFilter = {
    requests: 'all',
    electricians: 'all',
    jobs: 'all'
  };

  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => document.querySelectorAll(selector);

  function showAdminLoading(message) {
    if (window.VoltFriqMotion && typeof window.VoltFriqMotion.showGlobalLoading === 'function') {
      return window.VoltFriqMotion.showGlobalLoading(message || 'Syncing operations...');
    }
    return () => {};
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }

  async function init() {
    configureAdminRoutes();
    bindEvents();
    updateAdminRecoveryUI();
    pendingAdminRoute = getCurrentRouteState();
    try {
      const boot = await Store.init();
      if (!boot.configured) {
        showLoginError('The admin portal is still starting. Refresh the page in a moment.');
        return;
      }

      if (boot.profile && boot.profile.role === 'customer') {
        window.location.href = Store.getRoleHome('customer');
        return;
      }
      if (boot.profile && boot.profile.role === 'electrician') {
        window.location.href = Store.getRoleHome('electrician');
        return;
      }

      if (boot.profile && boot.profile.role === 'admin' && !wantsPasswordReset()) {
        attachRealtime();
        await showApp(pendingAdminRoute);
      } else {
        await handleAdminRouteActivation({
          screen: (pendingAdminRoute && pendingAdminRoute.screen) || 'admin-login',
          data: pendingAdminRoute ? pendingAdminRoute.data : null,
          source: 'initial'
        });
      }
    } catch (error) {
      showLoginError(error.message || 'Could not start the admin portal.');
    }
  }

  function configureAdminRoutes() {
    configureRoutes({
      defaultScreen: 'admin-login',
      pathParser: parseAdminRoute,
      pathResolver: resolveAdminPath,
      titleResolver: resolveAdminTitle,
      onRouteActivated: async (route) => {
        await handleAdminRouteActivation(route);
      }
    });
  }

  function parseAdminRoute(pathname) {
    const path = normalizeAdminPath(pathname);
    if (path === '/admin' || path === '/admin/login' || path === '/admin.html') return { screen: 'admin-login' };
    if (path === '/admin/dashboard') return { screen: 'admin-dashboard' };
    if (path.indexOf('/admin/dispatch/') === 0) return { screen: 'admin-request-detail', data: { ticket: decodeURIComponent(path.split('/').pop() || '') } };
    if (path === '/admin/dispatch') return { screen: 'admin-requests' };
    if (path.indexOf('/admin/jobs/') === 0) return { screen: 'admin-job-detail', data: { ticket: decodeURIComponent(path.split('/').pop() || '') } };
    if (path === '/admin/jobs') return { screen: 'admin-jobs' };
    if (path.indexOf('/admin/electricians/') === 0) return { screen: 'admin-elec-detail', data: { electricianId: decodeURIComponent(path.split('/').pop() || '') } };
    if (path === '/admin/electricians') return { screen: 'admin-electricians' };
    if (path === '/admin/finance') return { screen: 'admin-finance' };
    if (path === '/admin/trust') return { screen: 'admin-trust' };
    if (path === '/admin/disputes') return { screen: 'admin-disputes' };
    if (path === '/admin/settings') return { screen: 'admin-settings' };
    return { screen: 'admin-login' };
  }

  function resolveAdminPath(screen, routeData) {
    if (screen === 'admin-login') return '/admin/login';
    if (screen === 'admin-dashboard') return '/admin/dashboard';
    if (screen === 'admin-requests') return '/admin/dispatch';
    if (screen === 'admin-request-detail') return routeData && routeData.ticket ? '/admin/dispatch/' + encodeURIComponent(routeData.ticket) : '/admin/dispatch';
    if (screen === 'admin-jobs') return '/admin/jobs';
    if (screen === 'admin-job-detail') return routeData && routeData.ticket ? '/admin/jobs/' + encodeURIComponent(routeData.ticket) : '/admin/jobs';
    if (screen === 'admin-electricians') return '/admin/electricians';
    if (screen === 'admin-elec-detail') return routeData && routeData.electricianId ? '/admin/electricians/' + encodeURIComponent(routeData.electricianId) : '/admin/electricians';
    if (screen === 'admin-finance') return '/admin/finance';
    if (screen === 'admin-trust') return '/admin/trust';
    if (screen === 'admin-disputes') return '/admin/disputes';
    if (screen === 'admin-settings' || screen === 'admin-expertise' || screen === 'admin-prices') return '/admin/settings';
    return '/admin/dashboard';
  }

  function resolveAdminTitle(screen, routeData) {
    if (screen === 'admin-job-detail' && routeData && routeData.ticket) {
      return 'VoltFriq Admin | Job ' + routeData.ticket;
    }
    if (screen === 'admin-request-detail' && routeData && routeData.ticket) {
      return 'VoltFriq Admin | Dispatch ' + routeData.ticket;
    }
    if (screen === 'admin-elec-detail' && routeData && routeData.electricianId) {
      return 'VoltFriq Admin | Electrician ' + routeData.electricianId.slice(0, 8).toUpperCase();
    }
    return ADMIN_ROUTE_TITLES[screen] || 'VoltFriq Admin';
  }

  async function handleAdminRouteActivation(route) {
    if (!route || !route.screen) return;
    const profile = Store.getCurrentProfile();
    const isAdmin = profile && profile.role === 'admin';

    if (!isAdmin) {
      goTo('admin-login', { replace: route.source !== 'popstate' });
      return;
    }

    await showApp(route);
  }

  function bindEvents() {
    $('#btn-admin-login').addEventListener('click', handleLogin);
    $('#btn-admin-forgot').addEventListener('click', handleForgotPassword);
    $('#admin-password').addEventListener('keydown', (event) => {
      if (event.key === 'Enter') handleLogin();
    });

    $$('.admin-nav-item').forEach((button) => {
      button.addEventListener('click', () => {
        navigateTo(button.dataset.screen);
      });
    });
  }

  function attachRealtime() {
    if (portalSubscription) portalSubscription.unsubscribe();
    portalSubscription = Store.subscribeToPortalFeed(async () => {
      if (realtimeRefreshTimer) window.clearTimeout(realtimeRefreshTimer);
      realtimeRefreshTimer = window.setTimeout(async () => {
        realtimeRefreshTimer = null;
        await loadData({ includeCore: true, includeOperational: false });
        refreshScreen(currentScreen || 'admin-dashboard');
        scheduleAdminDataRefresh({ includeCore: false, includeOperational: true, delayMs: 900 });
      }, 700);
    });
  }

  function adminAccessErrorMessage(profile, profileLoadError) {
    if (profileLoadError && !profile) {
      return 'Admin access could not be verified because your profile did not load: ' + profileLoadError.message;
    }
    if (!profile) {
      return 'Admin access could not be verified because no profile was loaded for this account.';
    }
    if (profile.role !== 'admin') {
      return 'This account is signed in as ' + (profile.role || 'unknown') + ', not admin.';
    }
    return 'This account does not have admin access.';
  }

  async function handleLogin() {
    await withButtonLoading('btn-admin-login', wantsPasswordReset() ? 'Updating Password...' : 'Signing In...', async () => {
      const email = $('#admin-email').value.trim();
      const password = $('#admin-password').value.trim();
      if (wantsPasswordReset()) {
        if (!password) throw new Error('Enter your new password to finish the reset.');
        await Store.updatePassword(password);
        window.history.replaceState({}, '', '/admin/login');
        updateAdminRecoveryUI();
        showLoginNotice('Password updated. Sign in with the new password.');
        $('#admin-password').value = '';
        return;
      }
      if (!email || !password) throw new Error('Enter admin email and password.');
      await Store.signIn(email, password);
      const profile = Store.getCurrentProfile();
      if (!profile || profile.role !== 'admin') {
        const profileLoadError = Store.getProfileLoadError ? Store.getProfileLoadError() : null;
        const accessErrorMessage = adminAccessErrorMessage(profile, profileLoadError);
        await Store.signOut();
        throw new Error(accessErrorMessage);
      }
      attachRealtime();
      await showApp((pendingAdminRoute && pendingAdminRoute.screen && pendingAdminRoute.screen !== 'admin-login')
        ? Object.assign({}, pendingAdminRoute, { source: 'login' })
        : { screen: 'admin-dashboard', data: null, source: 'login' });
    });
  }

  async function handleForgotPassword() {
    const email = $('#admin-email').value.trim();
    if (!email) {
      showLoginError('Enter the admin email first so we can send the reset link.');
      return;
    }
    await withButtonLoading('btn-admin-forgot', 'Sending Reset Link...', async () => {
      await Store.requestPasswordReset(email, '/admin/login?reset=1');
      showLoginNotice('Reset link sent. Open it on this device, then choose a new password.');
    });
  }

  async function showApp(route) {
    const finishLoading = showAdminLoading('Syncing operations...');
    try {
      $('#admin-bottom-nav').style.display = 'flex';
      bindAdminReconnectRefresh();
      renderAdminLoadingState();
      clearLoginError();
      await activateAdminRoute(route && route.screen ? route : { screen: 'admin-dashboard', data: null, source: 'app' });
    } finally {
      finishLoading();
    }
    scheduleAdminDataRefresh({ includeCore: true, includeOperational: false, delayMs: 0 });
    scheduleAdminDataRefresh({ includeCore: false, includeOperational: true, delayMs: 1200 });
  }

  function bindAdminReconnectRefresh() {
    if (adminReconnectBound) return;
    adminReconnectBound = true;
    const scheduleAdminRefresh = () => {
      if (adminReconnectRefreshTimer) window.clearTimeout(adminReconnectRefreshTimer);
      adminReconnectRefreshTimer = window.setTimeout(async () => {
        adminReconnectRefreshTimer = null;
        try {
          const profile = Store.getCurrentProfile && Store.getCurrentProfile();
          if (!profile || profile.role !== 'admin') return;
          await loadData({ includeCore: true, includeOperational: false });
          refreshScreen(currentScreen || 'admin-dashboard');
          scheduleAdminDataRefresh({ includeCore: false, includeOperational: true, delayMs: 900 });
        } catch (error) {
          console.warn('Admin refresh after reconnect failed', error);
        }
      }, 600);
    };
    if (window.VoltFriqNetwork && window.VoltFriqNetwork.onReconnect) {
      window.VoltFriqNetwork.onReconnect('admin-portal-refresh', scheduleAdminRefresh);
    }
    window.addEventListener('voltfriq:refresh-requested', () => {
      try {
        scheduleAdminRefresh();
      } catch (error) {
        console.warn('Admin refresh after reconnect failed', error);
      }
    });
  }

  function scheduleAdminDataRefresh(options) {
    const refreshOptions = Object.assign({
      includeCore: true,
      includeOperational: true,
      delayMs: 0
    }, options || {});
    const operationalOnly = refreshOptions.includeCore === false && refreshOptions.includeOperational !== false;
    const delayMs = Math.max(Number(refreshOptions.delayMs || 0), 0);
    if (operationalOnly) {
      if (adminOperationalRefreshTimer) window.clearTimeout(adminOperationalRefreshTimer);
      adminOperationalRefreshTimer = window.setTimeout(async () => {
        adminOperationalRefreshTimer = null;
        try {
          await loadData(refreshOptions);
          refreshScreen(currentScreen || 'admin-dashboard');
        } catch (error) {
          console.warn('Admin operational refresh failed', error);
        }
      }, delayMs);
      return;
    }
    if (adminDataRefreshTimer) window.clearTimeout(adminDataRefreshTimer);
    adminDataRefreshTimer = window.setTimeout(async () => {
      adminDataRefreshTimer = null;
      try {
        await loadData(refreshOptions);
        refreshScreen(currentScreen || 'admin-dashboard');
      } catch (error) {
        console.warn('Admin data refresh failed', error);
      }
    }, delayMs);
  }

  function formatDataLoadError(error) {
    const message = error && error.message ? error.message : String(error || 'Unknown error');
    return message.replace(/\s+/g, ' ').trim() || 'Unknown error';
  }

  function trimDataLoadMessage(message) {
    const clean = String(message || '').replace(/\s+/g, ' ').trim();
    return clean.length > 120 ? clean.slice(0, 117) + '...' : clean;
  }

  function setDataLoadFailure(key, label, error) {
    adminDataFailuresByKey[key] = {
      key,
      label,
      message: formatDataLoadError(error)
    };
    currentAdminDataWarnings = Object.keys(adminDataFailuresByKey).map((failureKey) => adminDataFailuresByKey[failureKey]);
  }

  function clearDataLoadFailure(key) {
    if (adminDataFailuresByKey[key]) {
      delete adminDataFailuresByKey[key];
      currentAdminDataWarnings = Object.keys(adminDataFailuresByKey).map((failureKey) => adminDataFailuresByKey[failureKey]);
    }
  }

  function adminDataWarningText() {
    if (!currentAdminDataWarnings.length) return '';
    if (currentAdminDataWarnings.length === 1) {
      const warning = currentAdminDataWarnings[0];
      return 'DATA REFRESH WARNING: ' + warning.label + ' could not refresh. Showing last available data. ' + trimDataLoadMessage(warning.message);
    }
    return 'DATA REFRESH WARNING: ' + currentAdminDataWarnings.length + ' admin sections could not refresh. Showing last available data.';
  }

  function addRefreshTask(tasks, requestedSections, group, refreshOptions, task) {
    if (requestedSections) {
      if (requestedSections.has(task.key)) tasks.push(task);
      return;
    }
    if (group === 'core' && refreshOptions.includeCore !== false) tasks.push(task);
    if (group === 'operational' && refreshOptions.includeOperational !== false) tasks.push(task);
  }

  function upsertCurrentJob(job) {
    if (!job || !job.id) return;
    const existingIndex = currentJobs.findIndex((entry) => entry.id === job.id);
    if (existingIndex >= 0) {
      currentJobs[existingIndex] = job;
    } else {
      currentJobs.unshift(job);
    }
    if (selectedJob && selectedJob.id === job.id) {
      selectedJob = job;
    }
  }

  async function loadData(options) {
    const refreshOptions = Object.assign({
      includeCore: true,
      includeOperational: true
    }, options || {});
    const requestedSections = Array.isArray(refreshOptions.sections) && refreshOptions.sections.length
      ? new Set(refreshOptions.sections)
      : null;
    const tasks = [];

    [
      { key: 'jobs', label: 'Jobs', run: () => Store.listAdminJobs({ includeProtectedAssets: false }), apply: (value) => { currentJobs = value || []; } },
      { key: 'customers', label: 'Customers', run: () => Store.listCustomers(), apply: (value) => { currentCustomers = value || []; } },
      { key: 'electricians', label: 'Electricians', run: () => Store.listElectricians('all', { includeDocumentUrls: false }), apply: (value) => { currentElectricians = value || []; } },
      { key: 'payments', label: 'Payment queue', run: () => Store.listPaymentsNeedingVerification(), apply: (value) => { currentPayments = value || []; } },
      { key: 'notifications', label: 'Notifications', run: () => Store.listNotifications(), apply: (value) => { currentNotifications = value || []; } },
      { key: 'disputes', label: 'Disputes', run: () => Store.listDisputes(), apply: (value) => { currentDisputes = value || []; } },
      { key: 'appeals', label: 'Appeals', run: () => Store.listAppeals(), apply: (value) => { currentAppeals = value || []; } },
      { key: 'expertise', label: 'Expertise settings', run: () => Store.loadExpertiseCategories(), apply: () => {} }
    ].forEach((task) => addRefreshTask(tasks, requestedSections, 'core', refreshOptions, task));

    [
      { key: 'operationalSummary', label: 'Operational metrics', run: () => Store.getOperationalSummary(), apply: (value) => { currentOperationalSummary = value || null; } },
      { key: 'operationalQueues', label: 'Operational queues', run: () => Store.getOperationalQueues(), apply: (value) => { currentOperationalQueues = value || null; } }
    ].forEach((task) => addRefreshTask(tasks, requestedSections, 'operational', refreshOptions, task));

    if (!tasks.length) {
      return {
        warnings: currentAdminDataWarnings.slice()
      };
    }

    const settled = await Promise.allSettled(tasks.map((task) => task.run()));
    settled.forEach((result, index) => {
      const task = tasks[index];
      if (result.status === 'fulfilled') {
        task.apply(result.value);
        clearDataLoadFailure(task.key);
        return;
      }
      setDataLoadFailure(task.key, task.label, result.reason);
      console.warn('Admin data section failed', task.label, result.reason);
    });
    clearLoginError();
    return {
      warnings: currentAdminDataWarnings.slice()
    };
  }

  function refreshScreen(screen) {
    Chat.destroy();
    if (screen === 'admin-dashboard') renderDashboard();
    if (screen === 'admin-requests') renderRequests();
    if (screen === 'admin-electricians') renderElectricians();
    if (screen === 'admin-jobs') renderJobs();
    if (screen === 'admin-settings') renderSettings();
    if (screen === 'admin-finance') renderFinance();
    if (screen === 'admin-disputes') renderDisputes();
    if (screen === 'admin-trust') renderTrust();
    if (screen === 'admin-materials') renderMaterials();
    if (screen === 'admin-chats') renderChats();
    if (screen === 'admin-prices') renderPrices();
    if (screen === 'admin-expertise') renderExpertiseCategories();
  }

  function renderDashboard() {
    const alerts = buildAlerts();
    const newBookingCount = currentJobs.filter((job) => ['requested', 'matching', 'assigned'].includes(job.status) || job.needsManualAssignment).length;
    const pendingElectricianCount = currentElectricians.filter((electrician) => electrician.status === 'pending').length;
	    const manualAssignmentCount = currentJobs.filter((job) => job.needsManualAssignment || (job.status === 'matching' && !job.assignedElectricianId)).length;
	    const paymentVerificationCount = currentPayments.length;
	    const stuckJobCount = currentJobs.filter(isStuckJob).length;
	    const expiredAssignmentCount = currentJobs.filter(isExpiredAssignment).length;
	    const openDisputeCount = currentDisputes.filter((dispute) => (dispute.status || 'open') === 'open').length;
	    const summaryQueues = currentOperationalSummary && currentOperationalSummary.queues ? currentOperationalSummary.queues : {};
	    const summaryMetrics = currentOperationalSummary && currentOperationalSummary.metrics ? currentOperationalSummary.metrics : {};
	    const operationalQueues = currentOperationalQueues || {};
	    const queueCount = (key) => Array.isArray(operationalQueues[key]) ? operationalQueues[key].length : 0;
		    const operationalPaymentCount = queueCount('pendingPayments') || paymentVerificationCount || Number(summaryQueues.pendingPayments || 0);
		    const operationalElectricianCount = queueCount('pendingElectricians') || pendingElectricianCount || Number(summaryQueues.pendingElectricians || 0);
		    const operationalStuckCount = queueCount('stuckJobs') || Number(summaryQueues.stuckPairingJobs || stuckJobCount || 0);
		    const failedPairingCount = queueCount('failedPairingJobs') || Number(summaryQueues.failedPairingJobs || 0);
		    const operationalExpiredCount = queueCount('expiredAssignments') || Number(summaryQueues.expiredAssignments || expiredAssignmentCount || 0);
		    const snapshotDriftCount = queueCount('snapshotDriftJobs') || Number(summaryQueues.snapshotDriftJobs || 0);
		    const predictiveAlertCount = queueCount('predictiveAlerts') || Number(summaryQueues.predictiveAlerts || 0);
		    const operationalDisputeCount = queueCount('openDisputes') || openDisputeCount || Number(summaryQueues.openDisputes || 0);
		    const operationalLogCount = Array.isArray(operationalQueues.alerts) ? operationalQueues.alerts.length : Number(summaryQueues.openAlerts || summaryQueues.criticalAlerts || 0);
		    const criticalAlertCount = (Array.isArray(operationalQueues.alerts) ? operationalQueues.alerts.filter((alert) => alert.severity === 'critical').length : 0) || Number(summaryQueues.criticalAlerts || 0);
		    const actionSummary = [
		      criticalAlertCount ? criticalAlertCount + ' critical alert' + (criticalAlertCount === 1 ? '' : 's') : null,
		      operationalPaymentCount ? operationalPaymentCount + ' payment' + (operationalPaymentCount === 1 ? '' : 's') + ' pending' : null,
		      operationalElectricianCount
		        ? operationalElectricianCount + ' electrician' + (operationalElectricianCount === 1 ? '' : 's') + ' pending approval'
		        : null,
		      operationalStuckCount ? operationalStuckCount + ' stuck job' + (operationalStuckCount === 1 ? '' : 's') : null,
		      failedPairingCount ? failedPairingCount + ' failed pairing queue' + (failedPairingCount === 1 ? '' : 's') : null,
		      operationalExpiredCount ? operationalExpiredCount + ' expired assignment' + (operationalExpiredCount === 1 ? '' : 's') : null,
		      snapshotDriftCount ? snapshotDriftCount + ' snapshot drift' + (snapshotDriftCount === 1 ? '' : 's') : null,
		      predictiveAlertCount ? predictiveAlertCount + ' predictive risk' + (predictiveAlertCount === 1 ? '' : 's') : null,
		      operationalDisputeCount ? operationalDisputeCount + ' dispute' + (operationalDisputeCount === 1 ? '' : 's') + ' open' : null
    ].filter(Boolean);

    if ($('#admin-action-banner')) {
      const dataWarning = adminDataWarningText();
      $('#admin-action-banner').textContent = dataWarning || (actionSummary.length
        ? 'LIVE OPERATIONS: ' + actionSummary.join(' • ')
        : 'LIVE OPERATIONS: No urgent items right now');
    }

    $('#pending-count').textContent = String(alerts.length);
    $('#admin-pending-actions').innerHTML = alerts.length
      ? alerts.map((alert) => actionCardMarkup(alert)).join('')
      : emptyState('No urgent alerts right now.');
    $('#admin-pending-actions').querySelectorAll('.admin-pending-card').forEach((card) => {
      card.addEventListener('click', () => navigateTo(card.dataset.target, filterRouteData(card)));
    });

	    const stats = {
	      assignTime: formatDuration(summaryMetrics.averageTimeToAssignSeconds || 0),
	      acceptTime: formatDuration(summaryMetrics.averageTimeToAcceptSeconds || 0),
		      rejectionRate: formatPercent(summaryMetrics.rejectionRate || 0),
		      paymentDelay: formatDuration(summaryMetrics.paymentVerificationDelaySeconds || 0),
		      stuckJobs: String(summaryMetrics.stuckJobsCount || operationalStuckCount || 0),
		      predictiveRisks: String(summaryMetrics.predictiveAlerts || predictiveAlertCount || 0),
		      health: formatPercent(summaryMetrics.systemHealthScore == null ? 100 : summaryMetrics.systemHealthScore)
		    };

		    $('#admin-stats').innerHTML = [
		      statCard('!', stats.health, 'System health'),
		      statCard('↗', stats.assignTime, 'Avg assign'),
		      statCard('✓', stats.acceptTime, 'Avg accept'),
		      statCard('%', stats.rejectionRate, 'Rejection rate'),
		      statCard('₦', stats.paymentDelay, 'Payment delay'),
		      statCard('!', stats.stuckJobs, 'Stuck jobs'),
		      statCard('!', stats.predictiveRisks, 'Predictive risks')
		    ].join('');

	    $('#admin-control-queue').innerHTML = [
	      queueCard('Dispatch Queue', operationalStuckCount + failedPairingCount + operationalExpiredCount, 'Routing queue', 'Review stuck pairing, failed retries, and expired offers.', 'admin-requests', 'requests', 'manual'),
	      queueCard('Payment Queue', operationalPaymentCount, 'Finance queue', 'Verify proofs before jobs move forward.', 'admin-finance'),
	      queueCard('Approval Queue', operationalElectricianCount, 'Onboarding queue', 'Review pending VoltFriq applications and approve or reject.', 'admin-electricians', 'electricians', 'pending'),
	      queueCard('Dispute Queue', operationalDisputeCount, 'Trust queue', 'Resolve open disputes and customer interventions.', 'admin-disputes'),
	      queueCard('Recovery Queue', snapshotDriftCount + predictiveAlertCount, 'Reliability queue', 'Reconcile state drift and predictive operational risks.', 'admin-jobs'),
	      queueCard('Operational Log', operationalLogCount, 'Event log', 'Review active alerts and recent operational events.', 'admin-jobs')
	    ].join('');
    $('#admin-control-queue').querySelectorAll('.admin-queue-card').forEach((card) => {
      card.addEventListener('click', () => navigateTo(card.dataset.target, filterRouteData(card)));
    });

    const activity = currentJobs
      .slice()
      .sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt))
      .slice(0, 10)
      .map((job) => {
        const lastTimeline = job.timeline[job.timeline.length - 1];
        return '<div class="admin-feed-item">' +
          '<div class="admin-feed-dot"></div>' +
          '<div class="admin-feed-text"><strong>' + escapeHtml(job.ticket) + '</strong> ' + escapeHtml(lastTimeline ? Store.getStatusLabel(lastTimeline.status) : job.statusLabel) + '</div>' +
          '<div class="admin-feed-time">' + formatRelative(job.updatedAt) + '</div>' +
        '</div>';
      }).join('');
    $('#admin-feed').innerHTML = activity || emptyState('No job activity yet.');
  }
