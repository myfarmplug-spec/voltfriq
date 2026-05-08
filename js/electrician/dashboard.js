  async function loadDashboard() {
    try {
      renderDashboardLoading();
      currentJobs = await Store.listElectricianJobs();
      renderDashboardHeader();
      renderDashboardLists();
      renderProfile();
      renderHistory();
      clearError();
    } catch (error) {
      showError(error.message || 'Could not load your dashboard.');
    }
  }

  function renderDashboardHeader() {
    const profile = Store.getCurrentProfile() || {};
    const electrician = Store.getCurrentElectrician() || {};
    const nearbyRequests = currentJobs.filter((job) => job.status === 'assigned').length;
    const acceptedJobs = currentJobs.filter((job) => ['accepted', 'assessment_fee_pending', 'assessment_payment_pending_verification', 'assessment_confirmed', 'quoted', 'quote_accepted', 'work_payment_pending_verification', 'payment_confirmed'].includes(job.status)).length;
    const inProgressJobs = currentJobs.filter((job) => ['en_route', 'on_site', 'work_in_progress', 'electrician_completed'].includes(job.status)).length;
    const pendingPayout = currentJobs
      .filter((job) => ['customer_confirmed', 'payout_pending'].includes(job.status))
      .reduce((sum, job) => sum + (job.quote.total || 0), 0);
    const completedEarnings = currentJobs
      .filter((job) => ['payout_complete', 'rated'].includes(job.status))
      .reduce((sum, job) => sum + (job.quote.total || 0), 0);
    document.getElementById('dash-avatar').textContent = '⚡';
    document.getElementById('dash-name').textContent = profile.full_name || 'VoltFriq';
    document.getElementById('dash-live-status').textContent = electrician.availability_status === 'available' ? 'Available for jobs' : 'Offline for now';
    document.getElementById('stat-jobs-month').textContent = nearbyRequests;
    document.getElementById('stat-earnings').textContent = Store.formatCurrency(completedEarnings);
    document.getElementById('stat-rating').textContent = electrician.average_rating
      ? Number(electrician.average_rating).toFixed(1) + '/5'
      : '--';
    document.getElementById('stat-payouts').textContent = Store.formatCurrency(pendingPayout);
    renderTrustPanel(electrician, {
      nearbyRequests,
      acceptedJobs,
      inProgressJobs,
      pendingPayout
    });
  }

  function renderTrustPanel(electrician, summary) {
    const level = electrician.level_badge || 'Verified Pro';
    const completed = Number(electrician.completed_jobs || 0);
    const rating = Number(electrician.average_rating || 0);
    const nextGoal = nextLevelGoal(level, completed, rating);
    const watchlist = electrician.watchlist
      ? '<div class="elec-watch-note">Watchlist: ' + escapeHtml(electrician.watchlist_reason || 'Admin is monitoring recent performance.') + '</div>'
      : '';
    const availabilityLabel = electrician.availability_status === 'available' ? 'Available now' : 'Offline';
    const availabilityButton = electrician.availability_status === 'available' ? 'Go offline' : 'Go available';
    document.getElementById('dash-trust-panel').innerHTML =
      '<div class="elec-hero-topline"><span class="elec-level-pill">' + escapeHtml(level) + '</span><span class="elec-availability-pill' + (electrician.availability_status === 'available' ? ' is-live' : '') + '">' + escapeHtml(availabilityLabel) + '</span></div>' +
      '<div class="elec-trust-title">Stay ready for the next nearby request</div>' +
      '<div class="elec-trust-copy">' + escapeHtml(nextGoal) + '</div>' +
      '<div class="elec-hero-stats">' +
        '<div class="elec-hero-stat"><strong>' + escapeHtml(String(summary.nearbyRequests || 0)) + '</strong><span>Nearby requests</span></div>' +
        '<div class="elec-hero-stat"><strong>' + escapeHtml(String(summary.acceptedJobs || 0)) + '</strong><span>Accepted jobs</span></div>' +
        '<div class="elec-hero-stat"><strong>' + escapeHtml(String(summary.inProgressJobs || 0)) + '</strong><span>In progress</span></div>' +
      '</div>' +
      '<div class="elec-trust-meter"><span style="width:' + Math.min(100, Math.max(12, completed * 4)) + '%"></span></div>' +
      '<div class="elec-trust-meta">' + completed + ' completed · ' + (rating ? rating.toFixed(1) + '/5' : 'No rating yet') + ' · ' + Number(electrician.negative_rating_count || 0) + ' negative</div>' +
      '<div class="elec-hero-actions"><button class="btn-primary" id="btn-dash-toggle-availability">' + escapeHtml(availabilityButton) + '</button><button class="btn-secondary" id="btn-dash-open-active">Open active jobs</button></div>' +
      '<div class="elec-payout-hero"><span class="elec-payout-label">Payout waiting</span><strong>' + escapeHtml(Store.formatCurrency(summary.pendingPayout || 0)) + '</strong><small>Customer-confirmed work waiting for release.</small></div>' +
      watchlist;
    const toggleButton = document.getElementById('btn-dash-toggle-availability');
    if (toggleButton) {
      toggleButton.addEventListener('click', toggleDashboardAvailability);
    }
    const activeButton = document.getElementById('btn-dash-open-active');
    if (activeButton) {
      activeButton.addEventListener('click', () => {
        const next = currentJobs.find((job) => ['accepted', 'assessment_fee_pending', 'assessment_payment_pending_verification', 'assessment_confirmed', 'quoted', 'quote_accepted', 'work_payment_pending_verification', 'payment_confirmed', 'en_route', 'on_site', 'work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending'].includes(job.status));
        if (next) {
          openJob(next.id);
          return;
        }
        goTo('elec-history');
      });
    }
  }

  function renderDashboardLists() {
    const newAssignments = currentJobs.filter((job) => job.status === 'assigned');
    const acceptedJobs = currentJobs.filter((job) => ['accepted', 'assessment_fee_pending', 'assessment_payment_pending_verification', 'assessment_confirmed', 'quoted', 'quote_accepted', 'work_payment_pending_verification', 'payment_confirmed'].includes(job.status));
    const progressJobs = currentJobs.filter((job) => ['en_route', 'on_site', 'work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending'].includes(job.status));
    const completedJobs = currentJobs.filter((job) => ['payout_complete', 'rated'].includes(job.status));

    document.getElementById('notif-dot').style.display = newAssignments.length ? 'block' : 'none';
    document.getElementById('dash-new-assignments').innerHTML = newAssignments.length
      ? newAssignments.map((job) => dashboardJobCard(job, true)).join('')
      : '<div class="elec-empty"><div class="elec-empty-text">No new assignments right now.</div></div>';

    document.getElementById('dash-accepted-jobs').innerHTML = acceptedJobs.length
      ? acceptedJobs.map((job) => dashboardJobCard(job, false)).join('')
      : '<div class="elec-empty"><div class="elec-empty-text">No accepted jobs yet.</div></div>';

    document.getElementById('dash-progress-jobs').innerHTML = progressJobs.length
      ? progressJobs.map((job) => dashboardJobCard(job, false)).join('')
      : '<div class="elec-empty"><div class="elec-empty-text">No jobs in progress right now.</div></div>';

    document.getElementById('dash-completed-jobs').innerHTML = completedJobs.length
      ? completedJobs.map((job) => dashboardJobCard(job, false)).join('')
      : '<div class="elec-empty"><div class="elec-empty-text">No active jobs yet.</div></div>';

    document.querySelectorAll('.elec-alert-card, .elec-job-item').forEach((card) => {
      card.addEventListener('click', (event) => {
        if (event.target.closest('[data-inline-action]')) return;
        openJob(card.dataset.jobId);
      });
    });
    document.querySelectorAll('[data-inline-action="accept"]').forEach((button) => {
      button.addEventListener('click', (event) => {
        event.stopPropagation();
        actOnSpecificJob(button.dataset.jobId, () => Store.acceptAssignedJob(button.dataset.jobId));
      });
    });
    document.querySelectorAll('[data-inline-action="reject"]').forEach((button) => {
      button.addEventListener('click', (event) => {
        event.stopPropagation();
        actOnSpecificJob(button.dataset.jobId, () => Store.rejectAssignedJob(button.dataset.jobId));
      });
    });
  }

  function dashboardJobCard(job, isNew) {
    const issue = humanizeIssue(job.issueCategory);
    const estimate = estimateRangeLabel(job);
    const location = job.locationLabel || job.serviceArea || 'Location shared after accept';
    const photoPreview = (job.photos || []).length
      ? '<div class="elec-job-photo-stack">' + job.photos.slice(0, 3).map((photo, index) => photo.url
        ? '<img class="elec-job-photo-thumb" src="' + escapeHtml(photo.url) + '" alt="Job photo ' + (index + 1) + '" loading="lazy" />'
        : '<div class="elec-job-photo-thumb elec-job-photo-fallback">' + (index + 1) + '</div>').join('') + '</div>'
      : '';
    const actions = isNew
      ? '<div class="elec-inline-actions"><button class="btn-primary btn-full" data-inline-action="accept" data-job-id="' + job.id + '">Accept</button><button class="btn-secondary btn-full" data-inline-action="reject" data-job-id="' + job.id + '">Reject</button></div>'
      : '';
    return '<div class="' + (isNew ? 'elec-alert-card' : 'elec-job-item') + '" data-job-id="' + job.id + '">' +
      '<div class="elec-job-item-head"><div class="elec-job-item-name">' + escapeHtml(issue) + '</div><div class="elec-job-item-time">' + timeAgo(new Date(job.updatedAt).getTime()) + '</div></div>' +
      '<div class="elec-job-item-tags"><span class="badge badge-yellow">' + escapeHtml(job.serviceArea) + '</span><span class="badge ' + urgencyBadgeClass(job.urgency) + '">' + escapeHtml(formatUrgency(job.urgency)) + '</span><span class="badge badge-green">' + escapeHtml(estimate) + '</span></div>' +
      '<div class="elec-job-item-status"><span class="dot-live"></span>' + escapeHtml(job.statusLabel) + '</div>' +
      '<div class="elec-job-item-status" style="color:var(--mid)">' + escapeHtml(location) + ' · ' + escapeHtml(issue) + '</div>' +
      '<div class="elec-job-item-note">' + escapeHtml(job.description || 'No customer note added.') + '</div>' +
      customerTrustMini(job) +
      '<div class="elec-job-item-meta"><span>' + escapeHtml(distanceLabel(job)) + '</span><span>' + escapeHtml(String((job.photos || []).length)) + ' photo(s)</span></div>' +
      photoPreview +
      actions +
    '</div>';
  }

  function estimateRangeLabel(job) {
    if (job && job.quote && Number(job.quote.total || 0)) return Store.formatCurrency(job.quote.total);
    const range = ISSUE_ESTIMATES[job && job.issueCategory] || ISSUE_ESTIMATES[humanizeIssue(job && job.issueCategory)] || ISSUE_ESTIMATES.Other;
    if (!range) return 'Estimate after assessment';
    if (!range[1]) return Store.formatCurrency(range[0]) + '+ estimate';
    return Store.formatCurrency(range[0]) + ' - ' + Store.formatCurrency(range[1]) + ' estimate';
  }

