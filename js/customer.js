/* ─── VOLTFRIQ OCEAN — CUSTOMER PORTAL LOGIC ─────────────────────── */

(function () {
  'use strict';

  let hasInitialized = false;
  let currentCustomer = null;
  let currentJobId = null;
  let ratingValue = 0;
  let authMode = 'login';
  let historyFilter = 'active';
  let pollTimer = null;
  let uploadedPhotos = [];
  let sheetSelectionId = null;

  const draft = {
    serviceArea: '',
    availabilityCount: 0,
    issueCategory: '',
    urgency: 'today',
    assessmentRequested: true,
    materialHandling: 'voltfriq-supplied',
    description: '',
    candidateIds: [],
    chosenElectricianId: null
  };

  const CATEGORY_EMOJIS = {
    'Power outage': '&#9889;',
    'Wiring issue': '&#128268;',
    'Tripped breaker': '&#9888;',
    'Light fitting': '&#128161;',
    'Socket repair': '&#128268;',
    'Generator': '&#9981;',
    'CCTV Installation': '&#128249;',
    'Solar Installation': '&#9728;',
    'General Installation': '&#128295;',
    'Security Alarm': '&#128680;',
    'Inverter': '&#128267;',
    'Other': '&#10067;'
  };

  function init() {
    if (hasInitialized) return;
    hasInitialized = true;

    Store.seedIfEmpty();
    renderServiceAreaOptions();
    renderCategoryOptions();
    bindEvents();
    loadCustomerSession();

    if (!currentScreen) {
      goTo('welcome');
    }
  }

  function bindEvents() {
    on('btn-begin-area', 'click', function () { goTo('service-area'); });
    on('btn-welcome-login', 'click', function () {
      setAuthMode('login');
      goTo('customer-auth');
    });
    on('btn-track-job', 'click', function () {
      if (currentJobId && Store.getJob(currentJobId)) {
        resumeJob();
        return;
      }
      showJobHistory();
    });
    on('btn-view-prices', 'click', function () {
      renderCustomerPriceList();
      goTo('prices');
    });
    on('btn-prices-back', 'click', function () { goBack(); });
    on('btn-prices-find', 'click', function () { goTo('service-area'); });

    on('service-area-select', 'change', handleAreaChange);
    on('btn-use-location', 'click', useLocationHelper);
    on('btn-area-continue', 'click', function () {
      syncProblemSummary();
      goTo('problem');
    });

    on('problem-category', 'change', function () {
      draft.issueCategory = document.getElementById('problem-category').value;
      updateProblemButton();
    });
    on('problem-desc', 'input', function () {
      const field = document.getElementById('problem-desc');
      draft.description = field.value;
      document.getElementById('desc-count').textContent = field.value.length;
    });

    document.getElementById('urgency-selector').addEventListener('click', function (event) {
      const chip = event.target.closest('.urgency-chip');
      if (!chip) return;
      document.querySelectorAll('#urgency-selector .urgency-chip').forEach(function (item) {
        item.classList.remove('active');
      });
      chip.classList.add('active');
      draft.urgency = chip.dataset.urgency;
    });

    bindChoiceRow('assessment-choice', function (value) {
      draft.assessmentRequested = value === 'yes';
    });
    bindChoiceRow('material-choice', function (value) {
      draft.materialHandling = value;
    });

    on('photo-add-btn', 'click', function () {
      document.getElementById('photo-input').click();
    });
    on('photo-input', 'change', function (event) {
      const files = Array.from(event.target.files || []);
      const remaining = 3 - uploadedPhotos.length;
      files.slice(0, remaining).forEach(function (file) {
        const reader = new FileReader();
        reader.onload = function (loadEvent) {
          uploadedPhotos.push(loadEvent.target.result);
          renderPhotoPreviews();
        };
        reader.readAsDataURL(file);
      });
      event.target.value = '';
    });

    on('btn-review-match', 'click', prepareRecommendation);

    on('tab-login', 'click', function () { setAuthMode('login'); });
    on('tab-register', 'click', function () { setAuthMode('register'); });
    on('btn-auth-submit', 'click', handleAuth);
    on('btn-guest', 'click', function () {
      currentCustomer = Store.saveCustomer({
        id: 'cust-' + Store.uid(),
        name: 'Guest User',
        contact: '',
        isGuest: true
      });
      saveSession();
      finishCustomerAuthFlow();
    });

    on('btn-continue-match', 'click', function () {
      if (!draft.chosenElectricianId) return;
      if (currentCustomer) {
        createJob();
      } else {
        goTo('customer-auth');
      }
    });
    on('btn-change-specialist', 'click', openSpecialistSheet);
    on('btn-close-sheet', 'click', closeSpecialistSheet);
    on('btn-select-specialist', 'click', applySpecialistSelection);

    on('btn-fee-paid', 'click', confirmAssessmentPayment);
    on('fee-copy-btn', 'click', function () { copyAccountNumber('fee-account-number', 'fee-copy-btn'); });
    on('pay-copy-btn', 'click', function () { copyAccountNumber('pay-account-number', 'pay-copy-btn'); });

    on('btn-open-chat', 'click', openChat);
    on('btn-view-quote', 'click', function () {
      const job = Store.getJob(currentJobId);
      if (!job) return;
      showQuotationScreen(job);
      goTo('quotation');
    });
    on('btn-assigned-history', 'click', function () {
      showJobHistory();
    });

    on('btn-chat-back', 'click', function () {
      Chat.destroy();
      goBack();
    });
    on('btn-chat-quotation', 'click', function () {
      const job = Store.getJob(currentJobId);
      if (!job) return;
      showQuotationScreen(job);
      goTo('quotation');
    });

    on('btn-accept-quote', 'click', acceptQuote);
    on('btn-negotiate-quote', 'click', openChat);
    on('btn-decline-quote', 'click', declineQuote);

    on('btn-payment-paid', 'click', confirmQuotePayment);

    on('confirm-checkbox', 'change', function () {
      document.getElementById('btn-confirm-complete').disabled = !document.getElementById('confirm-checkbox').checked;
    });
    on('btn-confirm-complete', 'click', confirmCompletionAndRelease);

    document.getElementById('star-rating').addEventListener('click', function (event) {
      const star = event.target.closest('.star');
      if (!star) return;
      ratingValue = parseInt(star.dataset.star, 10);
      updateStars();
    });
    on('rating-comment', 'input', function () {
      const field = document.getElementById('rating-comment');
      document.getElementById('rating-count').textContent = field.value.length;
    });
    on('btn-submit-rating', 'click', submitRating);

    on('btn-view-history', 'click', function () {
      showJobHistory();
    });
    on('btn-find-another', 'click', function () {
      resetDraftAndForms();
      goTo('welcome');
    });

    on('btn-history-back', 'click', function () { goBack(); });
    document.getElementById('history-tabs').addEventListener('click', function (event) {
      const tab = event.target.closest('.tab');
      if (!tab) return;
      document.querySelectorAll('#history-tabs .tab').forEach(function (item) {
        item.classList.remove('active');
      });
      tab.classList.add('active');
      historyFilter = tab.dataset.filter;
      renderHistory();
    });

    Store.onUpdate(function () {
      if (currentJobId) {
        checkJobStatus();
      }
      if (currentScreen === 'history') {
        renderHistory();
      }
      if (currentScreen === 'service-area') {
        renderAvailabilityCard();
      }
    });
  }

  function bindChoiceRow(id, callback) {
    const container = document.getElementById(id);
    if (!container) return;
    container.addEventListener('click', function (event) {
      const pill = event.target.closest('.choice-pill');
      if (!pill) return;
      container.querySelectorAll('.choice-pill').forEach(function (item) {
        item.classList.remove('active');
      });
      pill.classList.add('active');
      callback(pill.dataset.value);
    });
  }

  function on(id, event, handler) {
    const element = document.getElementById(id);
    if (element) {
      element.addEventListener(event, handler);
    }
  }

  function hasReadyDraft() {
    return !!(draft.serviceArea && draft.issueCategory && draft.chosenElectricianId);
  }

  function showJobHistory() {
    loadHistory();
    goTo('history');
  }

  function finishCustomerAuthFlow() {
    if (hasReadyDraft()) {
      createJob();
      return;
    }
    showJobHistory();
  }

  function renderServiceAreaOptions() {
    const select = document.getElementById('service-area-select');
    if (!select) return;
    const settings = Store.getSettings();
    select.innerHTML = '<option value="">Select a service area</option>' + settings.serviceAreas.map(function (area) {
      return '<option value="' + area + '">' + area + '</option>';
    }).join('');
  }

  function renderCategoryOptions() {
    const select = document.getElementById('problem-category');
    if (!select) return;
    const settings = Store.getSettings();
    select.innerHTML = '<option value="">Select the main issue</option>' + settings.categories.map(function (category) {
      const emoji = CATEGORY_EMOJIS[category] || '&#128295;';
      return '<option value="' + category + '">' + emoji.replace(/&#(\d+);/, '') + ' ' + category + '</option>';
    }).join('');
  }

  function handleAreaChange() {
    draft.serviceArea = document.getElementById('service-area-select').value;
    draft.availabilityCount = Store.countAvailableElectricians(draft.serviceArea);
    renderAvailabilityCard();
    syncProblemSummary();
  }

  function useLocationHelper() {
    const areas = Store.getSettings().serviceAreas;
    const preferred = draft.serviceArea || areas[0] || '';
    if (!preferred) return;
    document.getElementById('service-area-select').value = preferred;
    draft.serviceArea = preferred;
    draft.availabilityCount = Store.countAvailableElectricians(preferred);
    document.getElementById('location-helper-note').textContent = 'Using demo location mapping for ' + preferred + '.';
    renderAvailabilityCard();
    syncProblemSummary();
  }

  function renderAvailabilityCard() {
    const count = draft.availabilityCount;
    document.getElementById('availability-count').textContent = count;
    if (draft.serviceArea) {
      document.getElementById('availability-meta').textContent = count > 0
        ? count + ' approved VoltFriq' + (count > 1 ? 's are' : ' is') + ' currently available in ' + draft.serviceArea + '.'
        : 'No approved VoltFriqs are currently available in ' + draft.serviceArea + '. Try another service area.';
    } else {
      document.getElementById('availability-meta').textContent = 'Choose a service area to see live availability.';
    }
    document.getElementById('btn-area-continue').disabled = !draft.serviceArea;
  }

  function syncProblemSummary() {
    document.getElementById('problem-area-label').textContent = draft.serviceArea || '--';
    document.getElementById('problem-availability-pill').textContent = draft.availabilityCount + ' available';
  }

  function updateProblemButton() {
    document.getElementById('btn-review-match').disabled = !draft.issueCategory;
  }

  function renderPhotoPreviews() {
    const container = document.getElementById('photo-previews');
    container.innerHTML = uploadedPhotos.map(function (src, index) {
      return '<div class="photo-preview">' +
        '<img src="' + src + '" alt="Issue photo" />' +
        '<button class="photo-remove" data-index="' + index + '">&times;</button>' +
      '</div>';
    }).join('');

    document.getElementById('photo-add-btn').style.display = uploadedPhotos.length >= 3 ? 'none' : '';
    container.querySelectorAll('.photo-remove').forEach(function (button) {
      button.addEventListener('click', function () {
        uploadedPhotos.splice(parseInt(button.dataset.index, 10), 1);
        renderPhotoPreviews();
      });
    });
  }

  function prepareRecommendation() {
    draft.description = document.getElementById('problem-desc').value.trim();
    const ranked = Store.rankElectricians(draft.serviceArea, [draft.issueCategory]);
    draft.candidateIds = ranked.map(function (electrician) { return electrician.id; });
    draft.chosenElectricianId = ranked.length ? ranked[0].id : null;
    sheetSelectionId = draft.chosenElectricianId;

    renderRecommendationScreen(ranked);
    goTo('match');
  }

  function renderRecommendationScreen(ranked) {
    const summary = document.getElementById('match-summary-card');
    const button = document.getElementById('btn-continue-match');

    if (!ranked.length) {
      summary.innerHTML = '<strong>No VoltFriq is currently available in ' + draft.serviceArea + '.</strong><br/>Try another area or come back shortly.';
      document.getElementById('match-electrician-card').style.display = 'none';
      document.getElementById('transparency-card').style.display = 'none';
      button.disabled = true;
      return;
    }

    const electrician = ranked[0];
    document.getElementById('match-electrician-card').style.display = '';
    document.getElementById('transparency-card').style.display = '';
    button.disabled = false;

    summary.innerHTML =
      '<strong>' + draft.availabilityCount + ' VoltFriq' + (draft.availabilityCount === 1 ? '' : 's') + ' available in ' + draft.serviceArea + '.</strong><br/>' +
      'We ranked this specialist highest for ' + draft.issueCategory + ' based on expertise, ratings, completed jobs, and distance.';

    document.getElementById('match-avatar').textContent = electrician.avatar || '👷';
    document.getElementById('match-name').textContent = electrician.name;
    document.getElementById('match-specialty').textContent = electrician.specialty || electrician.expertise[0] || 'General Electrical';
    document.getElementById('match-rating').textContent = electrician.rating ? electrician.rating.toFixed(1) : '--';
    document.getElementById('match-jobs').textContent = electrician.jobsCompleted || electrician.jobs || 0;
    document.getElementById('match-distance').textContent = electrician.distance;
    document.getElementById('match-reason').textContent = electrician.matchReason;

    renderTransparencyCard();
    renderSpecialistSheet(ranked);
  }

  function renderTransparencyCard() {
    const rows = [
      ['Area availability', draft.availabilityCount + ' available'],
      ['Issue category', draft.issueCategory || '--'],
      ['Assessment', draft.assessmentRequested ? 'Required before quote' : 'Skip visit, start remote quote'],
      ['Billing mode', formatBillingMode(Store.getSettings().defaultBillingMode)],
      ['Payout mode', formatPayoutMode(Store.getSettings().defaultPayoutMode)],
      ['Materials', draft.materialHandling === 'self-procured' ? 'Customer buys materials' : 'Voltfriq buys materials']
    ];
    document.getElementById('transparency-card').innerHTML = rows.map(function (row) {
      return '<div class="transparency-row"><span class="transparency-label">' + row[0] + '</span><span class="transparency-value">' + row[1] + '</span></div>';
    }).join('');
  }

  function renderSpecialistSheet(ranked) {
    const list = document.getElementById('specialist-list');
    list.innerHTML = ranked.map(function (electrician) {
      const isSelected = electrician.id === sheetSelectionId;
      return '<div class="sheet-option' + (isSelected ? ' selected' : '') + '" data-elec-id="' + electrician.id + '">' +
        '<div class="sheet-option-avatar">' + (electrician.avatar || '👷') + '</div>' +
        '<div style="flex:1;min-width:0;">' +
          '<div class="sheet-option-name">' + electrician.name + '</div>' +
          '<div class="sheet-option-sub">' + (electrician.specialty || '') + ' · ★ ' + (electrician.rating ? electrician.rating.toFixed(1) : '--') + ' · ' + (electrician.jobsCompleted || electrician.jobs || 0) + ' jobs · ' + electrician.distance + ' km</div>' +
          '<div class="sheet-option-reason">' + electrician.matchReason + '</div>' +
        '</div>' +
      '</div>';
    }).join('');

    list.querySelectorAll('.sheet-option').forEach(function (option) {
      option.addEventListener('click', function () {
        sheetSelectionId = option.dataset.elecId;
        list.querySelectorAll('.sheet-option').forEach(function (item) {
          item.classList.toggle('selected', item.dataset.elecId === sheetSelectionId);
        });
      });
    });
  }

  function openSpecialistSheet() {
    if (!draft.candidateIds.length) return;
    document.getElementById('specialist-sheet').style.display = 'flex';
  }

  function closeSpecialistSheet() {
    document.getElementById('specialist-sheet').style.display = 'none';
  }

  function applySpecialistSelection() {
    if (!sheetSelectionId) return;
    draft.chosenElectricianId = sheetSelectionId;
    const ranked = Store.rankElectricians(draft.serviceArea, [draft.issueCategory]);
    const selected = ranked.find(function (electrician) { return electrician.id === sheetSelectionId; });
    if (!selected) return;

    document.getElementById('match-avatar').textContent = selected.avatar || '👷';
    document.getElementById('match-name').textContent = selected.name;
    document.getElementById('match-specialty').textContent = selected.specialty || selected.expertise[0] || 'General Electrical';
    document.getElementById('match-rating').textContent = selected.rating ? selected.rating.toFixed(1) : '--';
    document.getElementById('match-jobs').textContent = selected.jobsCompleted || selected.jobs || 0;
    document.getElementById('match-distance').textContent = selected.distance;
    document.getElementById('match-reason').textContent = selected.matchReason;
    closeSpecialistSheet();
  }

  function setAuthMode(mode) {
    authMode = mode;
    document.getElementById('tab-login').classList.toggle('active', mode === 'login');
    document.getElementById('tab-register').classList.toggle('active', mode === 'register');
    document.getElementById('auth-name-group').style.display = mode === 'register' ? 'block' : 'none';
    document.getElementById('btn-auth-submit').textContent = mode === 'login' ? 'Login' : 'Register';
    hideAuthError();
  }

  function handleAuth() {
    const contact = document.getElementById('auth-contact').value.trim();
    const password = document.getElementById('auth-password').value.trim();

    if (!contact || !password) {
      showAuthError('Please enter your phone/email and password.');
      return;
    }

    if (authMode === 'register') {
      const name = document.getElementById('auth-name').value.trim();
      if (!name) {
        showAuthError('Please enter your full name.');
        return;
      }
      currentCustomer = Store.saveCustomer({
        id: 'cust-' + Store.uid(),
        name: name,
        contact: contact,
        password: password,
        isGuest: false,
        createdAt: Date.now()
      });
      saveSession();
      finishCustomerAuthFlow();
      return;
    }

    const customers = Store.getCustomers();
    const existing = customers.find(function (customer) {
      return (customer.contact === contact || customer.name === contact) && customer.password === password;
    });

    if (existing) {
      currentCustomer = existing;
      saveSession();
      finishCustomerAuthFlow();
      return;
    }

    currentCustomer = Store.saveCustomer({
      id: 'cust-' + Store.uid(),
      name: contact.split('@')[0] || 'Customer',
      contact: contact,
      password: password,
      isGuest: false,
      createdAt: Date.now()
    });
    saveSession();
    finishCustomerAuthFlow();
  }

  function showAuthError(message) {
    const error = document.getElementById('auth-error');
    error.textContent = message;
    error.style.display = 'block';
  }

  function hideAuthError() {
    document.getElementById('auth-error').style.display = 'none';
  }

  function createJob() {
    const electrician = draft.chosenElectricianId ? Store.getElectrician(draft.chosenElectricianId) : null;
    if (!electrician) {
      showJobHistory();
      return;
    }

    const settings = Store.getSettings();
    const now = Date.now();
    const assessmentRequested = !!draft.assessmentRequested;
    const status = assessmentRequested ? 'assessment-pending' : 'matched';
    const job = Store.saveJob({
      id: 'job-' + Store.uid(),
      ticket: Store.ticketId(),
      customerId: currentCustomer ? currentCustomer.id : null,
      customerName: currentCustomer ? currentCustomer.name : 'Guest User',
      customerContact: currentCustomer ? currentCustomer.contact || '' : '',
      serviceArea: draft.serviceArea,
      availabilityCount: draft.availabilityCount,
      issueCategories: [draft.issueCategory],
      description: draft.description,
      location: draft.serviceArea,
      urgency: draft.urgency,
      photos: uploadedPhotos.slice(),
      status: status,
      visitStage: 'awaiting-acceptance',
      createdAt: now,
      updatedAt: now,
      assignedElectricianId: electrician.id,
      electricianName: electrician.name,
      recommendedElectricianId: draft.candidateIds[0] || electrician.id,
      candidateElectricianIds: draft.candidateIds.slice(),
      assessmentRequested: assessmentRequested,
      assessmentFeeSnapshot: settings.defaultAssessmentFee,
      assessmentRequestedAt: assessmentRequested ? now : null,
      billingModeSnapshot: settings.defaultBillingMode,
      payoutModeSnapshot: settings.defaultPayoutMode,
      materialHandling: draft.materialHandling,
      workTimer: {
        running: false,
        startedAt: null,
        stoppedAt: null,
        accumulatedMs: 0,
        perSecondRate: electrician.perSecondRate
      },
      ratePerSecondSnapshot: electrician.perSecondRate,
      quote: {
        findings: '',
        measurements: '',
        items: [],
        materials: [],
        createdAt: null
      },
      payoutState: assessmentRequested ? 'awaiting-assessment-fee' : 'awaiting-quote',
      timeline: [
        {
          status: 'requested',
          timestamp: now,
          note: 'Customer requested ' + draft.issueCategory + ' help in ' + draft.serviceArea
        },
        {
          status: status,
          timestamp: now,
          note: 'Recommended ' + electrician.name + ' after checking ' + draft.availabilityCount + ' available VoltFriqs'
        }
      ]
    });

    currentJobId = job.id;
    saveSession();

    Chat.sendSystemMessage(job.id, 'New customer request created. Recommended VoltFriq: ' + electrician.name + '.');
    if (assessmentRequested) {
      showFeeScreen(job);
      goTo('appearance-fee');
    } else {
      Chat.sendSystemMessage(job.id, 'Customer skipped assessment and requested a remote quote.');
      showAssignedScreen(job);
      goTo('assigned');
    }
    startJobPoll();
  }

  function confirmAssessmentPayment() {
    let job = Store.getJob(currentJobId);
    if (!job) return;
    job.assessmentFeePaid = true;
    job.assessmentFeePaidAt = Date.now();
    job.status = 'matched';
    job.payoutState = job.payoutModeSnapshot === 'platform-hold' ? 'assessment-fee-held' : 'assessment-fee-paid-direct';
    job = Store.addTimelineEvent(job, 'matched', 'Customer confirmed assessment fee payment');
    job = Store.saveJob(job);
    Chat.sendSystemMessage(job.id, 'Assessment fee marked as paid. VoltFriq can now accept and begin assessment.');
    showAssignedScreen(job);
    goTo('assigned');
    startJobPoll();
  }

  function acceptQuote() {
    let job = Store.getJob(currentJobId);
    if (!job) return;
    job.status = 'payment-pending';
    job.quoteAcceptedAt = Date.now();
    job = Store.addTimelineEvent(job, 'payment-pending', 'Customer accepted the quotation');
    job = Store.saveJob(job);
    Chat.sendSystemMessage(job.id, 'Customer accepted the quotation.');
    showPaymentScreen(job);
    goTo('payment');
  }

  function declineQuote() {
    let job = Store.getJob(currentJobId);
    if (!job) return;
    job.status = 'cancelled';
    job = Store.addTimelineEvent(job, 'cancelled', 'Customer declined the quotation');
    Store.saveJob(job);
    clearJobSession();
    goTo('welcome');
  }

  function confirmQuotePayment() {
    let job = Store.getJob(currentJobId);
    if (!job) return;

    const receiptInput = document.getElementById('receipt-upload');
    job.paymentConfirmedAt = Date.now();
    job.paymentProof = receiptInput && receiptInput.files && receiptInput.files[0]
      ? receiptInput.files[0].name
      : 'Customer marked payment as complete';
    job.payoutState = job.payoutModeSnapshot === 'platform-hold' ? 'held-by-platform' : 'paid-direct';
    job = Store.addTimelineEvent(job, 'payment-pending', 'Customer confirmed payment setup');
    job = Store.saveJob(job);

    Chat.sendSystemMessage(job.id, paymentStatusMessage(job));
    showAssignedScreen(job);
    goTo('assigned');
    startJobPoll();
  }

  function confirmCompletionAndRelease() {
    let job = Store.getJob(currentJobId);
    if (!job) return;

    job.customerConfirmed = true;
    job.customerConfirmedAt = Date.now();
    job.status = 'payout-complete';
    job.payoutState = job.payoutModeSnapshot === 'platform-hold'
      ? 'released-to-electrician'
      : 'direct-payment-confirmed';
    job.receipt = Store.createReceipt(job);
    job = Store.addTimelineEvent(job, 'payout-complete', 'Customer confirmed completion and released payout');
    job = Store.saveJob(job);

    Chat.sendReceipt(job.id, job.receipt);
    Chat.sendSystemMessage(job.id, 'Customer approved completion. Payout marked complete.');
    stopJobPoll();
    showRatingScreen(job);
    goTo('rating');
  }

  function submitRating() {
    let job = Store.getJob(currentJobId);
    if (!job) return;
    const score = ratingValue || 5;

    job.rating = score;
    job.ratingComment = document.getElementById('rating-comment').value.trim();
    job.ratedAt = Date.now();
    job.status = 'rated';
    job = Store.addTimelineEvent(job, 'rated', 'Customer rated the VoltFriq ' + score + ' star' + (score === 1 ? '' : 's'));
    job = Store.saveJob(job);

    Store.applyRatingToElectrician(job, score);

    clearJobSession();
    showDoneScreen(job);
    goTo('done');
  }

  function showFeeScreen(job) {
    const destination = Store.getPayoutDestination(job);
    document.getElementById('fee-amount').textContent = fmt(job.assessmentFeeSnapshot || Store.getSettings().defaultAssessmentFee);
    document.getElementById('fee-bank-label').textContent = destination.label;
    document.getElementById('fee-bank-name').textContent = destination.bankName;
    document.getElementById('fee-account-number').textContent = destination.accountNumber;
    document.getElementById('fee-account-name').textContent = destination.accountName;

    document.getElementById('assessment-snapshot').innerHTML = [
      ['Assessment', 'Visit + report + quote'],
      ['Billing mode after quote', formatBillingMode(job.billingModeSnapshot)],
      ['Materials', formatMaterialHandling(job.materialHandling)],
      ['Payout mode', formatPayoutMode(job.payoutModeSnapshot)]
    ].map(function (row) {
      return '<div class="transparency-row"><span class="transparency-label">' + row[0] + '</span><span class="transparency-value">' + row[1] + '</span></div>';
    }).join('');
  }

  function showAssignedScreen(jobInput) {
    const job = Store.refreshJobFinancials(jobInput);
    const electrician = job.assignedElectricianId ? Store.getElectrician(job.assignedElectricianId) : null;
    const topLabel = summarizeStatus(job);
    const viewQuote = job.quote && (job.quote.items.length || job.quote.materials.length);

    document.getElementById('tracking-summary').innerHTML =
      '<div><div class="summary-strip-label">Ticket</div><div class="summary-strip-value">' + job.ticket + '</div></div>' +
      '<div class="summary-strip-pill">' + topLabel + '</div>';

    if (electrician) {
      document.getElementById('assigned-avatar').textContent = electrician.avatar || '👷';
      document.getElementById('assigned-name').textContent = electrician.name;
      document.getElementById('assigned-specialty').textContent = electrician.specialty || electrician.expertise[0] || 'General Electrical';
      document.getElementById('assigned-rating').textContent = electrician.rating ? electrician.rating.toFixed(1) : '--';
      document.getElementById('assigned-jobs').textContent = electrician.jobsCompleted || electrician.jobs || 0;
      document.getElementById('assigned-distance').textContent = electrician.distance;
    } else {
      document.getElementById('assigned-avatar').textContent = '⏳';
      document.getElementById('assigned-name').textContent = 'Waiting for reassignment';
      document.getElementById('assigned-specialty').textContent = 'Admin can reassign another VoltFriq';
      document.getElementById('assigned-rating').textContent = '--';
      document.getElementById('assigned-jobs').textContent = '--';
      document.getElementById('assigned-distance').textContent = '--';
    }

    document.getElementById('assigned-categories').innerHTML = job.issueCategories.map(function (category) {
      return '<span class="badge badge-yellow">' + category + '</span>';
    }).join('');
    document.getElementById('assigned-desc').textContent = job.description || 'No extra note added by the customer.';
    document.getElementById('assigned-meta-list').innerHTML = [
      ['Area', job.serviceArea],
      ['Availability count', job.availabilityCount + ' VoltFriq' + (job.availabilityCount === 1 ? '' : 's')],
      ['Assessment', job.assessmentRequested ? (job.assessmentFeePaid ? 'Paid and ready' : 'Awaiting fee payment') : 'Skipped'],
      ['Billing', formatBillingMode(job.billingModeSnapshot)],
      ['Materials', formatMaterialHandling(job.materialHandling)],
      ['Payout', formatPayoutMode(job.payoutModeSnapshot)]
    ].map(function (row) {
      return '<div class="mini-meta-row"><span class="mini-meta-label">' + row[0] + '</span><span class="mini-meta-value">' + row[1] + '</span></div>';
    }).join('');

    renderStatusLines(job);
    document.getElementById('btn-view-quote').style.display = viewQuote || job.status === 'quoted' ? '' : 'none';
  }

  function renderStatusLines(job) {
    const lines = [
      {
        title: 'Specialist matched',
        sub: job.electricianName ? job.electricianName + ' is assigned in ' + job.serviceArea + '.' : 'Waiting for a specialist recommendation.',
        state: job.assignedElectricianId ? 'done' : 'active'
      },
      {
        title: job.assessmentRequested ? 'Assessment and quotation' : 'Remote quotation',
        sub: assessmentStatusText(job),
        state: ['quoted', 'payment-pending', 'work-in-progress', 'electrician-complete', 'payout-complete', 'rated'].includes(job.status)
          ? 'done'
          : (['assessment-pending', 'matched'].includes(job.status) ? 'active' : '')
      },
      {
        title: 'Work and billing',
        sub: workStatusText(job),
        state: ['electrician-complete', 'payout-complete', 'rated'].includes(job.status)
          ? 'done'
          : (['payment-pending', 'work-in-progress'].includes(job.status) ? 'active' : '')
      },
      {
        title: 'Completion and receipt',
        sub: completionStatusText(job),
        state: ['payout-complete', 'rated'].includes(job.status)
          ? 'done'
          : (job.status === 'electrician-complete' ? 'active' : '')
      }
    ];

    document.getElementById('status-lines').innerHTML = lines.map(function (line) {
      const classes = line.state ? 'status-line ' + line.state : 'status-line';
      return '<div class="' + classes + '">' +
        '<div class="status-line-dot"></div>' +
        '<div>' +
          '<div class="status-line-title">' + line.title + '</div>' +
          '<div class="status-line-sub">' + line.sub + '</div>' +
        '</div>' +
      '</div>';
    }).join('');
  }

  function showQuotationScreen(jobInput) {
    const job = Store.refreshJobFinancials(jobInput);
    const quote = job.quote || { items: [], materials: [] };
    const findings = quote.findings || (job.assessmentRequested ? 'Assessment details will appear here.' : 'Remote quote based on customer description and photos.');

    document.getElementById('quot-findings').textContent = findings;
    document.getElementById('quot-labour-items').innerHTML = quote.items.length
      ? quote.items.map(function (item) {
          return '<div class="quot-item"><span class="quot-item-name">' + item.description + '</span><span class="quot-item-amount">' + fmt(item.amount) + '</span></div>';
        }).join('')
      : '<div class="quot-item"><span class="quot-item-name">' + (job.billingModeSnapshot === 'per-second' ? 'Timer-based labour billing will run after work starts.' : 'No labour items yet.') + '</span><span class="quot-item-amount">' + (job.billingModeSnapshot === 'per-second' ? formatPerSecond(job.ratePerSecondSnapshot) : '—') + '</span></div>';

    document.getElementById('quot-material-items').innerHTML = quote.materials.length
      ? quote.materials.map(function (material) {
          const total = material.quantity * material.unitPrice;
          const suffix = job.materialHandling === 'self-procured' ? ' (reference only)' : '';
          return '<div class="quot-item"><span class="quot-item-name">' + material.name + ' (x' + material.quantity + ')' + suffix + '</span><span class="quot-item-amount">' + fmt(total) + '</span></div>';
        }).join('')
      : '<div class="quot-item"><span class="quot-item-name">No materials listed</span><span class="quot-item-amount">—</span></div>';

    document.getElementById('quot-total-amount').textContent = fmt(getAmountDueNow(job));
    document.getElementById('quotation-note').textContent = buildQuotationNote(job);
    document.getElementById('quot-materials').style.display = quote.materials.length ? 'block' : 'none';
  }

  function showPaymentScreen(jobInput) {
    const job = Store.refreshJobFinancials(jobInput);
    const amountDueNow = getAmountDueNow(job);
    const destination = Store.getPayoutDestination(job);

    document.getElementById('payment-amount').textContent = fmt(amountDueNow);
    document.getElementById('payment-note').textContent = buildPaymentNote(job, amountDueNow);
    document.getElementById('btn-payment-paid').textContent = amountDueNow > 0 ? 'I Have Paid' : 'Continue To Tracking';
    document.getElementById('pay-bank-label').textContent = destination.label;
    document.getElementById('pay-bank-name').textContent = destination.bankName;
    document.getElementById('pay-account-number').textContent = destination.accountNumber;
    document.getElementById('pay-account-name').textContent = destination.accountName;

    document.getElementById('payment-snapshot').innerHTML = [
      ['Billing mode', formatBillingMode(job.billingModeSnapshot)],
      ['Payout mode', formatPayoutMode(job.payoutModeSnapshot)],
      ['Materials', formatMaterialHandling(job.materialHandling)],
      ['Release rule', job.payoutModeSnapshot === 'platform-hold' ? 'Payout releases after you confirm completion' : 'Direct payment is recorded for final confirmation']
    ].map(function (row) {
      return '<div class="transparency-row"><span class="transparency-label">' + row[0] + '</span><span class="transparency-value">' + row[1] + '</span></div>';
    }).join('');
  }

  function showConfirmScreen(jobInput) {
    const job = Store.refreshJobFinancials(jobInput);
    const quote = job.quote || { items: [], materials: [], laborTotal: 0, customerMaterialTotal: 0, customerPayableTotal: 0 };

    const summaryItems = [
      ['Ticket', job.ticket],
      ['Issue', job.issueCategories.join(', ')],
      ['Area', job.serviceArea],
      ['Billing mode', formatBillingMode(job.billingModeSnapshot)]
    ];
    document.getElementById('confirm-items').innerHTML = summaryItems.map(function (item) {
      return '<div class="confirm-item"><span class="confirm-item-check">&#10003;</span><span><strong>' + item[0] + ':</strong> ' + item[1] + '</span></div>';
    }).join('');

    const status = document.getElementById('confirm-elec-status');
    if (job.electricianConfirmed || job.status === 'electrician-complete') {
      status.innerHTML = '<span style="color:var(--green);">&#10003;</span> VoltFriq marked the work as complete';
      status.classList.add('confirmed');
    } else {
      status.innerHTML = '<span class="dot-live"></span> Waiting for the VoltFriq to mark the job complete';
      status.classList.remove('confirmed');
    }

    document.getElementById('final-settlement-card').innerHTML =
      '<div class="confirm-title">Final Settlement</div>' +
      '<div class="mini-meta-list">' +
        '<div class="mini-meta-row"><span class="mini-meta-label">Labour total</span><span class="mini-meta-value">' + fmt(quote.laborTotal || 0) + '</span></div>' +
        '<div class="mini-meta-row"><span class="mini-meta-label">Material total charged now</span><span class="mini-meta-value">' + fmt(quote.customerMaterialTotal || 0) + '</span></div>' +
        '<div class="mini-meta-row"><span class="mini-meta-label">Payout destination</span><span class="mini-meta-value">' + formatPayoutMode(job.payoutModeSnapshot) + '</span></div>' +
        '<div class="mini-meta-row"><span class="mini-meta-label">Receipt total</span><span class="mini-meta-value">' + fmt(quote.customerPayableTotal || 0) + '</span></div>' +
      '</div>';

    document.getElementById('confirm-checkbox').checked = false;
    document.getElementById('btn-confirm-complete').disabled = true;
  }

  function showRatingScreen(jobInput) {
    ratingValue = 0;
    updateStars();
    document.getElementById('rating-comment').value = jobInput.ratingComment || '';
    document.getElementById('rating-count').textContent = '0';
  }

  function showDoneScreen(job) {
    const receipt = job.receipt || Store.createReceipt(job);
    document.getElementById('done-receipt-card').innerHTML = [
      ['Ticket', receipt.ticket || job.ticket],
      ['Total', fmt(receipt.amount || 0)],
      ['Billing', formatBillingMode(receipt.billingMode || job.billingModeSnapshot)],
      ['Reference', receipt.reference || '--']
    ].map(function (row) {
      return '<div class="mini-meta-row"><span class="mini-meta-label">' + row[0] + '</span><span class="mini-meta-value">' + row[1] + '</span></div>';
    }).join('');
  }

  function updateStars() {
    document.querySelectorAll('#star-rating .star').forEach(function (star) {
      const value = parseInt(star.dataset.star, 10);
      star.classList.toggle('active', value <= ratingValue);
      star.innerHTML = value <= ratingValue ? '&#9733;' : '&#9734;';
    });
  }

  function openChat() {
    const job = Store.getJob(currentJobId);
    if (!job) return;

    document.getElementById('chat-elec-name').textContent = job.electricianName || 'VoltFriq Chat';
    document.getElementById('chat-ticket-label').textContent = job.ticket;

    Chat.destroy();
    goTo('chat');
    Chat.init('customer-chat-container', job.id, 'customer', currentCustomer ? currentCustomer.name : 'Customer');
    document.getElementById('btn-chat-quotation').style.display = job.quote && (job.quote.items.length || job.quote.materials.length) ? '' : 'none';
  }

  function startJobPoll() {
    stopJobPoll();
    pollTimer = setInterval(checkJobStatus, 2000);
  }

  function stopJobPoll() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }

  function checkJobStatus() {
    if (!currentJobId) return;
    const job = Store.getJob(currentJobId);
    if (!job) return;

    if (currentScreen === 'appearance-fee' && job.assessmentFeePaid) {
      showAssignedScreen(job);
      goTo('assigned');
      return;
    }

    if (currentScreen === 'assigned' || currentScreen === 'chat') {
      showAssignedScreen(job);
      if (job.quote && (job.quote.items.length || job.quote.materials.length || job.status === 'quoted')) {
        document.getElementById('btn-view-quote').style.display = '';
        if (currentScreen === 'chat') {
          document.getElementById('btn-chat-quotation').style.display = '';
        }
      }
    }

    if (currentScreen === 'assigned' && job.status === 'quoted') {
      showQuotationScreen(job);
      goTo('quotation');
      return;
    }

    if ((currentScreen === 'assigned' || currentScreen === 'chat' || currentScreen === 'payment') && job.status === 'electrician-complete') {
      showConfirmScreen(job);
      goTo('confirm-work');
      return;
    }

    if (currentScreen === 'confirm-work') {
      showConfirmScreen(job);
      if (job.status === 'payout-complete') {
        stopJobPoll();
        showRatingScreen(job);
        goTo('rating');
      }
    }

    if (currentScreen === 'quotation' && job.status === 'payment-pending' && job.paymentConfirmedAt) {
      showAssignedScreen(job);
      goTo('assigned');
    }
  }

  function loadCustomerSession() {
    const storedCustomer = localStorage.getItem('vfo_current_customer');
    if (storedCustomer) {
      try {
        currentCustomer = JSON.parse(storedCustomer);
      } catch (err) {
        currentCustomer = null;
      }
    }

    const storedJobId = localStorage.getItem('vfo_current_job_id');
    if (storedJobId) {
      currentJobId = storedJobId;
      resumeJob();
    }
  }

  function saveSession() {
    if (currentCustomer) {
      localStorage.setItem('vfo_current_customer', JSON.stringify(currentCustomer));
    }
    if (currentJobId) {
      localStorage.setItem('vfo_current_job_id', currentJobId);
    }
  }

  function clearJobSession() {
    currentJobId = null;
    localStorage.removeItem('vfo_current_job_id');
  }

  function resumeJob() {
    const job = Store.getJob(currentJobId);
    if (!job) {
      clearJobSession();
      return;
    }

    if (job.status === 'assessment-pending' && !job.assessmentFeePaid) {
      showFeeScreen(job);
      goTo('appearance-fee');
      startJobPoll();
      return;
    }

    if (job.status === 'quoted') {
      showQuotationScreen(job);
      goTo('quotation');
      return;
    }

    if (job.status === 'payment-pending' && !job.paymentConfirmedAt) {
      showPaymentScreen(job);
      goTo('payment');
      return;
    }

    if (job.status === 'electrician-complete') {
      showConfirmScreen(job);
      goTo('confirm-work');
      startJobPoll();
      return;
    }

    if (job.status === 'payout-complete') {
      showRatingScreen(job);
      goTo('rating');
      return;
    }

    if (job.status === 'rated') {
      showDoneScreen(job);
      goTo('done');
      return;
    }

    showAssignedScreen(job);
    goTo('assigned');
    startJobPoll();
  }

  function loadHistory() {
    renderHistory();
  }

  function renderHistory() {
    let jobs = Store.getJobs();
    if (currentCustomer) {
      jobs = jobs.filter(function (job) { return job.customerId === currentCustomer.id; });
    }

    const completedStatuses = ['rated', 'cancelled'];
    const filtered = historyFilter === 'completed'
      ? jobs.filter(function (job) { return completedStatuses.includes(job.status); })
      : jobs.filter(function (job) { return !completedStatuses.includes(job.status); });

    const list = document.getElementById('history-list');
    if (!filtered.length) {
      list.innerHTML = '<div class="history-empty"><div class="history-empty-icon">&#128203;</div><div class="history-empty-text">No ' + historyFilter + ' jobs yet</div></div>';
      return;
    }

    filtered.sort(function (a, b) {
      return (b.updatedAt || b.createdAt || 0) - (a.updatedAt || a.createdAt || 0);
    });

    list.innerHTML = filtered.map(function (job) {
      const amount = job.quote ? fmt(job.quote.customerPayableTotal || 0) : '--';
      const categories = job.issueCategories.map(function (category) {
        return '<span class="badge badge-yellow" style="font-size:11px;padding:2px 8px;">' + category + '</span>';
      }).join('');
      return '<div class="history-card" data-job-id="' + job.id + '">' +
        '<div class="history-card-top">' +
          '<div class="history-card-ticket">' + job.ticket + '</div>' +
          '<div class="history-card-date">' + fmtDate(job.updatedAt || job.createdAt) + '</div>' +
        '</div>' +
        '<div class="history-card-cats">' + categories + '</div>' +
        '<div class="history-card-bottom">' +
          '<div class="history-card-elec">&#128119; ' + (job.electricianName || 'No specialist yet') + '</div>' +
          getStatusBadge(job.status) +
        '</div>' +
        '<div class="history-card-bottom" style="margin-top:6px;">' +
          '<div class="history-card-amount">' + amount + '</div>' +
        '</div>' +
      '</div>';
    }).join('');

    list.querySelectorAll('.history-card').forEach(function (card) {
      card.addEventListener('click', function () {
        currentJobId = card.dataset.jobId;
        saveSession();
        resumeJob();
      });
    });
  }

  function getStatusBadge(status) {
    const labels = {
      requested: ['Reassignment', 'badge-red'],
      'assessment-pending': ['Assessment fee', 'badge-yellow'],
      'matched': ['Matched', 'badge-blue'],
      'quoted': ['Quote ready', 'badge-yellow'],
      'payment-pending': ['Payment setup', 'badge-blue'],
      'work-in-progress': ['In progress', 'badge-green'],
      'electrician-complete': ['Confirm job', 'badge-yellow'],
      'payout-complete': ['Rate now', 'badge-blue'],
      'rated': ['Completed', 'badge-green'],
      'cancelled': ['Cancelled', 'badge-red']
    };
    const info = labels[status] || ['Active', 'badge-gray'];
    return '<span class="badge ' + info[1] + '">' + info[0] + '</span>';
  }

  function renderCustomerPriceList() {
    const prices = Store.getPriceList();
    const container = document.getElementById('customer-price-list');
    if (!container) return;

    if (!prices.length) {
      container.innerHTML = '<div class="empty-state"><div class="empty-state-icon">💰</div><div class="empty-state-text">No pricing available yet.</div></div>';
      return;
    }

    container.innerHTML = prices.map(function (item, index) {
      return '<div class="customer-price-row">' +
        '<div class="customer-price-num">' + (index + 1) + '.</div>' +
        '<div class="customer-price-service">' + item.service + '</div>' +
        '<div class="customer-price-amount">' + fmt(item.price) + '</div>' +
      '</div>';
    }).join('');
  }

  function copyAccountNumber(elId, btnId) {
    const text = document.getElementById(elId).textContent;
    if (!navigator.clipboard) return;
    navigator.clipboard.writeText(text).then(function () {
      const button = document.getElementById(btnId);
      button.textContent = 'Copied!';
      setTimeout(function () {
        button.innerHTML = '&#128203; Copy Account Number';
      }, 2000);
    });
  }

  function resetDraftAndForms() {
    draft.serviceArea = '';
    draft.availabilityCount = 0;
    draft.issueCategory = '';
    draft.urgency = 'today';
    draft.assessmentRequested = true;
    draft.materialHandling = 'voltfriq-supplied';
    draft.description = '';
    draft.candidateIds = [];
    draft.chosenElectricianId = null;
    uploadedPhotos = [];
    ratingValue = 0;
    sheetSelectionId = null;

    document.getElementById('service-area-select').value = '';
    document.getElementById('problem-category').value = '';
    document.getElementById('problem-desc').value = '';
    document.getElementById('desc-count').textContent = '0';
    document.querySelectorAll('#urgency-selector .urgency-chip').forEach(function (chip) {
      chip.classList.toggle('active', chip.dataset.urgency === 'today');
    });
    document.querySelectorAll('#assessment-choice .choice-pill').forEach(function (pill) {
      pill.classList.toggle('active', pill.dataset.value === 'yes');
    });
    document.querySelectorAll('#material-choice .choice-pill').forEach(function (pill) {
      pill.classList.toggle('active', pill.dataset.value === 'voltfriq-supplied');
    });
    document.getElementById('photo-previews').innerHTML = '';
    document.getElementById('photo-add-btn').style.display = '';
    document.getElementById('location-helper-note').textContent = 'We will map you to the closest service area available in this demo.';
    renderAvailabilityCard();
    syncProblemSummary();
    updateProblemButton();
    closeSpecialistSheet();
  }

  function summarizeStatus(job) {
    const labels = {
      requested: 'Awaiting reassignment',
      'assessment-pending': job.assessmentFeePaid ? 'Assessment queued' : 'Assessment fee pending',
      'matched': job.assessmentRequested ? 'Assessment in progress' : 'Waiting for remote quote',
      'quoted': 'Quote ready',
      'payment-pending': job.paymentConfirmedAt ? 'Payment recorded' : 'Awaiting payment',
      'work-in-progress': 'Work in progress',
      'electrician-complete': 'Awaiting your confirmation',
      'payout-complete': 'Ready for rating',
      'rated': 'Completed'
    };
    return labels[job.status] || 'Active';
  }

  function assessmentStatusText(job) {
    if (job.status === 'quoted') return 'Assessment report and quotation are ready.';
    if (job.assessmentRequested && !job.assessmentFeePaid) return 'Assessment fee is waiting for payment confirmation.';
    if (!job.assessmentRequested) return 'VoltFriq is reviewing your note, category, and photos for a remote quote.';
    if (job.visitStage === 'on-site') return 'VoltFriq is on site completing the assessment.';
    if (job.visitStage === 'en-route') return 'VoltFriq is on the way to assess the issue.';
    if (job.visitStage === 'accepted') return 'VoltFriq accepted the assessment request.';
    return 'The issue is queued with your recommended VoltFriq.';
  }

  function workStatusText(job) {
    if (job.status === 'work-in-progress') {
      if (job.billingModeSnapshot === 'per-second') {
        return 'Timer-based labour is running at ' + formatPerSecond(job.ratePerSecondSnapshot) + '.';
      }
      return 'Work has started and the quote is now being executed.';
    }
    if (job.status === 'payment-pending' && job.paymentConfirmedAt) {
      return 'Payment is recorded. VoltFriq can now begin the job.';
    }
    if (job.status === 'payment-pending') {
      return 'Customer payment or billing setup is still required.';
    }
    if (job.status === 'electrician-complete') {
      return 'VoltFriq has stopped work and is waiting for your confirmation.';
    }
    return 'Work will move here after quote acceptance.';
  }

  function completionStatusText(job) {
    if (job.status === 'rated') return 'Receipt saved, rating submitted, and history updated.';
    if (job.status === 'payout-complete') return 'Receipt is ready and rating is the only step left.';
    if (job.status === 'electrician-complete') return 'Review the final settlement and release payout when satisfied.';
    return 'The receipt is generated after you confirm completion.';
  }

  function buildQuotationNote(job) {
    const parts = [];
    if (job.billingModeSnapshot === 'per-second') {
      parts.push('Labour is timer-based at ' + formatPerSecond(job.ratePerSecondSnapshot) + '. The final labour total is frozen when the VoltFriq marks work complete.');
    } else {
      parts.push('Labour uses fixed pricing from the quotation.');
    }
    if (job.materialHandling === 'self-procured') {
      parts.push('Materials are shown for reference only because you chose to buy them yourself.');
    } else {
      parts.push('Materials supplied by VoltFriq are included in the payable material total.');
    }
    return parts.join(' ');
  }

  function buildPaymentNote(job, amountDueNow) {
    if (job.billingModeSnapshot === 'per-second') {
      if (amountDueNow > 0) {
        return 'Pay the material cost now. Labour is billed by the second and released after you confirm the completed work.';
      }
      return 'No upfront payment is due now. Labour will be billed by the second and released after you confirm the completed work.';
    }
    return 'This payment covers the current customer-payable amount based on the accepted quote and material choice.';
  }

  function paymentStatusMessage(job) {
    if (job.billingModeSnapshot === 'per-second') {
      return job.materialHandling === 'self-procured'
        ? 'Billing mode is per-second. No upfront material charge is required.'
        : 'Material payment confirmed. Labour will be settled after the timed work stops.';
    }
    return 'Quote payment confirmed. VoltFriq can begin work.';
  }

  function getAmountDueNow(job) {
    const quote = job.quote || { customerPayableTotal: 0, customerMaterialTotal: 0 };
    if (job.billingModeSnapshot === 'per-second') {
      return quote.customerMaterialTotal || 0;
    }
    return quote.customerPayableTotal || 0;
  }

  function formatBillingMode(mode) {
    return mode === 'per-second' ? 'Per-second labour billing' : 'Fixed-price labour billing';
  }

  function formatPayoutMode(mode) {
    return mode === 'direct-to-electrician' ? 'Direct to VoltFriq' : 'Platform hold and release';
  }

  function formatMaterialHandling(mode) {
    return mode === 'self-procured' ? 'Customer buys materials' : 'Voltfriq buys materials';
  }

  function formatPerSecond(rate) {
    return '₦' + Number(rate || 0).toFixed(2) + '/sec';
  }

  document.addEventListener('DOMContentLoaded', init);
  if (document.readyState !== 'loading') {
    init();
  }
})();
