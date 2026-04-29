/* ─── VOLTFRIQ — CUSTOMER PORTAL ───────────────────────────────── */

(function () {
  'use strict';

  let currentJob = null;
  let jobSubscription = null;
  let chatOpen = false;
  let authMode = 'login';
  let historyFilter = 'active';
  let uploadedFiles = [];
  let ratingValue = 0;
  let selectedRatingTags = [];
  let screenBusy = false;

  const ISSUE_OPTIONS = [
    { issue_type: 'Socket / Switch', value: 'Socket repair', description: 'Faulty socket, switch, or new socket point.', estimated_fee_min: 5000, estimated_fee_max: 8000 },
    { issue_type: 'Lighting', value: 'Light fitting', description: 'Install or fix lighting units.', estimated_fee_min: 4000, estimated_fee_max: 8000 },
    { issue_type: 'Wiring', value: 'Wiring issue', description: 'Standard electrical wiring work.', estimated_fee_min: 6000, estimated_fee_max: null },
    { issue_type: 'Breaker / Fuse', value: 'Tripped breaker', description: 'Breaker, fuse, or DB issue.', estimated_fee_min: 8000, estimated_fee_max: 12000 },
    { issue_type: 'Installation', value: 'General Installation', description: 'Install fittings, fixtures, or electrical points.', estimated_fee_min: 8000, estimated_fee_max: null },
    { issue_type: 'Inspection', value: 'General Installation', description: 'Diagnosis, safety check, or quotation visit.', estimated_fee_min: 5000, estimated_fee_max: null },
    { issue_type: 'Solar / Inverter', value: 'Inverter', description: 'Solar or inverter electrical support.', estimated_fee_min: 15000, estimated_fee_max: null },
    { issue_type: 'Other', value: 'Other', description: 'Not sure? Let VoltFriq diagnose it.', estimated_fee_min: null, estimated_fee_max: null }
  ];

  const draft = {
    serviceArea: '',
    locationLabel: '',
    latitude: null,
    longitude: null,
    issueCategory: '',
    issueLabel: '',
    issueKey: '',
    urgency: 'today',
    requiresAssessment: true,
    materialHandling: 'voltfriq_supplied',
    note: '',
    guestPhone: '',
    selectedElectricianId: null,
    matches: []
  };

  document.addEventListener('DOMContentLoaded', init);

  async function init() {
    bindEvents();
    try {
      const boot = await Store.init();
      if (!boot.configured) {
        showConfigurationMessage();
        return;
      }

      if (boot.profile && boot.profile.role !== 'customer') {
        window.location.href = Store.getRoleHome(boot.profile.role);
        return;
      }

      if (document.getElementById('btn-guest')) {
        document.getElementById('btn-guest').style.display = 'none';
      }
      renderSettings();

      if (Store.getCurrentProfile() || Store.getGuestAccess()) {
        await resumeLatestJob();
      } else {
        goTo('welcome');
      }
    } catch (error) {
      showError(error);
    }
  }

  function bindEvents() {
    on('btn-begin-area', 'click', startBooking);
    on('btn-view-prices', 'click', () => {
      renderPriceList();
      goTo('prices');
    });
    on('btn-prices-back', 'click', goBack);
    on('btn-prices-find', 'click', startBooking);

    on('btn-welcome-login', 'click', () => {
      setAuthMode('login');
      goTo('customer-auth');
    });
    on('btn-track-job', 'click', async () => {
      if (currentJob) {
        await openTrackedJob(currentJob.id);
        return;
      }
      if (Store.getGuestAccess()) {
        await resumeLatestJob();
        return;
      }
      await showHistory();
    });

    on('service-area-select', 'change', () => {
      draft.serviceArea = document.getElementById('service-area-select').value;
      if (!document.getElementById('manual-location-input').value.trim()) {
        draft.locationLabel = draft.serviceArea;
      }
      updateAvailabilityCard();
    });
    on('manual-location-input', 'input', () => {
      const manualLocation = document.getElementById('manual-location-input').value.trim();
      draft.locationLabel = manualLocation || draft.serviceArea;
      updateAvailabilityCard();
    });
    on('btn-use-location', 'click', () => useCurrentLocation(false));
    on('btn-area-continue', 'click', () => {
      goTo('problem');
    });

    bindIssueSelect();
    on('problem-desc', 'input', () => {
      draft.note = document.getElementById('problem-desc').value.trim();
      document.getElementById('desc-count').textContent = draft.note.length;
    });

    document.getElementById('urgency-selector').addEventListener('click', (event) => {
      const chip = event.target.closest('.urgency-chip');
      if (!chip) return;
      document.querySelectorAll('#urgency-selector .urgency-chip').forEach((item) => item.classList.remove('active'));
      chip.classList.add('active');
      draft.urgency = chip.dataset.urgency;
    });

    on('photo-add-btn', 'click', () => document.getElementById('photo-input').click());
    on('photo-input', 'change', handlePhotoSelect);
    on('btn-review-match', 'click', () => goTo('urgency'));
    on('btn-urgency-continue', 'click', () => goTo('details'));
    on('btn-details-review', 'click', handleDetailsContinue);
    on('guest-phone', 'input', () => {
      draft.guestPhone = normalizePhoneInput(document.getElementById('guest-phone').value);
      updateGuestContactButton();
    });
    on('btn-guest-continue', 'click', previewMatch);

    on('tab-login', 'click', () => setAuthMode('login'));
    on('tab-register', 'click', () => setAuthMode('register'));
    on('btn-auth-submit', 'click', handleAuthSubmit);

    on('btn-continue-match', 'click', continueFromMatch);
    on('btn-change-specialist', 'click', openSpecialistSheet);
    on('btn-close-sheet', 'click', closeSpecialistSheet);
    on('btn-select-specialist', 'click', applySpecialistSelection);

    on('btn-fee-paid', 'click', () => submitCurrentPayment('assessment_fee'));
    on('fee-copy-btn', 'click', () => copyText('fee-account-number', 'fee-copy-btn'));
    on('pay-copy-btn', 'click', () => copyText('pay-account-number', 'pay-copy-btn'));

    on('btn-open-chat', 'click', openChat);
    on('btn-chat-back', 'click', () => {
      chatOpen = false;
      Chat.destroy();
      goBack();
    });
    on('btn-chat-quotation', 'click', () => {
      if (currentJob) {
        renderQuoteScreen(currentJob);
        goTo('quotation');
      }
    });
    on('btn-view-quote', 'click', () => {
      if (currentJob) {
        renderQuoteScreen(currentJob);
        goTo('quotation');
      }
    });

    on('btn-accept-quote', 'click', acceptCurrentQuote);
    on('btn-negotiate-quote', 'click', openChat);
    on('btn-decline-quote', 'click', () => {
      if (currentJob) {
        Store.updateJobStatus(currentJob.id, 'cancelled', 'Customer cancelled the job.')
          .then(() => resumeLatestJob())
          .catch(showError);
      }
    });

    on('btn-payment-paid', 'click', () => submitCurrentPayment('quote_payment'));
    on('btn-report-issue-assigned', 'click', () => currentJob ? goTo('report-issue') : null);
    on('btn-report-issue-confirm', 'click', () => currentJob ? goTo('report-issue') : null);
    on('btn-submit-dispute', 'click', submitDispute);

    on('confirm-checkbox', 'change', () => {
      document.getElementById('btn-confirm-complete').disabled = !document.getElementById('confirm-checkbox').checked;
    });
    on('btn-confirm-complete', 'click', confirmCompletion);

    document.getElementById('star-rating').addEventListener('click', (event) => {
      const star = event.target.closest('.star');
      if (!star) return;
      ratingValue = parseInt(star.dataset.star, 10);
      updateStars();
    });
    document.getElementById('rating-tags').addEventListener('click', (event) => {
      const tag = event.target.closest('[data-rating-tag]');
      if (!tag) return;
      tag.classList.toggle('active');
      selectedRatingTags = Array.from(document.querySelectorAll('#rating-tags [data-rating-tag].active')).map((item) => item.dataset.ratingTag);
    });
    on('rating-comment', 'input', () => {
      document.getElementById('rating-count').textContent = document.getElementById('rating-comment').value.length;
    });
    on('btn-submit-rating', 'click', submitRating);

    on('btn-view-history', 'click', showHistory);
    on('btn-find-another', 'click', () => {
      resetDraft();
      goTo('welcome');
    });
    on('btn-assigned-history', 'click', showHistory);
    on('btn-history-back', 'click', goBack);

    document.getElementById('history-tabs').addEventListener('click', (event) => {
      const tab = event.target.closest('.tab');
      if (!tab) return;
      document.querySelectorAll('#history-tabs .tab').forEach((item) => item.classList.remove('active'));
      tab.classList.add('active');
      historyFilter = tab.dataset.filter;
      showHistory();
    });
  }

  function showConfigurationMessage() {
    document.getElementById('availability-meta').textContent = 'Add your Supabase URL and anon key in js/config.js to enable live booking.';
    document.getElementById('auth-error').style.display = 'block';
    document.getElementById('auth-error').textContent = 'Supabase is not configured yet.';
  }

  function renderSettings() {
    const settings = Store.getSettings();
    document.getElementById('service-area-select').innerHTML = '<option value="">Select a service area</option>' +
      (settings.service_areas || []).map((area) => '<option value="' + area + '">' + area + '</option>').join('');

    renderIssueSelect();
  }

  function startBooking() {
    resetDraft();
    goTo('service-area');
    window.setTimeout(() => useCurrentLocation(true), 250);
  }

  function bindChoiceRow(id, callback) {
    const container = document.getElementById(id);
    if (!container) return;
    container.addEventListener('click', (event) => {
      const pill = event.target.closest('.choice-pill');
      if (!pill) return;
      container.querySelectorAll('.choice-pill').forEach((item) => item.classList.remove('active'));
      pill.classList.add('active');
      callback(pill.dataset.value);
    });
  }

  async function useCurrentLocation(autoStarted) {
    if (!navigator.geolocation) {
      document.getElementById('location-helper-note').textContent = 'GPS is not available on this device. Enter your area manually.';
      return;
    }

    const button = document.getElementById('btn-use-location');
    const originalText = button ? button.textContent : '';
    const detectedCard = document.getElementById('detected-location-card');
    const detectedText = document.getElementById('detected-location-text');
    if (button) {
      button.disabled = true;
      button.textContent = autoStarted ? 'Finding Your Location...' : 'Refreshing Location...';
    }
    if (detectedCard) detectedCard.style.display = '';
    if (detectedText) detectedText.textContent = 'Finding your location...';
    document.getElementById('location-helper-note').textContent = 'Allow location access so VoltFriq can route the nearest available electrician.';

    navigator.geolocation.getCurrentPosition(async (position) => {
      draft.latitude = position.coords.latitude;
      draft.longitude = position.coords.longitude;
      const readableLocation = await reverseGeocode(position.coords.latitude, position.coords.longitude);
      const fallbackLabel = 'GPS location (' + position.coords.latitude.toFixed(4) + ', ' + position.coords.longitude.toFixed(4) + ')';
      const manualLocation = document.getElementById('manual-location-input').value.trim();
      draft.locationLabel = manualLocation || readableLocation || fallbackLabel;
      draft.serviceArea = manualLocation || readableLocation || draft.serviceArea || 'GPS location';
      if (!manualLocation && readableLocation) {
        document.getElementById('manual-location-input').value = readableLocation;
      }
      if (detectedText) detectedText.textContent = draft.locationLabel;
      document.getElementById('location-helper-note').textContent = 'Confirm this location or edit the area before continuing.';
      if (button) {
        button.disabled = false;
        button.textContent = 'Refresh Current Location';
      }
      updateAvailabilityCard();
    }, () => {
      if (detectedText) detectedText.textContent = 'Location access was blocked.';
      document.getElementById('location-helper-note').textContent = 'Enter your area manually to continue.';
      if (button) {
        button.disabled = false;
        button.textContent = originalText || 'Use Current Location';
      }
      updateAvailabilityCard();
    }, {
      enableHighAccuracy: true,
      timeout: 12000,
      maximumAge: 60000
    });
  }

  async function reverseGeocode(latitude, longitude) {
    try {
      const response = await fetch('https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=' + encodeURIComponent(latitude) + '&longitude=' + encodeURIComponent(longitude) + '&localityLanguage=en');
      if (!response.ok) return '';
      const data = await response.json();
      const parts = [
        data.locality,
        data.city && data.city !== data.locality ? data.city : '',
        data.principalSubdivision
      ].filter(Boolean);
      return Array.from(new Set(parts)).join(', ');
    } catch (error) {
      return '';
    }
  }

  function handlePhotoSelect(event) {
    const files = Array.from(event.target.files || []);
    const validFiles = files.filter((file) => file.type.indexOf('image/') === 0 && file.size <= 5 * 1024 * 1024);
    const availableSlots = 3 - uploadedFiles.length;
    uploadedFiles = uploadedFiles.concat(validFiles.slice(0, availableSlots));
    if (validFiles.length !== files.length) {
      showError(new Error('Only image uploads under 5MB are allowed.'));
    }
    renderPhotoPreviews();
    event.target.value = '';
  }

  function renderPhotoPreviews() {
    const list = document.getElementById('photo-previews');
    list.innerHTML = uploadedFiles.map((file, index) => {
      return '<div class="photo-preview">' +
        '<div style="padding:14px 10px;font-size:12px;font-weight:600;line-height:1.4;">' + escapeHtml(file.name) + '</div>' +
        '<button class="photo-remove" data-index="' + index + '">&times;</button>' +
      '</div>';
    }).join('');

    list.querySelectorAll('.photo-remove').forEach((button) => {
      button.addEventListener('click', () => {
        uploadedFiles.splice(parseInt(button.dataset.index, 10), 1);
        renderPhotoPreviews();
      });
    });
  }

  function updateAvailabilityCard() {
    const selectedArea = document.getElementById('service-area-select').value;
    const manualLocation = document.getElementById('manual-location-input').value.trim();
    draft.serviceArea = selectedArea || (manualLocation || draft.serviceArea);
    if (manualLocation) {
      draft.locationLabel = manualLocation;
    } else if (selectedArea) {
      draft.locationLabel = selectedArea;
    } else if (!draft.latitude || !draft.longitude) {
      draft.locationLabel = '';
      draft.serviceArea = '';
    }
    const hasLocation = !!(draft.serviceArea || draft.locationLabel || (draft.latitude && draft.longitude));
    document.getElementById('availability-count').textContent = hasLocation ? 'Ready' : 'Waiting';
    document.getElementById('availability-meta').textContent = hasLocation
      ? 'Location saved.'
      : 'Enter an area or use current location.';
    document.getElementById('btn-area-continue').disabled = !hasLocation;
  }

  function syncProblemSummary() {
    const areaLabel = document.getElementById('problem-area-label');
    const availabilityPill = document.getElementById('problem-availability-pill');
    if (areaLabel) areaLabel.textContent = draft.locationLabel || draft.serviceArea || '--';
    if (availabilityPill) availabilityPill.textContent = (draft.locationLabel || draft.serviceArea) ? 'Ready to book' : 'No area';
  }

  function updateReviewButton() {
    document.getElementById('btn-review-match').disabled = !draft.issueCategory;
  }

  function bindIssueSelect() {
    const select = document.getElementById('problem-category');
    if (!select) return;
    select.addEventListener('change', () => selectIssue(select.value));
  }

  function renderIssueSelect() {
    const select = document.getElementById('problem-category');
    if (!select) return;
    const issues = getIssueOptions();
    select.innerHTML = '<option value="">Select the issue</option>' + issues.map((issue) => {
      return '<option value="' + escapeHtml(issue.key) + '">' + escapeHtml(issue.issue_type) + '</option>';
    }).join('');
    select.value = draft.issueKey || '';
    renderIssueEstimate();
  }

  function selectIssue(key) {
    const issue = getIssueOptions().find((item) => item.key === key);
    if (!issue) {
      draft.issueCategory = '';
      draft.issueLabel = '';
      draft.issueKey = '';
      renderIssueEstimate();
      updateReviewButton();
      return;
    }
    draft.issueCategory = issue.value;
    draft.issueLabel = issue.issue_type;
    draft.issueKey = issue.key;
    document.getElementById('problem-category').value = issue.key;
    renderIssueEstimate();
    updateReviewButton();
  }

  function renderIssueEstimate() {
    const card = document.getElementById('issue-estimate-card');
    if (!card) return;
    const issue = getIssueOption(draft.issueCategory, draft.issueLabel);
    card.style.display = issue ? '' : 'none';
    if (issue) {
      document.getElementById('issue-estimate-value').textContent = formatIssueFee(issue);
    }
  }

  function handleDetailsContinue() {
    if (!Store.getCurrentProfile()) {
      renderGuestContact();
      goTo('guest-contact');
      return;
    }
    previewMatch();
  }

  function renderGuestContact() {
    const profile = Store.getCurrentProfile();
    const knownPhone = (profile && profile.phone) || draft.guestPhone || '';
    if (knownPhone) {
      document.getElementById('guest-phone').value = knownPhone;
      draft.guestPhone = normalizePhoneInput(knownPhone);
    }
    document.getElementById('guest-location-confirm').innerHTML = [
      ['Location', draft.locationLabel || draft.serviceArea || 'Not set'],
      ['GPS', draft.latitude && draft.longitude ? 'Captured' : 'Manual area only']
    ].map(renderMiniMetaRow).join('');
    updateGuestContactButton();
  }

  function updateGuestContactButton() {
    const button = document.getElementById('btn-guest-continue');
    if (!button) return;
    button.disabled = !isValidPhone(draft.guestPhone);
  }

  async function previewMatch() {
    await withButtonLoading('btn-details-review', 'Preparing Review...', async () => {
      draft.matches = [];
      draft.selectedElectricianId = null;
      renderMatch();
      goTo('match');
    });
  }

  function renderMatch() {
    const summary = document.getElementById('match-summary-card');
    const card = document.getElementById('match-electrician-card');
    const transparency = document.getElementById('transparency-card');
    const submitButton = document.getElementById('btn-continue-match');

    card.style.display = 'none';
    transparency.style.display = '';
    submitButton.disabled = false;
    submitButton.textContent = 'Submit Booking';

    summary.innerHTML = '<strong>Review booking</strong><br/>Submit once everything looks right.';
    document.getElementById('match-avatar').textContent = '⚡';
    document.getElementById('match-name').textContent = 'Verified electrician matching starts after submission';
    document.getElementById('match-specialty').textContent = 'Approved, available, nearby VoltFriqs only';
    document.getElementById('match-rating').textContent = 'Live';
    document.getElementById('match-jobs').textContent = uploadedFiles.length;
    document.getElementById('match-distance').textContent = draft.latitude && draft.longitude ? 'GPS' : 'Area';
    document.getElementById('match-reason').textContent = 'Matching will use issue fit, area or GPS location, urgency, rating, completed jobs, response time, and availability.';

    transparency.innerHTML = [
      ['Location', draft.locationLabel || draft.serviceArea],
      ['Issue type', draft.issueLabel || draft.issueCategory],
      ['Estimated Workmanship Fee', getIssueEstimate(draft.issueCategory, draft.issueLabel)],
      ['Urgency', formatUrgencyLabel(draft.urgency)],
      ['Mobile number', Store.getCurrentProfile() ? ((Store.getCurrentProfile() && Store.getCurrentProfile().phone) || 'Account phone') : draft.guestPhone],
      ['Description', draft.note || 'No extra description added'],
      ['Photos', uploadedFiles.length ? String(uploadedFiles.length) + ' attached' : 'No photo attached']
    ].map(renderKeyValueRow).join('');
  }

  function renderSpecialistSheet() {
    if (!draft.matches.length) {
      document.getElementById('specialist-list').innerHTML = '';
      return;
    }
    document.getElementById('specialist-list').innerHTML = draft.matches.map((match) => {
      const selected = match.id === draft.selectedElectricianId ? ' selected' : '';
      return '<div class="sheet-option' + selected + '" data-elec-id="' + match.id + '">' +
        '<div class="sheet-option-avatar">⚡</div>' +
        '<div style="flex:1;min-width:0;">' +
          '<div class="sheet-option-name">' + escapeHtml(match.name) + '</div>' +
          '<div class="sheet-option-sub">' + escapeHtml(match.serviceAreas.join(', ')) + ' · ★ ' + (match.rating ? match.rating.toFixed(1) : '--') + ' · ' + match.jobsCompleted + ' jobs · ' + match.distance + ' km</div>' +
        '</div>' +
      '</div>';
    }).join('');

    document.querySelectorAll('#specialist-list .sheet-option').forEach((option) => {
      option.addEventListener('click', () => {
        draft.selectedElectricianId = option.dataset.elecId;
        renderSpecialistSheet();
      });
    });
  }

  function openSpecialistSheet() {
    document.getElementById('specialist-sheet').style.display = 'flex';
  }

  function closeSpecialistSheet() {
    document.getElementById('specialist-sheet').style.display = 'none';
  }

  function applySpecialistSelection() {
    const selected = draft.matches.find((match) => match.id === draft.selectedElectricianId);
    if (selected) {
      document.getElementById('match-name').textContent = selected.name;
      document.getElementById('match-specialty').textContent = selected.serviceAreas.join(', ');
      document.getElementById('match-rating').textContent = selected.rating ? selected.rating.toFixed(1) : '--';
      document.getElementById('match-jobs').textContent = selected.jobsCompleted || 0;
      document.getElementById('match-distance').textContent = selected.distance;
    }
    closeSpecialistSheet();
  }

  function setAuthMode(mode) {
    authMode = mode;
    document.getElementById('tab-login').classList.toggle('active', mode === 'login');
    document.getElementById('tab-register').classList.toggle('active', mode === 'register');
    document.getElementById('auth-name-group').style.display = mode === 'register' ? 'block' : 'none';
    document.getElementById('auth-referral-group').style.display = mode === 'register' ? 'block' : 'none';
    document.getElementById('btn-auth-submit').textContent = mode === 'register' ? 'Create Account' : 'Login';
    document.getElementById('auth-error').style.display = 'none';
  }

  async function handleAuthSubmit() {
    const email = document.getElementById('auth-contact').value.trim();
    const password = document.getElementById('auth-password').value.trim();
    const name = document.getElementById('auth-name').value.trim();
    const referralCode = document.getElementById('auth-referral-code').value.trim();

    await withButtonLoading('btn-auth-submit', authMode === 'register' ? 'Creating Account...' : 'Signing In...', async () => {
      if (!email || !password) {
        throw new Error('Enter your email and password to continue.');
      }
      if (authMode === 'register') {
        if (!name) throw new Error('Enter your full name to create the account.');
        await Store.signUpCustomer({
          email: email,
          password: password,
          fullName: name,
          referralCode: referralCode
        });
      } else {
        await Store.signIn(email, password);
      }

      await continueFromMatch();
    });
  }

  async function continueFromMatch() {
    await withButtonLoading('btn-continue-match', 'Creating Booking...', async () => {
      if (!Store.getCurrentProfile() && !isValidPhone(draft.guestPhone)) {
        renderGuestContact();
        goTo('guest-contact');
        return;
      }
      const bookingPayload = {
        serviceArea: draft.serviceArea || draft.locationLabel,
        locationLabel: draft.locationLabel || draft.serviceArea,
        latitude: draft.latitude,
        longitude: draft.longitude,
        issueCategory: draft.issueCategory,
        urgency: draft.urgency,
        note: draft.note,
        requiresAssessment: draft.requiresAssessment,
        materialHandling: draft.materialHandling,
        photos: uploadedFiles,
        phone: draft.guestPhone
      };
      const job = Store.getCurrentProfile()
        ? await Store.createBooking(bookingPayload)
        : await Store.createGuestBooking(bookingPayload);
      await openTrackedJob(job.id);
    });
  }

  async function resumeLatestJob() {
    if (!Store.getCurrentProfile() && Store.getGuestAccess()) {
      try {
        const guestJob = await Store.getGuestJob(Store.getGuestAccess().jobId, Store.getGuestAccess().accessToken);
        if (guestJob && !['rated', 'cancelled'].includes(guestJob.status)) {
          await openTrackedJob(guestJob.id);
          return;
        }
      } catch (error) {
        Store.clearGuestAccess();
      }
    }
    const jobs = await Store.listCustomerJobs();
    const active = jobs.find((job) => !['rated', 'cancelled'].includes(job.status));
    if (active) {
      await openTrackedJob(active.id);
      return;
    }
    if (jobs[0]) {
      currentJob = jobs[0];
    }
    goTo('welcome');
  }

  async function openTrackedJob(jobId) {
    currentJob = await Store.getJob(jobId);
    bindJobSubscription(jobId);
    await renderSidecars();
    routeJob(currentJob);
  }

  function bindJobSubscription(jobId) {
    if (jobSubscription) jobSubscription.unsubscribe();
    jobSubscription = Store.subscribeToJob(jobId, async (job) => {
      currentJob = job;
      await renderSidecars();
      routeJob(job, true);
      if (chatOpen) {
        await Chat.render();
      }
    });
  }

  function routeJob(job, preserveScreen) {
    renderAssigned(job);

    if (job.status === 'assessment_fee_pending' || job.status === 'assessment_payment_pending_verification' || job.status === 'assessment_confirmed') {
      renderAssessmentFee(job);
      if (!preserveScreen && ['assessment_fee_pending', 'assessment_payment_pending_verification'].includes(job.status)) goTo('appearance-fee');
      if (job.status === 'assessment_confirmed' && !preserveScreen) goTo('assigned');
      return;
    }

    if (job.status === 'quoted') {
      renderQuoteScreen(job);
      if (!preserveScreen) goTo('quotation');
      return;
    }

    if (job.status === 'quote_accepted' || job.status === 'work_payment_pending_verification' || job.status === 'payment_confirmed') {
      renderPaymentScreen(job);
      if (!preserveScreen && ['quote_accepted', 'work_payment_pending_verification'].includes(job.status)) goTo('payment');
      if (job.status === 'payment_confirmed' && !preserveScreen) goTo('assigned');
      return;
    }

    if (job.status === 'electrician_completed' || job.status === 'customer_confirmed' || job.status === 'payout_pending') {
      renderConfirmScreen(job);
      if (!preserveScreen && job.status === 'electrician_completed') goTo('confirm-work');
      if (!preserveScreen && ['customer_confirmed', 'payout_pending'].includes(job.status)) goTo('assigned');
      return;
    }

    if (job.status === 'payout_complete') {
      if (job.isGuest) {
        renderDoneScreen(job);
        if (!preserveScreen) goTo('done');
        return;
      }
      renderRatingScreen(job);
      if (!preserveScreen) goTo('rating');
      return;
    }

    if (job.status === 'rated') {
      renderDoneScreen(job);
      if (!preserveScreen) goTo('done');
      return;
    }

    if (!preserveScreen) goTo('assigned');
  }

  function renderAssigned(job) {
    const electrician = job.assignedElectrician;
    const matchingMessage = job.needsManualAssignment
      ? 'No electrician available yet — VoltFriq support will follow up'
      : job.status === 'assigned'
        ? 'Electrician assigned'
        : ['assessment_fee_pending', 'assessment_payment_pending_verification', 'assessment_confirmed', 'quoted', 'quote_accepted', 'work_payment_pending_verification', 'payment_confirmed', 'en_route', 'on_site', 'work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated'].includes(job.status)
          ? 'Electrician accepted'
        : job.status === 'accepted'
          ? 'Electrician accepted'
          : 'Finding a verified electrician near you';
    document.getElementById('tracking-summary').innerHTML = [
      ['Ticket', job.ticket],
      ['Dispatch', matchingMessage],
      ['Issue', humanizeIssueCategory(job.issueCategory)]
    ].map(renderKeyValueRow).join('');

    document.getElementById('assigned-avatar').textContent = '⚡';
    document.getElementById('assigned-name').textContent = electrician ? electrician.name : (job.needsManualAssignment ? 'VoltFriq support is reviewing this request' : 'Finding a verified electrician near you');
    document.getElementById('assigned-specialty').textContent = electrician
      ? ((electrician.locationLabel || electrician.serviceAreas.join(', ')) || 'Nearest available VoltFriq')
      : (job.needsManualAssignment ? 'Manual assignment required' : 'Matching the nearest verified VoltFriq');
    document.getElementById('assigned-rating').textContent = electrician && electrician.rating ? electrician.rating.toFixed(1) : '--';
    document.getElementById('assigned-jobs').textContent = electrician ? electrician.jobsCompleted : '--';
    document.getElementById('assigned-distance').textContent = electrician ? calculateDistanceLabel(job, electrician) : '--';
    document.getElementById('assigned-badges').innerHTML = electrician && electrician.badges ? electrician.badges.map((badge) => '<span class="badge badge-blue">' + escapeHtml(badge) + '</span>').join('') : '<span class="badge badge-blue">Verified Pro</span>';
    document.getElementById('assigned-trust-note').textContent = electrician
      ? 'Response rate ' + Math.round(electrician.responseRate || 0) + '% · ' + (electrician.totalRatings || 0) + ' rating(s)'
      : 'Approved electricians only';
    document.getElementById('assigned-categories').innerHTML = '<span class="badge badge-yellow">' + escapeHtml(humanizeIssueCategory(job.issueCategory)) + '</span>';
    document.getElementById('assigned-desc').textContent = job.description || 'No additional note added.';
    document.getElementById('assigned-meta-list').innerHTML = [
      ['Service area', job.serviceArea],
      ['Location', job.locationLabel || job.serviceArea],
      ['Assessment', job.requiresAssessment ? 'Required' : 'Remote quote first'],
      ['Materials', job.materialHandling === 'self_procured' ? 'Customer supplied' : 'VoltFriq supplied']
    ].map(renderMiniMetaRow).join('');
    document.getElementById('btn-view-quote').style.display = job.quote && job.quote.id ? '' : 'none';
    document.getElementById('btn-open-chat').style.display = job.isGuest ? 'none' : '';
    document.getElementById('btn-report-issue-assigned').style.display = job.isGuest ? 'none' : '';
    document.getElementById('btn-report-issue-confirm').style.display = job.isGuest ? 'none' : '';
    renderStatusLines(job);
  }

  function renderStatusLines(job) {
    const lines = [
      statusLine('Finding verified electrician near you', ['requested', 'matching', 'assigned', 'accepted', 'assessment_fee_pending', 'assessment_payment_pending_verification', 'assessment_confirmed', 'quoted', 'quote_accepted', 'work_payment_pending_verification', 'payment_confirmed', 'en_route', 'on_site', 'work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated'].includes(job.status), job.needsManualAssignment ? 'No electrician is available yet. VoltFriq support will follow up.' : 'VoltFriq is routing the nearest approved electrician for this request.'),
      statusLine('Electrician assigned', ['assigned', 'accepted', 'assessment_fee_pending', 'assessment_payment_pending_verification', 'assessment_confirmed', 'quoted', 'quote_accepted', 'work_payment_pending_verification', 'payment_confirmed', 'en_route', 'on_site', 'work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated'].includes(job.status), 'An available electrician has been assigned to your booking.'),
      statusLine('Payment proof submitted', ['assessment_payment_pending_verification', 'work_payment_pending_verification', 'assessment_confirmed', 'payment_confirmed', 'en_route', 'on_site', 'work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated'].includes(job.status), 'Submitted payment proofs stay pending until admin verification is complete.'),
      statusLine('Payment verified', ['assessment_confirmed', 'payment_confirmed', 'en_route', 'on_site', 'work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated'].includes(job.status), 'VoltFriq only moves forward after manual payment verification.'),
      statusLine('Electrician en route', ['en_route', 'on_site', 'work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated'].includes(job.status), 'Track the assigned electrician as the visit begins.'),
      statusLine('Work in progress', ['work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated'].includes(job.status), 'The electrician is actively working on your request.'),
      statusLine('Completed', ['electrician_completed', 'customer_confirmed', 'payout_pending', 'payout_complete', 'rated'].includes(job.status), 'Confirm completion before payout is released.'),
      statusLine('Rate electrician', ['payout_complete', 'rated'].includes(job.status), 'Rate the finished job after payout is released.')
    ];
    document.getElementById('status-lines').innerHTML = lines.join('');
  }

  function statusLine(title, done, sub) {
    return '<div class="status-line ' + (done ? 'done' : '') + '">' +
      '<div class="status-line-dot"></div>' +
      '<div><div class="status-line-title">' + title + '</div><div class="status-line-sub">' + sub + '</div></div>' +
    '</div>';
  }

  function renderAssessmentFee(job) {
    const settings = Store.getSettings();
    document.getElementById('fee-amount').textContent = Store.formatCurrency(settings.assessment_fee || 0);
    document.getElementById('assessment-snapshot').innerHTML = [
      ['Status', job.statusLabel],
      ['Verification', 'Manual review required before the VoltFriq can continue'],
      ['Ticket', job.ticket]
    ].map(renderKeyValueRow).join('');
    document.getElementById('fee-bank-name').textContent = settings.platform_bank_name || '';
    document.getElementById('fee-account-number').textContent = settings.platform_account_number || '';
    document.getElementById('fee-account-name').textContent = settings.platform_account_name || '';
    document.getElementById('btn-fee-paid').textContent = job.status === 'assessment_payment_pending_verification'
      ? 'Payment Proof Submitted'
      : 'Submit Assessment Payment Proof';
    document.getElementById('btn-fee-paid').disabled = job.status === 'assessment_payment_pending_verification';
  }

  function renderQuoteScreen(job) {
    const quote = job.quote;
    document.getElementById('quot-findings').textContent = quote.findings || 'The VoltFriq has prepared the quote.';
    document.getElementById('quot-labour-items').innerHTML = quote.items.filter((item) => item.itemType !== 'material').map(renderQuoteItem).join('') || '<div class="quot-empty">No labour items listed.</div>';
    document.getElementById('quot-material-items').innerHTML = quote.items.filter((item) => item.itemType === 'material').map(renderQuoteItem).join('') || '<div class="quot-empty">No materials listed.</div>';
    document.getElementById('quot-total-amount').textContent = Store.formatCurrency(quote.total || 0);
    document.getElementById('quotation-note').textContent = 'Admin verifies any payment proof before the job moves into work.';
  }

  function renderQuoteItem(item) {
    return '<div class="quot-item"><span>' + escapeHtml(item.description) + '</span><span>' + Store.formatCurrency(item.lineTotal || 0) + '</span></div>';
  }

  function renderPaymentScreen(job) {
    const settings = Store.getSettings();
    const amount = job.quote && job.quote.total ? job.quote.total : 0;
    document.getElementById('payment-amount').textContent = Store.formatCurrency(amount);
    document.getElementById('payment-note').textContent = 'Upload your payment proof. A VoltFriq only moves forward after admin verifies it.';
    document.getElementById('payment-snapshot').innerHTML = [
      ['Status', job.statusLabel],
      ['Ticket', job.ticket],
      ['Verification', 'Manual admin review']
    ].map(renderKeyValueRow).join('');
    document.getElementById('pay-bank-name').textContent = settings.platform_bank_name || '';
    document.getElementById('pay-account-number').textContent = settings.platform_account_number || '';
    document.getElementById('pay-account-name').textContent = settings.platform_account_name || '';
    document.getElementById('btn-payment-paid').textContent = job.status === 'work_payment_pending_verification'
      ? 'Payment Proof Submitted'
      : 'Submit Payment Proof';
    document.getElementById('btn-payment-paid').disabled = job.status === 'work_payment_pending_verification';
    document.getElementById('payment-reference').value = '';
  }

  function renderConfirmScreen(job) {
    const quote = job.quote || { items: [], total: 0 };
    document.getElementById('confirm-items').innerHTML = [
      ['Ticket', job.ticket],
      ['Issue', humanizeIssueCategory(job.issueCategory)],
      ['Current total', Store.formatCurrency(quote.total || 0)]
    ].map(renderKeyValueRow).join('');

    document.getElementById('confirm-elec-status').innerHTML = job.status === 'electrician_completed'
      ? '<span class="dot-live"></span> VoltFriq marked the work complete. Confirm when satisfied.'
      : '<span class="dot-live"></span> Completion confirmed. Waiting for admin payout release.';

    document.getElementById('final-settlement-card').innerHTML = [
      ['Job status', job.statusLabel],
      ['Next action', job.status === 'electrician_completed' ? 'Confirm the job' : 'Wait for payout release']
    ].map(renderKeyValueRow).join('');

    const disabled = job.status !== 'electrician_completed';
    document.getElementById('confirm-checkbox').checked = false;
    document.getElementById('confirm-checkbox').disabled = disabled;
    document.getElementById('btn-confirm-complete').disabled = true;
  }

  function renderRatingScreen(job) {
    document.getElementById('rating-comment').value = '';
    document.getElementById('rating-count').textContent = '0';
    document.getElementById('btn-submit-rating').disabled = false;
    ratingValue = 0;
    selectedRatingTags = [];
    document.querySelectorAll('#rating-tags [data-rating-tag]').forEach((tag) => tag.classList.remove('active'));
    updateStars();
  }

  function renderDoneScreen(job) {
    document.getElementById('done-receipt-card').innerHTML = [
      ['Ticket', job.ticket],
      ['Status', Store.getStatusLabel(job.status)],
      ['Area', job.serviceArea]
    ].map(renderKeyValueRow).join('');
  }

  async function acceptCurrentQuote() {
    await withButtonLoading('btn-accept-quote', 'Accepting Quote...', async () => {
      if (!currentJob) return;
      await Store.acceptQuote(currentJob.id);
      await openTrackedJob(currentJob.id);
    });
  }

  async function submitCurrentPayment(paymentType) {
    const buttonId = paymentType === 'assessment_fee' ? 'btn-fee-paid' : 'btn-payment-paid';
    await withButtonLoading(buttonId, 'Uploading Proof...', async () => {
      if (!currentJob) return;
      const file = document.getElementById(paymentType === 'assessment_fee' ? 'assessment-receipt-upload' : 'receipt-upload');
      const amount = paymentType === 'assessment_fee'
        ? Number(Store.getSettings().assessment_fee || 0)
        : Number((currentJob.quote && currentJob.quote.total) || 0);
      if (!file || !file.files || !file.files[0]) {
        throw new Error('Attach your payment proof before submitting.');
      }
      await Store.submitPaymentProof(currentJob.id, {
        paymentType: paymentType,
        amount: amount,
        reference: paymentType === 'assessment_fee' ? '' : document.getElementById('payment-reference').value.trim(),
        file: file && file.files ? file.files[0] : null
      });
      await openTrackedJob(currentJob.id);
    });
  }

  async function confirmCompletion() {
    await withButtonLoading('btn-confirm-complete', 'Confirming...', async () => {
      if (!currentJob) return;
      await Store.markCustomerConfirmed(currentJob.id);
      await Store.markPayoutPending(currentJob.id);
      await openTrackedJob(currentJob.id);
    });
  }

  async function submitRating() {
    await withButtonLoading('btn-submit-rating', 'Submitting Rating...', async () => {
      if (!currentJob || !ratingValue) {
        throw new Error('Select a rating before submitting.');
      }
      await Store.submitRating(currentJob.id, ratingValue, document.getElementById('rating-comment').value.trim(), selectedRatingTags);
      await openTrackedJob(currentJob.id);
    });
  }

  async function showHistory() {
    try {
      setScreenBusy(true, 'Loading your jobs...');
      await renderSidecars();
      const jobs = await Store.listCustomerJobs();
      const filtered = historyFilter === 'completed'
        ? jobs.filter((job) => ['rated', 'cancelled'].includes(job.status))
        : jobs.filter((job) => !['rated', 'cancelled'].includes(job.status));
      document.getElementById('history-list').innerHTML = filtered.length ? filtered.map(renderHistoryCard).join('') : '<div class="empty-state"><div class="empty-state-text">No jobs in this view yet.</div></div>';
      document.querySelectorAll('#history-list .history-card').forEach((card) => {
        card.addEventListener('click', () => openTrackedJob(card.dataset.jobId));
      });
      goTo('history');
    } catch (error) {
      showError(error);
    } finally {
      setScreenBusy(false);
    }
  }

  function renderHistoryCard(job) {
    return '<div class="history-card" data-job-id="' + job.id + '">' +
      '<div class="history-card-date">' + fmtDate(new Date(job.createdAt).getTime()) + '</div>' +
      '<div class="history-card-title">' + escapeHtml(humanizeIssueCategory(job.issueCategory)) + '</div>' +
      '<div class="history-card-sub">' + escapeHtml(job.serviceArea) + '</div>' +
      '<div class="history-card-badge badge badge-blue">' + escapeHtml(job.statusLabel) + '</div>' +
      (job.rating ? '<div class="history-card-sub">Your rating: ' + escapeHtml(String(job.rating.score)) + '/5</div>' : '') +
    '</div>';
  }

  function renderPriceList() {
    const container = document.getElementById('customer-price-list');
    container.innerHTML = '<div class="estimate-list">' + getIssueOptions().map((issue) => (
      '<div class="estimate-row"><div class="estimate-service"><div class="estimate-service-name">' + escapeHtml(issue.issue_type) +
      '</div><div class="estimate-service-note">' + escapeHtml(issue.description || 'Final cost may vary after inspection.') +
      '</div></div><div class="estimate-amount">' + escapeHtml(formatIssueFee(issue)) + '</div></div>'
    )).join('') + '</div>';
  }

  async function openChat() {
    if (!currentJob) return;
    chatOpen = true;
    document.getElementById('chat-elec-name').textContent = currentJob.assignedElectrician ? currentJob.assignedElectrician.name : 'VoltFriq Support';
    document.getElementById('chat-ticket-label').textContent = currentJob.ticket;
    goTo('chat');
    await Chat.init('customer-chat-container', currentJob.id, 'customer', (Store.getCurrentProfile() || {}).full_name || 'Customer');
  }

  function copyText(sourceId, buttonId) {
    const value = document.getElementById(sourceId).textContent;
    navigator.clipboard.writeText(value).then(() => {
      const button = document.getElementById(buttonId);
      const original = button.textContent;
      button.textContent = 'Copied';
      setTimeout(() => {
        button.textContent = original;
      }, 1200);
    });
  }

  function updateStars() {
    document.querySelectorAll('#star-rating .star').forEach((star) => {
      const value = parseInt(star.dataset.star, 10);
      star.classList.toggle('active', value <= ratingValue);
      star.innerHTML = value <= ratingValue ? '&#9733;' : '&#9734;';
    });
  }

  function resetDraft() {
    draft.serviceArea = '';
    draft.locationLabel = '';
    draft.latitude = null;
    draft.longitude = null;
    draft.issueCategory = '';
    draft.issueLabel = '';
    draft.issueKey = '';
    draft.urgency = 'today';
    draft.requiresAssessment = true;
    draft.materialHandling = 'voltfriq_supplied';
    draft.note = '';
    draft.guestPhone = '';
    draft.selectedElectricianId = null;
    draft.matches = [];
    uploadedFiles = [];
    document.getElementById('service-area-select').value = '';
    document.getElementById('manual-location-input').value = '';
    document.getElementById('problem-category').value = '';
    document.getElementById('problem-desc').value = '';
    if (document.getElementById('guest-phone')) document.getElementById('guest-phone').value = '';
    if (document.getElementById('detected-location-card')) document.getElementById('detected-location-card').style.display = 'none';
    document.getElementById('auth-referral-code').value = '';
    document.getElementById('dispute-type').value = '';
    document.getElementById('dispute-details').value = '';
    document.getElementById('desc-count').textContent = '0';
    renderPhotoPreviews();
    updateAvailabilityCard();
    renderIssueSelect();
    updateReviewButton();
  }

  async function renderSidecars() {
    try {
      const notifications = await Store.listNotifications();
      const walletSummary = await Store.getWalletSummary();
      const referralSummary = await Store.getReferralSummary();
      renderNotifications(notifications);
      renderWalletAndReferral(walletSummary, referralSummary);
    } catch (error) {
      // Keep the core flow moving even if these side panels fail.
    }
  }

  function renderNotifications(notifications) {
    const list = (notifications || []).slice(0, 4);
    const markup = list.length
      ? list.map((note) => '<div class="mini-meta-row"><span class="mini-meta-label">' + escapeHtml(note.title) + '</span><span class="mini-meta-value">' + escapeHtml(note.read_at ? 'Seen' : 'New') + '</span></div>').join('')
      : '<div class="mini-meta-row"><span class="mini-meta-label">Updates</span><span class="mini-meta-value">No new notifications</span></div>';
    if (document.getElementById('customer-notifications-list')) {
      document.getElementById('customer-notifications-list').innerHTML = markup;
    }
  }

  function renderWalletAndReferral(walletSummary, referralSummary) {
    const wallet = walletSummary && walletSummary.wallet ? walletSummary.wallet : Store.getCurrentWallet();
    const completedReferrals = referralSummary && referralSummary.referrals
      ? referralSummary.referrals.filter((referral) => referral.status === 'rewarded').length
      : 0;
    const rows = [
      ['Wallet credit', Store.formatCurrency(wallet && wallet.balance ? wallet.balance : 0)],
      ['Referral code', (Store.getCurrentProfile() && Store.getCurrentProfile().referral_code) || '--'],
      ['Completed referrals', String(completedReferrals)]
    ].map(renderMiniMetaRow).join('');
    if (document.getElementById('wallet-referral-summary')) {
      document.getElementById('wallet-referral-summary').innerHTML = rows;
    }
    if (document.getElementById('history-wallet-referral')) {
      document.getElementById('history-wallet-referral').innerHTML = rows;
    }
  }

  async function submitDispute() {
    await withButtonLoading('btn-submit-dispute', 'Submitting...', async () => {
      if (!currentJob) throw new Error('Open a job before reporting an issue.');
      const issueType = document.getElementById('dispute-type').value;
      if (!issueType) throw new Error('Select the issue you want to report.');
      await Store.createDispute(currentJob.id, issueType, document.getElementById('dispute-details').value.trim());
      document.getElementById('dispute-type').value = '';
      document.getElementById('dispute-details').value = '';
      await openTrackedJob(currentJob.id);
      goTo('assigned');
    });
  }

  function renderKeyValueRow(row) {
    return '<div class="transparency-row"><span class="transparency-label">' + escapeHtml(row[0]) + '</span><span class="transparency-value">' + escapeHtml(String(row[1] || '')) + '</span></div>';
  }

  function renderMiniMetaRow(row) {
    return '<div class="mini-meta-row"><span class="mini-meta-label">' + escapeHtml(row[0]) + '</span><span class="mini-meta-value">' + escapeHtml(String(row[1] || '')) + '</span></div>';
  }

  function formatUrgencyLabel(value) {
    if (value === 'emergency') return 'Emergency';
    if (value === 'scheduled' || value === 'this-week') return 'Scheduled';
    return 'Today';
  }

  function humanizeIssueCategory(value) {
    const match = getIssueOption(value);
    return match ? match.issue_type : value;
  }

  function getIssueOption(value, label) {
    return getIssueOptions().find((issue) => issue.value === value && (!label || issue.issue_type === label)) ||
      getIssueOptions().find((issue) => issue.value === value || issue.issue_type === value || issue.key === value);
  }

  function getIssueEstimate(value, label) {
    const match = getIssueOption(value, label);
    return match ? formatIssueFee(match) : 'Quote after review';
  }

  function getIssueOptions() {
    const invoiceItems = ((Store.getSettings && Store.getSettings().workmanship_prices) || [])
      .map(normalizeInvoiceIssue)
      .filter(Boolean);
    const usedInvoiceIndexes = new Set();
    return ISSUE_OPTIONS.map((issue) => {
      const invoiceIndex = invoiceItems.findIndex((item, index) => !usedInvoiceIndexes.has(index) && issueMatchesInvoice(issue, item));
      if (invoiceIndex === -1) return normalizeIssue(issue);
      usedInvoiceIndexes.add(invoiceIndex);
      const invoice = invoiceItems[invoiceIndex];
      return normalizeIssue({
        ...issue,
        description: invoice.description || issue.description,
        estimated_fee_min: invoice.estimated_fee_min,
        estimated_fee_max: invoice.estimated_fee_max
      });
    });
  }

  function normalizeIssue(issue) {
    return {
      ...issue,
      key: slugifyIssue(issue.issue_type + '-' + issue.value),
      issue_type: issue.issue_type || 'Other',
      description: issue.description || '',
      estimated_fee_min: parseFeeValue(issue.estimated_fee_min),
      estimated_fee_max: parseFeeValue(issue.estimated_fee_max)
    };
  }

  function normalizeInvoiceIssue(item) {
    if (!item || typeof item !== 'object') return null;
    const issueType = item.issue_type || item.description || item.service || item.name;
    if (!issueType) return null;
    const min = item.estimated_fee_min ?? item.rate ?? item.amount ?? item.price ?? null;
    const max = item.estimated_fee_max ?? item.max_rate ?? item.max_amount ?? item.price_max ?? null;
    return {
      issue_type: String(issueType),
      description: item.short_description || item.note || item.details || '',
      estimated_fee_min: parseFeeValue(min),
      estimated_fee_max: parseFeeValue(max)
    };
  }

  function issueMatchesInvoice(issue, invoice) {
    const issueText = slugifyIssue(issue.issue_type + ' ' + issue.value);
    const invoiceText = slugifyIssue(invoice.issue_type);
    return issueText.indexOf(invoiceText) !== -1 || invoiceText.indexOf(issueText) !== -1 ||
      keywordMatch(issueText, invoiceText);
  }

  function keywordMatch(left, right) {
    return ['socket', 'light', 'wiring', 'wire', 'breaker', 'fuse', 'inverter', 'solar', 'generator', 'inspection']
      .some((word) => left.indexOf(word) !== -1 && right.indexOf(word) !== -1);
  }

  function inferSkillCategory(issueType) {
    const text = slugifyIssue(issueType);
    if (text.indexOf('socket') !== -1 || text.indexOf('switch') !== -1) return 'Socket repair';
    if (text.indexOf('light') !== -1) return 'Light fitting';
    if (text.indexOf('wire') !== -1 || text.indexOf('wiring') !== -1) return 'Wiring issue';
    if (text.indexOf('breaker') !== -1 || text.indexOf('fuse') !== -1) return 'Tripped breaker';
    if (text.indexOf('solar') !== -1 || text.indexOf('inverter') !== -1) return 'Inverter';
    if (text.indexOf('generator') !== -1) return 'Generator';
    if (text.indexOf('inspection') !== -1 || text.indexOf('diagnose') !== -1) return 'General Installation';
    return 'Other';
  }

  function formatIssueFee(issue) {
    const min = Number(issue.estimated_fee_min || 0);
    const max = Number(issue.estimated_fee_max || 0);
    if (min && max && max !== min) return Store.formatCurrency(min) + ' - ' + Store.formatCurrency(max);
    if (min && max && max === min) return Store.formatCurrency(min);
    if (min) return Store.formatCurrency(min) + '+';
    return 'Quote after review';
  }

  function parseFeeValue(value) {
    if (value == null || value === '') return null;
    if (typeof value === 'number') return Number.isFinite(value) ? value : null;
    const cleaned = String(value).replace(/[^0-9.]/g, '');
    if (!cleaned) return null;
    const parsed = Number(cleaned);
    return Number.isFinite(parsed) ? parsed : null;
  }

  function slugifyIssue(value) {
    return String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  }

  function calculateDistanceLabel(job, electrician) {
    if (!job || !electrician) return '--';
    if (typeof job.latitude !== 'number' || typeof job.longitude !== 'number' || typeof electrician.latitude !== 'number' || typeof electrician.longitude !== 'number') {
      return electrician.locationLabel || 'Nearby';
    }
    const toRadians = (value) => (value * Math.PI) / 180;
    const earthRadiusKm = 6371;
    const dLat = toRadians(electrician.latitude - job.latitude);
    const dLng = toRadians(electrician.longitude - job.longitude);
    const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(toRadians(job.latitude)) * Math.cos(toRadians(electrician.latitude)) *
      Math.sin(dLng / 2) * Math.sin(dLng / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return (earthRadiusKm * c).toFixed(1);
  }

  function normalizePhoneInput(value) {
    return String(value || '').replace(/[^\d+]/g, '').trim();
  }

  function isValidPhone(value) {
    const normalized = normalizePhoneInput(value);
    return normalized.replace(/\D/g, '').length >= 10;
  }

  function on(id, event, handler) {
    const element = document.getElementById(id);
    if (element) element.addEventListener(event, handler);
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
      showError(error);
      return null;
    } finally {
      if (button) {
        button.textContent = originalText;
        button.disabled = wasDisabled;
      }
    }
  }

  function setScreenBusy(nextBusy, message) {
    screenBusy = nextBusy;
    if (!nextBusy) return;
    clearError();
    const authError = document.getElementById('auth-error');
    authError.style.display = 'block';
    authError.textContent = message || 'Loading...';
  }

  function clearError() {
    if (screenBusy) screenBusy = false;
    const authError = document.getElementById('auth-error');
    authError.style.display = 'none';
    authError.textContent = '';
  }

  function showError(error) {
    const message = error && error.message ? error.message : 'Something went wrong.';
    const authError = document.getElementById('auth-error');
    authError.style.display = 'block';
    authError.textContent = message;
  }

  function escapeHtml(value) {
    return String(value || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }
})();
