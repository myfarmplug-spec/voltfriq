/* ─── VOLTFRIQ OCEAN — ELECTRICIAN PORTAL JS ─────────────────────── */

const ElecApp = (() => {
  let currentElec = null;
  let currentJobId = null;
  let chatJobId = null;
  let pollTimer = null;
  let regData = {};
  let laborItems = [];
  let materialItems = [];
  let quoteMode = 'assessment';

  function init() {
    Store.seedIfEmpty();
    renderDynamicRegistration();
    bindEvents();
    restoreSession();
    startPolling();

    Store.onUpdate(() => {
      if (currentElec && currentScreen === 'elec-dashboard') {
        loadDashboard();
      }
      if (currentElec && currentScreen === 'elec-job-detail' && currentJobId) {
        openJobDetail(currentJobId);
      }
      if (currentElec && currentScreen === 'elec-confirm' && currentJobId) {
        openConfirmation(currentJobId);
      }
      if (currentElec && currentScreen === 'elec-profile') {
        loadProfile();
      }
    });
  }

  function bindEvents() {
    document.getElementById('btn-login').addEventListener('click', handleLogin);
    document.getElementById('login-password').addEventListener('keydown', (event) => {
      if (event.key === 'Enter') handleLogin();
    });
    document.getElementById('btn-apply').addEventListener('click', () => goTo('elec-reg-1'));

    document.getElementById('btn-reg-next-1').addEventListener('click', handleRegStep1);
    document.getElementById('btn-reg-next-2').addEventListener('click', handleRegStep2);
    document.getElementById('btn-submit-application').addEventListener('click', handleRegSubmit);
    document.getElementById('btn-pending-back').addEventListener('click', handlePendingBack);
    document.getElementById('btn-notifications').addEventListener('click', openNewestAssignment);

    document.getElementById('btn-add-labor').addEventListener('click', addLaborItem);
    document.getElementById('btn-add-material').addEventListener('click', addMaterialItem);
    document.getElementById('btn-submit-assessment').addEventListener('click', submitQuoteOrAssessment);

    document.getElementById('btn-confirm-work').addEventListener('click', handleConfirmWork);
    document.getElementById('btn-logout').addEventListener('click', handleLogout);
    document.getElementById('btn-add-skill').addEventListener('click', openAddSkillModal);
    document.getElementById('btn-close-skill-modal').addEventListener('click', () => {
      document.getElementById('add-skill-modal').style.display = 'none';
    });
    document.getElementById('btn-save-new-skill').addEventListener('click', handleAddSkills);
    document.getElementById('add-skill-modal').addEventListener('click', (event) => {
      if (event.target === event.currentTarget) {
        event.currentTarget.style.display = 'none';
      }
    });

    document.querySelectorAll('.nav-item[data-nav]').forEach((button) => {
      button.addEventListener('click', () => handleNavigation(button.dataset.nav));
    });
  }

  function restoreSession() {
    const stored = Store.get('currentElectrician');
    if (!stored) return;
    const fresh = Store.getElectrician(stored.id);
    if (!fresh) return;
    currentElec = fresh;
    Store.set('currentElectrician', currentElec);
    if (currentElec.status === 'pending' || currentElec.onboardingStatus === 'pending-review') {
      document.getElementById('pending-ref-id').textContent = currentElec.refId || 'VFQ-XXXXXX';
      goTo('elec-pending');
      return;
    }
    loadDashboard();
    goTo('elec-dashboard');
  }

  function handleLogin() {
    const email = document.getElementById('login-email').value.trim();
    const password = document.getElementById('login-password').value.trim();
    const error = document.getElementById('login-error');

    if (!email || !password) {
      error.textContent = 'Please enter email and password.';
      error.style.display = 'block';
      return;
    }

    const found = Store.getElectricians().find((electrician) => electrician.email === email && electrician.password === password);
    if (!found) {
      error.textContent = 'Invalid email or password.';
      error.style.display = 'block';
      return;
    }

    error.style.display = 'none';
    currentElec = found;
    Store.set('currentElectrician', currentElec);

    if (found.status === 'pending' || found.onboardingStatus === 'pending-review') {
      document.getElementById('pending-ref-id').textContent = found.refId || 'VFQ-XXXXXX';
      goTo('elec-pending');
      return;
    }

    loadDashboard();
    goTo('elec-dashboard');
  }

  function renderDynamicRegistration() {
    const settings = Store.getSettings();

    document.getElementById('reg-service-areas').innerHTML = settings.serviceAreas.map((area) => {
      return '<button class="chip" data-area="' + area + '">' + area + '</button>';
    }).join('');

    document.getElementById('reg-skills-grid').innerHTML = settings.categories.map((skill) => {
      return '<button class="chip" data-skill="' + skill + '">' + skill + '</button>';
    }).join('');

    document.getElementById('reg-service-areas').addEventListener('click', (event) => {
      const chip = event.target.closest('.chip');
      if (chip) chip.classList.toggle('active');
    });

    document.getElementById('reg-skills-grid').addEventListener('click', (event) => {
      const chip = event.target.closest('.chip');
      if (chip) chip.classList.toggle('active');
    });

    renderDocumentFields(settings.requiredDocuments);
    renderOnboarding(settings);
  }

  function renderDocumentFields(requiredDocuments) {
    const container = document.getElementById('reg-document-fields');
    container.innerHTML = requiredDocuments.map((documentRule) => {
      if (documentRule.type === 'text') {
        return '<div class="doc-field-card">' +
          '<div class="doc-field-label">' + documentRule.label + '</div>' +
          '<div class="doc-field-help">Type the requested information for admin review.</div>' +
          '<textarea class="form-input" rows="3" data-doc-id="' + documentRule.id + '" data-doc-type="text" placeholder="Enter ' + documentRule.label.toLowerCase() + '"></textarea>' +
        '</div>';
      }
      return '<div class="doc-field-card">' +
        '<div class="doc-field-label">' + documentRule.label + '</div>' +
        '<div class="doc-field-help">Upload the document name or choose a file for demo review.</div>' +
        '<input type="file" class="form-input" data-doc-id="' + documentRule.id + '" data-doc-type="upload" />' +
      '</div>';
    }).join('');
  }

  function renderOnboarding(settings) {
    const config = settings.onboardingConfig;
    const questions = Store.getSuggestedQuestions(regData.expertise || [], config.mode === 'live' ? config.livePrompt : config.virtualPrompt);

    document.getElementById('onboarding-mode-badge').textContent = config.mode === 'live' ? 'Live onboarding' : 'Virtual onboarding';
    document.getElementById('onboarding-note').textContent = config.welcomeNote || 'Follow the admin onboarding notes.';
    document.getElementById('onboarding-video-card').style.display = config.mode === 'virtual' ? '' : 'none';
    document.getElementById('onboarding-live-card').style.display = config.mode === 'live' ? '' : 'none';
    document.getElementById('onboarding-video-link').href = config.videoUrl || '#';
    document.getElementById('onboarding-live-note').textContent = config.livePrompt || 'Admin will review your live onboarding answers and approve the account.';
    document.getElementById('onboarding-question-list').innerHTML = questions.map((question, index) => {
      return '<div class="elec-question-card">' +
        '<div class="elec-question-title">' + question + '</div>' +
        '<textarea class="form-input" rows="3" data-question-idx="' + index + '" placeholder="Type your response here"></textarea>' +
      '</div>';
    }).join('');
  }

  function handleRegStep1() {
    const name = document.getElementById('reg-name').value.trim();
    const phone = document.getElementById('reg-phone').value.trim();
    const email = document.getElementById('reg-email').value.trim();
    const password = document.getElementById('reg-password').value.trim();
    const location = document.getElementById('reg-location').value.trim();

    if (!name || !phone || !email || !password || !location) {
      alert('Please fill in all required fields.');
      return;
    }

    const duplicate = Store.getElectricians().find((electrician) => electrician.email === email);
    if (duplicate) {
      alert('An account with this email already exists.');
      return;
    }

    regData = {
      name,
      first: name.split(' ')[0],
      phone,
      email,
      password,
      location
    };
    goTo('elec-reg-2');
  }

  function handleRegStep2() {
    const experience = document.getElementById('reg-experience').value;
    const certifications = document.getElementById('reg-certifications').value.trim();
    const serviceAreas = Array.from(document.querySelectorAll('#reg-service-areas .chip.active')).map((chip) => chip.dataset.area);
    const expertise = Array.from(document.querySelectorAll('#reg-skills-grid .chip.active')).map((chip) => chip.dataset.skill);
    const documents = collectDocumentValues();
    const payoutDetails = {
      bankName: document.getElementById('reg-payout-bank').value.trim(),
      accountNumber: document.getElementById('reg-payout-account-number').value.trim(),
      accountName: document.getElementById('reg-payout-account-name').value.trim()
    };

    if (!experience) {
      alert('Please select your years of experience.');
      return;
    }
    if (!serviceAreas.length) {
      alert('Please select at least one service area.');
      return;
    }
    if (!expertise.length) {
      alert('Please choose at least one area of expertise.');
      return;
    }
    if (!payoutDetails.bankName || !payoutDetails.accountNumber || !payoutDetails.accountName) {
      alert('Please enter the payout bank details requested by admin.');
      return;
    }
    if (documents.some((documentRule) => !documentRule.value)) {
      alert('Please provide every required document or text response before continuing.');
      return;
    }

    regData.experience = experience + (String(experience).includes('year') ? '' : ' years');
    regData.certifications = certifications;
    regData.serviceAreas = serviceAreas;
    regData.expertise = expertise;
    regData.skills = expertise.map((skill) => ({ name: skill, status: 'pending' }));
    regData.documents = documents;
    regData.payoutDetails = payoutDetails;

    renderOnboarding(Store.getSettings());
    goTo('elec-reg-3');
  }

  function collectDocumentValues() {
    return Array.from(document.querySelectorAll('#reg-document-fields [data-doc-id]')).map((field) => {
      const type = field.dataset.docType;
      const value = type === 'upload'
        ? (field.files && field.files[0] ? field.files[0].name : '')
        : field.value.trim();
      return {
        id: field.dataset.docId,
        value,
        submittedAt: value ? Date.now() : null,
        status: 'pending'
      };
    });
  }

  function handleRegSubmit() {
    const confirmed = document.getElementById('reg-onboarding-confirm').checked;
    if (!confirmed) {
      alert('Please confirm the onboarding rules before submitting.');
      return;
    }

    const onboardingAnswers = Array.from(document.querySelectorAll('#onboarding-question-list textarea')).map((field) => field.value.trim());
    if (onboardingAnswers.some((answer) => !answer)) {
      alert('Please answer all onboarding questions.');
      return;
    }

    const settings = Store.getSettings();
    const refId = Store.ticketId();
    const electrician = Store.saveElectrician({
      id: 'elec-' + Store.uid(),
      name: regData.name,
      first: regData.first,
      email: regData.email,
      phone: regData.phone,
      password: regData.password,
      avatar: '👷',
      distance: 0.9,
      rating: 0,
      jobs: 0,
      jobsCompleted: 0,
      specialty: regData.expertise[0],
      expertise: regData.expertise,
      skills: regData.skills,
      rate: 3500,
      location: regData.location,
      serviceAreas: regData.serviceAreas,
      experience: regData.experience,
      certifications: regData.certifications,
      documents: regData.documents,
      payoutDetails: regData.payoutDetails,
      status: 'pending',
      onboardingStatus: 'pending-review',
      onboardingMode: settings.onboardingConfig.mode,
      onboardingAnswers: onboardingAnswers,
      refId: refId,
      joinedDate: new Date().toISOString().slice(0, 10),
      availabilityStatus: 'offline'
    });

    currentElec = electrician;
    Store.set('currentElectrician', electrician);
    document.getElementById('pending-ref-id').textContent = refId;
    goTo('elec-pending');
  }

  function handlePendingBack() {
    Store.remove('currentElectrician');
    currentElec = null;
    goTo('elec-login');
  }

  function loadDashboard() {
    if (!currentElec) return;
    const fresh = Store.getElectrician(currentElec.id);
    if (fresh) {
      currentElec = fresh;
      Store.set('currentElectrician', currentElec);
    }

    document.getElementById('dash-avatar').textContent = currentElec.avatar || '👷';
    document.getElementById('dash-name').textContent = currentElec.first || currentElec.name;

    const jobs = Store.getJobs().filter((job) => job.assignedElectricianId === currentElec.id);
    const now = new Date();
    const monthJobs = jobs.filter((job) => {
      const date = new Date(job.createdAt || Date.now());
      return date.getMonth() === now.getMonth() && date.getFullYear() === now.getFullYear();
    });
    const completedJobs = jobs.filter((job) => ['payout-complete', 'rated'].includes(job.status));
    const earnings = completedJobs.reduce((sum, job) => sum + ((job.quote && job.quote.customerPayableTotal) || 0), 0);

    document.getElementById('stat-jobs-month').textContent = monthJobs.length;
    document.getElementById('stat-earnings').textContent = fmt(earnings);
    document.getElementById('stat-rating').textContent = currentElec.rating ? currentElec.rating.toFixed(1) : '--';

    const newAssignments = jobs.filter((job) => ['matched', 'assessment-pending'].includes(job.status) && job.visitStage === 'awaiting-acceptance');
    const activeJobs = jobs.filter((job) => !['rated', 'cancelled'].includes(job.status) && !newAssignments.some((item) => item.id === job.id));

    const newAssignEl = document.getElementById('dash-new-assignments');
    const activeEl = document.getElementById('dash-active-jobs');

    if (newAssignments.length) {
      document.getElementById('notif-dot').style.display = 'block';
      newAssignEl.innerHTML = newAssignments.map((job) => renderJobCard(job, true)).join('');
    } else {
      document.getElementById('notif-dot').style.display = 'none';
      newAssignEl.innerHTML = '<div class="elec-empty"><div class="elec-empty-icon">📭</div><div class="elec-empty-text">No new assignments right now.</div></div>';
    }

    if (activeJobs.length) {
      activeEl.innerHTML = activeJobs.map((job) => renderJobCard(job, false)).join('');
    } else if (!newAssignments.length) {
      activeEl.innerHTML = '<div class="elec-empty"><div class="elec-empty-icon">🔧</div><div class="elec-empty-text">No active jobs yet. New jobs will appear here after matching.</div></div>';
    } else {
      activeEl.innerHTML = '';
    }

    document.querySelectorAll('.elec-job-item, .elec-alert-card').forEach((card) => {
      card.addEventListener('click', () => {
        const jobId = card.getAttribute('data-job-id');
        if (jobId) openJobDetail(jobId);
      });
    });
  }

  function renderJobCard(job, isNew) {
    const cls = isNew ? 'elec-alert-card' : 'elec-job-item';
    const categories = (job.issueCategories || []).map((category) => '<span class="badge badge-yellow">' + category + '</span>').join('');
    return '<div class="' + cls + '" data-job-id="' + job.id + '">' +
      '<div class="elec-job-item-head">' +
        '<div class="elec-job-item-name">' + (isNew ? '🔔 New: ' : '') + (job.customerName || 'Customer') + '</div>' +
        '<div class="elec-job-item-time">' + timeAgo(job.updatedAt || job.createdAt) + '</div>' +
      '</div>' +
      '<div class="elec-job-item-tags">' + categories + '</div>' +
      '<div class="elec-job-item-status"><span class="dot-live"></span>' + formatStatus(job) + '</div>' +
    '</div>';
  }

  function formatStatus(job) {
    if (job.status === 'assessment-pending' && !job.assessmentFeePaid) return 'Waiting for assessment fee';
    if (job.status === 'assessment-pending') return 'Assessment requested';
    if (job.status === 'matched' && !job.assessmentRequested) return 'Remote quote required';
    if (job.status === 'quoted') return 'Quote submitted';
    if (job.status === 'payment-pending' && !job.paymentConfirmedAt) return 'Waiting for customer payment';
    if (job.status === 'payment-pending') return 'Payment confirmed, ready to work';
    if (job.status === 'work-in-progress') {
      return job.billingModeSnapshot === 'per-second' && job.workTimer.running ? 'Timer running' : 'Work in progress';
    }
    if (job.status === 'electrician-complete') return 'Waiting for customer confirmation';
    if (job.status === 'payout-complete') return 'Payout complete';
    if (job.status === 'rated') return 'Rated and completed';
    return job.status;
  }

  function openJobDetail(jobId) {
    const job = Store.refreshJobFinancials(Store.getJob(jobId));
    if (!job) return;
    currentJobId = jobId;

    document.getElementById('jd-customer').textContent = job.customerName || 'Customer';
    document.getElementById('jd-location').textContent = job.location || job.serviceArea || '--';
    document.getElementById('jd-ticket').textContent = job.ticket || job.id;
    document.getElementById('jd-billing').textContent = job.billingModeSnapshot === 'per-second' ? 'Per-second labour' : 'Fixed labour';
    document.getElementById('jd-materials').textContent = job.materialHandling === 'self-procured' ? 'Customer buys materials' : 'Voltfriq buys materials';
    document.getElementById('jd-payout').textContent = job.payoutModeSnapshot === 'direct-to-electrician' ? 'Direct payment' : 'Platform hold';

    document.getElementById('jd-categories').innerHTML = (job.issueCategories || []).map((category) => '<span class="badge badge-yellow">' + category + '</span>').join('');
    document.getElementById('jd-description').textContent = job.description || 'No extra description from the customer.';
    document.getElementById('jd-urgency').innerHTML = job.urgency === 'emergency'
      ? '<span class="badge badge-red" style="margin-top:8px">Emergency</span>'
      : '<span class="badge badge-blue" style="margin-top:8px">' + capitalize(job.urgency || 'today') + '</span>';

    renderTimerCard(job);
    updateStatusTracker(job);
    renderJobActions(job);
    goTo('elec-job-detail');
  }

  function renderTimerCard(job) {
    const timerCard = document.getElementById('jd-timer-card');
    if (job.billingModeSnapshot !== 'per-second') {
      timerCard.style.display = 'none';
      return;
    }

    timerCard.style.display = '';
    document.getElementById('jd-timer-status').textContent = job.workTimer.running ? 'Running' : (job.workTimer.accumulatedMs > 0 ? 'Stopped' : 'Not started');
    document.getElementById('jd-timer-amount').textContent = fmt(Store.computePerSecondLaborTotal(job));
    document.getElementById('jd-timer-rate').textContent = '₦' + Number(job.ratePerSecondSnapshot || 0).toFixed(2) + '/sec';
  }

  function updateStatusTracker(job) {
    const steps = [
      { id: 'track-assigned', done: job.visitStage !== 'awaiting-acceptance', active: job.visitStage === 'awaiting-acceptance' },
      { id: 'track-enroute', done: ['accepted', 'en-route', 'on-site', 'assessment-submitted', 'work-started', 'work-stopped'].includes(job.visitStage), active: ['accepted', 'en-route', 'on-site'].includes(job.visitStage) },
      { id: 'track-onsite', done: ['quoted', 'payment-pending', 'work-in-progress', 'electrician-complete', 'payout-complete', 'rated'].includes(job.status), active: job.status === 'matched' || job.status === 'assessment-pending' },
      { id: 'track-quoted', done: ['work-in-progress', 'electrician-complete', 'payout-complete', 'rated'].includes(job.status), active: ['quoted', 'payment-pending'].includes(job.status) },
      { id: 'track-completed', done: ['payout-complete', 'rated'].includes(job.status), active: job.status === 'electrician-complete' }
    ];

    const lineIds = ['tline-1', 'tline-2', 'tline-3', 'tline-4'];
    steps.forEach((step, index) => {
      const el = document.getElementById(step.id);
      el.classList.remove('done', 'active');
      if (step.done) el.classList.add('done');
      else if (step.active) el.classList.add('active');

      if (lineIds[index]) {
        const line = document.getElementById(lineIds[index]);
        line.classList.toggle('done-line', step.done);
      }
    });
  }

  function renderJobActions(job) {
    const actions = [];

    if (job.visitStage === 'awaiting-acceptance' && ['matched', 'assessment-pending'].includes(job.status)) {
      actions.push(buttonMarkup('btn-accept-job', 'btn-primary btn-full', 'Accept Job'));
      actions.push(buttonMarkup('btn-reject-job', 'btn-secondary btn-full', 'Reject Job'));
    } else if (job.assessmentRequested && !job.assessmentFeePaid) {
      actions.push('<div class="elec-reg-note">Waiting for the customer to pay the assessment fee before you travel.</div>');
    } else if (job.assessmentRequested && job.visitStage === 'accepted') {
      actions.push(buttonMarkup('btn-mark-enroute', 'btn-primary btn-full', 'Mark En Route'));
    } else if (job.assessmentRequested && job.visitStage === 'en-route') {
      actions.push(buttonMarkup('btn-mark-onsite', 'btn-primary btn-full', 'Mark On Site'));
    } else if (job.assessmentRequested && job.visitStage === 'on-site') {
      actions.push(buttonMarkup('btn-submit-assessment-view', 'btn-primary btn-full', 'Submit Assessment & Quote'));
    } else if (!job.assessmentRequested && job.status === 'matched' && job.visitStage === 'accepted') {
      actions.push(buttonMarkup('btn-prepare-remote-quote', 'btn-primary btn-full', 'Prepare Remote Quote'));
      actions.push(buttonMarkup('btn-request-assessment', 'btn-secondary btn-full', 'Request Assessment Instead'));
    } else if (job.status === 'quoted') {
      actions.push('<div class="elec-reg-note">Quote sent. Waiting for the customer to accept it.</div>');
    } else if (job.status === 'payment-pending' && !job.paymentConfirmedAt) {
      actions.push('<div class="elec-reg-note">Waiting for customer payment confirmation.</div>');
    } else if (job.status === 'payment-pending' && job.paymentConfirmedAt) {
      actions.push(buttonMarkup('btn-start-work', 'btn-primary btn-full', job.billingModeSnapshot === 'per-second' ? 'Start Timed Work' : 'Start Work'));
    } else if (job.status === 'work-in-progress' && job.billingModeSnapshot === 'per-second' && job.workTimer.running) {
      actions.push(buttonMarkup('btn-stop-work', 'btn-primary btn-full', 'Stop Work Timer'));
      actions.push(buttonMarkup('btn-open-chat-jd', 'btn-secondary btn-full', 'Open Chat'));
    } else if ((job.status === 'work-in-progress' && job.billingModeSnapshot === 'per-second' && !job.workTimer.running) ||
               (job.status === 'work-in-progress' && job.billingModeSnapshot === 'fixed')) {
      actions.push(buttonMarkup('btn-mark-complete', 'btn-primary btn-full btn-success', 'Mark Work Complete'));
    } else if (job.status === 'electrician-complete') {
      actions.push('<div class="elec-confirmed-badge"><span>✓</span> Waiting for customer confirmation</div>');
    } else if (job.status === 'payout-complete' || job.status === 'rated') {
      actions.push('<div class="elec-confirmed-badge"><span>✓</span> Payout recorded and job closed</div>');
    }

    if (!actions.some((entry) => entry.indexOf('btn-open-chat-jd') >= 0)) {
      actions.push(buttonMarkup('btn-open-chat-jd', 'btn-secondary btn-full', 'Open Chat'));
    }

    const container = document.getElementById('jd-actions');
    container.innerHTML = actions.join('');

    bindAction('btn-accept-job', () => acceptJob(job.id));
    bindAction('btn-reject-job', () => rejectJob(job.id));
    bindAction('btn-mark-enroute', () => updateVisit(job.id, 'en-route', 'VoltFriq is en route'));
    bindAction('btn-mark-onsite', () => updateVisit(job.id, 'on-site', 'VoltFriq arrived on site'));
    bindAction('btn-submit-assessment-view', () => openQuoteBuilder(job.id, 'assessment'));
    bindAction('btn-prepare-remote-quote', () => openQuoteBuilder(job.id, 'remote-quote'));
    bindAction('btn-request-assessment', () => requestAssessment(job.id));
    bindAction('btn-start-work', () => startWork(job.id));
    bindAction('btn-stop-work', () => stopWork(job.id));
    bindAction('btn-mark-complete', () => openConfirmation(job.id));
    bindAction('btn-open-chat-jd', () => openChat(job.id));
  }

  function buttonMarkup(id, className, label) {
    return '<button class="' + className + '" id="' + id + '">' + label + '</button>';
  }

  function bindAction(id, handler) {
    const button = document.getElementById(id);
    if (button) button.addEventListener('click', handler);
  }

  function acceptJob(jobId) {
    let job = Store.getJob(jobId);
    if (!job) return;
    job.visitStage = 'accepted';
    job = Store.addTimelineEvent(job, job.status, 'VoltFriq accepted the job');
    job = Store.saveJob(job);
    Chat.sendSystemMessage(job.id, currentElec.name + ' accepted the job.');
    openJobDetail(jobId);
  }

  function rejectJob(jobId) {
    let job = Store.getJob(jobId);
    if (!job) return;
    job.assignedElectricianId = null;
    job.electricianName = null;
    job.status = 'requested';
    job.visitStage = 'awaiting-acceptance';
    job = Store.addTimelineEvent(job, 'requested', 'Assigned VoltFriq rejected the job. Waiting for reassignment.');
    job = Store.saveJob(job);
    Chat.sendSystemMessage(job.id, currentElec.name + ' declined the job. Another VoltFriq can now be assigned.');
    loadDashboard();
    goTo('elec-dashboard');
  }

  function updateVisit(jobId, stage, note) {
    let job = Store.getJob(jobId);
    if (!job) return;
    job.visitStage = stage;
    job = Store.addTimelineEvent(job, job.status, note);
    job = Store.saveJob(job);
    Chat.sendSystemMessage(job.id, note + '.');
    openJobDetail(jobId);
  }

  function requestAssessment(jobId) {
    let job = Store.getJob(jobId);
    if (!job) return;
    job.assessmentRequested = true;
    job.assessmentFeePaid = false;
    job.assessmentRequestedAt = Date.now();
    job.status = 'assessment-pending';
    job = Store.addTimelineEvent(job, 'assessment-pending', 'VoltFriq requested an on-site assessment before quoting');
    job = Store.saveJob(job);
    Chat.sendSystemMessage(job.id, 'VoltFriq requested an on-site assessment before proceeding with the quote.');
    openJobDetail(jobId);
  }

  function openQuoteBuilder(jobId, mode) {
    const job = Store.refreshJobFinancials(Store.getJob(jobId));
    if (!job) return;
    currentJobId = jobId;
    quoteMode = mode;
    laborItems = [];
    materialItems = [];

    document.getElementById('assess-findings').value = '';
    document.getElementById('assess-measurements').value = '';
    document.getElementById('labor-items').innerHTML = '';
    document.getElementById('material-items').innerHTML = '';
    document.getElementById('quote-total').textContent = fmt(0);
    document.getElementById('assessment-mode-note').textContent = job.billingModeSnapshot === 'per-second'
      ? 'Labour is billed by the second. Use labour rows as descriptive tasks and list priced materials separately.'
      : 'Use labour rows for fixed-price workmanship and materials for itemized supply costs.';

    if (job.billingModeSnapshot === 'fixed') {
      addLaborItem();
    } else {
      addLaborItem(true);
    }

    goTo('elec-assessment');
  }

  function addLaborItem(preFilled) {
    const id = Store.uid();
    laborItems.push({ id, description: preFilled ? 'Timer-based labour' : '', amount: 0 });

    const job = Store.getJob(currentJobId);
    const fixedMode = job && job.billingModeSnapshot === 'fixed';
    const container = document.getElementById('labor-items');
    const item = document.createElement('div');
    item.className = 'elec-line-item';
    item.id = 'labor-' + id;
    item.innerHTML =
      '<input type="text" class="li-desc" placeholder="Labour description" data-id="' + id + '" data-field="description" value="' + (preFilled ? 'Timer-based labour' : '') + '" />' +
      '<input type="number" class="li-amount" placeholder="' + (fixedMode ? 'Amount' : 'Optional') + '" data-id="' + id + '" data-field="amount" ' + (fixedMode ? '' : 'disabled') + ' />' +
      '<button class="btn-remove-item" data-id="' + id + '">x</button>';
    container.appendChild(item);

    item.querySelectorAll('input').forEach((input) => input.addEventListener('input', () => updateLaborItem(input)));
    item.querySelector('.btn-remove-item').addEventListener('click', () => removeLaborItem(id));
  }

  function updateLaborItem(input) {
    const item = laborItems.find((entry) => entry.id === input.dataset.id);
    if (!item) return;
    item[input.dataset.field] = input.dataset.field === 'amount' ? (parseFloat(input.value) || 0) : input.value;
    recalcQuoteTotal();
  }

  function removeLaborItem(id) {
    laborItems = laborItems.filter((item) => item.id !== id);
    const el = document.getElementById('labor-' + id);
    if (el) el.remove();
    recalcQuoteTotal();
  }

  function addMaterialItem() {
    const id = Store.uid();
    materialItems.push({ id, name: '', quantity: 1, unitPrice: 0 });

    const container = document.getElementById('material-items');
    const item = document.createElement('div');
    item.className = 'elec-line-item';
    item.id = 'material-' + id;
    item.innerHTML =
      '<input type="text" class="li-name" placeholder="Material name" data-id="' + id + '" data-field="name" />' +
      '<input type="number" class="li-qty" placeholder="Qty" value="1" data-id="' + id + '" data-field="quantity" />' +
      '<input type="number" class="li-price" placeholder="Unit price" data-id="' + id + '" data-field="unitPrice" />' +
      '<button class="btn-remove-item" data-id="' + id + '">x</button>';
    container.appendChild(item);

    item.querySelectorAll('input').forEach((input) => input.addEventListener('input', () => updateMaterialItem(input)));
    item.querySelector('.btn-remove-item').addEventListener('click', () => removeMaterialItem(id));
  }

  function updateMaterialItem(input) {
    const item = materialItems.find((entry) => entry.id === input.dataset.id);
    if (!item) return;
    if (input.dataset.field === 'quantity') item.quantity = parseInt(input.value, 10) || 1;
    else if (input.dataset.field === 'unitPrice') item.unitPrice = parseFloat(input.value) || 0;
    else item[input.dataset.field] = input.value;
    recalcQuoteTotal();
  }

  function removeMaterialItem(id) {
    materialItems = materialItems.filter((item) => item.id !== id);
    const el = document.getElementById('material-' + id);
    if (el) el.remove();
    recalcQuoteTotal();
  }

  function recalcQuoteTotal() {
    const job = Store.getJob(currentJobId);
    const materialTotal = materialItems.reduce((sum, item) => sum + ((item.unitPrice || 0) * (item.quantity || 1)), 0);
    const laborTotal = job && job.billingModeSnapshot === 'fixed'
      ? laborItems.reduce((sum, item) => sum + (item.amount || 0), 0)
      : 0;
    document.getElementById('quote-total').textContent = fmt(materialTotal + laborTotal);
  }

  function submitQuoteOrAssessment() {
    let job = Store.getJob(currentJobId);
    if (!job) return;

    const findings = document.getElementById('assess-findings').value.trim();
    const measurements = document.getElementById('assess-measurements').value.trim();
    const validLabor = laborItems.filter((item) => item.description && (job.billingModeSnapshot === 'per-second' || item.amount > 0));
    const validMaterials = materialItems.filter((item) => item.name && item.unitPrice > 0);

    if (!findings && quoteMode === 'assessment') {
      alert('Please add your assessment findings before submitting.');
      return;
    }
    if (!validLabor.length) {
      alert(job.billingModeSnapshot === 'per-second'
        ? 'Add at least one labour description for the timed work.'
        : 'Add at least one labour item with a description and amount.');
      return;
    }

    const quote = {
      findings: findings,
      measurements: measurements,
      items: validLabor.map((item) => ({ description: item.description, amount: item.amount || 0 })),
      materials: validMaterials.map((item) => ({ name: item.name, quantity: item.quantity, unitPrice: item.unitPrice })),
      createdAt: Date.now()
    };

    job.quote = quote;
    job.status = 'quoted';
    job.visitStage = 'assessment-submitted';
    job = Store.addTimelineEvent(job, 'quoted', quoteMode === 'assessment' ? 'Assessment and quote submitted' : 'Remote quote submitted');
    job = Store.saveJob(job);

    if (findings) {
      Chat.sendAssessment(job.id, currentElec.name, {
        findings: findings,
        measurements: measurements
      });
    }
    Chat.sendQuotation(job.id, currentElec.name, {
      items: quote.items,
      materials: quote.materials,
      total: Store.refreshJobFinancials(job).quote.customerPayableTotal
    });
    Chat.sendSystemMessage(job.id, 'Quote submitted and waiting for customer approval.');

    openJobDetail(job.id);
  }

  function startWork(jobId) {
    let job = Store.getJob(jobId);
    if (!job) return;

    if (job.billingModeSnapshot === 'per-second') {
      job = Store.startWorkTimer(job);
    } else {
      job.status = 'work-in-progress';
      job.visitStage = 'work-started';
      job = Store.addTimelineEvent(job, 'work-in-progress', 'VoltFriq started fixed-price work');
    }

    job = Store.saveJob(job);
    Chat.sendSystemMessage(job.id, 'VoltFriq started work.');
    openJobDetail(job.id);
  }

  function stopWork(jobId) {
    let job = Store.getJob(jobId);
    if (!job) return;
    job = Store.stopWorkTimer(job);
    job.status = 'work-in-progress';
    job = Store.saveJob(job);
    Chat.sendSystemMessage(job.id, 'Timed work stopped. Labour total is now ' + fmt(Store.computePerSecondLaborTotal(job)) + '.');
    openJobDetail(job.id);
  }

  function openConfirmation(jobId) {
    const job = Store.refreshJobFinancials(Store.getJob(jobId));
    if (!job) return;
    currentJobId = jobId;

    document.getElementById('confirm-summary').innerHTML =
      '<div class="elec-job-row"><span class="elec-job-label">Customer</span><span class="elec-job-value">' + (job.customerName || 'Customer') + '</span></div>' +
      '<div class="elec-job-row"><span class="elec-job-label">Categories</span><span class="elec-job-value">' + (job.issueCategories || []).join(', ') + '</span></div>' +
      '<div class="elec-job-row"><span class="elec-job-label">Labour Total</span><span class="elec-job-value">' + fmt((job.quote && job.quote.laborTotal) || 0) + '</span></div>' +
      '<div class="elec-job-row"><span class="elec-job-label">Ticket</span><span class="elec-job-value">' + (job.ticket || job.id) + '</span></div>';

    document.getElementById('confirm-payout-summary').innerHTML =
      '<div class="elec-job-row"><span class="elec-job-label">Material amount charged now</span><span class="elec-job-value">' + fmt((job.quote && job.quote.customerMaterialTotal) || 0) + '</span></div>' +
      '<div class="elec-job-row"><span class="elec-job-label">Receipt total</span><span class="elec-job-value">' + fmt((job.quote && job.quote.customerPayableTotal) || 0) + '</span></div>' +
      '<div class="elec-job-row"><span class="elec-job-label">Payout mode</span><span class="elec-job-value">' + (job.payoutModeSnapshot === 'direct-to-electrician' ? 'Direct pay' : 'Platform hold') + '</span></div>';

    const customerStatus = document.getElementById('confirm-cust-status');
    if (job.customerConfirmed) {
      customerStatus.innerHTML = '<div class="confirm-status-icon">✅</div><div class="confirm-status-text">Customer already confirmed completion</div>';
      customerStatus.style.background = 'var(--green-light)';
      customerStatus.querySelector('.confirm-status-text').style.color = '#065F46';
    } else {
      customerStatus.innerHTML = '<div class="confirm-status-icon">⏳</div><div class="confirm-status-text">Waiting for customer confirmation after you mark the job complete</div>';
      customerStatus.style.background = 'var(--yellow-light)';
      customerStatus.querySelector('.confirm-status-text').style.color = '#92400E';
    }

    const button = document.getElementById('btn-confirm-work');
    const badge = document.getElementById('elec-confirmed-badge');
    if (job.electricianConfirmed || ['electrician-complete', 'payout-complete', 'rated'].includes(job.status)) {
      button.style.display = 'none';
      badge.style.display = 'block';
    } else {
      button.style.display = '';
      badge.style.display = 'none';
    }

    goTo('elec-confirm');
  }

  function handleConfirmWork() {
    let job = Store.getJob(currentJobId);
    if (!job) return;

    if (job.billingModeSnapshot === 'per-second' && job.workTimer.running) {
      job = Store.stopWorkTimer(job);
    }

    job.status = 'electrician-complete';
    job.visitStage = 'work-stopped';
    job.electricianConfirmed = true;
    job.electricianConfirmedAt = Date.now();
    job = Store.addTimelineEvent(job, 'electrician-complete', 'VoltFriq marked the work complete');
    job = Store.saveJob(job);

    Chat.sendSystemMessage(job.id, 'VoltFriq marked the work as complete. Waiting for customer confirmation.');
    openConfirmation(job.id);
  }

  function openChat(jobId) {
    if (!jobId && !chatJobId) {
      const jobs = Store.getJobs().filter((job) => job.assignedElectricianId === currentElec.id);
      if (jobs.length) {
        jobId = jobs.sort((a, b) => (b.updatedAt || b.createdAt) - (a.updatedAt || a.createdAt))[0].id;
      }
    }

    if (!jobId) jobId = chatJobId;
    if (!jobId) {
      goTo('elec-chat');
      document.getElementById('elec-chat-container').innerHTML = '<div class="elec-empty"><div class="elec-empty-icon">💬</div><div class="elec-empty-text">No active chats yet.</div></div>';
      return;
    }

    chatJobId = jobId;
    const job = Store.getJob(jobId);
    document.getElementById('chat-header-title').textContent = job ? ('Chat — ' + (job.ticket || job.id)) : 'Chat';

    Chat.destroy();
    goTo('elec-chat');
    Chat.init('elec-chat-container', jobId, 'electrician', currentElec.name);
  }

  function closeChat() {
    Chat.destroy();
    goBack();
  }

  function loadProfile() {
    if (!currentElec) return;
    const fresh = Store.getElectrician(currentElec.id);
    if (fresh) currentElec = fresh;

    document.getElementById('prof-avatar').textContent = currentElec.avatar || '👷';
    document.getElementById('prof-name').textContent = currentElec.name;
    document.getElementById('prof-rating').textContent = currentElec.rating ? '★ ' + currentElec.rating.toFixed(1) : '★ --';
    document.getElementById('prof-jobs').textContent = (currentElec.jobsCompleted || currentElec.jobs || 0) + ' jobs';

    const skills = currentElec.skills || [];
    document.getElementById('prof-skills').innerHTML = skills.length
      ? skills.map((skill) => '<div class="elec-skill-item"><span class="elec-skill-name">' + skill.name + '</span><span class="skill-status ' + skill.status + '">' + skill.status + '</span></div>').join('')
      : '<div class="elec-empty"><div class="elec-empty-text">No expertise listed yet.</div></div>';

    const documents = (currentElec.documents || []).map((doc) => doc.label + ' (' + doc.status + ')').join(', ');
    document.getElementById('prof-info').innerHTML =
      '<div class="elec-info-row"><span class="elec-info-label">Email</span><span class="elec-info-value">' + currentElec.email + '</span></div>' +
      '<div class="elec-info-row"><span class="elec-info-label">Phone</span><span class="elec-info-value">' + currentElec.phone + '</span></div>' +
      '<div class="elec-info-row"><span class="elec-info-label">Location</span><span class="elec-info-value">' + currentElec.location + '</span></div>' +
      '<div class="elec-info-row"><span class="elec-info-label">Service Areas</span><span class="elec-info-value">' + (currentElec.serviceAreas || []).join(', ') + '</span></div>' +
      '<div class="elec-info-row"><span class="elec-info-label">Experience</span><span class="elec-info-value">' + currentElec.experience + '</span></div>' +
      '<div class="elec-info-row"><span class="elec-info-label">Onboarding</span><span class="elec-info-value">' + currentElec.onboardingStatus + ' · ' + currentElec.onboardingMode + '</span></div>' +
      '<div class="elec-info-row"><span class="elec-info-label">Payout</span><span class="elec-info-value">' + currentElec.payoutDetails.bankName + '<br/>' + currentElec.payoutDetails.accountNumber + '</span></div>' +
      '<div class="elec-info-row"><span class="elec-info-label">Bad Ratings</span><span class="elec-info-value">' + currentElec.badRatingCount + '</span></div>' +
      '<div class="elec-info-row"><span class="elec-info-label">Documents</span><span class="elec-info-value">' + documents + '</span></div>';
  }

  function openAddSkillModal() {
    const existing = (currentElec.expertise || []).slice();
    const available = Store.getSettings().categories.filter((skill) => !existing.includes(skill));
    const grid = document.getElementById('modal-skills-grid');

    if (!available.length) {
      grid.innerHTML = '<div class="elec-empty"><div class="elec-empty-text">All current admin categories are already on your profile.</div></div>';
    } else {
      grid.innerHTML = available.map((skill) => '<button class="chip" data-skill="' + skill + '">' + skill + '</button>').join('');
      grid.querySelectorAll('.chip').forEach((chip) => chip.addEventListener('click', () => chip.classList.toggle('active')));
    }

    document.getElementById('add-skill-modal').style.display = 'flex';
  }

  function handleAddSkills() {
    const selected = Array.from(document.querySelectorAll('#modal-skills-grid .chip.active')).map((chip) => chip.dataset.skill);
    if (!selected.length) {
      alert('Please select at least one skill.');
      return;
    }

    const expertise = currentElec.expertise || [];
    currentElec.expertise = expertise.concat(selected);
    currentElec.skills = (currentElec.skills || []).concat(selected.map((skill) => ({ name: skill, status: 'pending' })));
    currentElec = Store.saveElectrician(currentElec);
    Store.set('currentElectrician', currentElec);
    document.getElementById('add-skill-modal').style.display = 'none';
    loadProfile();
  }

  function loadHistory() {
    if (!currentElec) return;
    const jobs = Store.getJobs().filter((job) => job.assignedElectricianId === currentElec.id && ['payout-complete', 'rated'].includes(job.status));
    const list = document.getElementById('history-list');

    if (!jobs.length) {
      list.innerHTML = '<div class="elec-empty" style="margin-top:60px"><div class="elec-empty-icon">📋</div><div class="elec-empty-text">No completed jobs yet.</div></div>';
      return;
    }

    list.innerHTML = jobs.sort((a, b) => (b.updatedAt || b.createdAt) - (a.updatedAt || a.createdAt)).map((job) => {
      return '<div class="elec-hist-card">' +
        '<div class="elec-hist-top">' +
          '<div class="elec-hist-customer">' + (job.customerName || 'Customer') + '</div>' +
          '<div class="elec-hist-date">' + fmtDate(job.updatedAt || job.createdAt) + '</div>' +
        '</div>' +
        '<div class="elec-hist-cat">' + (job.issueCategories || []).join(', ') + '</div>' +
        '<div class="elec-hist-bottom">' +
          '<div class="elec-hist-amount">' + fmt((job.quote && job.quote.customerPayableTotal) || 0) + '</div>' +
          '<div class="elec-hist-rating">' + (job.rating ? ('★ ' + job.rating) : 'Awaiting rating') + '</div>' +
        '</div>' +
      '</div>';
    }).join('');
  }

  function handleNavigation(target) {
    document.querySelectorAll('.nav-item[data-nav]').forEach((button) => {
      button.classList.toggle('active', button.dataset.nav === target);
    });

    switch (target) {
      case 'elec-dashboard':
        loadDashboard();
        goTo('elec-dashboard');
        break;
      case 'elec-history':
        loadHistory();
        goTo('elec-history');
        break;
      case 'elec-chat':
        openChat(null);
        break;
      case 'elec-profile':
        loadProfile();
        goTo('elec-profile');
        break;
    }
  }

  function openNewestAssignment() {
    if (!currentElec) return;
    const next = Store.getJobs()
      .filter((job) => job.assignedElectricianId === currentElec.id && ['matched', 'assessment-pending'].includes(job.status))
      .sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0))[0];
    if (next) openJobDetail(next.id);
  }

  function startPolling() {
    stopPolling();
    pollTimer = setInterval(() => {
      if (!currentElec) return;

      const fresh = Store.getElectrician(currentElec.id);
      if (fresh) {
        currentElec = fresh;
        Store.set('currentElectrician', currentElec);
      }

      if ((currentElec.status === 'active' || currentElec.onboardingStatus === 'approved') && currentScreen === 'elec-pending') {
        loadDashboard();
        goTo('elec-dashboard');
      }

      if (currentScreen === 'elec-dashboard') loadDashboard();
      if (currentScreen === 'elec-job-detail' && currentJobId) openJobDetail(currentJobId);
      if (currentScreen === 'elec-confirm' && currentJobId) openConfirmation(currentJobId);
    }, 2500);
  }

  function stopPolling() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }

  function handleLogout() {
    Store.remove('currentElectrician');
    currentElec = null;
    currentJobId = null;
    chatJobId = null;
    Chat.destroy();
    stopPolling();
    goTo('elec-login');
  }

  function capitalize(value) {
    const str = String(value || '');
    return str.charAt(0).toUpperCase() + str.slice(1);
  }

  return {
    init,
    closeChat,
    openChat,
    openJobDetail
  };
})();

document.addEventListener('DOMContentLoaded', ElecApp.init);
