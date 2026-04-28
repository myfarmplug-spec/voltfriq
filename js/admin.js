/* ─── VOLTFRIQ OCEAN — ADMIN PORTAL LOGIC ──────────────────────── */

(() => {
  'use strict';

  let currentFilter = {
    requests: 'all',
    electricians: 'all',
    jobs: 'all'
  };
  let selectedCandidateId = null;
  let currentJobId = null;
  let currentElecId = null;
  let pollTimer = null;

  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => document.querySelectorAll(selector);

  function statusLabel(status) {
    const labels = {
      requested: 'Requested',
      matched: 'Matched',
      'assessment-pending': 'Assessment Pending',
      quoted: 'Quoted',
      'payment-pending': 'Payment Pending',
      'work-in-progress': 'Work In Progress',
      'electrician-complete': 'Electrician Complete',
      'payout-complete': 'Payout Complete',
      rated: 'Rated',
      cancelled: 'Cancelled',
      pending: 'Pending',
      active: 'Active',
      suspended: 'Suspended',
      removed: 'Removed',
      rejected: 'Rejected'
    };
    return labels[status] || status || 'Unknown';
  }

  function statusClass(status) {
    const map = {
      requested: 'status-pending',
      matched: 'status-fee-pending',
      'assessment-pending': 'status-assessment',
      quoted: 'status-quoted',
      'payment-pending': 'status-payment',
      'work-in-progress': 'status-in-progress',
      'electrician-complete': 'status-payment',
      'payout-complete': 'status-completed',
      rated: 'status-completed',
      cancelled: 'status-rejected',
      pending: 'status-pending',
      active: 'status-active',
      suspended: 'status-suspended',
      removed: 'status-rejected',
      rejected: 'status-rejected'
    };
    return map[status] || 'status-pending';
  }

  function formatUrgency(urgency) {
    if (urgency === 'emergency') return ['Emergency', 'urgency-high'];
    if (urgency === 'today') return ['Today', 'urgency-medium'];
    return ['This Week', 'urgency-low'];
  }

  function jobAmount(job) {
    return job.quote ? (job.quote.customerPayableTotal || 0) : 0;
  }

  function currentAdminName() {
    const admin = Store.get('admin');
    return admin ? admin.name : 'VoltFriq Admin';
  }

  function initLogin() {
    $('#btn-admin-login').addEventListener('click', doLogin);
    $('#admin-password').addEventListener('keydown', (event) => {
      if (event.key === 'Enter') doLogin();
    });

    if (Store.get('adminLoggedIn')) {
      showApp();
    }
  }

  function doLogin() {
    const email = $('#admin-email').value.trim();
    const password = $('#admin-password').value;
    const admin = Store.get('admin');

    if (admin && admin.email === email && admin.password === password) {
      Store.set('adminLoggedIn', true);
      $('#admin-login-error').style.display = 'none';
      showApp();
      return;
    }
    $('#admin-login-error').style.display = 'block';
  }

  function showApp() {
    $('#admin-bottom-nav').style.display = 'flex';
    goTo('admin-dashboard');
    renderDashboard();
    startPolling();
  }

  function initBottomNav() {
    $$('.admin-nav-item').forEach((button) => {
      button.addEventListener('click', () => {
        const screen = button.dataset.screen;
        $$('.admin-nav-item').forEach((item) => item.classList.remove('active'));
        button.classList.add('active');
        screenHistory.length = 0;
        goTo(screen);
        refreshScreen(screen);
      });
    });
  }

  function initFilterLabels() {
    const requestTabs = $('#requests-filter-tabs');
    if (requestTabs) {
      requestTabs.querySelector('[data-filter="pending"]').textContent = 'New';
      requestTabs.querySelector('[data-filter="fee-pending"]').textContent = 'Matched';
      requestTabs.querySelector('[data-filter="in-progress"]').textContent = 'Live';
    }

    const jobTabs = $('#jobs-filter-tabs');
    if (jobTabs) {
      jobTabs.querySelector('[data-filter="pending"]').textContent = 'Requested';
      jobTabs.querySelector('[data-filter="fee-pending"]').textContent = 'Assess';
      jobTabs.querySelector('[data-filter="assessment"]').textContent = 'Matched';
      jobTabs.querySelector('[data-filter="payment"]').textContent = 'Payment';
      jobTabs.querySelector('[data-filter="in-progress"]').textContent = 'Work';
      jobTabs.querySelector('[data-filter="completed"]').textContent = 'Closed';
    }
  }

  function refreshScreen(screen) {
    Chat.destroy();
    switch (screen) {
      case 'admin-dashboard':
        renderDashboard();
        break;
      case 'admin-requests':
        renderRequests();
        break;
      case 'admin-jobs':
        renderJobs();
        break;
      case 'admin-electricians':
        renderElectricians();
        break;
      case 'admin-settings':
        renderSettings();
        break;
      case 'admin-materials':
        renderMaterials();
        break;
      case 'admin-finance':
        renderFinance();
        break;
      case 'admin-chats':
        renderChats();
        break;
      case 'admin-prices':
        renderPriceList();
        break;
    }
  }

  function renderDashboard() {
    const jobs = Store.getJobs();
    const electricians = Store.getElectricians();

    const activeJobs = jobs.filter((job) => !['rated', 'cancelled'].includes(job.status)).length;
    const pendingRequests = jobs.filter((job) => job.status === 'requested' || (job.status === 'assessment-pending' && !job.assignedElectricianId)).length;
    const activeElectricians = electricians.filter((electrician) => electrician.status === 'active').length;
    const revenue = jobs.filter((job) => ['payout-complete', 'rated'].includes(job.status)).reduce((sum, job) => sum + jobAmount(job), 0);
    const pendingApps = electricians.filter((electrician) => electrician.status === 'pending' || electrician.onboardingStatus === 'pending-review').length;
    const stuckAssessmentFees = jobs.filter((job) => job.status === 'assessment-pending' && job.assignedElectricianId && !job.assessmentFeePaid).length;
    const quoteFollowups = jobs.filter((job) => {
      return (job.status === 'matched' && job.visitStage !== 'awaiting-acceptance') || job.status === 'quoted';
    }).length;
    const paymentFollowups = jobs.filter((job) => job.status === 'payment-pending' && !job.paymentConfirmedAt).length;
    const completionFollowups = jobs.filter((job) => job.status === 'electrician-complete').length;
    const stuckJobs = stuckAssessmentFees + quoteFollowups + paymentFollowups + completionFollowups;
    const lowRated = electricians.filter((electrician) => electrician.badRatingCount >= Store.getSettings().badRatingThreshold).length;

    $('#admin-stats').innerHTML =
      statCard('⚡', activeJobs, 'Active Jobs') +
      statCard('📋', pendingRequests, 'Needs Assignment') +
      statCard('👷', activeElectricians, 'Active VoltFriqs') +
      statCard('💰', fmt(revenue), 'Revenue');

    const pendingActions = [];

    if (pendingApps > 0) {
      pendingActions.push(actionCard('👷', '1. Onboarding reviews', pendingApps + ' VoltFriq application' + (pendingApps === 1 ? '' : 's'), 'Trust gate', () => {
        navigateToTab('admin-electricians', 'electricians', 'pending');
      }));
    }
    if (pendingRequests > 0) {
      pendingActions.push(actionCard('📋', '2. Assignment queue', pendingRequests + ' job' + (pendingRequests === 1 ? '' : 's') + ' needing assignment or reassignment', 'Dispatch', () => {
        navigateToTab('admin-requests', 'requests', 'pending');
      }));
    }
    if (stuckJobs > 0) {
      pendingActions.push(actionCard('⏱', '3. Job follow-ups', buildStuckJobSummary({
        assessment: stuckAssessmentFees,
        quote: quoteFollowups,
        payment: paymentFollowups,
        completion: completionFollowups
      }), 'Ops watch', () => {
        const matchedQuoteFollowups = jobs.some((job) => job.status === 'matched' && job.visitStage !== 'awaiting-acceptance');
        const targetFilter = completionFollowups ? 'in-progress' : (paymentFollowups ? 'payment' : (quoteFollowups ? (matchedQuoteFollowups ? 'assessment' : 'quoted') : 'fee-pending'));
        navigateToTab('admin-jobs', 'jobs', targetFilter);
      }));
    }
    if (lowRated > 0) {
      pendingActions.push(actionCard('⭐', '4. Discipline review', lowRated + ' electrician' + (lowRated === 1 ? '' : 's') + ' reached the bad-rating threshold', 'Quality', () => {
        navigateToTab('admin-electricians', 'electricians', 'all');
      }));
    }
    pendingActions.push(actionCard('⚙️', '5. Rules and records', 'Review prices, materials, finance, chats, and service settings', 'Controls', () => {
      navigateToTab('admin-settings', null, null);
    }));

    $('#pending-count').textContent = pendingActions.length;
    $('#admin-pending-actions').innerHTML = pendingActions.length
      ? pendingActions.map((item) => item.html).join('')
      : '<div class="empty-state"><div class="empty-state-icon">✅</div><div class="empty-state-text">No pending admin actions.</div></div>';

    pendingActions.forEach((item) => {
      const element = document.getElementById(item.id);
      if (element) element.addEventListener('click', item.onClick);
    });

    const activity = jobs
      .flatMap((job) => (job.timeline || []).map((entry) => ({
        ticket: job.ticket,
        text: statusLabel(entry.status) + (entry.note ? ' — ' + entry.note : ''),
        timestamp: entry.timestamp
      })))
      .sort((a, b) => b.timestamp - a.timestamp)
      .slice(0, 6);

    $('#admin-feed').innerHTML = activity.length
      ? activity.map((entry) => {
          return '<div class="admin-feed-item">' +
            '<div class="admin-feed-dot"></div>' +
            '<div class="admin-feed-text"><strong>' + entry.ticket + '</strong> ' + entry.text + '</div>' +
            '<div class="admin-feed-time">' + timeAgo(entry.timestamp) + '</div>' +
          '</div>';
        }).join('')
      : '<div class="empty-state"><div class="empty-state-icon">📝</div><div class="empty-state-text">No activity yet.</div></div>';
  }

  function statCard(icon, value, label) {
    return '<div class="admin-stat">' +
      '<div class="admin-stat-icon">' + icon + '</div>' +
      '<div class="admin-stat-value">' + value + '</div>' +
      '<div class="admin-stat-label">' + label + '</div>' +
    '</div>';
  }

  function buildStuckJobSummary(counts) {
    const parts = [];
    if (counts.assessment) parts.push(counts.assessment + ' assessment fee');
    if (counts.quote) parts.push(counts.quote + ' quote');
    if (counts.payment) parts.push(counts.payment + ' payment');
    if (counts.completion) parts.push(counts.completion + ' completion');
    return parts.join(' · ') + ' follow-up' + (parts.length === 1 && Object.values(counts).reduce((sum, count) => sum + count, 0) === 1 ? '' : 's');
  }

  function actionCard(icon, label, count, priority, onClick) {
    const id = 'pending-' + Store.uid();
    return {
      id,
      onClick,
      html:
        '<div class="admin-pending-card" id="' + id + '">' +
          '<div class="admin-pending-icon">' + icon + '</div>' +
          '<div class="admin-pending-info">' +
            '<div class="admin-pending-priority">' + priority + '</div>' +
            '<div class="admin-pending-label">' + label + '</div>' +
            '<div class="admin-pending-count">' + count + '</div>' +
          '</div>' +
          '<div class="admin-pending-arrow">&rsaquo;</div>' +
        '</div>'
    };
  }

  function navigateToTab(screen, filterKey, filterValue) {
    if (filterKey && filterValue) {
      currentFilter[filterKey] = filterValue;
    }
    $$('.admin-nav-item').forEach((button) => button.classList.toggle('active', button.dataset.screen === screen));
    screenHistory.length = 0;
    goTo(screen);
    refreshScreen(screen);

    const tabSet = filterKey === 'requests' ? '#requests-filter-tabs' : (filterKey === 'jobs' ? '#jobs-filter-tabs' : '#elec-filter-tabs');
    if (filterKey && filterValue) {
      $$(tabSet + ' .admin-filter-tab').forEach((tab) => {
        tab.classList.toggle('active', tab.dataset.filter === filterValue);
      });
    }
  }

  function renderRequests() {
    const jobs = Store.getJobs().filter((job) => !['rated', 'cancelled'].includes(job.status));
    const filtered = jobs.filter((job) => {
      const filter = currentFilter.requests;
      if (filter === 'all') return true;
      if (filter === 'pending') return job.status === 'requested' || (job.status === 'assessment-pending' && !job.assignedElectricianId);
      if (filter === 'fee-pending') return ['matched', 'assessment-pending', 'quoted'].includes(job.status);
      if (filter === 'in-progress') return ['payment-pending', 'work-in-progress', 'electrician-complete', 'payout-complete'].includes(job.status);
      return true;
    });

    $('#requests-list').innerHTML = filtered.length
      ? filtered.map(renderJobCard).join('')
      : '<div class="empty-state"><div class="empty-state-icon">📭</div><div class="empty-state-text">No requests in this view.</div></div>';

    $$('.admin-job-card').forEach((card) => {
      card.addEventListener('click', () => openRequestDetail(card.dataset.jobId));
    });

    bindRequestFilters();
  }

  function bindRequestFilters() {
    $$('#requests-filter-tabs .admin-filter-tab').forEach((tab) => {
      tab.onclick = () => {
        $$('#requests-filter-tabs .admin-filter-tab').forEach((item) => item.classList.remove('active'));
        tab.classList.add('active');
        currentFilter.requests = tab.dataset.filter;
        renderRequests();
      };
    });
  }

  function renderJobCard(job) {
    const urgency = formatUrgency(job.urgency);
    const categories = (job.issueCategories || []).map((category) => '<span class="admin-tag">' + category + '</span>').join('');
    const assigned = job.electricianName || 'No specialist yet';
    const countNote = job.availabilityCount ? (job.availabilityCount + ' available in area') : 'Availability not checked';
    const flowStep = adminFlowStep(job);

    return '<div class="admin-job-card" data-job-id="' + job.id + '">' +
      '<div class="admin-job-card-top">' +
        '<div>' +
          '<div class="admin-job-card-name">' + (job.customerName || 'Customer') + '</div>' +
          '<div class="admin-job-card-id">' + (job.ticket || job.id) + ' · ' + job.serviceArea + '</div>' +
        '</div>' +
        '<span class="badge ' + statusClass(job.status) + '">' + statusLabel(job.status) + '</span>' +
      '</div>' +
      '<div class="admin-job-card-tags">' + categories + '</div>' +
      '<div class="admin-job-card-row"><span class="badge ' + urgency[1] + '">' + urgency[0] + '</span><span>' + countNote + '</span></div>' +
      '<div class="admin-job-card-row">Assigned: ' + assigned + '</div>' +
      '<div class="admin-job-card-row">Next: ' + flowStep + '</div>' +
      '<div class="admin-job-card-bottom">' +
        '<div class="admin-job-card-amount">' + fmt(jobAmount(job)) + '</div>' +
        '<div class="large-contract-flag">' + (job.assessmentRequested ? 'Assessment' : 'Remote Quote') + '</div>' +
      '</div>' +
    '</div>';
  }

  function adminFlowStep(job) {
    if (job.status === 'requested' || !job.assignedElectricianId) return 'assign or reassign VoltFriq';
    if (job.status === 'assessment-pending' && !job.assessmentFeePaid) return 'watch assessment fee confirmation';
    if (['matched', 'assessment-pending'].includes(job.status) && job.visitStage === 'awaiting-acceptance') return 'VoltFriq must accept assignment';
    if (job.status === 'matched') return job.assessmentRequested ? 'assessment and quote due' : 'remote quote due';
    if (job.status === 'quoted') return 'customer quote decision';
    if (job.status === 'payment-pending' && !job.paymentConfirmedAt) return 'customer payment confirmation';
    if (job.status === 'payment-pending') return 'VoltFriq can start work';
    if (job.status === 'work-in-progress') return 'work completion tracking';
    if (job.status === 'electrician-complete') return 'customer confirmation and payout release';
    if (job.status === 'payout-complete') return 'customer rating';
    if (job.status === 'rated') return 'closed with receipt';
    if (job.status === 'cancelled') return 'cancelled';
    return 'monitor job progress';
  }

  function openRequestDetail(jobId) {
    const job = Store.refreshJobFinancials(Store.getJob(jobId));
    if (!job) return;
    currentJobId = job.id;
    selectedCandidateId = job.assignedElectricianId || job.recommendedElectricianId || null;

    const customerCard =
      '<div class="admin-info-card">' +
        '<div class="admin-info-card-title">👤 Customer</div>' +
        infoRow('Name', job.customerName || 'Customer') +
        infoRow('Area', job.serviceArea || 'N/A') +
        infoRow('Urgency', formatUrgency(job.urgency)[0]) +
        infoRow('Issue', (job.issueCategories || []).join(', ')) +
        infoRow('Note', job.description || 'No additional note') +
      '</div>';

    const snapshotCard =
      '<div class="admin-info-card">' +
        '<div class="admin-info-card-title">🔍 Snapshots</div>' +
        infoRow('Available in area', String(job.availabilityCount || 0)) +
        infoRow('Assessment', job.assessmentRequested ? (job.assessmentFeePaid ? 'Paid' : 'Pending') : 'Skipped') +
        infoRow('Billing', job.billingModeSnapshot === 'per-second' ? 'Per-second labour' : 'Fixed labour') +
        infoRow('Payout', job.payoutModeSnapshot === 'direct-to-electrician' ? 'Direct to VoltFriq' : 'Platform hold') +
        infoRow('Materials', job.materialHandling === 'self-procured' ? 'Customer buys materials' : 'Voltfriq buys materials') +
      '</div>';

    const candidates = Store.rankElectricians(job.serviceArea, job.issueCategories || []);
    const candidateOptions = candidates.length
      ? candidates.map((electrician) => {
          const selected = electrician.id === selectedCandidateId ? ' selected' : '';
          return '<div class="admin-elec-option' + selected + '" data-elec-id="' + electrician.id + '">' +
            '<div class="admin-elec-avatar">' + (electrician.avatar || '👷') + '</div>' +
            '<div class="admin-elec-info">' +
              '<div class="admin-elec-name">' + electrician.name + '</div>' +
              '<div class="admin-elec-meta"><span>★ ' + (electrician.rating ? electrician.rating.toFixed(1) : '--') + '</span><span>' + (electrician.jobsCompleted || electrician.jobs || 0) + ' jobs</span><span>' + electrician.distance + ' km</span></div>' +
              '<div class="admin-skill-match">' + electrician.matchReason + '</div>' +
            '</div>' +
          '</div>';
        }).join('')
      : '<div class="empty-state"><div class="empty-state-icon">👷</div><div class="empty-state-text">No approved VoltFriqs are currently available for this area.</div></div>';

    const assignmentCard =
      '<div class="admin-assign-section">' +
        '<div class="admin-assign-title">Assignment Override</div>' +
        '<div style="font-size:13px;color:#92400E;margin-bottom:10px;">Customer saw ' + (job.availabilityCount || 0) + ' available VoltFriqs and the current recommendation is ranked by expertise, rating, jobs, and distance.</div>' +
        candidateOptions +
        '<button class="btn-primary btn-full" id="btn-assign-send"' + (candidates.length ? '' : ' disabled') + ' style="margin-top:12px">' + (job.assignedElectricianId ? 'Reassign VoltFriq' : 'Assign VoltFriq') + '</button>' +
      '</div>';

    const quote = job.quote;
    const quoteCard = quote && (quote.items.length || quote.materials.length)
      ? '<div class="admin-info-card">' +
          '<div class="admin-info-card-title">💰 Quote Summary</div>' +
          infoRow('Labour total', fmt(quote.laborTotal || 0)) +
          infoRow('Material total', fmt(quote.materialTotal || 0)) +
          infoRow('Customer pays now', fmt(quote.customerPayableTotal || 0)) +
        '</div>'
      : '';

    const payout = Store.getPayoutDestination(job);
    const paymentCard =
      '<div class="admin-info-card">' +
        '<div class="admin-info-card-title">💳 Payout Visibility</div>' +
        infoRow('Destination', payout.label) +
        infoRow('Bank', payout.bankName) +
        infoRow('Account', payout.accountNumber) +
        infoRow('State', job.payoutState || 'Awaiting payment') +
      '</div>';

    $('#request-detail-body').innerHTML =
      customerCard +
      snapshotCard +
      assignmentCard +
      quoteCard +
      paymentCard +
      '<div class="admin-chat-wrap">' +
        '<div class="admin-chat-header">💬 Job Chat</div>' +
        '<div id="admin-job-chat" class="chat-container" style="flex:1;min-height:0"></div>' +
      '</div>';

    $$('.admin-elec-option').forEach((option) => {
      option.addEventListener('click', () => {
        selectedCandidateId = option.dataset.elecId;
        $$('.admin-elec-option').forEach((item) => item.classList.toggle('selected', item.dataset.elecId === selectedCandidateId));
      });
    });

    const assignButton = $('#btn-assign-send');
    if (assignButton) {
      assignButton.addEventListener('click', () => {
        if (!selectedCandidateId) return;
        assignOrReassignJob(job.id, selectedCandidateId);
      });
    }

    goTo('admin-request-detail');
    Chat.destroy();
    setTimeout(() => Chat.init('admin-job-chat', job.id, 'admin', currentAdminName()), 0);
  }

  function assignOrReassignJob(jobId, electricianId) {
    let job = Store.getJob(jobId);
    const electrician = Store.getElectrician(electricianId);
    if (!job || !electrician) return;

    job.assignedElectricianId = electrician.id;
    job.electricianName = electrician.name;
    job.recommendedElectricianId = job.recommendedElectricianId || electrician.id;
    if (job.status === 'requested') {
      job.status = job.assessmentRequested ? 'assessment-pending' : 'matched';
    }
    job = Store.addTimelineEvent(job, job.status, 'Admin assigned ' + electrician.name);
    job = Store.saveJob(job);
    Chat.sendSystemMessage(job.id, 'Admin assigned ' + electrician.name + ' to this job.');

    renderRequests();
    openRequestDetail(job.id);
  }

  function renderElectricians() {
    const electricians = Store.getElectricians();
    const filtered = electricians.filter((electrician) => {
      const filter = currentFilter.electricians;
      if (filter === 'all') return true;
      if (filter === 'pending') return electrician.status === 'pending' || electrician.onboardingStatus === 'pending-review';
      if (filter === 'active') return electrician.status === 'active';
      if (filter === 'suspended') return electrician.status === 'suspended' || electrician.status === 'removed';
      return true;
    });

    $('#elec-list').innerHTML = filtered.length
      ? filtered.map((electrician) => {
          const expertise = (electrician.expertise || []).slice(0, 3).map((skill) => '<span class="admin-skill-tag">' + skill + '</span>').join('');
          const more = (electrician.expertise || []).length > 3 ? '<span class="admin-skill-tag">+' + (electrician.expertise.length - 3) + '</span>' : '';
          return '<div class="admin-elec-card" data-elec-id="' + electrician.id + '">' +
            '<div class="admin-elec-card-avatar">' + (electrician.avatar || '👷') + '</div>' +
            '<div class="admin-elec-card-info">' +
              '<div class="admin-elec-card-name">' + electrician.name + ' <span class="badge ' + statusClass(electrician.status) + '" style="margin-left:6px">' + statusLabel(electrician.status) + '</span></div>' +
              '<div class="admin-elec-card-meta"><span>★ ' + (electrician.rating ? electrician.rating.toFixed(1) : '--') + '</span><span>' + (electrician.jobsCompleted || electrician.jobs || 0) + ' jobs</span><span>' + (electrician.serviceAreas || []).join(', ') + '</span></div>' +
              '<div class="admin-elec-card-skills">' + expertise + more + '</div>' +
            '</div>' +
          '</div>';
        }).join('')
      : '<div class="empty-state"><div class="empty-state-icon">👷</div><div class="empty-state-text">No electricians in this view.</div></div>';

    $$('.admin-elec-card').forEach((card) => {
      card.addEventListener('click', () => openElecDetail(card.dataset.elecId));
    });

    bindElecFilters();
  }

  function bindElecFilters() {
    $$('#elec-filter-tabs .admin-filter-tab').forEach((tab) => {
      tab.onclick = () => {
        $$('#elec-filter-tabs .admin-filter-tab').forEach((item) => item.classList.remove('active'));
        tab.classList.add('active');
        currentFilter.electricians = tab.dataset.filter;
        renderElectricians();
      };
    });
  }

  function openElecDetail(elecId) {
    const electrician = Store.getElectrician(elecId);
    if (!electrician) return;
    currentElecId = elecId;

    const jobs = Store.getJobs().filter((job) => job.assignedElectricianId === electrician.id);
    const documents = (electrician.documents || []).map((doc) => {
      return '<div class="admin-skill-item">' +
        '<span class="admin-skill-name">' + doc.label + '</span>' +
        '<div class="admin-skill-actions">' +
          '<button class="admin-skill-btn approve ' + (doc.status === 'approved' ? 'active' : '') + '" data-doc-id="' + doc.id + '" data-doc-action="approved">Approve</button>' +
          '<button class="admin-skill-btn reject ' + (doc.status === 'rejected' ? 'active' : '') + '" data-doc-id="' + doc.id + '" data-doc-action="rejected">Reject</button>' +
        '</div>' +
      '</div>';
    }).join('');

    const expertise = (electrician.skills || []).map((skill, index) => {
      return '<div class="admin-skill-item">' +
        '<span class="admin-skill-name">' + skill.name + '</span>' +
        '<div class="admin-skill-actions">' +
          '<button class="admin-skill-btn approve ' + (skill.status === 'approved' ? 'active' : '') + '" data-skill-idx="' + index + '" data-skill-action="approved">Approve</button>' +
          '<button class="admin-skill-btn reject ' + (skill.status === 'rejected' ? 'active' : '') + '" data-skill-idx="' + index + '" data-skill-action="rejected">Reject</button>' +
        '</div>' +
      '</div>';
    }).join('');

    $('#elec-detail-body').innerHTML =
      '<div class="admin-info-card">' +
        '<div class="admin-info-card-title">👷 Electrician Profile</div>' +
        infoRow('Name', electrician.name) +
        infoRow('Email', electrician.email) +
        infoRow('Phone', electrician.phone) +
        infoRow('Service areas', (electrician.serviceAreas || []).join(', ')) +
        infoRow('Experience', electrician.experience) +
        infoRow('Onboarding', electrician.onboardingStatus + ' · ' + electrician.onboardingMode) +
        infoRow('Bad ratings', String(electrician.badRatingCount)) +
        infoRow('Payout', electrician.payoutDetails.bankName + ' / ' + electrician.payoutDetails.accountNumber) +
      '</div>' +
      '<div class="admin-info-card">' +
        '<div class="admin-info-card-title">📄 Required Documents</div>' +
        '<div class="admin-skill-list">' + (documents || '<div style="color:var(--mid)">No documents supplied.</div>') + '</div>' +
      '</div>' +
      '<div class="admin-info-card">' +
        '<div class="admin-info-card-title">🔧 Expertise Review</div>' +
        '<div class="admin-skill-list">' + (expertise || '<div style="color:var(--mid)">No expertise supplied.</div>') + '</div>' +
      '</div>' +
      '<div class="admin-info-card">' +
        '<div class="admin-info-card-title">📊 Work Summary</div>' +
        infoRow('Assigned jobs', String(jobs.length)) +
        infoRow('Completed jobs', String(jobs.filter((job) => ['payout-complete', 'rated'].includes(job.status)).length)) +
        infoRow('Average rating', electrician.rating ? electrician.rating.toFixed(1) : '--') +
      '</div>' +
      actionButtonsForElectrician(electrician);

    $$('[data-doc-id]').forEach((button) => {
      button.addEventListener('click', () => updateElectricianDocument(electrician.id, button.dataset.docId, button.dataset.docAction));
    });
    $$('[data-skill-idx]').forEach((button) => {
      button.addEventListener('click', () => updateElectricianSkill(electrician.id, parseInt(button.dataset.skillIdx, 10), button.dataset.skillAction));
    });
    bindAdminElecActions(electrician.id);

    goTo('admin-elec-detail');
  }

  function actionButtonsForElectrician(electrician) {
    if (electrician.status === 'pending' || electrician.onboardingStatus === 'pending-review') {
      return '<div style="display:flex;gap:10px;margin-top:14px">' +
        '<button class="btn-primary btn-success" style="flex:1" id="btn-approve-elec">Approve</button>' +
        '<button class="btn-primary btn-danger" style="flex:1" id="btn-reject-elec">Reject</button>' +
      '</div>';
    }
    if (electrician.status === 'active') {
      return '<button class="btn-primary btn-danger btn-full" id="btn-suspend-elec" style="margin-top:14px">Suspend VoltFriq</button>';
    }
    if (electrician.status === 'suspended') {
      return '<button class="btn-primary btn-success btn-full" id="btn-reactivate-elec" style="margin-top:14px">Reactivate VoltFriq</button>';
    }
    return '';
  }

  function bindAdminElecActions(elecId) {
    const approve = $('#btn-approve-elec');
    const reject = $('#btn-reject-elec');
    const suspend = $('#btn-suspend-elec');
    const reactivate = $('#btn-reactivate-elec');

    if (approve) approve.addEventListener('click', () => setElectricianState(elecId, 'active', 'approved'));
    if (reject) reject.addEventListener('click', () => setElectricianState(elecId, 'rejected', 'rejected'));
    if (suspend) suspend.addEventListener('click', () => setElectricianState(elecId, 'suspended', 'approved'));
    if (reactivate) reactivate.addEventListener('click', () => setElectricianState(elecId, 'active', 'approved'));
  }

  function setElectricianState(elecId, status, onboardingStatus) {
    let electrician = Store.getElectrician(elecId);
    if (!electrician) return;
    electrician.status = status;
    electrician.onboardingStatus = onboardingStatus;
    electrician.availabilityStatus = status === 'active' ? 'available' : 'offline';
    electrician = Store.saveElectrician(electrician);
    renderElectricians();
    openElecDetail(electrician.id);
  }

  function updateElectricianDocument(elecId, docId, status) {
    let electrician = Store.getElectrician(elecId);
    if (!electrician) return;
    electrician.documents = (electrician.documents || []).map((doc) => doc.id === docId ? Object.assign({}, doc, { status }) : doc);
    electrician = Store.saveElectrician(electrician);
    openElecDetail(electrician.id);
  }

  function updateElectricianSkill(elecId, skillIndex, status) {
    let electrician = Store.getElectrician(elecId);
    if (!electrician) return;
    electrician.skills = (electrician.skills || []).map((skill, index) => index === skillIndex ? Object.assign({}, skill, { status }) : skill);
    electrician.expertise = electrician.skills.filter((skill) => skill.status === 'approved').map((skill) => skill.name);
    electrician.specialty = electrician.expertise[0] || electrician.specialty;
    electrician = Store.saveElectrician(electrician);
    openElecDetail(electrician.id);
  }

  function renderJobs() {
    const jobs = Store.getJobs();
    const filtered = jobs.filter((job) => {
      switch (currentFilter.jobs) {
        case 'all':
          return true;
        case 'pending':
          return job.status === 'requested';
        case 'fee-pending':
          return job.status === 'assessment-pending';
        case 'assessment':
          return job.status === 'matched';
        case 'quoted':
          return job.status === 'quoted';
        case 'payment':
          return job.status === 'payment-pending';
        case 'in-progress':
          return ['work-in-progress', 'electrician-complete'].includes(job.status);
        case 'completed':
          return ['payout-complete', 'rated', 'cancelled'].includes(job.status);
        default:
          return true;
      }
    });

    $('#jobs-list').innerHTML = filtered.length
      ? filtered.map(renderJobCard).join('')
      : '<div class="empty-state"><div class="empty-state-icon">⚡</div><div class="empty-state-text">No jobs in this filter.</div></div>';

    $$('.admin-job-card').forEach((card) => {
      card.addEventListener('click', () => openJobDetail(card.dataset.jobId));
    });

    bindJobFilters();
  }

  function bindJobFilters() {
    $$('#jobs-filter-tabs .admin-filter-tab').forEach((tab) => {
      tab.onclick = () => {
        $$('#jobs-filter-tabs .admin-filter-tab').forEach((item) => item.classList.remove('active'));
        tab.classList.add('active');
        currentFilter.jobs = tab.dataset.filter;
        renderJobs();
      };
    });
  }

  function openJobDetail(jobId) {
    const job = Store.refreshJobFinancials(Store.getJob(jobId));
    if (!job) return;
    currentJobId = jobId;

    const timeline = (job.timeline || []).map((entry) => {
      return '<div class="admin-timeline-item">' +
        '<div class="admin-timeline-dot">&#9679;</div>' +
        '<div class="admin-timeline-content">' +
          '<div class="admin-timeline-title">' + statusLabel(entry.status) + (entry.note ? ' — ' + entry.note : '') + '</div>' +
          '<div class="admin-timeline-time">' + fmtDate(entry.timestamp) + ' · ' + timeAgo(entry.timestamp) + '</div>' +
        '</div>' +
      '</div>';
    }).join('') || '<div style="color:var(--mid);font-size:13px;padding:8px 0">No timeline events</div>';

    const quote = job.quote || { items: [], materials: [] };
    const quoteRows = quote.items.map((item) => infoRow(item.description, fmt(item.amount))).join('') +
      quote.materials.map((material) => infoRow(material.name + ' (x' + material.quantity + ')', fmt(material.quantity * material.unitPrice))).join('');

    const payout = Store.getPayoutDestination(job);

    $('#job-detail-body').innerHTML =
      '<div class="admin-dual-cards">' +
        '<div class="admin-info-card">' +
          '<div class="admin-info-card-title">📋 Job Summary</div>' +
          infoRow('Ticket', job.ticket) +
          infoRow('Customer', job.customerName || 'Customer') +
          infoRow('VoltFriq', job.electricianName || 'Unassigned') +
          infoRow('Area', job.serviceArea || 'N/A') +
          infoRow('Status', '<span class="badge ' + statusClass(job.status) + '">' + statusLabel(job.status) + '</span>') +
          infoRow('Next', adminFlowStep(job)) +
        '</div>' +
        '<div class="admin-info-card">' +
          '<div class="admin-info-card-title">💡 Business Rules</div>' +
          infoRow('Assessment', job.assessmentRequested ? (job.assessmentFeePaid ? 'Paid' : 'Pending') : 'Skipped') +
          infoRow('Billing', job.billingModeSnapshot === 'per-second' ? 'Per-second labour' : 'Fixed labour') +
          infoRow('Materials', job.materialHandling === 'self-procured' ? 'Customer buys' : 'Voltfriq buys') +
          infoRow('Payout', job.payoutModeSnapshot === 'direct-to-electrician' ? 'Direct pay' : 'Platform hold') +
        '</div>' +
      '</div>' +
      '<div class="admin-info-card">' +
        '<div class="admin-info-card-title">📜 Timeline</div>' +
        '<div class="admin-timeline">' + timeline + '</div>' +
      '</div>' +
      '<div class="admin-info-card">' +
        '<div class="admin-info-card-title">💰 Quote &amp; Settlement</div>' +
        quoteRows +
        infoRow('Labour total', fmt(quote.laborTotal || 0)) +
        infoRow('Material total', fmt(quote.materialTotal || 0)) +
        infoRow('Customer pays now', fmt(quote.customerPayableTotal || 0)) +
      '</div>' +
      '<div class="admin-info-card">' +
        '<div class="admin-info-card-title">🏦 Payout Destination</div>' +
        infoRow('Label', payout.label) +
        infoRow('Bank', payout.bankName) +
        infoRow('Account', payout.accountNumber) +
        infoRow('State', job.payoutState || 'Awaiting payment') +
      '</div>' +
      '<div class="admin-chat-wrap">' +
        '<div class="admin-chat-header">💬 Job Chat</div>' +
        '<div id="admin-job-chat" class="chat-container" style="flex:1;min-height:0"></div>' +
      '</div>';

    goTo('admin-job-detail');
    Chat.destroy();
    setTimeout(() => Chat.init('admin-job-chat', job.id, 'admin', currentAdminName()), 0);
  }

  function renderMaterials() {
    const jobs = Store.getJobs().filter((job) => job.quote && job.quote.materials && job.quote.materials.length);
    $('#materials-list').innerHTML = jobs.length
      ? jobs.map((job) => {
          const items = job.quote.materials.map((material) => {
            return '<div class="admin-material-item"><span>' + material.name + ' (x' + material.quantity + ')</span><span>' + fmt(material.quantity * material.unitPrice) + '</span></div>';
          }).join('');
          return '<div class="admin-material-card">' +
            '<div class="admin-material-header"><div><div class="admin-material-job">' + job.ticket + '</div><div style="font-size:12px;color:var(--mid)">' + (job.materialHandling === 'self-procured' ? 'Customer buys materials' : 'Voltfriq buys materials') + '</div></div></div>' +
            '<div class="admin-material-items">' + items + '</div>' +
          '</div>';
        }).join('')
      : '<div class="empty-state"><div class="empty-state-icon">📦</div><div class="empty-state-text">No material quotes yet.</div></div>';
  }

  function renderFinance() {
    const jobs = Store.getJobs();
    const totalRevenue = jobs.filter((job) => ['payout-complete', 'rated'].includes(job.status)).reduce((sum, job) => sum + jobAmount(job), 0);
    const transactions = jobs
      .filter((job) => job.receipt || job.paymentConfirmedAt)
      .map((job) => ({
        type: 'payment',
        desc: 'Job payment — ' + (job.ticket || job.id),
        customer: job.customerName || 'Customer',
        amount: job.receipt ? job.receipt.amount : jobAmount(job),
        date: job.receipt ? job.receipt.date : job.paymentConfirmedAt
      }))
      .sort((a, b) => b.date - a.date);

    $('#finance-summary').innerHTML =
      '<div class="admin-finance-summary">' +
        '<div class="admin-finance-label">Total Revenue</div>' +
        '<div class="admin-finance-total">' + fmt(totalRevenue) + '</div>' +
        '<div class="admin-finance-row">' +
          '<div class="admin-finance-metric"><div class="admin-finance-metric-value">' + transactions.length + '</div><div class="admin-finance-metric-label">Transactions</div></div>' +
          '<div class="admin-finance-metric"><div class="admin-finance-metric-value">' + jobs.filter((job) => ['payout-complete', 'rated'].includes(job.status)).length + '</div><div class="admin-finance-metric-label">Closed Jobs</div></div>' +
          '<div class="admin-finance-metric"><div class="admin-finance-metric-value">' + jobs.filter((job) => job.payoutModeSnapshot === 'direct-to-electrician').length + '</div><div class="admin-finance-metric-label">Direct Pay</div></div>' +
        '</div>' +
      '</div>';

    $('#finance-tx-list').innerHTML = transactions.length
      ? transactions.map((tx) => {
          return '<div class="admin-tx-item">' +
            '<div class="admin-tx-icon payment">💰</div>' +
            '<div class="admin-tx-info"><div class="admin-tx-desc">' + tx.desc + '</div><div class="admin-tx-date">' + tx.customer + ' · ' + fmtDate(tx.date) + '</div></div>' +
            '<div class="admin-tx-amount credit">' + fmt(tx.amount) + '</div>' +
          '</div>';
        }).join('')
      : '<div class="empty-state"><div class="empty-state-icon">💳</div><div class="empty-state-text">No transactions yet.</div></div>';
  }

  function renderSettings() {
    const settings = Store.getSettings();
    const fields = ['location', 'experience', 'serviceAreas', 'expertise', 'payoutDetails'];

    $('#settings-form').innerHTML =
      '<div class="admin-settings-section">' +
        '<div class="admin-settings-section-title">Pricing &amp; Payout Rules</div>' +
        fieldTemplate('Assessment Fee (₦)', '<input type="number" class="form-input" id="set-assessment-fee" value="' + settings.defaultAssessmentFee + '" />') +
        fieldTemplate('Default Billing Mode', '<select class="form-select" id="set-billing-mode"><option value="fixed"' + (settings.defaultBillingMode === 'fixed' ? ' selected' : '') + '>Fixed</option><option value="per-second"' + (settings.defaultBillingMode === 'per-second' ? ' selected' : '') + '>Per-second</option></select>') +
        fieldTemplate('Default Payout Mode', '<select class="form-select" id="set-payout-mode"><option value="platform-hold"' + (settings.defaultPayoutMode === 'platform-hold' ? ' selected' : '') + '>Platform hold</option><option value="direct-to-electrician"' + (settings.defaultPayoutMode === 'direct-to-electrician' ? ' selected' : '') + '>Direct to VoltFriq</option></select>') +
        fieldTemplate('Platform Bank Name', '<input type="text" class="form-input" id="set-bank-name" value="' + settings.bankName + '" />') +
        fieldTemplate('Platform Account Number', '<input type="text" class="form-input" id="set-account-number" value="' + settings.accountNumber + '" />') +
        fieldTemplate('Platform Account Name', '<input type="text" class="form-input" id="set-account-name" value="' + settings.accountName + '" />') +
      '</div>' +
      '<div class="admin-settings-section">' +
        '<div class="admin-settings-section-title">Discipline Rules</div>' +
        fieldTemplate('Bad Ratings Count As', '<input type="text" class="form-input" id="set-bad-stars" value="' + settings.badRatingStars.join(', ') + '" placeholder="e.g. 1, 2" />') +
        fieldTemplate('Bad Rating Threshold', '<input type="number" class="form-input" id="set-bad-threshold" value="' + settings.badRatingThreshold + '" />') +
        fieldTemplate('Action At Threshold', '<select class="form-select" id="set-bad-action"><option value="suspend"' + (settings.badRatingAction === 'suspend' ? ' selected' : '') + '>Suspend</option><option value="remove"' + (settings.badRatingAction === 'remove' ? ' selected' : '') + '>Remove</option></select>') +
      '</div>' +
      '<div class="admin-settings-section">' +
        '<div class="admin-settings-section-title">Service Areas</div>' +
        '<div class="admin-cat-list" id="service-area-list">' + renderChipList(settings.serviceAreas, 'service-area') + '</div>' +
        '<div class="admin-cat-add-row"><input type="text" class="form-input" id="set-new-service-area" placeholder="Add a service area" /><button class="btn-primary" id="btn-add-service-area">Add</button></div>' +
      '</div>' +
      '<div class="admin-settings-section">' +
        '<div class="admin-settings-section-title">Issue Categories</div>' +
        '<div class="admin-cat-list" id="category-list">' + renderChipList(settings.categories, 'category') + '</div>' +
        '<div class="admin-cat-add-row"><input type="text" class="form-input" id="set-new-category" placeholder="Add a category" /><button class="btn-primary" id="btn-add-category">Add</button></div>' +
      '</div>' +
      '<div class="admin-settings-section">' +
        '<div class="admin-settings-section-title">Required Electrician Fields</div>' +
        '<div class="admin-cat-list">' + fields.map((field) => {
          const active = settings.requiredElectricianFields.includes(field);
          return '<button class="chip' + (active ? ' active' : '') + '" type="button" data-required-field="' + field + '">' + field + '</button>';
        }).join('') + '</div>' +
      '</div>' +
      '<div class="admin-settings-section">' +
        '<div class="admin-settings-section-title">Required Documents</div>' +
        '<div id="required-doc-list">' + renderRequiredDocuments(settings.requiredDocuments) + '</div>' +
        '<div class="admin-cat-add-row" style="margin-top:10px"><input type="text" class="form-input" id="set-new-doc-label" placeholder="Document label" /><select class="form-select" id="set-new-doc-type"><option value="upload">Upload</option><option value="text">Text</option></select><button class="btn-primary" id="btn-add-doc">Add</button></div>' +
      '</div>' +
      '<div class="admin-settings-section">' +
        '<div class="admin-settings-section-title">Onboarding Runtime</div>' +
        fieldTemplate('Onboarding Mode', '<select class="form-select" id="set-onboarding-mode"><option value="virtual"' + (settings.onboardingConfig.mode === 'virtual' ? ' selected' : '') + '>Virtual</option><option value="live"' + (settings.onboardingConfig.mode === 'live' ? ' selected' : '') + '>Live</option></select>') +
        fieldTemplate('Video URL', '<input type="text" class="form-input" id="set-video-url" value="' + (settings.onboardingConfig.videoUrl || '') + '" />') +
        fieldTemplate('Welcome Note', '<textarea class="form-input" rows="3" id="set-onboarding-welcome">' + (settings.onboardingConfig.welcomeNote || '') + '</textarea>') +
        fieldTemplate('Virtual Prompt', '<textarea class="form-input" rows="3" id="set-virtual-prompt">' + (settings.onboardingConfig.virtualPrompt || '') + '</textarea>') +
        fieldTemplate('Live Prompt', '<textarea class="form-input" rows="3" id="set-live-prompt">' + (settings.onboardingConfig.livePrompt || '') + '</textarea>') +
      '</div>' +
      '<div class="admin-settings-section">' +
        '<div class="admin-settings-section-title">Ranking Weights</div>' +
        fieldTemplate('Rating Weight', '<input type="number" class="form-input" id="set-weight-rating" value="' + settings.rankingWeights.rating + '" />') +
        fieldTemplate('Jobs Weight', '<input type="number" class="form-input" id="set-weight-jobs" value="' + settings.rankingWeights.jobs + '" />') +
        fieldTemplate('Distance Weight', '<input type="number" class="form-input" id="set-weight-distance" value="' + settings.rankingWeights.distance + '" />') +
        fieldTemplate('Expertise Weight', '<input type="number" class="form-input" id="set-weight-expertise" value="' + settings.rankingWeights.expertise + '" />') +
      '</div>' +
      '<button class="btn-primary btn-full" id="btn-save-settings">Save Settings</button>' +
      '<div id="settings-saved-msg" style="display:none;text-align:center;color:var(--green);font-size:13px;font-weight:700;margin-top:10px">Settings saved.</div>' +
      '<div style="margin-top:16px"><button class="btn-secondary btn-full" id="go-prices" style="margin-bottom:10px">💰 Manage Workmanship Prices</button></div>' +
      '<div style="margin-top:16px;padding-top:16px;border-top:1px solid #F3F4F6"><button class="btn-ghost" id="btn-more-sections" style="width:100%;text-align:center;font-size:14px">More: Materials · Finance · Chats</button></div>' +
      '<div style="margin-top:16px;text-align:center"><button class="btn-ghost" id="btn-admin-logout" style="color:var(--red)">Logout</button></div>';

    $('#btn-save-settings').addEventListener('click', saveSettingsFromForm);
    $('#btn-add-service-area').addEventListener('click', () => addArrayItem('serviceAreas', '#set-new-service-area'));
    $('#btn-add-category').addEventListener('click', () => addArrayItem('categories', '#set-new-category'));
    $('#btn-add-doc').addEventListener('click', addRequiredDocument);
    $$('.remove-service-area').forEach((button) => button.addEventListener('click', () => removeArrayItem('serviceAreas', button.dataset.value)));
    $$('.remove-category').forEach((button) => button.addEventListener('click', () => removeArrayItem('categories', button.dataset.value)));
    $$('.remove-required-doc').forEach((button) => button.addEventListener('click', () => removeRequiredDocument(button.dataset.docId)));
    $$('[data-required-field]').forEach((button) => {
      button.addEventListener('click', () => {
        button.classList.toggle('active');
      });
    });

    $('#go-prices').addEventListener('click', () => { goTo('admin-prices'); renderPriceList(); });
    $('#btn-more-sections').addEventListener('click', () => {
      $('#btn-more-sections').outerHTML =
        '<div style="display:flex;gap:8px;flex-wrap:wrap">' +
          '<button class="btn-secondary" id="go-materials" style="flex:1">📦 Materials</button>' +
          '<button class="btn-secondary" id="go-finance" style="flex:1">💰 Finance</button>' +
          '<button class="btn-secondary" id="go-chats" style="flex:1">💬 Chats</button>' +
        '</div>';
      $('#go-materials').addEventListener('click', () => { goTo('admin-materials'); renderMaterials(); });
      $('#go-finance').addEventListener('click', () => { goTo('admin-finance'); renderFinance(); });
      $('#go-chats').addEventListener('click', () => { goTo('admin-chats'); renderChats(); });
    });
    $('#btn-admin-logout').addEventListener('click', () => {
      Store.remove('adminLoggedIn');
      stopPolling();
      $('#admin-bottom-nav').style.display = 'none';
      goTo('admin-login');
    });
  }

  function fieldTemplate(label, inputHtml) {
    return '<div class="form-group"><label class="form-label">' + label + '</label>' + inputHtml + '</div>';
  }

  function renderChipList(values, type) {
    return (values || []).map((value) => {
      return '<span class="admin-cat-chip">' + value + ' <button class="remove-' + type + '" data-value="' + value + '">&times;</button></span>';
    }).join('');
  }

  function renderRequiredDocuments(documents) {
    return (documents || []).map((doc) => {
      return '<div class="admin-skill-item">' +
        '<span class="admin-skill-name">' + doc.label + ' <span style="color:var(--mid);font-size:12px">(' + doc.type + ')</span></span>' +
        '<div class="admin-skill-actions"><button class="admin-skill-btn reject remove-required-doc" data-doc-id="' + doc.id + '">Remove</button></div>' +
      '</div>';
    }).join('');
  }

  function saveSettingsFromForm() {
    const settings = Store.getSettings();
    settings.defaultAssessmentFee = parseInt($('#set-assessment-fee').value, 10) || settings.defaultAssessmentFee;
    settings.defaultBillingMode = $('#set-billing-mode').value;
    settings.defaultPayoutMode = $('#set-payout-mode').value;
    settings.bankName = $('#set-bank-name').value.trim();
    settings.accountNumber = $('#set-account-number').value.trim();
    settings.accountName = $('#set-account-name').value.trim();
    settings.badRatingStars = $('#set-bad-stars').value.split(',').map((value) => parseInt(value.trim(), 10)).filter((value) => !Number.isNaN(value));
    settings.badRatingThreshold = parseInt($('#set-bad-threshold').value, 10) || settings.badRatingThreshold;
    settings.badRatingAction = $('#set-bad-action').value;
    settings.requiredElectricianFields = Array.from($$('[data-required-field].active')).map((button) => button.dataset.requiredField);
    settings.onboardingConfig.mode = $('#set-onboarding-mode').value;
    settings.onboardingConfig.videoUrl = $('#set-video-url').value.trim();
    settings.onboardingConfig.welcomeNote = $('#set-onboarding-welcome').value.trim();
    settings.onboardingConfig.virtualPrompt = $('#set-virtual-prompt').value.trim();
    settings.onboardingConfig.livePrompt = $('#set-live-prompt').value.trim();
    settings.rankingWeights.rating = parseInt($('#set-weight-rating').value, 10) || settings.rankingWeights.rating;
    settings.rankingWeights.jobs = parseInt($('#set-weight-jobs').value, 10) || settings.rankingWeights.jobs;
    settings.rankingWeights.distance = parseInt($('#set-weight-distance').value, 10) || settings.rankingWeights.distance;
    settings.rankingWeights.expertise = parseInt($('#set-weight-expertise').value, 10) || settings.rankingWeights.expertise;

    Store.saveSettings(settings);
    $('#settings-saved-msg').style.display = 'block';
    setTimeout(() => { $('#settings-saved-msg').style.display = 'none'; }, 1800);
  }

  function addArrayItem(key, selector) {
    const value = $(selector).value.trim();
    if (!value) return;
    const settings = Store.getSettings();
    if (!settings[key].includes(value)) {
      settings[key].push(value);
      Store.saveSettings(settings);
      renderSettings();
    }
  }

  function removeArrayItem(key, value) {
    const settings = Store.getSettings();
    settings[key] = settings[key].filter((entry) => entry !== value);
    Store.saveSettings(settings);
    renderSettings();
  }

  function addRequiredDocument() {
    const label = $('#set-new-doc-label').value.trim();
    const type = $('#set-new-doc-type').value;
    if (!label) return;
    const settings = Store.getSettings();
    settings.requiredDocuments.push({
      id: 'doc-' + Store.uid(),
      label,
      type
    });
    Store.saveSettings(settings);
    renderSettings();
  }

  function removeRequiredDocument(docId) {
    const settings = Store.getSettings();
    settings.requiredDocuments = settings.requiredDocuments.filter((doc) => doc.id !== docId);
    Store.saveSettings(settings);
    renderSettings();
  }

  function renderPriceList() {
    const prices = Store.getPriceList();
    const container = $('#price-list-container');

    container.innerHTML = prices.length
      ? prices.map((item, index) => {
          return '<div class="price-item" data-id="' + item.id + '">' +
            '<div class="price-item-info">' +
              '<div class="price-item-num">' + (index + 1) + '.</div>' +
              '<div class="price-item-details"><div class="price-item-service">' + item.service + '</div><div class="price-item-amount">' + fmt(item.price) + '</div></div>' +
            '</div>' +
            '<div class="price-item-actions">' +
              '<button class="btn-icon price-edit-btn" data-id="' + item.id + '" data-service="' + item.service + '" data-price="' + item.price + '">✎</button>' +
              '<button class="btn-icon price-delete-btn" data-id="' + item.id + '" style="color:var(--red)">🗑</button>' +
            '</div>' +
          '</div>';
        }).join('')
      : '<div class="empty-state"><div class="empty-state-icon">💰</div><div class="empty-state-text">No workmanship prices yet.</div></div>';

    $$('.price-edit-btn').forEach((button) => {
      button.addEventListener('click', () => {
        const nextService = prompt('Edit service description', button.dataset.service);
        if (!nextService) return;
        const nextPrice = prompt('Edit price (₦)', button.dataset.price);
        if (!nextPrice) return;
        Store.updatePriceItem(button.dataset.id, nextService, parseInt(nextPrice, 10) || 0);
        renderPriceList();
      });
    });

    $$('.price-delete-btn').forEach((button) => {
      button.addEventListener('click', () => {
        if (!confirm('Delete this price item?')) return;
        Store.deletePriceItem(button.dataset.id);
        renderPriceList();
      });
    });

    const addButton = $('#btn-add-price');
    if (addButton) {
      addButton.onclick = () => {
        const service = $('#new-price-service').value.trim();
        const amount = parseInt($('#new-price-amount').value, 10);
        if (!service || !amount) {
          alert('Please enter both a service description and a valid price.');
          return;
        }
        Store.addPriceItem(service, amount);
        $('#new-price-service').value = '';
        $('#new-price-amount').value = '';
        renderPriceList();
      };
    }
  }

  function renderChats() {
    const chats = Store.getJobs().filter((job) => Store.getChat(job.id).length);
    $('#chats-list').innerHTML = chats.length
      ? chats.map((job) => {
          const messages = Store.getChat(job.id);
          const lastMessage = messages[messages.length - 1];
          const preview = lastMessage.type === 'quotation'
            ? '💰 Quotation'
            : (lastMessage.type === 'assessment'
              ? '📋 Assessment'
              : (lastMessage.type === 'receipt' ? '✅ Receipt' : lastMessage.content));
          return '<div class="admin-chat-list-item" data-job-id="' + job.id + '">' +
            '<div class="admin-chat-list-avatar">💬</div>' +
            '<div class="admin-chat-list-info"><div class="admin-chat-list-name">' + job.ticket + '</div><div class="admin-chat-list-preview">' + preview + '</div></div>' +
            '<div class="admin-chat-list-meta"><div class="admin-chat-list-time">' + timeAgo(lastMessage.timestamp) + '</div></div>' +
          '</div>';
        }).join('')
      : '<div class="empty-state"><div class="empty-state-icon">💬</div><div class="empty-state-text">No chats yet.</div></div>';

    $$('.admin-chat-list-item').forEach((item) => {
      item.addEventListener('click', () => openJobDetail(item.dataset.jobId));
    });
  }

  function infoRow(label, value) {
    return '<div class="admin-info-row"><span class="admin-info-label">' + label + '</span><span class="admin-info-value">' + value + '</span></div>';
  }

  function startPolling() {
    stopPolling();
    pollTimer = setInterval(() => {
      const active = document.querySelector('.screen.active');
      if (!active) return;
      const id = active.id.replace('screen-', '');
      if (['admin-request-detail', 'admin-job-detail', 'admin-elec-detail', 'admin-settings', 'admin-prices'].includes(id)) {
        return;
      }
      refreshScreen(id);
    }, 3000);
  }

  function stopPolling() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }

  function init() {
    Store.seedIfEmpty();
    initFilterLabels();
    initLogin();
    initBottomNav();
    bindRequestFilters();
    bindElecFilters();
    bindJobFilters();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
