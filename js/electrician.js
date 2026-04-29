/* ─── VOLTFRIQ — ELECTRICIAN PORTAL ────────────────────────────── */

const ElecApp = (() => {
  let currentJob = null;
  let currentJobs = [];
  let jobSubscription = null;
  let portalSubscription = null;
  let selectedSkills = [];
  let onboardingFiles = [];
  let pendingProfilePhoto = null;
  let chatOpen = false;
  let laborItems = [];
  let materialItems = [];
  let customerReviewValue = 0;
  let selectedCustomerTags = [];
  const ISSUE_LABELS = {
    'Light fitting': 'Light issue',
    'Socket repair': 'Socket/switch issue',
    'Wiring issue': 'Wiring',
    Inverter: 'Inverter/solar',
    Generator: 'Generator connection',
    'Tripped breaker': 'Breaker/fuse',
    'General Installation': 'Full inspection',
    Other: 'Other'
  };

  async function init() {
    bindEvents();
    try {
      const boot = await Store.init();
      if (!boot.configured) {
        showError('Add your Supabase keys in js/config.js before using the electrician portal.');
        return;
      }

      if (boot.profile && boot.profile.role === 'customer') {
        window.location.href = 'index.html';
        return;
      }
      if (boot.profile && boot.profile.role === 'admin') {
        window.location.href = 'admin.html';
        return;
      }

      renderRegistrationOptions();

      if (portalSubscription) portalSubscription.unsubscribe();
      portalSubscription = Store.subscribeToPortalFeed(async () => {
        if (Store.getCurrentElectrician() && currentScreen === 'elec-dashboard') {
          await loadDashboard();
        }
        if (Store.getCurrentElectrician() && currentJob) {
          currentJob = await Store.getJob(currentJob.id);
          renderJobDetail();
          renderConfirmScreen();
        }
      });

      if (boot.profile) {
        await resumeSession();
      } else {
        goTo('elec-login');
      }
    } catch (error) {
      showError(error.message || 'Could not start the electrician portal.');
    }
  }

  function bindEvents() {
    document.getElementById('btn-login').addEventListener('click', handleLogin);
    document.getElementById('login-password').addEventListener('keydown', (event) => {
      if (event.key === 'Enter') handleLogin();
    });
    document.getElementById('btn-apply').addEventListener('click', () => goTo('elec-reg-1'));

    document.getElementById('btn-reg-next-1').addEventListener('click', nextRegistrationStepOne);
    document.getElementById('btn-reg-next-2').addEventListener('click', nextRegistrationStepTwo);
    document.getElementById('btn-reg-next-3').addEventListener('click', nextRegistrationStepThree);
    document.getElementById('btn-reg-next-4').addEventListener('click', nextRegistrationStepFour);
    document.getElementById('btn-submit-application').addEventListener('click', submitApplication);
    document.getElementById('btn-pending-back').addEventListener('click', handleLogout);
    document.getElementById('btn-appeal-logout').addEventListener('click', handleLogout);
    document.getElementById('btn-submit-appeal').addEventListener('click', submitAppeal);
    document.getElementById('btn-notifications').addEventListener('click', openNewestAssignment);

    document.getElementById('btn-add-labor').addEventListener('click', () => addLineItem('labor'));
    document.getElementById('btn-add-material').addEventListener('click', () => addLineItem('material'));
    document.getElementById('btn-submit-assessment').addEventListener('click', submitQuote);
    document.getElementById('btn-confirm-work').addEventListener('click', markComplete);
    document.getElementById('btn-submit-customer-review').addEventListener('click', submitCustomerReview);
    document.getElementById('customer-star-rating').addEventListener('click', (event) => {
      const star = event.target.closest('.star');
      if (!star) return;
      customerReviewValue = parseInt(star.dataset.star, 10);
      updateCustomerStars();
    });
    document.getElementById('customer-review-tags').addEventListener('click', (event) => {
      const tag = event.target.closest('[data-customer-tag]');
      if (!tag) return;
      tag.classList.toggle('active');
      selectedCustomerTags = Array.from(document.querySelectorAll('#customer-review-tags [data-customer-tag].active')).map((item) => item.dataset.customerTag);
    });

    document.getElementById('btn-logout').addEventListener('click', handleLogout);
    document.getElementById('btn-add-skill').addEventListener('click', openAddSkillModal);
    document.getElementById('btn-close-skill-modal').addEventListener('click', closeAddSkillModal);
    document.getElementById('btn-save-new-skill').addEventListener('click', saveSelectedSkills);
    document.getElementById('btn-save-availability').addEventListener('click', saveAvailability);

    document.querySelectorAll('.nav-item[data-nav]').forEach((button) => {
      button.addEventListener('click', () => handleNav(button.dataset.nav));
    });
  }

  async function resumeSession() {
    const electrician = Store.getCurrentElectrician();
    if (!electrician) {
      goTo('elec-login');
      return;
    }

    if (electrician.status === 'pending') {
      document.getElementById('pending-ref-id').textContent = electrician.id.slice(0, 8).toUpperCase();
      goTo('elec-pending');
      return;
    }
    if (electrician.status === 'suspended') {
      await renderAppealScreen(electrician);
      goTo('elec-appeal');
      return;
    }
    if (electrician.status === 'rejected') {
      document.getElementById('pending-ref-id').textContent = electrician.id.slice(0, 8).toUpperCase();
      document.querySelector('.elec-pending-title').textContent = 'Application Needs Review';
      document.querySelector('.elec-pending-sub').textContent = 'Your onboarding has not been approved yet. VoltFriq support will contact you.';
      document.querySelector('.elec-pending-note').textContent = 'Contact VoltFriq support if you need help with your application or account status.';
      goTo('elec-pending');
      return;
    }

    await loadDashboard();
    goTo('elec-dashboard');
  }

  async function handleLogin() {
    await withButtonLoading('btn-login', 'Signing In...', async () => {
      const email = document.getElementById('login-email').value.trim();
      const password = document.getElementById('login-password').value.trim();
      if (!email || !password) throw new Error('Enter your email and password.');
      await Store.signIn(email, password);
      if ((Store.getCurrentProfile() || {}).role !== 'electrician') {
        throw new Error('This account is not registered as a VoltFriq.');
      }
      await resumeSession();
    });
  }

  function renderRegistrationOptions() {
    const settings = Store.getSettings();
    document.getElementById('reg-service-areas').innerHTML = (settings.service_areas || []).map((area) => chipMarkup('area', area)).join('');
    document.getElementById('reg-skills-grid').innerHTML = (settings.issue_categories || []).map((skill) => chipMarkup('skill', skill)).join('');

    document.getElementById('reg-service-areas').addEventListener('click', toggleChip);
    document.getElementById('reg-skills-grid').addEventListener('click', toggleChip);

    document.getElementById('reg-photo').addEventListener('click', () => {
      const input = document.getElementById('reg-photo-input') || createHiddenFileInput('reg-photo-input');
      input.click();
    });

    createHiddenFileInput('reg-photo-input').addEventListener('change', (event) => {
      pendingProfilePhoto = event.target.files && event.target.files[0] ? event.target.files[0] : null;
      document.getElementById('reg-photo').innerHTML = '<span class="photo-icon">✓</span><span>' + (pendingProfilePhoto ? pendingProfilePhoto.name : 'Tap to upload photo') + '</span>';
    });

    renderDocumentFields();
    renderOnboardingQuestions();
  }

  function createHiddenFileInput(id) {
    let input = document.getElementById(id);
    if (input) return input;
    input = document.createElement('input');
    input.type = 'file';
    input.id = id;
    input.style.display = 'none';
    document.body.appendChild(input);
    return input;
  }

  function renderDocumentFields() {
    const container = document.getElementById('reg-document-fields');
    container.innerHTML = [
      documentFieldMarkup('government_id', 'Government ID'),
      documentFieldMarkup('certification', 'Trade license or certification'),
      documentFieldMarkup('bank_proof', 'Bank detail proof')
    ].join('');

    container.querySelectorAll('input[type="file"]').forEach((field) => {
      field.addEventListener('change', () => {
        const name = field.files && field.files[0] ? field.files[0].name : 'Choose file';
        field.nextElementSibling.textContent = name;
      });
    });
  }

  function renderOnboardingQuestions() {
    const questions = [
      'How do you make a customer feel safe before starting electrical work?',
      'When do you stop a remote diagnosis and request an on-site assessment?',
      'How do you document findings, materials, and completed work clearly?'
    ];
    document.getElementById('onboarding-question-list').innerHTML = questions.map((question, index) => {
      return '<div class="elec-question-card">' +
        '<div class="elec-question-title">' + question + '</div>' +
        '<textarea class="form-input" rows="3" data-onboarding-question="' + index + '" placeholder="Type your answer here"></textarea>' +
      '</div>';
    }).join('');
  }

  function nextRegistrationStepOne() {
    const required = ['reg-name', 'reg-phone', 'reg-email', 'reg-password', 'reg-location'];
    const missing = required.some((id) => !document.getElementById(id).value.trim());
    if (missing) {
      showError('Complete your personal details before continuing.');
      return;
    }
    goTo('elec-reg-2');
  }

  function nextRegistrationStepTwo() {
    const serviceAreas = activeChipValues('#reg-service-areas .chip.active', 'area');
    if (!serviceAreas.length) {
      showError('Choose at least one service area before continuing.');
      return;
    }
    goTo('elec-reg-3');
  }

  function nextRegistrationStepThree() {
    const experience = document.getElementById('reg-experience').value;
    const skills = activeChipValues('#reg-skills-grid .chip.active', 'skill');
    if (!experience || !skills.length) {
      showError('Add your experience and skill set before continuing.');
      return;
    }
    const answers = Array.from(document.querySelectorAll('[data-onboarding-question]')).map((field) => field.value.trim());
    if (answers.some((answer) => !answer)) {
      showError('Answer the short safety questions before continuing.');
      return;
    }
    selectedSkills = skills.slice();
    goTo('elec-reg-4');
  }

  function nextRegistrationStepFour() {
    goTo('elec-reg-5');
  }

  async function submitApplication() {
    await withButtonLoading('btn-submit-application', 'Submitting Application...', async () => {
      if (!document.getElementById('reg-onboarding-confirm').checked) {
        throw new Error('Confirm the onboarding rules before submitting your application.');
      }

      const answers = Array.from(document.querySelectorAll('[data-onboarding-question]')).map((field) => field.value.trim());
      if (answers.some((answer) => !answer)) {
        throw new Error('Answer every onboarding question before submitting.');
      }

      const documents = Array.from(document.querySelectorAll('#reg-document-fields .doc-upload')).map((field) => ({
        type: field.dataset.documentType,
        file: field.files && field.files[0] ? field.files[0] : null
      })).filter((documentItem) => documentItem.file);

      if (!document.getElementById('reg-payout-bank').value.trim() || !document.getElementById('reg-payout-account-number').value.trim() || !document.getElementById('reg-payout-account-name').value.trim()) {
        throw new Error('Add payout bank details before submitting.');
      }

      await Store.signUpElectrician({
        fullName: document.getElementById('reg-name').value.trim(),
        phone: document.getElementById('reg-phone').value.trim(),
        email: document.getElementById('reg-email').value.trim(),
        password: document.getElementById('reg-password').value.trim(),
        locationLabel: document.getElementById('reg-location').value.trim(),
        yearsExperience: parseInt(document.getElementById('reg-experience').value, 10) || 0,
        availabilityStatus: document.getElementById('reg-availability-status').value || 'available',
        serviceAreas: activeChipValues('#reg-service-areas .chip.active', 'area'),
        skills: activeChipValues('#reg-skills-grid .chip.active', 'skill'),
        bankName: document.getElementById('reg-payout-bank').value.trim(),
        bankAccountNumber: document.getElementById('reg-payout-account-number').value.trim(),
        bankAccountName: document.getElementById('reg-payout-account-name').value.trim(),
        profilePhoto: pendingProfilePhoto,
        documents: documents
      });

      document.getElementById('pending-ref-id').textContent = (Store.getCurrentElectrician() || { id: 'pending' }).id.slice(0, 8).toUpperCase();
      goTo('elec-pending');
    });
  }

  async function loadDashboard() {
    try {
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
    const pendingPayout = currentJobs
      .filter((job) => ['customer_confirmed', 'payout_pending'].includes(job.status))
      .reduce((sum, job) => sum + (job.quote.total || 0), 0);
    document.getElementById('dash-avatar').textContent = '⚡';
    document.getElementById('dash-name').textContent = profile.full_name || 'VoltFriq';
    document.getElementById('dash-live-status').textContent = electrician.availability_status === 'available' ? 'Available for jobs' : 'Offline for now';
    document.getElementById('stat-jobs-month').textContent = currentJobs.length;
    document.getElementById('stat-earnings').textContent = Store.formatCurrency(currentJobs.filter((job) => ['payout_complete', 'rated'].includes(job.status)).reduce((sum, job) => sum + (job.quote.total || 0), 0));
    document.getElementById('stat-rating').textContent = electrician.average_rating ? Number(electrician.average_rating).toFixed(1) : '--';
    document.getElementById('stat-payouts').textContent = Store.formatCurrency(pendingPayout);
    renderTrustPanel(electrician);
  }

  function renderTrustPanel(electrician) {
    const level = electrician.level_badge || 'Verified Pro';
    const completed = Number(electrician.completed_jobs || 0);
    const rating = Number(electrician.average_rating || 0);
    const nextGoal = nextLevelGoal(level, completed, rating);
    const watchlist = electrician.watchlist
      ? '<div class="elec-watch-note">Watchlist: ' + escapeHtml(electrician.watchlist_reason || 'Admin is monitoring recent performance.') + '</div>'
      : '';
    document.getElementById('dash-trust-panel').innerHTML =
      '<div class="elec-level-pill">' + escapeHtml(level) + '</div>' +
      '<div class="elec-trust-title">Grow with good jobs</div>' +
      '<div class="elec-trust-copy">' + escapeHtml(nextGoal) + '</div>' +
      '<div class="elec-trust-meter"><span style="width:' + Math.min(100, Math.max(12, completed * 4)) + '%"></span></div>' +
      '<div class="elec-trust-meta">' + completed + ' completed · ' + (rating ? rating.toFixed(1) + '/5' : 'No rating yet') + ' · ' + Number(electrician.negative_rating_count || 0) + ' negative</div>' +
      watchlist;
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
    const photoPreview = (job.photos || []).length
      ? '<div class="elec-job-photo-stack">' + job.photos.slice(0, 3).map((photo, index) => photo.url
        ? '<img class="elec-job-photo-thumb" src="' + escapeHtml(photo.url) + '" alt="Job photo ' + (index + 1) + '" loading="lazy" />'
        : '<div class="elec-job-photo-thumb elec-job-photo-fallback">' + (index + 1) + '</div>').join('') + '</div>'
      : '';
    const actions = isNew
      ? '<div class="elec-inline-actions"><button class="btn-primary btn-full" data-inline-action="accept" data-job-id="' + job.id + '">Accept</button><button class="btn-secondary btn-full" data-inline-action="reject" data-job-id="' + job.id + '">Reject</button></div>'
      : '';
    return '<div class="' + (isNew ? 'elec-alert-card' : 'elec-job-item') + '" data-job-id="' + job.id + '">' +
      '<div class="elec-job-item-head"><div class="elec-job-item-name">' + (isNew ? 'New job request' : escapeHtml(humanizeIssue(job.issueCategory))) + '</div><div class="elec-job-item-time">' + timeAgo(new Date(job.updatedAt).getTime()) + '</div></div>' +
      '<div class="elec-job-item-tags"><span class="badge badge-yellow">' + escapeHtml(job.serviceArea) + '</span><span class="badge badge-blue">' + escapeHtml(formatUrgency(job.urgency)) + '</span>' + (job.quote.total ? '<span class="badge badge-green">' + escapeHtml(Store.formatCurrency(job.quote.total)) + '</span>' : '') + '</div>' +
      '<div class="elec-job-item-status"><span class="dot-live"></span>' + escapeHtml(job.statusLabel) + '</div>' +
      '<div class="elec-job-item-status" style="color:var(--mid)">' + escapeHtml(job.locationLabel || job.serviceArea) + ' · ' + escapeHtml(humanizeIssue(job.issueCategory)) + '</div>' +
      '<div class="elec-job-item-note">' + escapeHtml(job.description || 'No customer note added.') + '</div>' +
      customerTrustMini(job) +
      '<div class="elec-job-item-meta"><span>' + escapeHtml(distanceLabel(job)) + '</span><span>' + escapeHtml(String((job.photos || []).length)) + ' photo(s)</span></div>' +
      photoPreview +
      actions +
    '</div>';
  }

  async function openJob(jobId) {
    currentJob = await Store.getJob(jobId);
    bindJobSubscription(jobId);
    renderJobDetail();
    goTo('elec-job-detail');
  }

  function bindJobSubscription(jobId) {
    if (jobSubscription) jobSubscription.unsubscribe();
    jobSubscription = Store.subscribeToJob(jobId, async (job) => {
      currentJob = job;
      renderJobDetail();
      renderConfirmScreen();
      if (chatOpen) {
        await Chat.render();
      }
    });
  }

  function renderJobDetail() {
    if (!currentJob) return;
    document.getElementById('jd-customer').textContent = currentJob.customer && currentJob.customer.name ? currentJob.customer.name : currentJob.ticket;
    document.getElementById('jd-location').textContent = currentJob.serviceArea;
    document.getElementById('jd-ticket').textContent = currentJob.ticket;
    document.getElementById('jd-billing').textContent = currentJob.requiresAssessment ? 'Assessment + quote' : 'Remote quote';
    document.getElementById('jd-materials').textContent = currentJob.materialHandling === 'self_procured' ? 'Customer supplied' : 'VoltFriq supplied';
    document.getElementById('jd-payout').textContent = currentJob.status === 'payout_complete' ? 'Released' : 'Pending admin release';
    document.getElementById('jd-distance').textContent = distanceLabel(currentJob);
    document.getElementById('jd-categories').innerHTML = '<span class="badge badge-yellow">' + escapeHtml(humanizeIssue(currentJob.issueCategory)) + '</span><span class="badge badge-blue">' + escapeHtml(formatUrgency(currentJob.urgency)) + '</span><span class="badge badge-green">' + escapeHtml(String(currentJob.photos.length || 0)) + ' photo(s)</span>';
    document.getElementById('jd-description').textContent = (currentJob.description || 'No customer note added.') + (currentJob.locationLabel ? ' Location: ' + currentJob.locationLabel + '.' : '');
    document.getElementById('jd-urgency').textContent = currentJob.urgency.replace('-', ' ');
    document.getElementById('jd-photos').innerHTML = (currentJob.photos || []).length
      ? currentJob.photos.map((photo, index) => photo.url
        ? '<img class="elec-job-photo-card" src="' + escapeHtml(photo.url) + '" alt="Customer upload ' + (index + 1) + '" loading="lazy" />'
        : '<div class="elec-job-photo-card elec-job-photo-fallback">Photo ' + (index + 1) + '</div>').join('')
      : '<div class="elec-job-photo-empty">No photo uploaded for this request.</div>';
    document.getElementById('jd-customer-trust-card').innerHTML = customerTrustDetail(currentJob);
    renderStatusTracker();
    renderJobActions();
  }

  function renderStatusTracker() {
    const statuses = ['assigned', 'accepted', 'assessment_confirmed', 'quoted', 'payment_confirmed', 'work_in_progress', 'electrician_completed', 'payout_complete'];
    const currentIndex = Math.max(statuses.indexOf(currentJob.status), 0);
    ['track-assigned', 'track-enroute', 'track-onsite', 'track-quoted', 'track-completed'].forEach((id, index) => {
      const step = document.getElementById(id);
      step.classList.remove('done', 'active');
      if (currentIndex > index) step.classList.add('done');
      if (currentIndex === index) step.classList.add('active');
    });
  }

  function renderJobActions() {
    const container = document.getElementById('jd-actions');
    const actions = [];

    if (currentJob.status === 'assigned') {
      actions.push(actionButton('btn-accept-job', 'btn-primary btn-full', 'Accept Job'));
      actions.push(actionButton('btn-reject-job', 'btn-secondary btn-full', 'Reject Job'));
    }
    if (currentJob.status === 'assessment_confirmed') {
      actions.push(actionButton('btn-enroute-job', 'btn-primary btn-full', 'Mark En Route'));
    }
    if (currentJob.status === 'en_route') {
      actions.push(actionButton('btn-onsite-job', 'btn-primary btn-full', 'Mark On Site'));
    }
    if (currentJob.status === 'accepted' || currentJob.status === 'on_site' || currentJob.status === 'assessment_confirmed') {
      actions.push(actionButton('btn-open-quote', 'btn-primary btn-full', currentJob.requiresAssessment ? 'Prepare Quote' : 'Prepare Remote Quote'));
    }
    if (currentJob.status === 'payment_confirmed') {
      actions.push(actionButton('btn-start-work', 'btn-primary btn-full', 'Start Work'));
    }
    if (currentJob.status === 'work_in_progress') {
      actions.push(actionButton('btn-open-confirm', 'btn-primary btn-full btn-success', 'Mark Work Complete'));
    }
    if (currentJob.status === 'electrician_completed') {
      actions.push('<div class="elec-confirmed-badge"><span>✓</span> Waiting for customer confirmation</div>');
      actions.push(actionButton('btn-open-confirm-review', 'btn-secondary btn-full', currentJob.customerReview ? 'View Customer Review' : 'Rate Customer'));
    }
    if (['customer_confirmed', 'payout_pending', 'payout_complete', 'rated'].includes(currentJob.status)) {
      actions.push(actionButton('btn-open-confirm-review', 'btn-secondary btn-full', currentJob.customerReview ? 'View Customer Review' : 'Rate Customer'));
    }
    actions.push(actionButton('btn-open-chat-jd', 'btn-secondary btn-full', 'Open Chat'));

    container.innerHTML = actions.join('');
    bindAction('btn-accept-job', () => actOnJob(() => Store.acceptAssignedJob(currentJob.id)));
    bindAction('btn-reject-job', () => actOnJob(() => Store.rejectAssignedJob(currentJob.id)));
    bindAction('btn-enroute-job', () => actOnJob(() => Store.updateJobStatus(currentJob.id, 'en_route', 'VoltFriq is on the way.')));
    bindAction('btn-onsite-job', () => actOnJob(markOnSiteWithLocation));
    bindAction('btn-open-quote', openQuoteBuilder);
    bindAction('btn-start-work', () => actOnJob(() => Store.markWorkStarted(currentJob.id)));
    bindAction('btn-open-confirm', openConfirmScreen);
    bindAction('btn-open-confirm-review', openConfirmScreen);
    bindAction('btn-open-chat-jd', openChat);
  }

  async function actOnJob(work) {
    clearError();
    try {
      await work();
      await openJob(currentJob.id);
      await loadDashboard();
    } catch (error) {
      showError(error.message || 'Action failed.');
    }
  }

  async function markOnSiteWithLocation() {
    const coords = await captureCurrentPosition();
    return Store.updateJobStatus(currentJob.id, 'on_site', 'VoltFriq arrived on site.', coords ? {
      arrival_latitude: coords.latitude,
      arrival_longitude: coords.longitude,
      accuracy_meters: coords.accuracy,
      captured_at: new Date().toISOString()
    } : {
      captured_at: new Date().toISOString(),
      location_capture: 'unavailable'
    });
  }

  function captureCurrentPosition() {
    if (!navigator.geolocation) return Promise.resolve(null);
    return new Promise((resolve) => {
      navigator.geolocation.getCurrentPosition((position) => {
        resolve({
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
          accuracy: position.coords.accuracy
        });
      }, () => resolve(null), {
        enableHighAccuracy: true,
        timeout: 10000,
        maximumAge: 60000
      });
    });
  }

  async function actOnSpecificJob(jobId, work) {
    clearError();
    try {
      await work();
      await loadDashboard();
      if (currentJob && currentJob.id === jobId) {
        await openJob(jobId);
      }
    } catch (error) {
      showError(error.message || 'Action failed.');
    }
  }

  function openQuoteBuilder() {
    laborItems = [];
    materialItems = [];
    document.getElementById('assess-findings').value = '';
    document.getElementById('assess-measurements').value = '';
    document.getElementById('labor-items').innerHTML = '';
    document.getElementById('material-items').innerHTML = '';
    document.getElementById('quote-total').textContent = Store.formatCurrency(0);
    addLineItem('labor');
    goTo('elec-assessment');
  }

  function addLineItem(type) {
    const target = type === 'material' ? materialItems : laborItems;
    const container = document.getElementById(type === 'material' ? 'material-items' : 'labor-items');
    const item = {
      id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
      itemType: type,
      description: '',
      quantity: 1,
      unitPrice: 0
    };
    target.push(item);
    const wrapper = document.createElement('div');
    wrapper.className = 'elec-line-item';
    wrapper.innerHTML =
      '<input type="text" class="li-desc" placeholder="' + (type === 'material' ? 'Material name' : 'Work description') + '" data-type="' + type + '" data-id="' + item.id + '" data-field="description" />' +
      '<input type="number" class="li-qty" placeholder="Qty" value="1" data-type="' + type + '" data-id="' + item.id + '" data-field="quantity" />' +
      '<input type="number" class="li-price" placeholder="Amount" data-type="' + type + '" data-id="' + item.id + '" data-field="unitPrice" />' +
      '<button class="btn-remove-item" data-type="' + type + '" data-id="' + item.id + '">x</button>';
    container.appendChild(wrapper);
    wrapper.querySelectorAll('input').forEach((input) => input.addEventListener('input', updateLineItem));
    wrapper.querySelector('.btn-remove-item').addEventListener('click', removeLineItem);
  }

  function updateLineItem(event) {
    const input = event.target;
    const target = input.dataset.type === 'material' ? materialItems : laborItems;
    const item = target.find((entry) => entry.id === input.dataset.id);
    if (!item) return;
    if (input.dataset.field === 'quantity' || input.dataset.field === 'unitPrice') {
      item[input.dataset.field] = parseFloat(input.value || '0') || 0;
    } else {
      item[input.dataset.field] = input.value;
    }
    updateQuoteTotal();
  }

  function removeLineItem(event) {
    const button = event.target;
    const target = button.dataset.type === 'material' ? materialItems : laborItems;
    const next = target.filter((entry) => entry.id !== button.dataset.id);
    if (button.dataset.type === 'material') materialItems = next;
    else laborItems = next;
    button.parentElement.remove();
    updateQuoteTotal();
  }

  function updateQuoteTotal() {
    const total = materialItems.concat(laborItems).reduce((sum, item) => {
      return sum + ((item.quantity || 1) * (item.unitPrice || 0));
    }, 0);
    document.getElementById('quote-total').textContent = Store.formatCurrency(total);
  }

  async function submitQuote() {
    await withButtonLoading('btn-submit-assessment', 'Submitting Quote...', async () => {
      const items = laborItems.concat(materialItems)
        .filter((item) => item.description && item.unitPrice > 0)
        .map((item) => ({
          itemType: item.itemType,
          description: item.description,
          quantity: item.quantity || 1,
          unitPrice: item.unitPrice || 0
        }));
      if (!items.length) {
        throw new Error('Add at least one priced quote item before submitting.');
      }
      await Store.submitQuote(currentJob.id, {
        findings: document.getElementById('assess-findings').value.trim(),
        measurements: document.getElementById('assess-measurements').value.trim(),
        items: items
      });
      await openJob(currentJob.id);
      await loadDashboard();
    });
  }

  function openConfirmScreen() {
    renderConfirmScreen();
    goTo('elec-confirm');
  }

  function renderConfirmScreen() {
    if (!currentJob) return;
    document.getElementById('confirm-summary').innerHTML = [
      ['Ticket', currentJob.ticket],
      ['Issue', currentJob.issueCategory],
      ['Quoted total', Store.formatCurrency((currentJob.quote && currentJob.quote.total) || 0)]
    ].map(confirmRow).join('');

    document.getElementById('confirm-cust-status').innerHTML = currentJob.status === 'electrician_completed'
      ? '<div class="confirm-status-icon">⏳</div><div class="confirm-status-text">Waiting for customer confirmation</div>'
      : '<div class="confirm-status-icon">⏳</div><div class="confirm-status-text">Mark the work complete when you are done.</div>';

    document.getElementById('confirm-payout-summary').innerHTML = [
      ['Payout status', currentJob.status === 'payout_complete' ? 'Released' : 'Pending admin release'],
      ['Payment gate', 'Customer payment is manually verified by admin']
    ].map(confirmRow).join('');

    renderCustomerReviewCard();

    const button = document.getElementById('btn-confirm-work');
    const badge = document.getElementById('elec-confirmed-badge');
    if (['electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated'].includes(currentJob.status)) {
      button.style.display = 'none';
      badge.style.display = 'block';
    } else {
      button.style.display = '';
      badge.style.display = 'none';
    }
  }

  async function markComplete() {
    await withButtonLoading('btn-confirm-work', 'Marking Complete...', async () => {
      await Store.markWorkCompleted(currentJob.id);
      await openJob(currentJob.id);
      await loadDashboard();
    });
  }

  function renderCustomerReviewCard() {
    const card = document.getElementById('customer-review-card');
    if (!currentJob || !['electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated'].includes(currentJob.status)) {
      card.style.display = 'none';
      return;
    }
    card.style.display = 'block';
    if (currentJob.customerReview) {
      customerReviewValue = Number(currentJob.customerReview.score || 0);
      selectedCustomerTags = currentJob.customerReview.behavior_tags || [];
      document.getElementById('customer-review-comment').value = currentJob.customerReview.comment || '';
      document.getElementById('customer-review-comment').disabled = true;
      document.getElementById('btn-submit-customer-review').textContent = 'Customer Review Submitted';
      document.getElementById('btn-submit-customer-review').disabled = true;
    } else {
      customerReviewValue = 0;
      selectedCustomerTags = [];
      document.getElementById('customer-review-comment').value = '';
      document.getElementById('customer-review-comment').disabled = false;
      document.getElementById('btn-submit-customer-review').textContent = 'Submit Customer Review';
      document.getElementById('btn-submit-customer-review').disabled = false;
    }
    document.querySelectorAll('#customer-review-tags [data-customer-tag]').forEach((tag) => {
      tag.classList.toggle('active', selectedCustomerTags.indexOf(tag.dataset.customerTag) !== -1);
      tag.disabled = !!currentJob.customerReview;
    });
    updateCustomerStars();
  }

  function updateCustomerStars() {
    document.querySelectorAll('#customer-star-rating .star').forEach((star) => {
      const value = parseInt(star.dataset.star, 10);
      star.classList.toggle('active', value <= customerReviewValue);
      star.innerHTML = value <= customerReviewValue ? '&#9733;' : '&#9734;';
    });
  }

  async function submitCustomerReview() {
    await withButtonLoading('btn-submit-customer-review', 'Saving Review...', async () => {
      if (!currentJob) throw new Error('Open a job before reviewing the customer.');
      if (!customerReviewValue) throw new Error('Select a customer rating before submitting.');
      await Store.submitCustomerReview(currentJob.id, customerReviewValue, document.getElementById('customer-review-comment').value.trim(), selectedCustomerTags);
      await openJob(currentJob.id);
      await loadDashboard();
      renderConfirmScreen();
    });
  }

  function renderProfile() {
    const profile = Store.getCurrentProfile() || {};
    const electrician = Store.getCurrentElectrician() || {};
    document.getElementById('prof-avatar').textContent = '⚡';
    document.getElementById('prof-name').textContent = profile.full_name || 'VoltFriq';
    document.getElementById('prof-rating').textContent = electrician.average_rating ? '★ ' + Number(electrician.average_rating).toFixed(1) : '★ --';
    document.getElementById('prof-jobs').textContent = (electrician.completed_jobs || 0) + ' jobs';
    document.getElementById('prof-availability-status').value = electrician.availability_status || 'offline';
    document.getElementById('prof-skills').innerHTML = (electrician.electrician_skills || []).length
      ? electrician.electrician_skills.map((skill) => '<div class="elec-skill-item"><span class="elec-skill-name">' + escapeHtml(skill.category) + '</span><span class="skill-status approved">approved</span></div>').join('')
      : '<div class="elec-empty"><div class="elec-empty-text">No skills listed yet.</div></div>';
    document.getElementById('prof-info').innerHTML = [
      ['Phone', profile.phone || '--'],
      ['Service areas', (electrician.service_areas || []).join(', ')],
      ['Status', electrician.status || 'pending'],
      ['Level', electrician.level_badge || 'Verified Pro'],
      ['Watchlist', electrician.watchlist ? 'Yes - admin monitoring' : 'No'],
      ['Negative ratings', electrician.negative_rating_count || 0],
      ['Availability', electrician.availability_status || 'offline'],
      ['Years of experience', electrician.years_experience || 0]
    ].map(profileRow).join('');
  }

  function renderHistory() {
    const completed = currentJobs.filter((job) => ['payout_complete', 'rated'].includes(job.status));
    document.getElementById('history-list').innerHTML = completed.length
      ? completed.map((job) => '<div class="elec-hist-card elec-job-item" data-job-id="' + job.id + '">' +
          '<div class="elec-hist-top"><div><div class="elec-hist-customer">' + escapeHtml(job.customer && job.customer.name ? job.customer.name : job.ticket) + '</div><div class="elec-hist-cat">' + escapeHtml(humanizeIssue(job.issueCategory)) + '</div></div><div class="elec-hist-date">' + escapeHtml(timeAgo(new Date(job.updatedAt).getTime())) + '</div></div>' +
          '<div class="elec-job-item-tags"><span class="badge badge-yellow">' + escapeHtml(job.serviceArea) + '</span><span class="badge badge-blue">' + escapeHtml(job.statusLabel) + '</span></div>' +
          '<div class="elec-hist-bottom"><div class="elec-hist-amount">' + escapeHtml(Store.formatCurrency(job.quote.total || 0)) + '</div><div class="elec-hist-rating">' + escapeHtml(job.rating ? ('★ ' + job.rating.score) : 'Awaiting rating') + '</div></div>' +
        '</div>').join('')
      : '<div class="elec-empty"><div class="elec-empty-text">Completed jobs will appear here.</div></div>';
    document.querySelectorAll('#history-list .elec-job-item').forEach((card) => card.addEventListener('click', () => openJob(card.dataset.jobId)));
  }

  async function openChat() {
    if (!currentJob) return;
    chatOpen = true;
    document.getElementById('chat-header-title').textContent = 'Chat — ' + currentJob.ticket;
    goTo('elec-chat');
    await Chat.init('elec-chat-container', currentJob.id, 'electrician', (Store.getCurrentProfile() || {}).full_name || 'VoltFriq');
  }

  function closeChat() {
    chatOpen = false;
    if (currentJob) {
      goTo('elec-job-detail');
      return;
    }
    goTo('elec-dashboard');
  }

  async function openNewestAssignment() {
    const next = currentJobs.find((job) => job.status === 'assigned') || currentJobs[0];
    if (next) {
      await openJob(next.id);
    }
  }

  async function handleNav(nav) {
    if (nav === 'elec-dashboard') {
      await loadDashboard();
      goTo('elec-dashboard');
      return;
    }
    if (nav === 'elec-history') {
      renderHistory();
      goTo('elec-history');
      return;
    }
    if (nav === 'elec-chat') {
      await openChat();
      return;
    }
    if (nav === 'elec-profile') {
      renderProfile();
      goTo('elec-profile');
    }
  }

  function openAddSkillModal() {
    const allSkills = Store.getSettings().issue_categories || [];
    const current = new Set((Store.getCurrentElectrician() && Store.getCurrentElectrician().electrician_skills || []).map((skill) => skill.category));
    document.getElementById('modal-skills-grid').innerHTML = allSkills.map((skill) => {
      return '<button class="chip' + (current.has(skill) ? ' active' : '') + '" data-modal-skill="' + skill + '">' + skill + '</button>';
    }).join('');
    document.getElementById('modal-skills-grid').onclick = toggleChip;
    document.getElementById('add-skill-modal').style.display = 'flex';
  }

  function closeAddSkillModal() {
    document.getElementById('add-skill-modal').style.display = 'none';
  }

  async function saveSelectedSkills() {
    await withButtonLoading('btn-save-new-skill', 'Saving...', async () => {
      const skills = Array.from(document.querySelectorAll('#modal-skills-grid .chip.active')).map((chip) => chip.dataset.modalSkill);
      if (!skills.length) {
        throw new Error('Select at least one skill to save.');
      }
      await Store.replaceCurrentElectricianSkills(skills);
      renderProfile();
      closeAddSkillModal();
    });
  }

  async function saveAvailability() {
    await withButtonLoading('btn-save-availability', 'Saving...', async () => {
      await Store.updateCurrentElectrician({
        availability_status: document.getElementById('prof-availability-status').value
      });
      renderProfile();
      await loadDashboard();
    });
  }

  async function handleLogout() {
    await Store.signOut();
    window.location.href = 'electrician.html';
  }

  async function renderAppealScreen(electrician) {
    document.getElementById('appeal-reason').textContent = electrician.suspended_reason || 'Your account needs admin review before you can receive jobs.';
    const appeals = await Store.listAppeals().catch(() => []);
    const openAppeal = appeals.find((appeal) => appeal.status === 'open');
    document.getElementById('appeal-trust-summary').innerHTML = [
      ['Current level', electrician.level_badge || 'Verified Pro'],
      ['Negative ratings', electrician.negative_rating_count || 0],
      ['Completed jobs', electrician.completed_jobs || 0],
      ['Appeal status', openAppeal ? 'Submitted - waiting for admin' : 'Not submitted']
    ].map(profileRow).join('');
    document.getElementById('btn-submit-appeal').disabled = !!openAppeal;
    document.getElementById('btn-submit-appeal').textContent = openAppeal ? 'Appeal Submitted' : 'Submit Appeal';
  }

  async function submitAppeal() {
    await withButtonLoading('btn-submit-appeal', 'Submitting Appeal...', async () => {
      const note = document.getElementById('appeal-note').value.trim();
      const fileInput = document.getElementById('appeal-file');
      await Store.submitElectricianAppeal({
        note,
        file: fileInput && fileInput.files ? fileInput.files[0] : null
      });
      await renderAppealScreen(Store.getCurrentElectrician() || {});
    });
  }

  function chipMarkup(type, label) {
    return '<button class="chip" data-' + type + '="' + label + '">' + label + '</button>';
  }

  function toggleChip(event) {
    const chip = event.target.closest('.chip');
    if (chip) chip.classList.toggle('active');
  }

  function activeChipValues(selector, key) {
    return Array.from(document.querySelectorAll(selector)).map((chip) => chip.dataset[key]);
  }

  function formatUrgency(value) {
    if (value === 'emergency') return 'Emergency';
    if (value === 'this-week' || value === 'scheduled') return 'Scheduled';
    return 'Today';
  }

  function humanizeIssue(value) {
    return ISSUE_LABELS[value] || value;
  }

  function distanceLabel(job) {
    if (!job || !job.customer || !job.customer.primaryServiceArea) {
      return job.locationLabel || job.serviceArea || 'Distance unavailable';
    }
    return job.locationLabel || job.customer.primaryServiceArea || job.serviceArea || 'Distance unavailable';
  }

  function customerTrustMini(job) {
    const trust = job.customer && job.customer.trustSummary ? job.customer.trustSummary : null;
    if (!trust) return '';
    const rating = trust.totalBehaviorRatings ? Number(trust.averageBehaviorRating || 0).toFixed(1) + '/5' : 'New customer';
    return '<div class="elec-customer-trust-mini">Customer history: ' + escapeHtml(rating) + ' · ' + escapeHtml(String(trust.completedRequests || 0)) + ' completed request(s)</div>';
  }

  function customerTrustDetail(job) {
    const trust = job.customer && job.customer.trustSummary ? job.customer.trustSummary : null;
    if (!trust) {
      return '<div class="elec-section-title">Customer history</div><div class="elec-job-desc">No customer trust history is available yet.</div>';
    }
    return '<div class="elec-section-title">Private customer history</div>' +
      '<div class="elec-job-desc">Only you and admin can see this because you are assigned to this job.</div>' +
      [
        ['Behavior rating', trust.totalBehaviorRatings ? Number(trust.averageBehaviorRating || 0).toFixed(1) + '/5' : 'New customer'],
        ['Completed requests', trust.completedRequests || 0],
        ['Disputes raised', trust.disputeCount || 0],
        ['Payment issues', trust.paymentIssueCount || 0],
        ['Trust status', trust.status || 'clear']
      ].map(confirmRow).join('');
  }

  function nextLevelGoal(level, completed, rating) {
    if (level === 'Elite Pro') return 'You are at the highest VoltFriq level. Keep ratings high to stay there.';
    if (level === 'Top Rated') return 'Next goal: 60 completed jobs, 4.8 rating, and fast response to reach Elite Pro.';
    if (level === 'Trusted Pro') return 'Next goal: 25 completed jobs and at least 4.6 rating to reach Top Rated.';
    if (level === 'Rising Pro') return 'Next goal: 10 completed jobs and at least 4.3 rating to reach Trusted Pro.';
    if (completed < 3) return 'Next goal: complete 3 jobs with strong customer ratings to reach Rising Pro.';
    if (rating < 4) return 'Next goal: improve your average rating to 4.0 or higher.';
    return 'Keep accepting jobs and collecting good reviews to move up.';
  }

  function documentFieldMarkup(type, label) {
    return '<div class="doc-field-card">' +
      '<div class="doc-field-label">' + label + '</div>' +
      '<input type="file" class="form-input doc-upload" data-document-type="' + type + '" />' +
      '<div class="doc-field-help">Choose file</div>' +
    '</div>';
  }

  function actionButton(id, className, label) {
    return '<button class="' + className + '" id="' + id + '">' + label + '</button>';
  }

  function bindAction(id, handler) {
    const button = document.getElementById(id);
    if (button) button.addEventListener('click', handler);
  }

  async function withButtonLoading(buttonId, loadingText, work) {
    const button = document.getElementById(buttonId);
    const originalText = button ? button.textContent : '';
    const wasDisabled = button ? button.disabled : false;
    if (button) {
      button.disabled = true;
      button.textContent = loadingText;
    }
    clearError();
    try {
      return await work();
    } catch (error) {
      showError(error.message || 'Action failed.');
      return null;
    } finally {
      if (button) {
        button.textContent = originalText;
        button.disabled = wasDisabled;
      }
    }
  }

  function confirmRow(row) {
    return '<div class="elec-job-row"><span class="elec-job-label">' + escapeHtml(row[0]) + '</span><span class="elec-job-value">' + escapeHtml(String(row[1] || '')) + '</span></div>';
  }

  function profileRow(row) {
    return '<div class="elec-info-row"><span class="elec-info-label">' + escapeHtml(row[0]) + '</span><span class="elec-info-value">' + escapeHtml(String(row[1] || '')) + '</span></div>';
  }

  function escapeHtml(value) {
    return String(value || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function showError(message) {
    const error = document.getElementById('login-error');
    error.textContent = message;
    error.style.display = 'block';
  }

  function clearError() {
    const error = document.getElementById('login-error');
    error.textContent = '';
    error.style.display = 'none';
  }

  document.addEventListener('DOMContentLoaded', init);

  return {
    openChat,
    closeChat
  };
})();
