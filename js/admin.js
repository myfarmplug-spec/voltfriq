/* ─── VOLTFRIQ — ADMIN PORTAL ──────────────────────────────────── */

(() => {
  'use strict';

  let currentJobs = [];
  let currentElectricians = [];
  let currentPayments = [];
  let currentNotifications = [];
  let currentDisputes = [];
  let currentAppeals = [];
  let selectedJob = null;
  let selectedElectrician = null;
  let portalSubscription = null;
  let realtimeRefreshTimer = null;
  let pendingAdminRoute = null;

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

  document.addEventListener('DOMContentLoaded', init);

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
        await loadData();
        refreshScreen(currentScreen || 'admin-dashboard');
      }, 700);
    });
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
      if ((Store.getCurrentProfile() || {}).role !== 'admin') {
        await Store.signOut();
        throw new Error('This account does not have admin access.');
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
    $('#admin-bottom-nav').style.display = 'flex';
    renderAdminLoadingState();
    await loadData();
    await activateAdminRoute(route && route.screen ? route : { screen: 'admin-dashboard', data: null, source: 'app' });
  }

  async function loadData() {
    const [
      jobs,
      electricians,
      payments,
      notifications,
      disputes,
      appeals
    ] = await Promise.all([
      Store.listAdminJobs({ includeProtectedAssets: false }),
      Store.listElectricians('all', { includeDocumentUrls: false }),
      Store.listPaymentsNeedingVerification(),
      Store.listNotifications(),
      Store.listDisputes(),
      Store.listAppeals(),
      Store.loadExpertiseCategories()
    ]);
    currentJobs = jobs || [];
    currentElectricians = electricians || [];
    currentPayments = payments || [];
    currentNotifications = notifications || [];
    currentDisputes = disputes || [];
    currentAppeals = appeals || [];
    clearLoginError();
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
    const actionSummary = [
      newBookingCount ? newBookingCount + ' new booking' + (newBookingCount === 1 ? '' : 's') : null,
      paymentVerificationCount ? paymentVerificationCount + ' payment' + (paymentVerificationCount === 1 ? '' : 's') + ' pending' : null,
      pendingElectricianCount
        ? pendingElectricianCount + ' electrician' + (pendingElectricianCount === 1 ? '' : 's') + ' pending approval'
        : null,
      manualAssignmentCount ? manualAssignmentCount + ' manual assignment' + (manualAssignmentCount === 1 ? '' : 's') : null
    ].filter(Boolean);

    if ($('#admin-action-banner')) {
      $('#admin-action-banner').textContent = actionSummary.length
        ? 'ACTION REQUIRED: ' + actionSummary.join(' • ')
        : 'ACTION REQUIRED: No urgent items right now';
    }

    $('#pending-count').textContent = String(alerts.length);
    $('#admin-pending-actions').innerHTML = alerts.length
      ? alerts.map((alert) => actionCardMarkup(alert)).join('')
      : emptyState('No urgent alerts right now.');
    $('#admin-pending-actions').querySelectorAll('.admin-pending-card').forEach((card) => {
      card.addEventListener('click', () => navigateTo(card.dataset.target));
    });

    const stats = {
      newBookings: newBookingCount,
      pendingElectricians: pendingElectricianCount,
      manualAssignments: manualAssignmentCount,
      paymentVerification: paymentVerificationCount
    };

    $('#admin-stats').innerHTML = [
      statCard('⚡', stats.newBookings, 'New bookings'),
      statCard('🧰', stats.pendingElectricians, 'Pending electricians'),
      statCard('🕒', stats.manualAssignments, 'Manual assignment'),
      statCard('💳', stats.paymentVerification, 'Payment verification')
    ].join('');

    $('#admin-control-queue').innerHTML = [
      queueCard('New bookings', newBookingCount, 'Review fresh requests and keep dispatch moving.', 'admin-requests'),
      queueCard('Pending electricians', pendingElectricianCount, 'Review onboarding and approve or reject electricians.', 'admin-electricians'),
      queueCard('Manual assignment', manualAssignmentCount, 'Assign or reassign jobs that need admin help.', 'admin-requests'),
      queueCard('Payment verification', paymentVerificationCount, 'Verify payment proofs before work moves forward.', 'admin-finance')
    ].join('');
    $('#admin-control-queue').querySelectorAll('.admin-queue-card').forEach((card) => {
      card.addEventListener('click', () => navigateTo(card.dataset.target));
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

  function renderRequests() {
    const jobs = currentJobs.filter((job) => {
      if (currentFilter.requests === 'matching') return job.status === 'matching' && !job.needsManualAssignment;
      if (currentFilter.requests === 'manual') return job.needsManualAssignment || !job.assignedElectricianId;
      if (currentFilter.requests === 'timeout') return hasTimeoutTimeline(job);
      if (currentFilter.requests === 'rejected') return hasRejectedTimeline(job);
      return job.status === 'matching' || job.status === 'assigned' || job.needsManualAssignment || hasRejectedTimeline(job) || hasTimeoutTimeline(job);
    });

    $('#requests-list').innerHTML = jobs.length ? jobs.map(dispatchJobCard).join('') : emptyState('No jobs in the dispatch queue.');
    bindJobCards('#requests-list', openRequestDetail);
    bindFilterTabs('#requests-filter-tabs', 'requests');
  }

  async function openRequestDetail(jobId) {
    selectedJob = await Store.getJob(jobId);
    const matches = await Store.previewMatches({
      serviceArea: selectedJob.serviceArea,
      issueCategory: selectedJob.issueCategory,
      latitude: selectedJob.latitude,
      longitude: selectedJob.longitude,
      limit: 8
    });

    $('#request-detail-body').innerHTML =
      infoCard('Customer', [
        ['Ticket', selectedJob.ticket],
        ['Customer', selectedJob.customer && selectedJob.customer.name ? selectedJob.customer.name : '--'],
        ['Phone', selectedJob.customer && selectedJob.customer.phone ? selectedJob.customer.phone : '--'],
        ['Area', selectedJob.serviceArea],
        ['Issue type', humanizeIssue(selectedJob.issueCategory)],
        ['Urgency', humanizeUrgency(selectedJob.urgency)]
      ]) +
      infoCard('Dispatch status', [
        ['Job status', selectedJob.statusLabel],
        ['Assigned electrician', selectedJob.assignedElectrician ? selectedJob.assignedElectrician.name : 'Unassigned'],
        ['Matching note', nextAction(selectedJob)],
        ['Dispatch attempts', String(selectedJob.dispatchAttempts || 0)]
      ]) +
      photoCard(selectedJob.photos) +
      assignmentCard(matches, selectedJob) +
      timelineCard(selectedJob.timeline);

    bindAssignmentControls(selectedJob);
    navigateTo('admin-request-detail', {
      routeData: { ticket: selectedJob.ticket }
    });
  }

  function renderElectricians() {
    const statusFilters = ['pending', 'approved', 'rejected', 'suspended'];
    const rows = currentElectricians.filter((electrician) => statusFilters.includes(currentFilter.electricians) ? electrician.status === currentFilter.electricians : true);
    const filteredRows = rows.filter((electrician) => {
      if (currentFilter.electricians === 'active') return electricianHasActiveJob(electrician);
      if (currentFilter.electricians === 'idle') return electrician.status === 'approved' && electrician.availability_status === 'available' && !electricianHasActiveJob(electrician);
      if (currentFilter.electricians === 'offline') return electrician.availability_status !== 'available';
      if (currentFilter.electricians === 'watchlist') return !!electrician.watchlist;
      return true;
    });
    $('#elec-list').innerHTML = filteredRows.length ? filteredRows.map(electricianCard).join('') : emptyState('No electricians in this view.');
    $('#elec-list').querySelectorAll('.admin-job-card').forEach((card) => {
      card.addEventListener('click', () => openElectricianDetail(card.dataset.elecId));
    });
    bindFilterTabs('#elec-filter-tabs', 'electricians');
  }

  function renderDisputes() {
    $('#disputes-list').innerHTML = currentDisputes.length ? currentDisputes.map((dispute) => {
      const job = dispute.jobs || {};
      const customerName = dispute.customer && dispute.customer.profile ? dispute.customer.profile.full_name : 'Customer';
      const electricianName = dispute.electrician && dispute.electrician.profile ? dispute.electrician.profile.full_name : 'Unassigned';
      return '<div class="admin-job-card" data-dispute-id="' + dispute.id + '" data-job-id="' + escapeAttribute(dispute.job_id) + '">' +
        cardHeader(dispute.issue_type || 'Dispute', dispute.status || 'open', dispute.status === 'open' ? 'status-rejected' : 'status-completed') +
        cardMetaRow((job.ticket || 'Job') + ' · ' + (job.service_area || '--')) +
        cardMetaRow('Customer: ' + customerName) +
        cardMetaRow('Electrician: ' + electricianName) +
        '<div class="admin-dispute-copy">' + escapeHtml(dispute.details || 'No extra details added.') + '</div>' +
        '<div class="admin-action-row">' +
          '<button class="btn-secondary btn-full" data-dispute-action="refund" data-dispute-id="' + dispute.id + '">Mark Refund Review</button>' +
          '<button class="btn-secondary btn-full" data-dispute-action="penalize" data-dispute-id="' + dispute.id + '">Penalize Electrician</button>' +
          '<button class="btn-primary btn-full" data-dispute-action="resolve" data-dispute-id="' + dispute.id + '">Resolve</button>' +
        '</div>' +
      '</div>';
    }).join('') : emptyState('No disputes have been raised.');

    $('#disputes-list').querySelectorAll('[data-dispute-action]').forEach((button) => {
      button.addEventListener('click', async (event) => {
        event.stopPropagation();
        const action = button.dataset.disputeAction;
        const note = action === 'refund'
          ? 'Customer refund requires manual follow-up.'
          : action === 'penalize'
            ? 'Electrician performance penalty recorded for review.'
            : 'Dispute resolved by admin.';
        await resolveDisputeAction(button.dataset.disputeId, action === 'resolve' ? 'resolved' : 'under_review', action, note);
      });
    });

    $('#disputes-list').querySelectorAll('.admin-job-card').forEach((card) => {
      card.addEventListener('click', async () => {
        await openJobDetail(card.dataset.jobId);
      });
    });
  }

  function renderTrust() {
    const openAppeals = currentAppeals.filter((appeal) => appeal.status === 'open');
    const watchlisted = currentElectricians.filter((electrician) => electrician.watchlist);
    const poorPerformance = currentElectricians.filter((electrician) => Number(electrician.negative_rating_count || 0) > 0 || Number(electrician.average_rating || 5) < 3.5);

    $('#appeals-list').innerHTML = openAppeals.length ? openAppeals.map(appealCard).join('') : emptyState('No open appeals right now.');
    $('#watchlist-list').innerHTML = watchlisted.length ? watchlisted.map(electricianCard).join('') : emptyState('No VoltFriqs are on watchlist.');
    $('#quality-list').innerHTML = poorPerformance.length ? poorPerformance.map(electricianCard).join('') : emptyState('No poor performance cases right now.');

    $('#appeals-list').querySelectorAll('[data-appeal-action]').forEach((button) => {
      button.addEventListener('click', async (event) => {
        event.stopPropagation();
        const approved = button.dataset.appealAction === 'approve';
        const note = approved
          ? 'Appeal approved. VoltFriq restored on watchlist.'
          : 'Appeal rejected after admin review.';
        await withButtonLoading(button.id, approved ? 'Approving...' : 'Rejecting...', async () => {
          await Store.resolveElectricianAppeal(button.dataset.appealId, approved, note);
          await loadData();
          renderTrust();
        });
      });
    });

    $('#appeals-list').querySelectorAll('.admin-job-card[data-elec-id]').forEach((card) => {
      card.addEventListener('click', () => openElectricianDetail(card.dataset.elecId));
    });
    $('#watchlist-list').querySelectorAll('.admin-job-card').forEach((card) => {
      card.addEventListener('click', () => openElectricianDetail(card.dataset.elecId));
    });
    $('#quality-list').querySelectorAll('.admin-job-card').forEach((card) => {
      card.addEventListener('click', () => openElectricianDetail(card.dataset.elecId));
    });
  }

  async function openElectricianDetail(electricianId) {
    selectedElectrician = currentElectricians.find((electrician) => electrician.id === electricianId);
    if (!selectedElectrician) return;
    await Store.hydrateElectricianDocuments(selectedElectrician).catch(() => selectedElectrician);

    const docs = (selectedElectrician.electrician_documents || []).map((documentItem) => {
      const href = documentItem.signedUrl || '';
      const link = href ? '<a class="admin-inline-link" href="' + escapeAttribute(href) + '" target="_blank" rel="noreferrer">View file</a>' : 'No file';
      return '<div class="admin-file-row"><div><div class="admin-file-name">' + escapeHtml(documentLabel(documentItem.document_type)) + '</div><div class="admin-file-meta">' + escapeHtml(documentItem.status || 'pending') + '</div></div><div>' + link + '</div></div>';
    }).join('') || '<div class="admin-empty-inline">No documents uploaded.</div>';
    const certifications = (selectedElectrician.electrician_certifications || []).length
      ? (selectedElectrician.electrician_certifications || []).map((certification) => {
          const pieces = [certification.title || 'Certification'];
          if (certification.issuer) pieces.push(certification.issuer);
          if (certification.license_number) pieces.push('License: ' + certification.license_number);
          return [pieces[0], pieces.slice(1).join(' · ') || 'Submitted during onboarding'];
        })
      : [['Certifications', 'No structured certifications submitted']];

    $('#elec-detail-body').innerHTML =
      infoCard('Electrician profile', [
        ['Name', selectedElectrician.profile && selectedElectrician.profile.full_name ? selectedElectrician.profile.full_name : 'VoltFriq'],
        ['Phone', selectedElectrician.profile && selectedElectrician.profile.phone ? selectedElectrician.profile.phone : '--'],
        ['Status', selectedElectrician.status],
        ['Level', selectedElectrician.level_badge || 'Verified Pro'],
        ['Watchlist', selectedElectrician.watchlist ? 'Yes' : 'No'],
        ['Negative ratings', String(selectedElectrician.negative_rating_count || 0)],
        ['Suspension reason', selectedElectrician.suspended_reason || '--'],
        ['Availability', selectedElectrician.availability_status || 'offline'],
        ['Experience', String(selectedElectrician.years_experience || 0) + ' years'],
        ['Service areas', (selectedElectrician.service_areas || []).join(', ') || '--'],
        ['Onboarding score', selectedElectrician.onboarding_score ? Number(selectedElectrician.onboarding_score).toFixed(0) + '%' : '--'],
        ['Onboarding review', selectedElectrician.onboarding_review_status || 'pending']
      ]) +
      infoCard('Trust history', electricianTrustRows(selectedElectrician)) +
      electricianActivityCard(selectedElectrician) +
      electricianAssignmentQueueCard(selectedElectrician) +
      appealsCard(selectedElectrician) +
      infoCard('Skills', (selectedElectrician.electrician_skills || []).length
        ? selectedElectrician.electrician_skills.map((skill) => [humanizeIssue(skill.category), 'Matched skill'])
        : [['Skills', 'No skills listed']]) +
      infoCard('Certifications', certifications) +
      '<div class="admin-info-card"><div class="admin-info-card-title">Documents</div>' + docs + '</div>' +
      electricianActionsCard(selectedElectrician);

    bindElectricianAction('btn-approve-elec', electricianId, 'approved');
    bindElectricianAction('btn-reject-elec', electricianId, 'rejected');
    bindElectricianAction('btn-suspend-elec', electricianId, 'suspended');
    bindWatchlistAction('btn-add-watchlist', electricianId, true);
    bindWatchlistAction('btn-remove-watchlist', electricianId, false);
    bindElectricianAssignmentQueue(electricianId);
    navigateTo('admin-elec-detail', {
      routeData: { electricianId: electricianId }
    });
  }

  function renderJobs() {
    const jobs = currentJobs.filter((job) => {
      if (currentFilter.jobs === 'matching') return job.status === 'matching';
      if (currentFilter.jobs === 'assigned') return job.status === 'assigned';
      if (currentFilter.jobs === 'accepted') return job.status === 'accepted';
      if (currentFilter.jobs === 'payment_pending_verification') return ['assessment_payment_pending_verification', 'work_payment_pending_verification'].includes(job.status);
      if (currentFilter.jobs === 'payment_confirmed') return job.status === 'payment_confirmed';
      if (currentFilter.jobs === 'in_progress') return ['en_route', 'on_site', 'work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending'].includes(job.status);
      if (currentFilter.jobs === 'completed') return isCompletedJob(job);
      if (currentFilter.jobs === 'cancelled') return job.status === 'cancelled';
      return true;
    });

    $('#jobs-list').innerHTML = jobs.length ? jobs.map(jobCard).join('') : emptyState('No jobs in this filter.');
    bindJobCards('#jobs-list', openJobDetail);
    bindFilterTabs('#jobs-filter-tabs', 'jobs');
  }

  async function openJobDetail(jobId) {
    selectedJob = await Store.getJob(jobId);
    $('#job-detail-title').textContent = selectedJob.ticket;
    $('#job-detail-body').innerHTML =
      infoCard('Job summary', [
        ['Status', selectedJob.statusLabel],
        ['Issue', humanizeIssue(selectedJob.issueCategory)],
        ['Urgency', humanizeUrgency(selectedJob.urgency)],
        ['Area', selectedJob.serviceArea],
        ['Description', selectedJob.description || 'No customer note']
      ]) +
      infoCard('People', [
        ['Customer', selectedJob.customer && selectedJob.customer.name ? selectedJob.customer.name : '--'],
        ['Customer phone', selectedJob.customer && selectedJob.customer.phone ? selectedJob.customer.phone : '--'],
        ['Electrician', selectedJob.assignedElectrician ? selectedJob.assignedElectrician.name : 'Unassigned'],
        ['Electrician phone', selectedJob.assignedElectrician ? selectedJob.assignedElectrician.phone : '--']
      ]) +
      infoCard('Customer behavior history', customerTrustRows(selectedJob.customer)) +
      infoCard('Customer request history', customerHistoryRows(selectedJob)) +
      infoCard('Two-sided reviews', reviewRows(selectedJob)) +
      photoCard(selectedJob.photos) +
      paymentVerificationCard(selectedJob) +
      payoutCard(selectedJob) +
      assignmentSummaryCard(selectedJob) +
      timelineCard(selectedJob.timeline) +
      '<div class="admin-chat-wrap"><div class="admin-chat-header">Job Chat</div><div id="admin-job-chat" class="chat-container" style="flex:1;min-height:0"></div></div>';

    bindPaymentButtons(selectedJob);
    bindPayoutButtons(selectedJob);
    bindQuickReassignButton(selectedJob);
    navigateTo('admin-job-detail', {
      routeData: { ticket: selectedJob.ticket }
    });
    await Chat.init('admin-job-chat', selectedJob.id, 'admin', (Store.getCurrentProfile() || {}).full_name || 'Admin');
  }

  async function renderFinance() {
    const payoutJobs = currentJobs.filter((job) => ['customer_confirmed', 'payout_pending'].includes(job.status));
    const completedJobs = currentJobs.filter(isCompletedJob);
    const totalRevenue = completedJobs.reduce((sum, job) => sum + Number((job.quote && job.quote.total) || 0), 0);

    $('#finance-summary').innerHTML =
      '<div class="admin-finance-summary">' +
        '<div class="admin-finance-label">Manual payment verification queue</div>' +
        '<div class="admin-finance-total">' + currentPayments.length + '</div>' +
        '<div class="admin-finance-row">' +
          '<div class="admin-finance-metric"><div class="admin-finance-metric-value">' + Store.formatCurrency(totalRevenue) + '</div><div class="admin-finance-metric-label">Completed revenue</div></div>' +
          '<div class="admin-finance-metric"><div class="admin-finance-metric-value">' + payoutJobs.length + '</div><div class="admin-finance-metric-label">Payouts waiting</div></div>' +
        '</div>' +
      '</div>';

    $('#finance-tx-list').innerHTML = currentPayments.length ? currentPayments.map(paymentCard).join('') : emptyState('No payments waiting for verification.');
    $('#finance-tx-list').querySelectorAll('.admin-tx-item').forEach((item) => {
      item.addEventListener('click', async () => {
        const payment = currentPayments.find((entry) => entry.id === item.dataset.paymentId);
        if (!payment) return;
        await openJobDetail(payment.job_id);
      });
    });

    $('#finance-payout-list').innerHTML = payoutJobs.length ? payoutJobs.map(payoutQueueCard).join('') : emptyState('No electrician payouts are waiting.');
    bindJobCards('#finance-payout-list', openJobDetail);
  }

  function renderMaterials() {
    const rows = currentJobs.filter((job) => job.quote && job.quote.items.some((item) => item.itemType === 'material'));
    $('#materials-list').innerHTML = rows.length ? rows.map((job) => {
      const materials = job.quote.items
        .filter((item) => item.itemType === 'material')
        .map((item) => '<div class="admin-material-item"><span>' + escapeHtml(item.description) + '</span><span>' + Store.formatCurrency(item.lineTotal || 0) + '</span></div>').join('');
      return '<div class="admin-material-card"><div class="admin-material-header"><div><div class="admin-material-job">' + escapeHtml(job.ticket) + '</div><div style="font-size:12px;color:var(--mid)">' + escapeHtml(job.serviceArea) + '</div></div></div><div class="admin-material-items">' + materials + '</div></div>';
    }).join('') : emptyState('No material requests yet.');
  }

  function renderChats() {
    $('#chats-list').innerHTML = currentJobs.length ? currentJobs.map((job) => {
      return '<div class="admin-chat-list-item" data-job-id="' + job.id + '">' +
        '<div class="admin-chat-list-avatar">💬</div>' +
        '<div class="admin-chat-list-info"><div class="admin-chat-list-name">' + escapeHtml(job.ticket) + '</div><div class="admin-chat-list-preview">' + escapeHtml(humanizeIssue(job.issueCategory)) + '</div></div>' +
        '<div class="admin-chat-list-meta"><div class="admin-chat-list-time">' + formatRelative(job.updatedAt) + '</div></div>' +
      '</div>';
    }).join('') : emptyState('No chats yet.');
    $('#chats-list').querySelectorAll('.admin-chat-list-item').forEach((item) => {
      item.addEventListener('click', async () => openJobDetail(item.dataset.jobId));
    });
  }

  function renderPrices() {
    const settings = Store.getSettings();
    const prices = settings.workmanship_prices || [];
    $('#price-list-container').innerHTML = prices.length ? prices.map((item, index) => {
      return '<div class="price-item">' +
        '<div class="price-item-info">' +
          '<div class="price-item-num">' + String(index + 1) + '</div>' +
          '<div class="price-item-details price-edit-grid" id="price-item-' + index + '">' +
            '<input class="form-input" data-price-field="issue" value="' + escapeAttribute(item.issue_type || item.service || '') + '" placeholder="Issue users can select" />' +
            '<input class="form-input" data-price-field="description" value="' + escapeAttribute(item.description || item.short_description || '') + '" placeholder="Short description" />' +
            '<input class="form-input" data-price-field="category" value="' + escapeAttribute(item.value || item.category || inferSkillCategory(item.issue_type || item.service || '')) + '" placeholder="Matching category" />' +
            '<div class="admin-price-range">' +
              '<input class="form-input" type="number" data-price-field="min" value="' + escapeAttribute(item.estimated_fee_min || item.price || item.amount || '') + '" placeholder="Min" />' +
              '<input class="form-input" type="number" data-price-field="max" value="' + escapeAttribute(item.estimated_fee_max || item.price_max || item.max_amount || '') + '" placeholder="Max" />' +
            '</div>' +
            '<div class="price-item-amount">' + escapeHtml(formatEstimateRange(item)) + '</div>' +
          '</div>' +
        '</div>' +
        '<div class="price-item-actions">' +
          '<button class="btn-secondary" id="btn-save-price-' + index + '" data-save-price="' + index + '">Save</button>' +
          '<button class="btn-icon" data-remove-price="' + index + '" aria-label="Remove estimate item">&times;</button>' +
        '</div>' +
      '</div>';
    }).join('') : emptyState('No workmanship prices published yet.');
    renderPriceCategoryOptions();
    const addButton = $('#btn-add-price');
    if (addButton) addButton.onclick = addPriceItem;
    $$('#price-list-container [data-save-price]').forEach((button) => {
      button.addEventListener('click', async () => {
        await withButtonLoading(button.id, 'Saving...', async () => updatePriceItem(Number(button.dataset.savePrice)));
      });
    });
    $$('#price-list-container [data-remove-price]').forEach((button) => {
      button.addEventListener('click', () => removePriceItem(Number(button.dataset.removePrice)));
    });
  }

  function renderSettings() {
    const settings = Store.getSettings();
    const trustSettings = settings.trust_settings || {};
    $('#settings-form').innerHTML =
      formField('Assessment Fee (₦)', '<input type="number" class="form-input" id="set-assessment-fee" value="' + Number(settings.assessment_fee || 0) + '" />') +
      formField('Platform Bank Name', '<input type="text" class="form-input" id="set-bank-name" value="' + escapeAttribute(settings.platform_bank_name || '') + '" />') +
      formField('Platform Account Number', '<input type="text" class="form-input" id="set-account-number" value="' + escapeAttribute(settings.platform_account_number || '') + '" />') +
      formField('Platform Account Name', '<input type="text" class="form-input" id="set-account-name" value="' + escapeAttribute(settings.platform_account_name || '') + '" />') +
      formField('Service Areas', '<textarea class="form-input" rows="3" id="set-service-areas">' + escapeHtml((settings.service_areas || []).join(', ')) + '</textarea>') +
      formField('Issue Categories', '<textarea class="form-input" rows="4" id="set-issue-categories">' + escapeHtml((settings.issue_categories || []).join(', ')) + '</textarea>') +
      formField('Negative Rating Limit', '<input type="number" class="form-input" id="set-negative-limit" value="' + Number(trustSettings.negative_rating_limit || 3) + '" />') +
      formField('Negative Rating Max Score', '<input type="number" class="form-input" id="set-negative-score" value="' + Number(trustSettings.negative_rating_max_score || 2) + '" />') +
      formField('Watchlist Rank Penalty (km)', '<input type="number" class="form-input" id="set-watchlist-penalty" value="' + Number(trustSettings.watchlist_rank_penalty_km || 8) + '" />') +
      '<button class="btn-primary btn-full" id="btn-save-settings">Save Settings</button>' +
      '<div style="margin-top:16px"><button class="btn-secondary btn-full" id="btn-open-expertise">Manage Expertise Categories</button></div>' +
      '<div style="margin-top:16px"><button class="btn-secondary btn-full" id="btn-open-prices">Manage Workmanship Prices</button></div>' +
      '<div style="margin-top:20px" class="admin-section-title">Advanced Operations</div>' +
      '<div style="display:grid;gap:12px;margin-top:12px">' +
        '<button class="btn-secondary btn-full" id="btn-open-jobs">All Jobs</button>' +
        '<button class="btn-secondary btn-full" id="btn-open-trust">Trust &amp; Appeals</button>' +
        '<button class="btn-secondary btn-full" id="btn-open-disputes">Disputes</button>' +
      '</div>' +
      '<div style="margin-top:16px"><button class="btn-ghost" id="btn-admin-logout" style="width:100%;color:var(--red)">Logout</button></div>';

    $('#btn-save-settings').addEventListener('click', saveSettings);
    $('#btn-open-expertise').addEventListener('click', async () => {
      navigateTo('admin-expertise');
      await renderExpertiseCategories();
    });
    $('#btn-open-prices').addEventListener('click', () => {
      navigateTo('admin-prices');
      renderPrices();
    });
    $('#btn-open-jobs').addEventListener('click', () => navigateTo('admin-jobs'));
    $('#btn-open-trust').addEventListener('click', () => navigateTo('admin-trust'));
    $('#btn-open-disputes').addEventListener('click', () => navigateTo('admin-disputes'));
    $('#btn-admin-logout').addEventListener('click', handleLogout);
  }

  async function saveSettings() {
    await withButtonLoading('btn-save-settings', 'Saving...', async () => {
      const trustSettings = Object.assign({}, Store.getSettings().trust_settings || {}, {
        negative_rating_limit: Number($('#set-negative-limit').value || 3),
        negative_rating_max_score: Number($('#set-negative-score').value || 2),
        watchlist_rank_penalty_km: Number($('#set-watchlist-penalty').value || 8)
      });
      await Store.saveSettings({
        assessment_fee: Number($('#set-assessment-fee').value || 0),
        platform_bank_name: $('#set-bank-name').value.trim(),
        platform_account_number: $('#set-account-number').value.trim(),
        platform_account_name: $('#set-account-name').value.trim(),
        service_areas: $('#set-service-areas').value.split(',').map((item) => item.trim()).filter(Boolean),
        issue_categories: $('#set-issue-categories').value.split(',').map((item) => item.trim()).filter(Boolean),
        trust_settings: trustSettings
      });
      await loadData();
      renderSettings();
    });
  }

  async function addPriceItem() {
    await withButtonLoading('btn-add-price', 'Adding...', async () => {
      const issueType = $('#new-price-service').value.trim();
      const description = $('#new-price-description').value.trim();
      const skillCategory = $('#new-price-category').value.trim();
      const min = Number($('#new-price-min').value || 0);
      const maxValue = $('#new-price-max').value ? Number($('#new-price-max').value) : null;
      if (!issueType) throw new Error('Enter the issue users can select.');
      if (!min || min < 0) throw new Error('Enter the estimated minimum workmanship fee.');
      if (maxValue && maxValue < min) throw new Error('Maximum estimate cannot be lower than minimum estimate.');

      const settings = Store.getSettings();
      const nextPrices = (settings.workmanship_prices || []).concat([{
        issue_type: issueType,
        service: issueType,
        description: description || 'Final cost may vary after inspection.',
        estimated_fee_min: min,
        estimated_fee_max: maxValue,
        value: skillCategory || inferSkillCategory(issueType),
        created_at: new Date().toISOString()
      }]);
      await Store.saveSettings({ workmanship_prices: nextPrices });
      await Store.loadSettings();
      $('#new-price-service').value = '';
      $('#new-price-description').value = '';
      $('#new-price-min').value = '';
      $('#new-price-max').value = '';
      renderPrices();
    });
  }

  async function updatePriceItem(index) {
    const settings = Store.getSettings();
    const prices = (settings.workmanship_prices || []).slice();
    const row = $('#price-item-' + index);
    if (!row || !prices[index]) return;

    const issueType = row.querySelector('[data-price-field="issue"]').value.trim();
    const description = row.querySelector('[data-price-field="description"]').value.trim();
    const skillCategory = row.querySelector('[data-price-field="category"]').value.trim();
    const min = Number(row.querySelector('[data-price-field="min"]').value || 0);
    const maxInput = row.querySelector('[data-price-field="max"]').value;
    const maxValue = maxInput ? Number(maxInput) : null;
    if (!issueType) throw new Error('Enter the issue users can select.');
    if (!min || min < 0) throw new Error('Enter the estimated minimum workmanship fee.');
    if (maxValue && maxValue < min) throw new Error('Maximum estimate cannot be lower than minimum estimate.');

    prices[index] = Object.assign({}, prices[index], {
      issue_type: issueType,
      service: issueType,
      description: description || 'Final cost may vary after inspection.',
      estimated_fee_min: min,
      estimated_fee_max: maxValue,
      value: skillCategory || inferSkillCategory(issueType),
      updated_at: new Date().toISOString()
    });
    await Store.saveSettings({ workmanship_prices: prices });
    await Store.loadSettings();
    renderPrices();
  }

  async function removePriceItem(index) {
    const settings = Store.getSettings();
    const nextPrices = (settings.workmanship_prices || []).filter((_, itemIndex) => itemIndex !== index);
    await Store.saveSettings({ workmanship_prices: nextPrices });
    await Store.loadSettings();
    renderPrices();
  }

  async function renderExpertiseCategories() {
    const categories = Store.getExpertiseCategories();
    $('#expertise-list-container').innerHTML = categories.length ? categories.map((label, index) => {
      return '<div class="price-item">' +
        '<div class="price-item-info">' +
          '<div class="price-item-num">' + String(index + 1) + '</div>' +
          '<div class="price-item-details"><input class="form-input expertise-inline-input" data-expertise-input="' + escapeAttribute(label) + '" value="' + escapeAttribute(label) + '" /></div>' +
        '</div>' +
        '<div class="price-item-actions">' +
          '<button class="btn-icon" id="save-expertise-' + slugify(label) + '" data-save-expertise="' + escapeAttribute(label) + '" aria-label="Save category">✓</button>' +
          '<button class="btn-icon" data-remove-expertise="' + escapeAttribute(label) + '" aria-label="Remove category">&times;</button>' +
        '</div>' +
      '</div>';
    }).join('') : emptyState('No expertise categories added yet.');
    const addButton = $('#btn-add-expertise-category');
    if (addButton) addButton.onclick = addExpertiseCategory;
    $$('#expertise-list-container [data-save-expertise]').forEach((button) => {
      button.onclick = async () => {
        const currentLabel = button.dataset.saveExpertise;
        const input = button.closest('.price-item').querySelector('[data-expertise-input]');
        await withButtonLoading(button.id, '...', async () => {
          await Store.saveExpertiseCategory(input.value.trim(), currentLabel);
          await Store.loadSettings();
          await Store.loadExpertiseCategories();
          await renderExpertiseCategories();
        });
      };
    });
    $$('#expertise-list-container [data-remove-expertise]').forEach((button) => {
      button.onclick = async () => {
        await Store.removeExpertiseCategory(button.dataset.removeExpertise);
        await Store.loadSettings();
        await renderExpertiseCategories();
      };
    });
  }

  async function addExpertiseCategory() {
    await withButtonLoading('btn-add-expertise-category', 'Adding...', async () => {
      await Store.saveExpertiseCategory($('#new-expertise-category').value.trim());
      $('#new-expertise-category').value = '';
      await Store.loadSettings();
      await renderExpertiseCategories();
    });
  }

  function renderPriceCategoryOptions() {
    const select = $('#new-price-category');
    if (!select) return;
    const settings = Store.getSettings();
    const categories = Array.from(new Set([
      'Socket repair',
      'Light fitting',
      'Wiring issue',
      'Tripped breaker',
      'General Installation',
      'Inverter',
      'Generator',
      'Other'
    ].concat(Store.getExpertiseCategories ? Store.getExpertiseCategories() : [], settings.issue_categories || [])));
    select.innerHTML = categories.map((category) => '<option value="' + escapeAttribute(category) + '">' + escapeHtml(humanizeIssue(category)) + '</option>').join('');
  }

  function formatEstimateRange(item) {
    const min = Number(item.estimated_fee_min || item.price || item.amount || 0);
    const max = Number(item.estimated_fee_max || item.price_max || item.max_amount || 0);
    if (min && max && min !== max) return Store.formatCurrency(min) + ' - ' + Store.formatCurrency(max);
    if (min) return Store.formatCurrency(min) + (max ? '' : '+');
    return 'Quote after review';
  }

  function inferSkillCategory(issueType) {
    const text = String(issueType || '').toLowerCase();
    if (text.includes('socket') || text.includes('switch')) return 'Socket repair';
    if (text.includes('light')) return 'Light fitting';
    if (text.includes('wire') || text.includes('wiring')) return 'Wiring issue';
    if (text.includes('breaker') || text.includes('fuse')) return 'Tripped breaker';
    if (text.includes('solar') || text.includes('inverter')) return 'Inverter';
    if (text.includes('generator')) return 'Generator';
    if (text.includes('inspection') || text.includes('install')) return 'General Installation';
    return 'Other';
  }

  async function handleLogout() {
    await Store.signOut();
    window.location.href = '/admin/login';
  }

  function bindFilterTabs(selector, key) {
    $$(selector + ' .admin-filter-tab').forEach((tab) => {
      tab.onclick = () => {
        $$(selector + ' .admin-filter-tab').forEach((item) => item.classList.remove('active'));
        tab.classList.add('active');
        currentFilter[key] = tab.dataset.filter;
        refreshScreen(tab.closest('.screen').id.replace('screen-', ''));
      };
    });
  }

  function bindJobCards(containerSelector, handler) {
    $(containerSelector).querySelectorAll('.admin-job-card').forEach((card) => {
      card.addEventListener('click', () => handler(card.dataset.jobId));
    });
  }

  function dispatchJobCard(job) {
    return '<div class="admin-job-card" data-job-id="' + job.id + '">' +
      cardHeader(humanizeIssue(job.issueCategory), job.statusLabel, statusClass(job.status)) +
      cardMetaRow(job.ticket + ' · ' + (job.customer && job.customer.name ? job.customer.name : 'Customer')) +
      cardMetaRow('Area: ' + job.serviceArea) +
      cardMetaRow('Assigned: ' + (job.assignedElectrician ? job.assignedElectrician.name : 'Unassigned')) +
      cardMetaRow('Alert: ' + nextAction(job)) +
      cardFooter(formatRelative(job.updatedAt), hasTimeoutTimeline(job) ? 'Timeout' : hasRejectedTimeline(job) ? 'Rejected' : job.needsManualAssignment ? 'Manual override' : 'Matching') +
    '</div>';
  }

  function jobCard(job) {
    return '<div class="admin-job-card" data-job-id="' + job.id + '">' +
      cardHeader(humanizeIssue(job.issueCategory), job.statusLabel, statusClass(job.status)) +
      cardMetaRow(job.ticket + ' · ' + job.serviceArea) +
      cardMetaRow('Customer: ' + (job.customer && job.customer.name ? job.customer.name : '--')) +
      cardMetaRow('Electrician: ' + (job.assignedElectrician ? job.assignedElectrician.name : 'Unassigned')) +
      cardMetaRow('Payment: ' + (job.latestPayment ? job.latestPayment.statusLabel : 'No proof yet')) +
      cardFooter(Store.formatCurrency((job.quote && job.quote.total) || 0), humanizeUrgency(job.urgency)) +
    '</div>';
  }

  function electricianHasActiveJob(electrician) {
    if (!electrician) return false;
    return currentJobs.some((job) => job.assignedElectricianId === electrician.id && !['rated', 'cancelled', 'payout_complete'].includes(job.status));
  }

  function electricianActiveJobs(electrician) {
    if (!electrician) return [];
    return currentJobs
      .filter((job) => job.assignedElectricianId === electrician.id)
      .sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt));
  }

  function electricianAssignableJobs() {
    return currentJobs
      .filter((job) => !['rated', 'cancelled', 'payout_complete'].includes(job.status))
      .filter((job) => job.status === 'matching' || job.status === 'assigned' || !job.assignedElectricianId || job.needsManualAssignment)
      .sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt));
  }

  function electricianCard(electrician) {
    const activeJobs = electricianActiveJobs(electrician).filter((job) => !['rated', 'cancelled', 'payout_complete'].includes(job.status));
    const liveState = activeJobs.length ? 'Active on ' + activeJobs.length + ' job' + (activeJobs.length === 1 ? '' : 's') : (electrician.availability_status === 'available' ? 'Idle and available' : 'Offline or paused');
    return '<div class="admin-job-card" data-elec-id="' + electrician.id + '">' +
      cardHeader((electrician.profile && electrician.profile.full_name) || 'VoltFriq', electrician.status, statusClass(electrician.status)) +
      cardMetaRow((electrician.service_areas || []).join(', ') || 'No service area selected') +
      cardMetaRow('Availability: ' + (electrician.availability_status || 'offline') + ' · ' + liveState) +
      cardMetaRow('Level: ' + (electrician.level_badge || 'Verified Pro') + (electrician.watchlist ? ' · Watchlist' : '')) +
      cardMetaRow('Negative ratings: ' + String(electrician.negative_rating_count || 0)) +
      cardMetaRow('Last offered: ' + (electrician.last_offered_at ? formatRelative(electrician.last_offered_at) : 'Never')) +
      cardMetaRow('Skills: ' + ((electrician.electrician_skills || []).map((skill) => humanizeIssue(skill.category)).join(', ') || 'None yet')) +
      cardFooter(String(electrician.completed_jobs || 0) + ' completed jobs', '★ ' + (electrician.average_rating ? Number(electrician.average_rating).toFixed(1) : '--')) +
    '</div>';
  }

  function paymentCard(payment) {
    return '<div class="admin-tx-item" data-payment-id="' + payment.id + '">' +
      '<div class="admin-tx-icon payment">💳</div>' +
      '<div class="admin-tx-info"><div class="admin-tx-desc">' + escapeHtml(payment.payment_type || 'Payment proof') + '</div><div class="admin-tx-date">' + escapeHtml(payment.reference || 'No reference') + '</div></div>' +
      '<div class="admin-tx-amount credit">' + Store.formatCurrency(payment.amount || 0) + '</div>' +
    '</div>';
  }

  function payoutQueueCard(job) {
    return '<div class="admin-job-card" data-job-id="' + job.id + '">' +
      cardHeader(job.ticket, job.statusLabel, statusClass(job.status)) +
      cardMetaRow('Electrician: ' + (job.assignedElectrician ? job.assignedElectrician.name : 'Unassigned')) +
      cardMetaRow('Customer: ' + (job.customer && job.customer.name ? job.customer.name : '--')) +
      cardFooter(Store.formatCurrency((job.quote && job.quote.total) || 0), 'Release payout') +
    '</div>';
  }

  function assignmentCard(matches, job) {
    const pools = buildDispatchPools(job, matches);
    return '<div class="admin-assign-section">' +
      '<div class="admin-assign-title">Dispatch Control</div>' +
      '<div class="admin-assign-copy">Automatic dispatch is the default. Admin can rerun matching, reassign to another approved available VoltFriq, or force deploy an override choice.</div>' +
      dispatchPoolSection('Recommended matches', 'Best fit by issue, location, urgency, and response performance.', pools.recommended, 'recommended') +
      dispatchPoolSection('Approved & available', 'Approved VoltFriqs who are available now even if they were not top-ranked.', pools.available, 'available') +
      dispatchPoolSection('Admin override', 'Approved VoltFriqs outside the recommended pool or currently off-policy. Use only when manual judgment is required.', pools.override, 'override') +
      '<div class="admin-action-row">' +
        '<button class="btn-secondary btn-full" id="btn-admin-auto-assign">Assign next available</button>' +
        '<button class="btn-primary btn-full" id="btn-admin-assign">' + (job.assignedElectrician ? 'Reassign selected VoltFriq' : 'Assign selected VoltFriq') + '</button>' +
        '<button class="btn-secondary btn-full" id="btn-admin-force-assign">Force deploy selected</button>' +
      '</div>' +
    '</div>';
  }

  function buildDispatchPools(job, matches) {
    const recommended = (matches || []).map((match) => ({
      id: match.id,
      name: match.name,
      levelBadge: match.levelBadge || 'Verified Pro',
      rating: match.rating,
      jobsCompleted: match.jobsCompleted,
      distance: match.distance,
      availability: 'available',
      watchlist: !!match.watchlist,
      pool: 'recommended'
    }));

    const recommendedIds = new Set(recommended.map((item) => item.id));
    const approved = currentElectricians.filter((electrician) => electrician.status === 'approved');
    const available = approved
      .filter((electrician) => electrician.availability_status === 'available' && !recommendedIds.has(electrician.id))
      .map((electrician) => normalizeDispatchElectrician(electrician, 'available', job));
    const override = approved
      .filter((electrician) => electrician.availability_status !== 'available' || !serviceAreaMatch(electrician, job.serviceArea))
      .filter((electrician) => !recommendedIds.has(electrician.id))
      .map((electrician) => normalizeDispatchElectrician(electrician, 'override', job));

    return { recommended, available, override };
  }

  function normalizeDispatchElectrician(electrician, pool, job) {
    return {
      id: electrician.id,
      name: electrician.profile && electrician.profile.full_name ? electrician.profile.full_name : 'VoltFriq',
      levelBadge: electrician.level_badge || 'Verified Pro',
      rating: electrician.average_rating ? Number(electrician.average_rating) : 0,
      jobsCompleted: Number(electrician.completed_jobs || 0),
      distance: serviceAreaMatch(electrician, job.serviceArea) ? 'In area' : 'Override',
      availability: electrician.availability_status || 'offline',
      watchlist: !!electrician.watchlist,
      pool
    };
  }

  function serviceAreaMatch(electrician, serviceArea) {
    const areas = electrician.service_areas || [];
    return areas.some((area) => String(area || '').toLowerCase() === String(serviceArea || '').toLowerCase());
  }

  function dispatchPoolSection(title, copy, items, pool) {
    return '<div class="admin-dispatch-group">' +
      '<div class="admin-dispatch-group-title">' + escapeHtml(title) + '</div>' +
      '<div class="admin-dispatch-group-copy">' + escapeHtml(copy) + '</div>' +
      (items.length
        ? items.map((item, index) => {
            return '<div class="admin-elec-option' + (index === 0 && pool === 'recommended' ? ' selected' : '') + '" data-elec-id="' + escapeAttribute(item.id) + '" data-pool="' + escapeAttribute(pool) + '">' +
              '<div class="admin-elec-avatar">⚡</div>' +
              '<div class="admin-elec-info">' +
                '<div class="admin-elec-name">' + escapeHtml(item.name) + '</div>' +
                '<div class="admin-elec-meta">' +
                  '<span>' + escapeHtml(item.levelBadge || 'Verified Pro') + '</span>' +
                  '<span>★ ' + escapeHtml(item.rating ? item.rating.toFixed(1) : '--') + '</span>' +
                  '<span>' + escapeHtml(String(item.jobsCompleted || 0)) + ' jobs</span>' +
                  '<span>' + escapeHtml(item.distance || '--') + '</span>' +
                  '<span>' + escapeHtml(item.availability || 'offline') + '</span>' +
                  (item.watchlist ? '<span>Watchlist</span>' : '') +
                '</div>' +
              '</div>' +
            '</div>';
          }).join('')
        : '<div class="admin-empty-inline">No VoltFriqs in this group right now.</div>') +
    '</div>';
  }

  function paymentVerificationCard(job) {
    const payment = job.latestPayment;
    if (!payment) {
      return infoCard('Payment verification', [['Latest proof', 'No payment proof submitted yet']]);
    }
    const proofUrl = payment.proofUrl || '';
    const proofMarkup = proofUrl
      ? '<a class="admin-inline-link" href="' + escapeAttribute(proofUrl) + '" target="_blank" rel="noreferrer">Open payment proof</a>'
      : 'No proof file uploaded';

    return '<div class="admin-info-card">' +
      '<div class="admin-info-card-title">Payment verification</div>' +
      adminInfoRow('Type', payment.payment_type) +
      adminInfoRow('Amount', Store.formatCurrency(payment.amount || 0)) +
      adminInfoRow('Status', payment.statusLabel || Store.getPaymentStatusLabel(payment.status)) +
      adminInfoRow('Reference', payment.reference || 'N/A') +
      adminInfoRow('Proof', proofMarkup, true) +
      (payment.status === 'submitted'
        ? '<div class="admin-action-row"><button class="btn-primary btn-full" id="btn-verify-payment" data-payment-id="' + payment.id + '">Approve Payment</button><button class="btn-secondary btn-full" id="btn-reject-payment" data-payment-id="' + payment.id + '">Reject Payment</button></div>'
        : '') +
    '</div>';
  }

  function payoutCard(job) {
    if (!['customer_confirmed', 'payout_pending'].includes(job.status)) return '';
    return '<div class="admin-info-card">' +
      '<div class="admin-info-card-title">Payout management</div>' +
      adminInfoRow('Status', job.statusLabel) +
      adminInfoRow('Electrician', job.assignedElectrician ? job.assignedElectrician.name : 'Unassigned') +
      adminInfoRow('Amount', Store.formatCurrency((job.quote && job.quote.total) || 0)) +
      '<button class="btn-primary btn-full" id="btn-release-payout">Mark payout as paid</button>' +
    '</div>';
  }

  function assignmentSummaryCard(job) {
    return '<div class="admin-info-card">' +
      '<div class="admin-info-card-title">Dispatch control</div>' +
      adminInfoRow('Current action', nextAction(job)) +
      adminInfoRow('Dispatch attempts', String(job.dispatchAttempts || 0)) +
      adminInfoRow('Assigned electrician', job.assignedElectrician ? job.assignedElectrician.name : 'None') +
      '<button class="btn-secondary btn-full" id="btn-open-reassign" style="margin-top:12px">Open dispatch override</button>' +
    '</div>';
  }

  function electricianActivityCard(electrician) {
    const jobs = electricianActiveJobs(electrician);
    const activeJobs = jobs.filter((job) => !['rated', 'cancelled', 'payout_complete'].includes(job.status));
    const rows = activeJobs.length
      ? activeJobs.slice(0, 6).map((job) => {
          return adminInfoRow(job.ticket, humanizeIssue(job.issueCategory) + ' · ' + job.statusLabel + ' · ' + formatRelative(job.updatedAt));
        }).join('')
      : '<div class="admin-empty-inline">No active job right now. This VoltFriq is idle if availability is set to available.</div>';
    return '<div class="admin-info-card">' +
      '<div class="admin-info-card-title">Live activity</div>' +
      adminInfoRow('Current state', activeJobs.length ? 'Active' : (electrician.availability_status === 'available' ? 'Idle' : 'Offline')) +
      adminInfoRow('Active jobs', String(activeJobs.length)) +
      rows +
    '</div>';
  }

  function electricianAssignmentQueueCard(electrician) {
    if (electrician.status !== 'approved') {
      return '<div class="admin-info-card"><div class="admin-info-card-title">Assign jobs</div><div class="admin-empty-inline">Approve this VoltFriq before assigning jobs.</div></div>';
    }
    const jobs = electricianAssignableJobs().filter((job) => job.assignedElectricianId !== electrician.id).slice(0, 6);
    return '<div class="admin-info-card">' +
      '<div class="admin-info-card-title">Assign or reassign jobs</div>' +
      (jobs.length
        ? jobs.map((job) => '<div class="admin-job-mini">' +
            '<div><strong>' + escapeHtml(job.ticket) + '</strong><span>' + escapeHtml(humanizeIssue(job.issueCategory) + ' · ' + job.serviceArea + ' · ' + (job.assignedElectrician ? 'Assigned to ' + job.assignedElectrician.name : 'Unassigned')) + '</span></div>' +
            '<button class="btn-secondary" type="button" id="btn-assign-' + job.id + '" data-assign-job="' + escapeAttribute(job.id) + '">Assign</button>' +
          '</div>').join('')
        : '<div class="admin-empty-inline">No matching or unassigned jobs are waiting right now.</div>') +
    '</div>';
  }

  function bindElectricianAssignmentQueue(electricianId) {
    document.querySelectorAll('[data-assign-job]').forEach((button) => {
      button.addEventListener('click', async () => {
        await withButtonLoading(button.id, 'Assigning...', async () => {
          await Store.setManualAssignment(button.dataset.assignJob, electricianId);
          await loadData();
          await openElectricianDetail(electricianId);
        });
      });
    });
  }

  function photoCard(photos) {
    return '<div class="admin-info-card"><div class="admin-info-card-title">Uploaded photos</div>' +
      ((photos || []).length
        ? '<div class="admin-photo-grid">' + photos.map((photo, index) => {
            return photo.url
              ? '<a class="admin-photo-link" href="' + escapeAttribute(photo.url) + '" target="_blank" rel="noreferrer"><img class="admin-photo-thumb" src="' + escapeAttribute(photo.url) + '" alt="Job photo ' + (index + 1) + '" loading="lazy" /></a>'
              : '<div class="admin-photo-box">🖼️</div>';
          }).join('') + '</div>'
        : '<div class="admin-empty-inline">No photos were uploaded for this job.</div>') +
    '</div>';
  }

  function timelineCard(timeline) {
    return '<div class="admin-info-card"><div class="admin-info-card-title">Job timeline</div><div class="admin-timeline">' +
      (timeline || []).map((entry) => '<div class="admin-timeline-item"><div class="admin-timeline-dot">•</div><div class="admin-timeline-content"><div class="admin-timeline-title">' + escapeHtml(Store.getStatusLabel(entry.status)) + '</div><div class="admin-feed-text">' + escapeHtml(entry.note || 'No note recorded.') + '</div><div class="admin-timeline-time">' + formatRelative(entry.created_at || entry.timestamp) + '</div></div></div>').join('') +
    '</div></div>';
  }

  function electricianActionsCard(electrician) {
    const buttons = [];
    if (electrician.status === 'pending') {
      buttons.push('<button class="btn-primary btn-full" id="btn-approve-elec">Approve electrician</button>');
      buttons.push('<button class="btn-secondary btn-full" id="btn-reject-elec">Reject electrician</button>');
    }
    if (electrician.status === 'approved') {
      buttons.push('<button class="btn-secondary btn-full" id="btn-suspend-elec">Suspend electrician</button>');
    }
    if (electrician.status === 'rejected' || electrician.status === 'suspended') {
      buttons.push('<button class="btn-primary btn-full" id="btn-approve-elec">Approve electrician</button>');
    }
    if (electrician.status === 'approved' && !electrician.watchlist) {
      buttons.push('<button class="btn-secondary btn-full" id="btn-add-watchlist">Add to watchlist</button>');
    }
    if (electrician.watchlist) {
      buttons.push('<button class="btn-primary btn-full" id="btn-remove-watchlist">Remove watchlist</button>');
    }
    return '<div class="admin-info-card"><div class="admin-info-card-title">Admin actions</div><div class="admin-action-row">' + buttons.join('') + '</div></div>';
  }

  function appealCard(appeal) {
    const electrician = appeal.electrician || {};
    const name = electrician.profile && electrician.profile.full_name ? electrician.profile.full_name : 'VoltFriq';
    const approveId = 'btn-appeal-approve-' + appeal.id;
    const rejectId = 'btn-appeal-reject-' + appeal.id;
    return '<div class="admin-job-card" data-elec-id="' + escapeAttribute(appeal.electrician_id) + '">' +
      cardHeader(name, appeal.status, appeal.status === 'open' ? 'status-payment' : 'status-completed') +
      cardMetaRow('Submitted: ' + formatRelative(appeal.created_at)) +
      cardMetaRow('Negative ratings: ' + String(electrician.negative_rating_count || 0)) +
      '<div class="admin-dispute-copy">' + escapeHtml(appeal.appeal_note || 'No appeal note.') + '</div>' +
      '<div class="admin-action-row">' +
        '<button class="btn-primary btn-full" id="' + approveId + '" data-appeal-action="approve" data-appeal-id="' + appeal.id + '">Approve Appeal</button>' +
        '<button class="btn-secondary btn-full" id="' + rejectId + '" data-appeal-action="reject" data-appeal-id="' + appeal.id + '">Reject Appeal</button>' +
      '</div>' +
    '</div>';
  }

  function appealsCard(electrician) {
    const appeals = currentAppeals.filter((appeal) => appeal.electrician_id === electrician.id);
    return '<div class="admin-info-card"><div class="admin-info-card-title">Appeals</div>' +
      (appeals.length
        ? appeals.slice(0, 5).map((appeal) => adminInfoRow(formatRelative(appeal.created_at), (appeal.status || 'open') + ' - ' + (appeal.admin_note || appeal.appeal_note || 'No note'))).join('')
        : '<div class="admin-empty-inline">No appeals submitted.</div>') +
    '</div>';
  }

  function electricianTrustRows(electrician) {
    return [
      ['Average rating', electrician.average_rating ? Number(electrician.average_rating).toFixed(1) + '/5' : '--'],
      ['Total ratings', String(electrician.total_ratings || 0)],
      ['Response rate', String(Math.round(Number(electrician.response_rate || 0))) + '%'],
      ['Completed jobs', String(electrician.completed_jobs || 0)],
      ['Negative ratings', String(electrician.negative_rating_count || 0)],
      ['Watchlist reason', electrician.watchlist_reason || '--']
    ];
  }

  function customerTrustRows(customer) {
    const trust = customer && customer.trustSummary ? customer.trustSummary : {};
    return [
      ['Behavior rating', trust.totalBehaviorRatings ? Number(trust.averageBehaviorRating || 0).toFixed(1) + '/5' : 'New customer'],
      ['Completed requests', String(trust.completedRequests || 0)],
      ['Trust status', trust.status || 'clear'],
      ['Disputes raised', String(trust.disputeCount || 0)],
      ['Payment issues', String(trust.paymentIssueCount || 0)],
      ['No-show reports', String(trust.noShowReports || 0)]
    ];
  }

  function customerHistoryRows(job) {
    if (!job || !job.customer) return [['History', 'No customer history available']];
    const jobs = currentJobs
      .filter((entry) => entry.customerId === job.customer.id)
      .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
    if (!jobs.length) return [['History', 'No previous requests found']];
    return [
      ['Total requests', String(jobs.length)],
      ['Completed', String(jobs.filter(isCompletedJob).length)],
      ['Cancelled', String(jobs.filter((entry) => entry.status === 'cancelled').length)],
      ['Latest issue', humanizeIssue(jobs[0].issueCategory) + ' - ' + jobs[0].statusLabel]
    ];
  }

  function reviewRows(job) {
    return [
      ['Customer to VoltFriq', job.electricianReview ? (job.electricianReview.score + '/5 - ' + (job.electricianReview.comment || 'No comment')) : 'Not submitted'],
      ['VoltFriq to customer', job.customerReview ? (job.customerReview.score + '/5 - ' + (job.customerReview.comment || 'No comment')) : 'Not submitted']
    ];
  }

  function infoCard(title, rows) {
    return '<div class="admin-info-card"><div class="admin-info-card-title">' + escapeHtml(title) + '</div>' + rows.map((row) => adminInfoRow(row[0], row[1])).join('') + '</div>';
  }

  function adminInfoRow(label, value, allowHtml) {
    return '<div class="admin-info-row"><span class="admin-info-label">' + escapeHtml(label) + '</span><span class="admin-info-value">' + (allowHtml ? String(value || '') : escapeHtml(String(value || ''))) + '</span></div>';
  }

  function statCard(icon, value, label) {
    return '<div class="admin-stat"><div class="admin-stat-icon">' + icon + '</div><div class="admin-stat-value">' + escapeHtml(String(value || '0')) + '</div><div class="admin-stat-label">' + escapeHtml(label) + '</div></div>';
  }

  function queueCard(title, count, copy, target) {
    return '<div class="admin-queue-card" data-target="' + target + '"><div class="admin-queue-count">' + escapeHtml(String(count)) + '</div><div class="admin-queue-title">' + escapeHtml(title) + '</div><div class="admin-queue-copy">' + escapeHtml(copy) + '</div></div>';
  }

  function actionCardMarkup(item) {
    return '<div class="admin-pending-card" data-target="' + item.target + '">' +
      '<div class="admin-pending-info"><div class="admin-pending-priority">' + escapeHtml(item.tag) + '</div><div class="admin-pending-label">' + escapeHtml(item.label) + '</div><div class="admin-pending-count">' + escapeHtml(item.count) + '</div></div>' +
      '<div class="admin-pending-arrow">&rsaquo;</div>' +
    '</div>';
  }

  function formField(label, input) {
    return '<div class="form-group"><label class="form-label">' + escapeHtml(label) + '</label>' + input + '</div>';
  }

  function cardHeader(title, badgeLabel, badgeClass) {
    return '<div class="admin-job-card-top"><div><div class="admin-job-card-name">' + escapeHtml(title) + '</div></div><span class="badge ' + badgeClass + '">' + escapeHtml(badgeLabel) + '</span></div>';
  }

  function cardMetaRow(value) {
    return '<div class="admin-job-card-row">' + escapeHtml(value) + '</div>';
  }

  function cardFooter(primary, secondary) {
    return '<div class="admin-job-card-bottom"><div class="admin-job-card-amount">' + escapeHtml(primary) + '</div><div class="large-contract-flag">' + escapeHtml(secondary) + '</div></div>';
  }

  async function bindAssignmentControls(job) {
    document.querySelectorAll('.admin-elec-option').forEach((option) => {
      option.addEventListener('click', () => {
        document.querySelectorAll('.admin-elec-option').forEach((item) => item.classList.remove('selected'));
        option.classList.add('selected');
      });
    });

    const assignButton = $('#btn-admin-assign');
    const forceButton = $('#btn-admin-force-assign');
    const autoButton = $('#btn-admin-auto-assign');
    const getSelected = () => document.querySelector('.admin-elec-option.selected');

    if (autoButton) {
      autoButton.addEventListener('click', async () => {
        await withButtonLoading('btn-admin-auto-assign', 'Assigning...', async () => {
          await Store.rerunAutomaticAssignment(job.id);
          await loadData();
          await openRequestDetail(job.id);
        });
      });
    }

    if (assignButton) {
      assignButton.addEventListener('click', async () => {
        const selectedOption = getSelected();
        if (!selectedOption) {
          showLoginError('Select an electrician before assigning.');
          return;
        }
        if (selectedOption.dataset.pool === 'override') {
          showLoginError('Use force deploy for an admin override selection.');
          return;
        }
        await withButtonLoading('btn-admin-assign', job.assignedElectrician ? 'Reassigning...' : 'Assigning...', async () => {
          await Store.setManualAssignment(job.id, selectedOption.dataset.elecId);
          await loadData();
          await openRequestDetail(job.id);
        });
      });
    }

    if (forceButton) {
      forceButton.addEventListener('click', async () => {
        const selectedOption = getSelected();
        if (!selectedOption) {
          showLoginError('Select an electrician before force deploying.');
          return;
        }
        await withButtonLoading('btn-admin-force-assign', 'Force deploying...', async () => {
          await Store.setManualAssignment(job.id, selectedOption.dataset.elecId);
          await loadData();
          await openRequestDetail(job.id);
        });
      });
    }
  }

  async function bindPaymentButtons(job) {
    const verify = $('#btn-verify-payment');
    const reject = $('#btn-reject-payment');
    if (verify) {
      verify.addEventListener('click', async () => {
        await withButtonLoading('btn-verify-payment', 'Approving...', async () => {
          await Store.verifyPayment(verify.dataset.paymentId, true, 'Payment manually verified by admin.');
          await loadData();
          await openJobDetail(job.id);
        });
      });
    }
    if (reject) {
      reject.addEventListener('click', async () => {
        await withButtonLoading('btn-reject-payment', 'Rejecting...', async () => {
          await Store.verifyPayment(reject.dataset.paymentId, false, 'Payment proof was rejected by admin.');
          await loadData();
          await openJobDetail(job.id);
        });
      });
    }
  }

  async function bindPayoutButtons(job) {
    const release = $('#btn-release-payout');
    if (!release) return;
    release.addEventListener('click', async () => {
      await withButtonLoading('btn-release-payout', 'Updating...', async () => {
        await Store.markPayoutComplete(job.id);
        await loadData();
        await openJobDetail(job.id);
      });
    });
  }

  function bindQuickReassignButton(job) {
    const button = $('#btn-open-reassign');
    if (!button) return;
    button.addEventListener('click', async () => {
      await openRequestDetail(job.id);
    });
  }

  function bindElectricianAction(buttonId, electricianId, status) {
    const button = $('#' + buttonId);
    if (!button) return;
    button.addEventListener('click', async () => {
      const text = status === 'approved' ? 'Approving...' : status === 'rejected' ? 'Rejecting...' : 'Suspending...';
      await withButtonLoading(buttonId, text, async () => {
        await Store.setElectricianStatus(electricianId, status);
        await loadData();
        await openElectricianDetail(electricianId);
      });
    });
  }

  function bindWatchlistAction(buttonId, electricianId, watchlist) {
    const button = $('#' + buttonId);
    if (!button) return;
    button.addEventListener('click', async () => {
      await withButtonLoading(buttonId, watchlist ? 'Adding...' : 'Removing...', async () => {
        await Store.setElectricianWatchlist(electricianId, watchlist, watchlist ? 'Admin quality monitoring.' : null);
        await loadData();
        await openElectricianDetail(electricianId);
      });
    });
  }

  async function withButtonLoading(buttonId, loadingText, work) {
    const button = $('#' + buttonId);
    const originalText = button ? button.textContent : '';
    const originalHtml = button ? button.innerHTML : '';
    const wasDisabled = button ? button.disabled : false;
    if (button) {
      button.disabled = true;
      button.textContent = loadingText;
    }
    clearLoginError();
    try {
      return await work();
    } catch (error) {
      showLoginError(error.message || 'Action failed.');
      return null;
    } finally {
      if (button) {
        button.innerHTML = originalHtml || originalText;
        button.disabled = wasDisabled;
      }
    }
  }

  function navigateTo(screen, options) {
    const navScreen = adminNavScreen(screen);
    $$('.admin-nav-item').forEach((item) => item.classList.toggle('active', item.dataset.screen === navScreen));
    goTo(screen, {
      replace: !!(options && options.replace),
      routeData: options && options.routeData ? options.routeData : null
    });
    refreshScreen(screen);
  }

  async function activateAdminRoute(route) {
    const nextRoute = route && route.screen ? route : { screen: 'admin-dashboard', data: null };

    if (nextRoute.screen === 'admin-login') {
      navigateTo('admin-dashboard', { replace: true });
      return;
    }

    if (nextRoute.screen === 'admin-request-detail' && nextRoute.data && nextRoute.data.ticket) {
      await openRequestDetailByTicket(nextRoute.data.ticket);
      return;
    }

    if (nextRoute.screen === 'admin-job-detail' && nextRoute.data && nextRoute.data.ticket) {
      await openJobDetailByTicket(nextRoute.data.ticket);
      return;
    }

    if (nextRoute.screen === 'admin-elec-detail' && nextRoute.data && nextRoute.data.electricianId) {
      await openElectricianDetail(nextRoute.data.electricianId);
      return;
    }

    navigateTo(nextRoute.screen, {
      replace: nextRoute.source !== 'popstate',
      routeData: nextRoute.data || null
    });
  }

  async function openRequestDetailByTicket(ticket) {
    const cleanTicket = String(ticket || '').trim().toUpperCase();
    const match = currentJobs.find((job) => String(job.ticket || '').toUpperCase() === cleanTicket);
    if (!match) {
      navigateTo('admin-requests', { replace: true });
      return;
    }
    await openRequestDetail(match.id);
  }

  async function openJobDetailByTicket(ticket) {
    const cleanTicket = String(ticket || '').trim().toUpperCase();
    const match = currentJobs.find((job) => String(job.ticket || '').toUpperCase() === cleanTicket);
    if (!match) {
      navigateTo('admin-jobs', { replace: true });
      return;
    }
    await openJobDetail(match.id);
  }

  function adminNavScreen(screen) {
    if (['admin-request-detail'].includes(screen)) return 'admin-requests';
    if (['admin-elec-detail'].includes(screen)) return 'admin-electricians';
    if (['admin-jobs', 'admin-job-detail', 'admin-materials', 'admin-chats', 'admin-trust', 'admin-disputes', 'admin-expertise', 'admin-prices'].includes(screen)) return 'admin-settings';
    return screen;
  }

  function normalizeAdminPath(pathname) {
    const raw = String(pathname || '/admin/login').trim();
    if (!raw) return '/admin/login';
    const cleaned = raw.replace(/\/+$/, '');
    return cleaned || '/admin/login';
  }

  function buildAlerts() {
    const alerts = [];
    const newBookingCount = currentJobs.filter((job) => ['requested', 'matching', 'assigned'].includes(job.status) || job.needsManualAssignment).length;
    if (newBookingCount) {
      alerts.push({ tag: 'Bookings', label: 'New bookings', count: newBookingCount + ' request(s) need dispatch attention', target: 'admin-requests' });
    }
    if (currentPayments.length) {
      alerts.push({ tag: 'Payment', label: 'Pending payments', count: currentPayments.length + ' proof submission(s) need review', target: 'admin-finance' });
    }
    const pendingElectricianCount = currentElectricians.filter((electrician) => electrician.status === 'pending').length;
    if (pendingElectricianCount) {
      alerts.push({ tag: 'Onboarding', label: 'Pending electricians', count: pendingElectricianCount + ' application(s) need review', target: 'admin-electricians' });
    }
    const stuckCount = currentJobs.filter(isStuckJob).length;
    if (stuckCount) {
      alerts.push({ tag: 'Dispatch', label: 'Stuck jobs', count: stuckCount + ' job(s) need intervention', target: 'admin-requests' });
    }
    return alerts;
  }

  async function resolveDisputeAction(disputeId, status, resolutionAction, resolutionNote) {
    await Store.resolveDispute(disputeId, status, resolutionAction, resolutionNote);
    await loadData();
    renderDisputes();
  }

  function isCustomerStuck(job) {
    if (!['assessment_fee_pending', 'quoted', 'quote_accepted', 'customer_confirmed'].includes(job.status)) return false;
    return hoursSince(job.updatedAt) >= 6;
  }

  function isStuckJob(job) {
    return !!(job.needsManualAssignment || hasTimeoutTimeline(job) || hasRejectedTimeline(job) || isCustomerStuck(job));
  }

  function hasRejectedTimeline(job) {
    return (job.timeline || []).some((entry) => /declined the booking/i.test(entry.note || ''));
  }

  function hasTimeoutTimeline(job) {
    return (job.timeline || []).some((entry) => /did not respond within 5 minutes/i.test(entry.note || ''));
  }

  function isCompletedJob(job) {
    return ['payout_complete', 'rated'].includes(job.status);
  }

  function nextAction(job) {
    if (job.needsManualAssignment) return 'No electrician available yet. Manual assignment required.';
    if (hasTimeoutTimeline(job) && job.status === 'matching') return 'An assignment expired. Reassign or let rematching continue.';
    if (hasRejectedTimeline(job) && job.status === 'matching') return 'Previous electrician rejected the job. Override if needed.';
    if (job.status === 'matching') return 'Automatic matching is trying approved nearby electricians.';
    if (job.status === 'assigned') return 'Waiting for the assigned electrician to accept or reject.';
    if (job.status === 'accepted') return 'Electrician can head out or prepare a remote quote.';
    if (job.status === 'assessment_fee_pending') return 'Customer must submit assessment payment proof.';
    if (job.status === 'assessment_payment_pending_verification') return 'Admin must verify the assessment payment.';
    if (job.status === 'assessment_confirmed') return 'Electrician can travel to the site.';
    if (job.status === 'en_route') return 'Electrician is on the way.';
    if (job.status === 'on_site') return 'Waiting for assessment and quote submission.';
    if (job.status === 'quoted') return 'Customer must accept the quote.';
    if (job.status === 'quote_accepted') return 'Customer must submit work payment proof.';
    if (job.status === 'work_payment_pending_verification') return 'Admin must verify the work payment.';
    if (job.status === 'payment_confirmed') return 'Electrician can start work.';
    if (job.status === 'work_in_progress') return 'Work is ongoing.';
    if (job.status === 'electrician_completed') return 'Customer needs to confirm completion.';
    if (job.status === 'customer_confirmed' || job.status === 'payout_pending') return 'Admin should release payout.';
    if (job.status === 'payout_complete') return 'Waiting for customer rating.';
    return job.statusLabel;
  }

  function statusClass(status) {
    if (['matching', 'assigned', 'accepted'].includes(status)) return 'status-pending';
    if (['assessment_payment_pending_verification', 'work_payment_pending_verification'].includes(status)) return 'status-payment';
    if (['payment_confirmed', 'en_route', 'on_site', 'work_in_progress'].includes(status)) return 'status-in-progress';
    if (['payout_complete', 'rated'].includes(status)) return 'status-completed';
    if (status === 'cancelled' || status === 'rejected' || status === 'suspended') return 'status-rejected';
    if (status === 'approved') return 'status-active';
    return 'status-pending';
  }

  function humanizeIssue(value) {
    const map = {
      'Light fitting': 'Light issue',
      'Socket repair': 'Socket/switch issue',
      'Wiring issue': 'Wiring',
      Inverter: 'Inverter/solar',
      Generator: 'Generator connection',
      'Tripped breaker': 'Breaker/fuse',
      'General Installation': 'Full inspection',
      Other: 'Other'
    };
    return map[value] || value || 'Unknown issue';
  }

  function humanizeUrgency(value) {
    if (value === 'emergency') return 'Emergency';
    if (value === 'this-week') return 'Scheduled';
    return 'Today';
  }

  function documentLabel(value) {
    const map = {
      government_id: 'Government ID',
      certification: 'Certification',
      bank_proof: 'Bank proof',
      utility_bill: 'Light bill'
    };
    return map[value] || value || 'Document';
  }

  function slugify(value) {
    return String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/(^-|-$)/g, '');
  }

  function formatRelative(value) {
    return timeAgo(new Date(value).getTime());
  }

  function hoursSince(value) {
    return (Date.now() - new Date(value).getTime()) / 3600000;
  }

  function emptyState(text) {
    return '<div class="empty-state"><div class="empty-state-text">' + escapeHtml(text) + '</div></div>';
  }

  function renderAdminLoadingState() {
    const skeleton = '<div class="skeleton-card"></div><div class="skeleton-card"></div>';
    if ($('#admin-stats')) {
      $('#admin-stats').innerHTML = skeleton;
    }
    if ($('#admin-pending-actions')) {
      $('#admin-pending-actions').innerHTML = skeleton;
    }
    if ($('#admin-control-queue')) {
      $('#admin-control-queue').innerHTML = skeleton;
    }
    if ($('#admin-feed')) {
      $('#admin-feed').innerHTML = '<div class="skeleton-stack"><div class="skeleton-line long"></div><div class="skeleton-line medium"></div><div class="skeleton-line long"></div></div>';
    }
  }

  function updateAdminRecoveryUI() {
    const passwordLabel = document.querySelector('label[for="admin-password"]') || document.querySelector('.admin-login-card .form-group:nth-child(2) .form-label');
    const note = document.querySelector('.admin-login-note');
    const button = $('#btn-admin-login');
    const forgot = $('#btn-admin-forgot');
    if (!passwordLabel || !note || !button || !forgot) return;
    if (wantsPasswordReset()) {
      passwordLabel.textContent = 'New Password';
      note.textContent = 'Use the reset link from your email, then choose a new password here.';
      button.textContent = 'Update Password';
      forgot.style.display = 'none';
      return;
    }
    passwordLabel.textContent = 'Password';
    note.textContent = 'Invite-only access for operations, dispatch, finance, trust, and approvals.';
    button.textContent = 'Login';
    forgot.style.display = '';
  }

  function showLoginError(message) {
    const loginError = $('#admin-login-error');
    if (currentScreen && currentScreen !== 'admin-login') {
      window.alert(message);
      return;
    }
    loginError.classList.remove('is-success');
    loginError.style.display = 'block';
    loginError.textContent = message;
  }

  function showLoginNotice(message) {
    const loginError = $('#admin-login-error');
    loginError.classList.add('is-success');
    loginError.style.display = 'block';
    loginError.textContent = message;
  }

  function clearLoginError() {
    $('#admin-login-error').classList.remove('is-success');
    $('#admin-login-error').style.display = 'none';
    $('#admin-login-error').textContent = '';
  }

  function escapeHtml(value) {
    return String(value || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function escapeAttribute(value) {
    return escapeHtml(value).replace(/"/g, '&quot;');
  }
})();
