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
  let addressMode = 'gps';
  let authScreenIntent = 'default';
  let pendingCustomerRoute = null;
  let currentTrackedTicket = null;
  let pendingCustomerSignup = null;
  let trackingDetailsExpanded = false;

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
    country: 'Nigeria',
    state: '',
    city: '',
    streetAddress: '',
    landmark: '',
    latitude: null,
    longitude: null,
    addressSource: '',
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

  const CUSTOMER_DRAFT_KEY = 'voltfriq_customer_draft_v1';
  const DEFAULT_COUNTRY = 'Nigeria';
  const SUPPORTED_STATES = ['Rivers', 'Imo'];
  const CITY_OPTIONS = {
    Rivers: ['Port Harcourt', 'Obio-Akpor', 'Eleme', 'Oyigbo', 'Ikwerre'],
    Imo: ['Owerri Municipal', 'Owerri North', 'Owerri West', 'Orlu', 'Okigwe']
  };

  function wantsPasswordReset() {
    const query = new URLSearchParams(window.location.search || '');
    const hash = new URLSearchParams(String(window.location.hash || '').replace(/^#/, ''));
    return query.get('reset') === '1' || hash.get('type') === 'recovery';
  }

  function hasSignupAuthCallback() {
    const query = new URLSearchParams(window.location.search || '');
    const hash = new URLSearchParams(String(window.location.hash || '').replace(/^#/, ''));
    return query.get('verify') === 'signup' || hash.get('type') === 'signup' || hash.has('access_token');
  }

  const CUSTOMER_ROUTE_TITLES = {
    welcome: 'VoltFriq | Port Harcourt Electricians',
    'service-area': 'VoltFriq | Book | Location',
    problem: 'VoltFriq | Book | Issue',
    details: 'VoltFriq | Book | Details',
    'customer-auth': 'VoltFriq | Customer Access',
    match: 'VoltFriq | Review Booking',
    'appearance-fee': 'VoltFriq | Assessment Fee',
    assigned: 'VoltFriq | Job Tracking',
    quotation: 'VoltFriq | Quote Review',
    payment: 'VoltFriq | Payment Setup',
    'confirm-work': 'VoltFriq | Confirm Completion',
    rating: 'VoltFriq | Rate Your VoltFriq',
    done: 'VoltFriq | Job Complete',
    dashboard: 'VoltFriq | Dashboard',
    history: 'VoltFriq | Dashboard | History',
    'report-issue': 'VoltFriq | Report an Issue',
    prices: 'VoltFriq | Pricing Guide',
    chat: 'VoltFriq | Job Chat'
  };

  document.addEventListener('DOMContentLoaded', init);

  async function init() {
    configureCustomerRoutes();
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
      hydrateDraftState();
      renderSettings();
      refreshWelcomeActions();
      pendingCustomerRoute = getCurrentRouteState();
      await applyInitialCustomerRoute(pendingCustomerRoute);
    } catch (error) {
      showError(error);
    }
  }

  function bindEvents() {
    on('btn-begin-area', 'click', startBooking);
    on('btn-begin-area-nav', 'click', startBooking);
    on('btn-begin-area-mobile', 'click', startBooking);
    on('btn-welcome-signup', 'click', () => openCustomerAuthScreen('dashboard', 'register'));
    on('btn-mobile-signup-inline', 'click', () => openCustomerAuthScreen('dashboard', 'register'));
    on('btn-mobile-signup', 'click', () => {
      closeMobileMenu();
      openCustomerAuthScreen('dashboard', 'register');
    });
    on('btn-open-dashboard', 'click', openDashboard);
    on('btn-open-dashboard-hero', 'click', openDashboard);
    on('btn-mobile-dashboard-inline', 'click', openDashboard);
    on('btn-mobile-dashboard', 'click', async () => {
      closeMobileMenu();
      await openDashboard();
    });
    on('btn-dashboard-new-booking', 'click', startBooking);
    on('btn-dashboard-history', 'click', () => showHistory(true));
    on('btn-dashboard-signout', 'click', handleCustomerSignOut);
    on('btn-dashboard-track', 'click', async () => {
      if (currentJob) {
        await openTrackedJob(currentJob.id);
        return;
      }
      await resumeLatestJob();
    });
    on('btn-view-prices', 'click', () => {
      renderPriceList();
      goTo('prices');
    });
    on('btn-prices-back', 'click', goBack);
    on('btn-prices-find', 'click', startBooking);

    on('btn-welcome-login', 'click', handleWelcomeLogin);
    on('btn-mobile-login-inline', 'click', handleWelcomeLogin);
    on('btn-mobile-login', 'click', handleWelcomeLogin);
    on('btn-track-job', 'click', handleTrackJobEntry);
    on('btn-mobile-track-inline', 'click', handleTrackJobEntry);
    on('btn-mobile-track', 'click', handleTrackJobEntry);
    on('btn-mobile-menu', 'click', () => toggleMobileMenu(true));
    on('btn-mobile-menu-close', 'click', closeMobileMenu);
    on('mobile-menu-backdrop', 'click', (event) => {
      if (event.target && event.target.id === 'mobile-menu-backdrop') {
        closeMobileMenu();
      }
    });
    document.querySelectorAll('[data-mobile-anchor]').forEach((link) => {
      link.addEventListener('click', closeMobileMenu);
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        closeMobileMenu();
      }
    });

    on('service-area-select', 'change', () => {
      syncManualAddressDraft();
      updateAvailabilityCard();
    });
    on('manual-country', 'change', () => {
      syncManualAddressDraft();
      updateAvailabilityCard();
    });
    on('manual-state', 'change', () => {
      renderManualCityOptions();
      syncManualAddressDraft();
      updateAvailabilityCard();
    });
    on('manual-city', 'change', () => {
      syncManualAddressDraft();
      updateAvailabilityCard();
    });
    on('manual-street-address', 'input', () => {
      syncManualAddressDraft();
      updateAvailabilityCard();
    });
    on('manual-landmark', 'input', () => {
      syncManualAddressDraft();
      updateAvailabilityCard();
    });
    const addressTabs = document.getElementById('address-mode-tabs');
    if (addressTabs) {
      addressTabs.addEventListener('click', (event) => {
        const button = event.target.closest('[data-address-mode]');
        if (!button) return;
        setAddressMode(button.dataset.addressMode);
      });
    }
    on('btn-area-continue', 'click', () => {
      if (addressMode === 'manual') syncManualAddressDraft();
      if (!hasDraftLocation()) {
        showError('Enter country, state, city, and street address before continuing, or use GPS.');
        return;
      }
      goTo('problem');
    });

    bindIssueSelect();
    on('problem-desc', 'input', () => {
      draft.note = document.getElementById('problem-desc').value.trim();
      document.getElementById('desc-count').textContent = draft.note.length;
      persistDraftState();
    });

    const urgencySelector = document.getElementById('urgency-selector');
    if (urgencySelector) {
      urgencySelector.addEventListener('click', (event) => {
        const chip = event.target.closest('.urgency-chip');
        if (!chip) return;
        urgencySelector.querySelectorAll('.urgency-chip').forEach((item) => item.classList.remove('active'));
        chip.classList.add('active');
        draft.urgency = chip.dataset.urgency;
        persistDraftState();
      });
    }

    on('photo-add-btn', 'click', () => document.getElementById('photo-input').click());
    on('photo-input', 'change', handlePhotoSelect);
    on('btn-review-match', 'click', () => {
      if (!draft.issueCategory) {
        showError('Select the issue before continuing.');
        return;
      }
      goTo('details');
    });
    on('btn-details-review', 'click', handleDetailsContinue);
    on('review-phone', 'input', () => {
      draft.guestPhone = normalizePhoneInput(document.getElementById('review-phone').value);
      persistDraftState();
      updateReviewContactState();
      renderMatchTransparency();
    });
    on('btn-guest-create-account', 'click', () => openCustomerAuthScreen('claim-guest', 'register'));

    on('tab-login', 'click', () => setAuthMode('login'));
    on('tab-register', 'click', () => setAuthMode('register'));
    on('btn-auth-forgot', 'click', handleCustomerPasswordResetRequest);
    on('btn-auth-resend', 'click', handleCustomerSignupResend);
    on('btn-auth-submit', 'click', handleAuthSubmit);

    on('btn-continue-match', 'click', continueFromMatch);
    on('btn-close-sheet', 'click', closeSpecialistSheet);
    on('btn-select-specialist', 'click', applySpecialistSelection);

    on('btn-fee-paid', 'click', () => submitCurrentPayment('assessment_fee'));
    on('fee-copy-btn', 'click', () => copyText('fee-account-number', 'fee-copy-btn'));
    on('pay-copy-btn', 'click', () => copyText('pay-account-number', 'pay-copy-btn'));

    on('btn-open-chat', 'click', openChat);
    on('btn-assigned-support', 'click', handleTrackingSupport);
    on('btn-assigned-back', 'click', goBack);
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
    const trackingDetails = document.getElementById('tracking-details');
    if (trackingDetails) {
      trackingDetails.addEventListener('click', (event) => {
        const contact = event.target.closest('#btn-tracking-contact');
        if (contact) {
          handleTrackingSupport();
          return;
        }
        const copy = event.target.closest('[data-copy-ticket]');
        if (copy) copyTrackingTicket(copy);
        const toggle = event.target.closest('#btn-toggle-tracking-details');
        if (toggle) {
          trackingDetailsExpanded = !trackingDetailsExpanded;
          renderTrackingDetails(currentJob);
        }
      });
    }
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

  async function handleWelcomeLogin() {
    closeMobileMenu();
    if (Store.getCurrentProfile()) {
      await openDashboard();
      return;
    }
    openCustomerAuthScreen('dashboard', 'login');
  }

  async function handleTrackJobEntry() {
    closeMobileMenu();
    if (currentJob) {
      await openTrackedJob(currentJob.id);
      return;
    }
    if (Store.getGuestAccess()) {
      await resumeLatestJob();
      return;
    }
    if (Store.getCurrentProfile()) {
      await openDashboard();
      return;
    }
    openCustomerAuthScreen('tracking', 'login');
  }

  function toggleMobileMenu(forceOpen) {
    const backdrop = document.getElementById('mobile-menu-backdrop');
    const toggle = document.getElementById('btn-mobile-menu');
    if (!backdrop || !toggle) return;
    const shouldOpen = typeof forceOpen === 'boolean' ? forceOpen : backdrop.hidden;
    backdrop.hidden = !shouldOpen;
    toggle.setAttribute('aria-expanded', shouldOpen ? 'true' : 'false');
    document.body.classList.toggle('mobile-menu-open', shouldOpen);
  }

  function closeMobileMenu() {
    toggleMobileMenu(false);
  }

  function configureCustomerRoutes() {
    configureRoutes({
      defaultScreen: 'welcome',
      pathParser: parseCustomerRoute,
      pathResolver: resolveCustomerPath,
      titleResolver: resolveCustomerTitle,
      onRouteActivated: async (route) => {
        await handleCustomerRouteActivation(route);
      }
    });
  }

  function parseCustomerRoute(pathname) {
    const path = normalizePath(pathname);
    if (path === '/' || path === '/index.html') return { screen: 'welcome' };
    if (path === '/login') return { screen: 'customer-auth', data: { mode: 'login', intent: 'dashboard' } };
    if (path === '/signup') return { screen: 'customer-auth', data: { mode: 'register', intent: 'dashboard' } };
    if (path === '/dashboard') return { screen: 'dashboard' };
    if (path === '/dashboard/history') return { screen: 'history' };
    if (path === '/track') return { screen: 'assigned' };
    if (path.indexOf('/track/') === 0) return { screen: 'assigned', data: { ticket: decodeURIComponent(path.split('/').pop() || '') } };
    if (path.indexOf('/book/') === 0) {
      const step = path.split('/')[2] || 'location';
      const map = {
        location: 'service-area',
        issue: 'problem',
        urgency: 'details',
        details: 'details',
        contact: 'match',
        review: 'match'
      };
      return { screen: map[step] || 'service-area' };
    }
    if (path === '/pricing') return { screen: 'prices' };
    if (path === '/report-issue') return { screen: 'report-issue' };
    return { screen: 'welcome' };
  }

  function resolveCustomerPath(screen, routeData) {
    if (screen === 'welcome') return '/';
    if (screen === 'service-area') return '/book/location';
    if (screen === 'problem') return '/book/issue';
    if (screen === 'details') return '/book/details';
    if (screen === 'customer-auth') return authMode === 'register' ? '/signup' : '/login';
    if (screen === 'match') return '/book/review';
    if (screen === 'dashboard') return '/dashboard';
    if (screen === 'history') return '/dashboard/history';
    if (screen === 'assigned') {
      const ticket = routeData && routeData.ticket ? routeData.ticket : currentTrackedTicket;
      return ticket ? '/track/' + encodeURIComponent(ticket) : '/track';
    }
    if (screen === 'prices') return '/pricing';
    if (screen === 'report-issue') return '/report-issue';
    return null;
  }

  function resolveCustomerTitle(screen, routeData) {
    if (screen === 'assigned') {
      const ticket = routeData && routeData.ticket ? routeData.ticket : currentTrackedTicket;
      return ticket ? 'VoltFriq | Track ' + ticket : CUSTOMER_ROUTE_TITLES.assigned;
    }
    if (screen === 'customer-auth' && authMode === 'register') {
      return 'VoltFriq | Create Account';
    }
    return CUSTOMER_ROUTE_TITLES[screen] || 'VoltFriq | Customer Portal';
  }

  async function applyInitialCustomerRoute(route) {
    const target = route && route.screen ? route : { screen: 'welcome', data: null };
    await handleCustomerRouteActivation({
      screen: target.screen,
      data: target.data || null,
      source: 'initial'
    });
  }

  async function handleCustomerRouteActivation(route) {
    if (!route || !route.screen) return;

    if (route.screen === 'welcome') {
      goTo('welcome', { replace: route.source !== 'popstate', routeData: route.data || null });
      focusCustomerScreen('welcome');
      return;
    }

    if (route.screen === 'customer-auth') {
      if (Store.getCurrentProfile() && !wantsPasswordReset() && hasSignupAuthCallback()) {
        await continueAfterCustomerAuth();
        return;
      }
      openCustomerAuthScreen((route.data && route.data.intent) || 'default', (route.data && route.data.mode) || 'login', { replace: route.source !== 'popstate' });
      return;
    }

    if (route.screen === 'dashboard') {
      await openDashboard({ replace: route.source !== 'popstate' });
      return;
    }

    if (route.screen === 'history') {
      await showHistory(true, { replace: route.source !== 'popstate' });
      return;
    }

    if (route.screen === 'assigned') {
      if (route.data && route.data.ticket) {
        const job = await openTrackedJobByTicket(route.data.ticket, { replace: route.source !== 'popstate' });
        if (job) return;
      }
      await resumeLatestJob({ replace: route.source !== 'popstate', preferTracking: true });
      return;
    }

    if (route.screen === 'prices') {
      renderPriceList();
      goTo('prices', { replace: route.source !== 'popstate' });
      return;
    }

    if (route.screen === 'report-issue') {
      if (!currentJob) {
        await resumeLatestJob({ replace: true, preferTracking: true });
      }
      if (currentJob) {
        goTo('report-issue', { replace: route.source !== 'popstate' });
      }
      return;
    }

    await openBookingRoute(route.screen, { replace: route.source !== 'popstate' });
  }

  async function openBookingRoute(targetScreen, options) {
    hydrateDraftState();
    await loadSavedAddresses();

    if (!hasDraftLocation()) {
      goTo('service-area', { replace: options && options.replace });
      focusCustomerScreen('service-area');
      if (targetScreen !== 'service-area') {
        persistDraftState();
      }
      return;
    }

    if (targetScreen === 'service-area') {
      goTo('service-area', { replace: options && options.replace });
      focusCustomerScreen('service-area');
      return;
    }

    if (!draft.issueCategory) {
      goTo('problem', { replace: options && options.replace });
      focusCustomerScreen('problem');
      return;
    }

    if (targetScreen === 'problem') {
      goTo('problem', { replace: options && options.replace });
      focusCustomerScreen('problem');
      return;
    }

    if (targetScreen === 'details') {
      goTo('details', { replace: options && options.replace });
      focusCustomerScreen('details');
      return;
    }

    if (targetScreen === 'match') {
      renderMatch();
      goTo('match', { replace: options && options.replace });
      focusCustomerScreen('match');
      return;
    }
  }

  function normalizePath(pathname) {
    const raw = String(pathname || '/').trim();
    if (!raw) return '/';
    const cleaned = raw.replace(/\/+$/, '');
    return cleaned || '/';
  }

  function showConfigurationMessage() {
    document.getElementById('availability-meta').textContent = 'Add your Supabase URL and anon key in js/config.js to enable live booking.';
    document.getElementById('auth-error').style.display = 'block';
    document.getElementById('auth-error').textContent = 'Supabase is not configured yet.';
  }

  function renderSettings() {
    const areas = getConfiguredServiceAreas();
    renderManualAddressControls();
    const serviceAreaSelect = document.getElementById('service-area-select');
    if (serviceAreaSelect) {
      serviceAreaSelect.innerHTML = '<option value="">Select a service area</option>' +
        areas.map((area) => '<option value="' + escapeAttribute(area) + '">' + escapeHtml(area) + '</option>').join('');
      if (draft.serviceArea) syncServiceAreaSelect(draft.serviceArea);
    }
    renderLocationDatalist(areas);

    renderIssueSelect();
  }

  function getConfiguredServiceAreas() {
    if (Store.getServiceAreas) return Store.getServiceAreas();
    const settings = Store.getSettings();
    return Array.isArray(settings.service_areas) ? settings.service_areas.filter(Boolean) : [];
  }

  function renderLocationDatalist(areas) {
    let datalist = document.getElementById('service-area-options');
    if (!datalist) {
      datalist = document.createElement('datalist');
      datalist.id = 'service-area-options';
      document.body.appendChild(datalist);
    }
    datalist.innerHTML = (areas || []).map((area) => '<option value="' + escapeAttribute(area) + '"></option>').join('');
  }

  function renderManualAddressControls() {
    renderSelectOptions('manual-country', [DEFAULT_COUNTRY], draft.country || DEFAULT_COUNTRY, 'Select country');
    renderSelectOptions('manual-state', SUPPORTED_STATES, draft.state, 'Select state');
    renderManualCityOptions();
    setInputValue('manual-street-address', draft.streetAddress);
    setInputValue('manual-landmark', draft.landmark);
  }

  function renderManualCityOptions() {
    const state = getElementValue('manual-state') || draft.state;
    const cities = CITY_OPTIONS[state] || [];
    if (draft.city && !cities.some((city) => city.toLowerCase() === draft.city.toLowerCase())) {
      draft.city = '';
    }
    renderSelectOptions('manual-city', cities, draft.city, 'Select city or LGA');
  }

  function renderSelectOptions(id, options, currentValue, placeholder) {
    const select = document.getElementById(id);
    if (!select) return;
    const cleanValue = String(currentValue || '').trim();
    select.innerHTML = '<option value="">' + escapeHtml(placeholder || 'Select') + '</option>' +
      (options || []).map((option) => '<option value="' + escapeAttribute(option) + '">' + escapeHtml(option) + '</option>').join('');
    if (cleanValue && (options || []).some((option) => option.toLowerCase() === cleanValue.toLowerCase())) {
      const match = (options || []).find((option) => option.toLowerCase() === cleanValue.toLowerCase());
      select.value = match;
    } else if (id === 'manual-country' && !cleanValue) {
      select.value = DEFAULT_COUNTRY;
    }
  }

  function setInputValue(id, value) {
    const input = document.getElementById(id);
    if (input && document.activeElement !== input) input.value = value || '';
  }

  function getElementValue(id) {
    const element = document.getElementById(id);
    return element ? String(element.value || '').trim() : '';
  }

  function syncServiceAreaSelect(value) {
    const select = document.getElementById('service-area-select');
    const cleanValue = String(value || '').trim();
    if (!select || !cleanValue) return;
    const hasOption = Array.from(select.options).some((option) => option.value.toLowerCase() === cleanValue.toLowerCase());
    if (!hasOption) {
      const option = document.createElement('option');
      option.value = cleanValue;
      option.textContent = cleanValue;
      select.appendChild(option);
    }
    select.value = cleanValue;
  }

  async function startBooking() {
    closeMobileMenu();
    resetDraft();
    goTo('service-area');
    focusCustomerScreen('service-area');
    setAddressMode('gps', { autoStarted: true });
  }

  function setAddressMode(mode, options) {
    addressMode = mode === 'manual' ? 'manual' : 'gps';
    document.querySelectorAll('#address-mode-tabs [data-address-mode]').forEach((button) => {
      button.classList.toggle('active', button.dataset.addressMode === addressMode);
    });

    togglePanel('manual-location-sheet', addressMode === 'manual');

    if (addressMode === 'gps' && !draft.latitude && !draft.longitude) {
      useCurrentLocation(!!(options && options.autoStarted));
    }
    if (addressMode === 'manual') {
      if (!draft.country) draft.country = DEFAULT_COUNTRY;
      renderManualAddressControls();
      syncManualAddressDraft();
      window.setTimeout(() => {
        const input = document.getElementById('manual-street-address');
        if (input) input.focus();
      }, 80);
    }
  }

  function togglePanel(id, visible) {
    const panel = document.getElementById(id);
    if (panel) panel.style.display = visible ? '' : 'none';
  }

  function applyAddressSelection(address, source) {
    const normalized = Store.selectDraftAddress ? Store.selectDraftAddress(address) : address;
    const label = normalized.locationLabel || normalized.addressText || normalized.label || '';
    draft.locationLabel = label;
    draft.serviceArea = label;
    draft.latitude = normalized.latitude == null ? null : Number(normalized.latitude);
    draft.longitude = normalized.longitude == null ? null : Number(normalized.longitude);
    draft.addressSource = source || normalized.source || 'gps';
    syncServiceAreaSelect(label);
    const detectedText = document.getElementById('detected-location-text');
    if (detectedText && source === 'gps') {
      detectedText.textContent = label;
    }
    persistDraftState();
    updateAvailabilityCard();
  }

  function syncManualAddressDraft() {
    const country = getElementValue('manual-country') || DEFAULT_COUNTRY;
    const state = getElementValue('manual-state');
    const city = getElementValue('manual-city');
    const streetAddress = getElementValue('manual-street-address');
    const landmark = getElementValue('manual-landmark');
    const closestServiceArea = getElementValue('service-area-select');

    draft.country = country;
    draft.state = state;
    draft.city = city;
    draft.streetAddress = streetAddress;
    draft.landmark = landmark;

    const hasManualInput = Boolean(country || state || city || streetAddress || landmark || closestServiceArea);
    if (hasManualInput) {
      draft.addressSource = 'manual';
    }

    if (streetAddress) {
      draft.latitude = null;
      draft.longitude = null;
    }

    const manualLabel = composeManualLocationLabel();
    if (manualLabel) {
      draft.locationLabel = manualLabel;
    } else if (draft.addressSource === 'manual') {
      draft.locationLabel = '';
    }
    const inferredServiceArea = Store.inferServiceAreaFromAddress
      ? Store.inferServiceAreaFromAddress({
          serviceArea: closestServiceArea,
          locationLabel: manualLabel,
          streetAddress,
          landmark,
          city,
          state,
          country
        })
      : '';
    draft.serviceArea = closestServiceArea || inferredServiceArea || manualServiceAreaFallback();
    if (!closestServiceArea && inferredServiceArea) {
      syncServiceAreaSelect(inferredServiceArea);
    }
    updateManualLocationSummary();
    persistDraftState();
  }

  function composeManualLocationLabel() {
    if (!draft.streetAddress) return '';
    return [draft.streetAddress, draft.landmark, draft.city, draft.state, draft.country]
      .map((part) => String(part || '').trim())
      .filter(Boolean)
      .join(', ');
  }

  function manualServiceAreaFallback() {
    return [draft.city, draft.state].filter(Boolean).join(', ') || draft.locationLabel || '';
  }

  function hasManualAddress() {
    return Boolean(draft.country && draft.state && draft.city && draft.streetAddress);
  }

  function updateManualLocationSummary() {
    const summary = document.getElementById('manual-location-summary');
    if (!summary) return;
    summary.textContent = hasManualAddress()
      ? composeManualLocationLabel()
      : 'Country, state, city, and street address';
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
      document.getElementById('location-helper-note').textContent = 'GPS is not available on this device. Enter your address to continue.';
      return;
    }

    const detectedText = document.getElementById('detected-location-text');
    if (detectedText) detectedText.textContent = 'Finding your location...';
    document.getElementById('location-helper-note').textContent = 'Allow location access so VoltFriq can route the nearest available electrician.';

    navigator.geolocation.getCurrentPosition(async (position) => {
      const latitude = position.coords.latitude;
      const longitude = position.coords.longitude;
      const readableLocation = await reverseGeocode(latitude, longitude);
      const fallbackLabel = 'GPS location (' + latitude.toFixed(4) + ', ' + longitude.toFixed(4) + ')';
      applyAddressSelection({
        label: 'Current location',
        addressText: readableLocation || fallbackLabel,
        locationLabel: readableLocation || fallbackLabel,
        latitude,
        longitude
      }, 'gps');
      if (detectedText) detectedText.textContent = draft.locationLabel;
      document.getElementById('location-helper-note').textContent = 'Confirm this location or edit the area before continuing.';
    }, () => {
      if (detectedText) detectedText.textContent = 'Location access was blocked.';
      document.getElementById('location-helper-note').textContent = 'Enter your address to continue without GPS.';
      setAddressMode('manual');
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
    persistDraftState();
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
        persistDraftState();
      });
    });
  }

  function updateAvailabilityCard() {
    if (addressMode === 'manual' || draft.addressSource === 'manual') {
      syncManualAddressDraft();
    }
    const bookingLocation = getFinalBookingLocation();
    const hasLocation = Boolean(bookingLocation.locationLabel);
    document.getElementById('availability-count').textContent = hasLocation ? 'Ready' : 'Waiting';
    document.getElementById('availability-meta').textContent = hasLocation
      ? 'Location saved. You can continue without GPS.'
      : 'Enter your street address or use current location.';
    document.getElementById('btn-area-continue').disabled = !hasLocation;
    persistDraftState();
  }

  function getFinalBookingLocation() {
    if (draft.addressSource === 'manual' || addressMode === 'manual') {
      syncManualAddressDraft();
    }
    const locationLabel = String(draft.locationLabel || composeManualLocationLabel() || '').trim();
    const inferredServiceArea = Store.inferServiceAreaFromAddress
      ? Store.inferServiceAreaFromAddress({
          serviceArea: draft.serviceArea,
          locationLabel,
          streetAddress: draft.streetAddress,
          landmark: draft.landmark,
          city: draft.city,
          state: draft.state,
          country: draft.country
        })
      : '';
    const serviceArea = String(draft.serviceArea || inferredServiceArea || manualServiceAreaFallback() || locationLabel).trim();
    return {
      locationLabel,
      serviceArea,
      latitude: draft.latitude == null ? null : draft.latitude,
      longitude: draft.longitude == null ? null : draft.longitude
    };
  }

  function hasDraftLocation() {
    return Boolean(getFinalBookingLocation().locationLabel);
  }

  function syncProblemSummary() {
    const areaLabel = document.getElementById('problem-area-label');
    const availabilityPill = document.getElementById('problem-availability-pill');
    const bookingLocation = getFinalBookingLocation();
    if (areaLabel) areaLabel.textContent = bookingLocation.locationLabel || bookingLocation.serviceArea || '--';
    if (availabilityPill) availabilityPill.textContent = bookingLocation.locationLabel ? 'Ready to book' : 'No area';
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
      persistDraftState();
      return;
    }
    draft.issueCategory = issue.value;
    draft.issueLabel = issue.issue_type;
    draft.issueKey = issue.key;
    document.getElementById('problem-category').value = issue.key;
    renderIssueEstimate();
    updateReviewButton();
    persistDraftState();
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
    if (!hasDraftLocation()) {
      showError('Choose a location before continuing.');
      goTo('service-area');
      return;
    }
    if (!draft.issueCategory) {
      showError('Select the issue before continuing.');
      goTo('problem');
      return;
    }
    previewMatch('btn-details-review');
  }

  function renderReviewContact() {
    const profile = Store.getCurrentProfile();
    const card = document.getElementById('review-contact-card');
    const phoneGroup = document.getElementById('review-phone-group');
    const phoneInput = document.getElementById('review-phone');
    if (!card) return;

    if (profile && profile.phone && !draft.guestPhone) {
      draft.guestPhone = normalizePhoneInput(profile.phone);
    }

    const needsPhone = !profile || !isValidPhone(profile.phone);
    card.style.display = needsPhone ? '' : 'none';
    if (phoneGroup) phoneGroup.style.display = needsPhone ? '' : 'none';
    if (!needsPhone) {
      updateReviewContactState();
      return;
    }

    if (phoneInput && document.activeElement !== phoneInput) {
      phoneInput.value = draft.guestPhone || '';
    }
    updateReviewContactState();
  }

  function updateReviewContactState() {
    const button = document.getElementById('btn-continue-match');
    const note = document.getElementById('review-contact-note');
    const profile = Store.getCurrentProfile();
    const needsPhone = !profile || !isValidPhone(profile.phone);
    if (!needsPhone) {
      if (button) button.disabled = false;
      if (note) note.style.display = 'none';
      renderBookingReadinessChecklist();
      return true;
    }

    const phoneValid = isValidPhone(draft.guestPhone);
    const hasGps = Boolean(draft.latitude && draft.longitude);

    if (button) button.disabled = !phoneValid;

    renderBookingReadinessChecklist();
    if (!note) return phoneValid;
    note.style.display = 'block';
    note.classList.remove('is-warning', 'is-success');

    if (!draft.guestPhone) {
      note.textContent = profile
        ? 'Add your mobile number to finish this booking.'
        : hasGps
          ? 'GPS captured successfully. Enter your mobile number to continue.'
          : 'Enter your mobile number to continue. You can still book with your area if GPS is unavailable.';
      return false;
    }

    if (!phoneValid) {
      note.textContent = profile
        ? 'Enter a valid 10+ digit mobile number to finish this booking.'
        : hasGps
          ? 'GPS captured successfully. Enter a valid 10+ digit mobile number to review your booking.'
          : 'Enter a valid 10+ digit mobile number to review your booking.';
      note.classList.add('is-warning');
      return false;
    }

    note.textContent = hasGps
      ? 'GPS captured successfully. Your contact details are ready for review.'
      : 'Your contact details are ready. VoltFriq will use your selected area for routing.';
    note.classList.add('is-success');
    return true;
  }

  function getBookingReadiness() {
    const profile = Store.getCurrentProfile();
    const bookingLocation = getFinalBookingLocation();
    return [
      {
        label: 'Phone',
        ready: Boolean((profile && isValidPhone(profile.phone)) || isValidPhone(draft.guestPhone))
      },
      {
        label: 'Location',
        ready: Boolean(bookingLocation.locationLabel)
      },
      {
        label: 'Issue',
        ready: Boolean(draft.issueCategory)
      },
      {
        label: 'Urgency',
        ready: Boolean(draft.urgency)
      }
    ];
  }

  function renderBookingReadinessChecklist() {
    const list = document.getElementById('booking-readiness-list');
    if (!list) return;
    list.innerHTML = getBookingReadiness().map((item) => {
      return '<div class="booking-readiness-item' + (item.ready ? ' is-ready' : '') + '">' +
        '<span>' + escapeHtml(item.label) + '</span>' +
        '<strong>' + (item.ready ? 'Ready' : 'Missing') + '</strong>' +
      '</div>';
    }).join('');
  }

  async function previewMatch(sourceButtonId) {
    const buttonId = sourceButtonId || 'btn-details-review';
    await withButtonLoading(buttonId, 'Preparing Review...', async () => {
      renderMatch();
      goTo('match');
    });
  }

  function renderMatch() {
    const summary = document.getElementById('match-summary-card');
    const transparency = document.getElementById('transparency-card');
    const submitButton = document.getElementById('btn-continue-match');
    const issueEstimate = getIssueEstimate(draft.issueCategory, draft.issueLabel);
    const urgencyLabel = formatUrgencyLabel(draft.urgency || 'emergency');
    const assessmentValue = Store.formatCurrency(0);
    const bookingLocation = getFinalBookingLocation();

    renderReviewContact();
    if (transparency) transparency.style.display = '';
    if (submitButton) {
      submitButton.innerHTML = '<span class="booking-step-cta-bolt" aria-hidden="true"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M13 2 4 14h6l-1 8 9-12h-6l1-8Z"/></svg></span><span>Submit Booking</span><span class="booking-step-cta-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14"/><path d="m13 5 7 7-7 7"/></svg></span>';
    }

    summary.innerHTML = [
      '<div class="review-summary-list">',
        '<div class="review-summary-row">',
          '<span class="review-summary-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M13 2 4 14h6l-1 8 9-12h-6l1-8Z"/></svg></span>',
          '<div class="review-summary-copy"><strong>' + escapeHtml(draft.issueLabel || draft.issueCategory || 'Issue') + ' <span class="review-summary-dot">•</span> ' + escapeHtml(urgencyLabel) + '</strong></div>',
        '</div>',
        '<div class="review-summary-row">',
          '<span class="review-summary-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"><path d="M12 21s7-4.5 7-10a7 7 0 1 0-14 0c0 5.5 7 10 7 10z"/><circle cx="12" cy="11" r="2.5"/></svg></span>',
          '<div class="review-summary-copy"><strong>' + escapeHtml(bookingLocation.locationLabel || bookingLocation.serviceArea || '--') + '</strong></div>',
        '</div>',
        '<div class="review-summary-row">',
          '<span class="review-summary-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 7h18"/><path d="M6 4h12l2 3v13H4V7l2-3Z"/><path d="M7 11h10"/><path d="M7 15h6"/></svg></span>',
          '<div class="review-summary-copy"><strong>' + escapeHtml(issueEstimate + ' estimate') + '</strong><span>Final price after assessment</span></div>',
        '</div>',
        '<div class="review-summary-row">',
          '<span class="review-summary-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4 2h3a2 2 0 0 1 2 1.7l.5 3a2 2 0 0 1-.6 1.8l-1.3 1.3a16 16 0 0 0 6.4 6.4l1.3-1.3a2 2 0 0 1 1.8-.6l3 .5A2 2 0 0 1 22 16.9Z"/></svg></span>',
          '<div class="review-summary-copy"><strong>' + escapeHtml(getBookingContactLabel()) + '</strong></div>',
        '</div>',
      '</div>',
      '<div class="booking-readiness-list" id="booking-readiness-list"></div>'
    ].join('');
    if (transparency) {
      transparency.innerHTML = '<div class="review-assessment-row"><span class="review-assessment-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M12 8h.01"/><path d="M11 12h1v4h1"/></svg></span><span class="review-assessment-label">Assessment visit: ' + escapeHtml(assessmentValue) + '</span><span class="review-assessment-arrow" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="m6 9 6 6 6-6"/></svg></span></div>';
    }
    renderMatchTransparency();
    updateReviewContactState();
  }

  function renderMatchTransparency() {
    const transparency = document.getElementById('transparency-card');
    if (!transparency) return;
    if (!transparency.innerHTML.trim()) {
      transparency.innerHTML = '<div class="review-assessment-row"><span class="review-assessment-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M12 8h.01"/><path d="M11 12h1v4h1"/></svg></span><span class="review-assessment-label">Assessment visit: ' + escapeHtml(Store.formatCurrency(0)) + '</span><span class="review-assessment-arrow" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="m6 9 6 6 6-6"/></svg></span></div>';
    }
  }

  function getBookingContactLabel() {
    const profile = Store.getCurrentProfile();
    if (profile) return profile.phone || draft.guestPhone || 'Add phone number';
    return draft.guestPhone || '--';
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
      draft.selectedElectricianId = selected.id;
      renderMatchTransparency();
    }
    closeSpecialistSheet();
  }

  function setAuthMode(mode) {
    authMode = mode;
    const isVerify = mode === 'verify';
    document.getElementById('tab-login').classList.toggle('active', mode === 'login');
    document.getElementById('tab-register').classList.toggle('active', mode === 'register');
    document.querySelector('.auth-tabs').style.display = isVerify ? 'none' : '';
    document.getElementById('auth-name-group').style.display = mode === 'register' ? 'block' : 'none';
    document.getElementById('auth-referral-group').style.display = mode === 'register' ? 'block' : 'none';
    document.getElementById('auth-password').closest('.form-group').style.display = isVerify ? 'none' : 'block';
    document.getElementById('auth-token-group').style.display = isVerify ? 'block' : 'none';
    document.getElementById('btn-auth-forgot').style.display = mode === 'login' ? '' : 'none';
    document.getElementById('btn-auth-resend').style.display = isVerify ? '' : 'none';
    document.getElementById('btn-auth-submit').textContent = mode === 'register'
      ? 'Create Account'
      : isVerify
        ? 'Verify Email'
      : mode === 'reset'
        ? 'Update Password'
        : 'Login';
    clearError();
  }

  async function handleAuthSubmit() {
    const email = document.getElementById('auth-contact').value.trim();
    const password = document.getElementById('auth-password').value.trim();
    const name = document.getElementById('auth-name').value.trim();
    const referralCode = document.getElementById('auth-referral-code').value.trim();

    await withButtonLoading('btn-auth-submit', authMode === 'register' ? 'Creating Account...' : authMode === 'verify' ? 'Verifying Email...' : authMode === 'reset' ? 'Updating Password...' : 'Signing In...', async () => {
      if (authMode === 'verify') {
        await verifyCustomerSignupCode();
        return;
      }

      if (authMode === 'reset') {
        if (!password) {
          throw new Error('Enter your new password to finish the reset.');
        }
        await Store.updatePassword(password);
        setAuthMode('login');
        applyAuthScreenContext();
        window.history.replaceState({}, '', '/login');
        showNotice('Password updated. You can now sign in with the new password.');
        document.getElementById('auth-password').value = '';
        return;
      }

      if (!email || !password) {
        throw new Error('Enter your email and password to continue.');
      }
      if (authMode === 'register') {
        if (!name) throw new Error('Enter your full name to create the account.');
        pendingCustomerSignup = {
          email: email,
          password: password,
          fullName: name,
          phone: draft.guestPhone || '',
          primaryServiceArea: draft.serviceArea || draft.locationLabel || '',
          latitude: draft.latitude,
          longitude: draft.longitude,
          referralCode: referralCode
        };
        const signupResult = await Store.signUpCustomer(pendingCustomerSignup);
        if (signupResult && signupResult.user && !signupResult.session) {
          setAuthMode('verify');
          applyAuthScreenContext();
          document.getElementById('auth-password').value = '';
          document.getElementById('auth-token').value = '';
          showNotice('We sent a 6-digit code to your email. Enter it here to continue.');
          return;
        }
      } else {
        await Store.signIn(email, password);
      }

      await continueAfterCustomerAuth();
    });
  }

  async function verifyCustomerSignupCode() {
    const payload = pendingCustomerSignup || {};
    const email = (payload.email || document.getElementById('auth-contact').value).trim();
    const token = document.getElementById('auth-token').value.replace(/\D/g, '');
    if (!email || token.length !== 6) {
      throw new Error('Enter the 6-digit code from your email.');
    }
    await Store.verifySignupOtp(email, token);
    if (pendingCustomerSignup) {
      await Store.finishCustomerSignup(pendingCustomerSignup);
    }
    pendingCustomerSignup = null;
    document.getElementById('auth-token').value = '';
    showNotice('Email verified. Opening your account...');
    await continueAfterCustomerAuth();
  }

  async function handleCustomerSignupResend() {
    const payload = pendingCustomerSignup || {};
    const email = (payload.email || document.getElementById('auth-contact').value).trim();
    if (!email) {
      showError('Enter your email first so we can resend the code.');
      return;
    }
    await withButtonLoading('btn-auth-resend', 'Resending...', async () => {
      await Store.resendSignupOtp(email, '/login?verify=signup');
      showNotice('A fresh 6-digit code has been sent to your email.');
    });
  }

  async function continueAfterCustomerAuth() {
    if (hasDraftLocation() && draft.issueCategory) {
      await continueFromMatch();
      return;
    }
    if (authScreenIntent === 'tracking' || authScreenIntent === 'dashboard' || authScreenIntent === 'claim-guest') {
      await openDashboard();
      return;
    }
    await resumeLatestJob();
  }

  async function handleCustomerPasswordResetRequest() {
    const email = document.getElementById('auth-contact').value.trim();
    if (!email) {
      showError('Enter your email first so we know where to send the reset link.');
      return;
    }
    await withButtonLoading('btn-auth-forgot', 'Sending Reset Link...', async () => {
      await Store.requestPasswordReset(email, '/login?reset=1');
      showNotice('Reset link sent. Open the email on this device, then choose a new password.');
    });
  }

  async function continueFromMatch() {
    if (draft.addressSource === 'manual' || addressMode === 'manual') {
      syncManualAddressDraft();
    }
    const bookingLocation = getFinalBookingLocation();
    if (!bookingLocation.locationLabel) {
      goTo('service-area');
      showError('Choose a location before submitting.');
      return;
    }
    if (!draft.issueCategory) {
      goTo('problem');
      showError('Select the issue before submitting.');
      return;
    }
    const profile = Store.getCurrentProfile();
    const profileHasPhone = profile && isValidPhone(profile.phone);
    if (!profileHasPhone && !isValidPhone(draft.guestPhone)) {
      renderMatch();
      goTo('match');
      showError('Enter your mobile number before submitting.');
      return;
    }

    await withButtonLoading('btn-continue-match', 'Creating Booking...', async () => {
      if (profile && !profileHasPhone) {
        await Store.updateProfile({ phone: draft.guestPhone });
      }
      const bookingPayload = {
        serviceArea: bookingLocation.serviceArea,
        locationLabel: bookingLocation.locationLabel,
        latitude: bookingLocation.latitude,
        longitude: bookingLocation.longitude,
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
      finishNewBooking(job);
    });
  }

  function finishNewBooking(job) {
    if (!job || !job.id) return;
    currentJob = job;
    currentTrackedTicket = job.ticket || currentTrackedTicket;
    bindJobSubscription(job.id);
    routeJob(job, false, { routeData: { ticket: job.ticket || currentTrackedTicket } });
    refreshWelcomeActions();
    renderSidecars();
    Store.getJob(job.id).then((freshJob) => {
      if (!freshJob || !currentJob || freshJob.id !== currentJob.id) return;
      currentJob = freshJob;
      currentTrackedTicket = freshJob.ticket || currentTrackedTicket;
      routeJob(freshJob, true, { routeData: { ticket: freshJob.ticket || currentTrackedTicket }, replace: true });
      refreshWelcomeActions();
    }).catch(() => {});
  }

  async function resumeLatestJob(options) {
    if (!Store.getCurrentProfile() && Store.getGuestAccess()) {
      try {
        const guestJob = await Store.getGuestJob(Store.getGuestAccess().jobId, Store.getGuestAccess().accessToken);
        if (guestJob && !['rated', 'cancelled'].includes(guestJob.status)) {
          await openTrackedJob(guestJob.id, { replace: !!(options && options.replace) });
          return;
        }
      } catch (error) {
        Store.clearGuestAccess();
      }
    }
    const jobs = await Store.listCustomerJobs();
    const active = jobs.find((job) => !['rated', 'cancelled'].includes(job.status));
    if (active) {
      await openTrackedJob(active.id, { replace: !!(options && options.replace) });
      return;
    }
    if (jobs[0]) {
      currentJob = jobs[0];
    }
    if (options && options.preferTracking) {
      goTo('welcome', { replace: !!options.replace });
      return;
    }
    goTo('welcome', { replace: !!(options && options.replace) });
  }

  async function openTrackedJob(jobId, options) {
    currentJob = await Store.getJob(jobId);
    currentTrackedTicket = currentJob.ticket || null;
    bindJobSubscription(jobId);
    routeJob(currentJob, false, options);
    refreshWelcomeActions();
    renderSidecars();
    return currentJob;
  }

  async function openTrackedJobByTicket(ticket, options) {
    const cleanTicket = String(ticket || '').trim().toUpperCase();
    if (!cleanTicket) return null;

    if (!Store.getCurrentProfile() && Store.getGuestAccess()) {
      try {
        const guestJob = await Store.getGuestJob(Store.getGuestAccess().jobId, Store.getGuestAccess().accessToken);
        if (guestJob && String(guestJob.ticket || '').toUpperCase() === cleanTicket) {
          return openTrackedJob(guestJob.id, options);
        }
      } catch (error) {
        Store.clearGuestAccess();
      }
    }

    const jobs = Store.getCurrentProfile()
      ? await Store.listCustomerJobs()
      : [];
    const match = jobs.find((job) => String(job.ticket || '').toUpperCase() === cleanTicket);
    if (!match) return null;
    return openTrackedJob(match.id, options);
  }

  function bindJobSubscription(jobId) {
    if (jobSubscription) jobSubscription.unsubscribe();
    jobSubscription = Store.subscribeToJob(jobId, async (job) => {
      currentJob = job;
       currentTrackedTicket = job.ticket || currentTrackedTicket;
      routeJob(job, true, { routeData: { ticket: job.ticket || currentTrackedTicket }, replace: true });
      renderSidecars();
      if (chatOpen) {
        await Chat.render();
      }
    });
  }

  function routeJob(job, preserveScreen, options) {
    const routeOptions = Object.assign({}, options || {}, {
      routeData: { ticket: job.ticket || currentTrackedTicket }
    });
    renderAssigned(job);

    if (job.status === 'assessment_fee_pending' || job.status === 'assessment_payment_pending_verification' || job.status === 'assessment_confirmed') {
      renderAssessmentFee(job);
      if (!preserveScreen && ['assessment_fee_pending', 'assessment_payment_pending_verification'].includes(job.status)) goTo('appearance-fee', routeOptions);
      if (job.status === 'assessment_confirmed' && !preserveScreen) goTo('assigned', routeOptions);
      return;
    }

    if (job.status === 'quoted') {
      renderQuoteScreen(job);
      if (!preserveScreen) goTo('quotation', routeOptions);
      return;
    }

    if (job.status === 'quote_accepted' || job.status === 'work_payment_pending_verification' || job.status === 'payment_confirmed') {
      renderPaymentScreen(job);
      if (!preserveScreen && ['quote_accepted', 'work_payment_pending_verification'].includes(job.status)) goTo('payment', routeOptions);
      if (job.status === 'payment_confirmed' && !preserveScreen) goTo('assigned', routeOptions);
      return;
    }

    if (job.status === 'electrician_completed' || job.status === 'customer_confirmed' || job.status === 'payout_pending') {
      renderConfirmScreen(job);
      if (!preserveScreen && job.status === 'electrician_completed') goTo('confirm-work', routeOptions);
      if (!preserveScreen && ['customer_confirmed', 'payout_pending'].includes(job.status)) goTo('assigned', routeOptions);
      return;
    }

    if (job.status === 'payout_complete') {
      if (job.isGuest) {
        renderDoneScreen(job);
        if (!preserveScreen) goTo('done', routeOptions);
        return;
      }
      renderRatingScreen(job);
      if (!preserveScreen) goTo('rating', routeOptions);
      return;
    }

    if (job.status === 'rated') {
      renderDoneScreen(job);
      if (!preserveScreen) goTo('done', routeOptions);
      return;
    }

    if (!preserveScreen) goTo('assigned', routeOptions);
  }

  function renderAssigned(job) {
    currentTrackedTicket = job.ticket || currentTrackedTicket;
    currentJob = job;
    renderTrackingHero(job);
    renderTrackingProgress(job);
    renderTrackingDetails(job);
  }

  function renderTrackingHero(job) {
    const title = document.getElementById('tracking-hero-title');
    const sub = document.getElementById('tracking-hero-sub');
    const note = document.getElementById('tracking-hero-note');
    if (!title || !sub || !note) return;

    if (job && job.assignedElectrician) {
      title.textContent = 'Your VoltFriq has been assigned';
      sub.textContent = job.assignedElectrician.name
        ? job.assignedElectrician.name + ' is attached to this booking.'
        : 'A verified electrician is attached to this booking.';
      note.textContent = 'Keep this page open for the next job update.';
      return;
    }

    title.textContent = 'Booking confirmed';
    sub.textContent = 'Finding the best VoltFriq near you...';
    note.textContent = 'Progress is happening. We will update this page as soon as pairing moves.';
  }

  function getTrackingStageIndex(job) {
    const status = (job && job.status) || 'matching';
    if (['rated', 'payout_complete', 'payout_pending', 'customer_confirmed', 'electrician_completed'].includes(status)) return 4;
    if (['en_route', 'on_site', 'work_in_progress'].includes(status)) return 3;
    if ([
      'assigned',
      'accepted',
      'assessment_fee_pending',
      'assessment_payment_pending_verification',
      'assessment_confirmed',
      'quoted',
      'quote_accepted',
      'work_payment_pending_verification',
      'payment_confirmed'
    ].includes(status)) return 2;
    return 1;
  }

  function renderTrackingProgress(job) {
    const container = document.getElementById('tracking-progress');
    if (!container) return;
    const activeIndex = getTrackingStageIndex(job);
    const submittedTime = formatTrackingTime(job && job.createdAt);
    const screen = document.getElementById('screen-assigned');
    if (screen) screen.classList.toggle('is-pairing', activeIndex === 1);
    const steps = [
      { title: 'Submitted', sub: submittedTime, icon: 'check' },
      { title: 'Pairing', sub: activeIndex === 1 ? 'Finding VoltFriq' : 'Done', icon: 'bolt' },
      { title: 'Assigned', sub: activeIndex >= 2 ? 'Done' : 'Pending', icon: 'person' },
      { title: 'On the way', sub: activeIndex >= 3 ? 'In progress' : 'Pending', icon: 'car' },
      { title: 'Completed', sub: activeIndex >= 4 ? 'Done' : 'Pending', icon: 'flag' }
    ];
    container.innerHTML = steps.map((step, index) => {
      const state = index < activeIndex ? 'done' : index === activeIndex ? 'active' : 'pending';
      const side = state === 'done'
        ? '<span class="tracking-step-side tracking-step-side-done">Done</span>'
        : state === 'active'
          ? '<span class="tracking-step-side tracking-step-side-active" aria-hidden="true"><i></i><i></i><i></i></span>'
          : '';
      return '<div class="tracking-step is-' + state + '">' +
          '<div class="tracking-step-icon">' + trackingIcon(step.icon) + '</div>' +
          '<div class="tracking-step-copy"><strong>' + escapeHtml(step.title) + '</strong><span>' + escapeHtml(step.sub) + '</span></div>' +
          side +
        '</div>';
    }).join('');
  }

  function renderTrackingDetails(job) {
    const container = document.getElementById('tracking-details');
    if (!container) return;
    const issue = getTrackingIssueLabel(job);
    const location = (job && (job.locationLabel || job.serviceArea)) || 'Selected service area';
    const ticket = (job && job.ticket) || currentTrackedTicket || 'VFQ-PENDING';
    const urgency = formatUrgencyLabel((job && job.urgency) || 'emergency');
    const serviceType = getTrackingServiceType(job);
    const estimate = getTrackingEstimate(job);
    const assessment = getTrackingAssessmentValue(job);
    const detailsState = trackingDetailsExpanded ? ' is-expanded' : '';
    const contactCta = shouldShowTrackingContact(job)
      ? '<button class="tracking-contact-btn" id="btn-tracking-contact" type="button">' + trackingIcon('message') + '<span>Contact Us</span></button>'
      : '';
    container.innerHTML = [
      '<div class="tracking-detail-main' + detailsState + '">',
        '<span class="tracking-detail-icon" aria-hidden="true">' + trackingIcon('socket') + '</span>',
        '<div class="tracking-detail-copy">',
          '<h3>' + escapeHtml(issue) + '</h3>',
          '<p>' + escapeHtml(location) + '</p>',
          '<div class="tracking-ticket-line">',
            '<span>Ticket ID: ' + escapeHtml(ticket) + '</span>',
            '<button class="tracking-copy-ticket" type="button" data-copy-ticket="' + escapeHtml(ticket) + '" aria-label="Copy ticket ID">' + trackingIcon('copy') + '</button>',
          '</div>',
        '</div>',
      '</div>',
      '<button class="tracking-detail-toggle" id="btn-toggle-tracking-details" type="button">' + escapeHtml(trackingDetailsExpanded ? 'Hide details' : 'View details') + '</button>',
      contactCta,
      '<div class="tracking-detail-metrics' + detailsState + '">',
        '<div class="tracking-metric"><span>Service type</span><strong>' + escapeHtml(serviceType) + '</strong><em>' + escapeHtml(urgency) + '</em></div>',
        '<div class="tracking-metric"><span>Estimated price</span><strong>' + escapeHtml(estimate) + '</strong><small>After assessment</small></div>',
        '<div class="tracking-metric"><span>Assessment visit</span><strong>' + escapeHtml(assessment) + '</strong></div>',
      '</div>'
    ].join('');
  }

  function shouldShowTrackingContact(job) {
    if (!job) return false;
    return ['accepted', 'en_route', 'on_site', 'work_in_progress', 'electrician_completed'].includes(job.status);
  }

  function getTrackingIssueLabel(job) {
    if (!job) return 'Electrical service';
    return humanizeIssueCategory(job.issueCategory) || job.issueCategory || 'Electrical service';
  }

  function getTrackingServiceType(job) {
    const issue = job ? getIssueOption(job.issueCategory, getTrackingIssueLabel(job)) : null;
    const service = (issue && issue.value) || (job && inferSkillCategory(job.issueCategory)) || 'Electrical work';
    return String(service).replace(/\s+issue$/i, '').replace(/^General Installation$/i, 'Installation');
  }

  function getTrackingEstimate(job) {
    const issue = job ? getIssueOption(job.issueCategory, getTrackingIssueLabel(job)) : null;
    const min = issue ? Number(issue.estimated_fee_min || 0) : 0;
    if (min) return Store.formatCurrency(min) + '+';
    return getIssueEstimate(job && job.issueCategory, getTrackingIssueLabel(job));
  }

  function getTrackingAssessmentValue(job) {
    const settings = Store.getSettings();
    const assessmentStatuses = ['assessment_fee_pending', 'assessment_payment_pending_verification', 'assessment_confirmed'];
    const amount = job && assessmentStatuses.includes(job.status) ? Number(settings.assessment_fee || 0) : 0;
    return Store.formatCurrency(amount);
  }

  function formatTrackingTime(value) {
    if (!value) return 'Submitted';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return 'Submitted';
    return date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  }

  function trackingIcon(name) {
    const icons = {
      check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.35" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12 4 4L19 6"/></svg>',
      bolt: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M13 2 4 14h6l-1 8 9-12h-6l1-8Z"/></svg>',
      person: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.05" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="3.4"/><path d="M5.5 20a6.5 6.5 0 0 1 13 0"/></svg>',
      car: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.05" stroke-linecap="round" stroke-linejoin="round"><path d="M5 11 7 5h10l2 6"/><path d="M4 11h16v7H4z"/><path d="M7 18v2"/><path d="M17 18v2"/><circle cx="8" cy="15" r="1"/><circle cx="16" cy="15" r="1"/></svg>',
      flag: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.05" stroke-linecap="round" stroke-linejoin="round"><path d="M5 21V4"/><path d="M5 4h11l-1.5 4L16 12H5"/></svg>',
      socket: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="4" width="14" height="16" rx="3"/><path d="M9 9v2"/><path d="M15 9v2"/><path d="M10 16h4"/></svg>',
      message: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.05" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a4 4 0 0 1-4 4H8l-5 3V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4z"/></svg>',
      copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.05" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="8" width="11" height="11" rx="2"/><path d="M5 16H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>'
    };
    return icons[name] || '';
  }

  function renderAssessmentFee(job) {
    const settings = Store.getSettings();
    document.getElementById('fee-amount').textContent = Store.formatCurrency(settings.assessment_fee || 0);
    document.getElementById('assessment-snapshot').innerHTML = [
      ['Status', job.statusLabel],
      ['Verification', 'Submitted does not mean verified. VoltFriq confirms this payment manually before the inspection visit can continue.'],
      ['Ticket', job.ticket]
    ].map(renderKeyValueRow).join('');
    document.getElementById('fee-bank-name').textContent = settings.platform_bank_name || '';
    document.getElementById('fee-account-number').textContent = settings.platform_account_number || '';
    document.getElementById('fee-account-name').textContent = settings.platform_account_name || '';
    document.getElementById('btn-fee-paid').textContent = job.status === 'assessment_payment_pending_verification'
      ? 'Payment Proof Submitted'
      : 'Submit Assessment Payment Proof';
    document.getElementById('btn-fee-paid').disabled = job.status === 'assessment_payment_pending_verification';
    focusCustomerScreen('appearance-fee');
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
    document.getElementById('payment-note').textContent = 'Upload your payment proof. Submitted means received, not yet verified. Work only moves after VoltFriq confirms the transfer.';
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
    document.getElementById('payment-reference').value = job.ticket || '';
    focusCustomerScreen('payment');
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
    focusCustomerScreen('confirm-work');
  }

  function renderRatingScreen(job) {
    document.getElementById('rating-comment').value = '';
    document.getElementById('rating-count').textContent = '0';
    document.getElementById('btn-submit-rating').disabled = false;
    ratingValue = 0;
    selectedRatingTags = [];
    document.querySelectorAll('#rating-tags [data-rating-tag]').forEach((tag) => tag.classList.remove('active'));
    updateStars();
    focusCustomerScreen('rating');
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

  async function showHistory(fromRoute, options) {
    if (!Store.getCurrentProfile()) {
      openCustomerAuthScreen('tracking', 'login', { replace: !!(options && options.replace) });
      return;
    }
    try {
      setScreenBusy(true, 'Loading your jobs...');
      renderHistoryLoading();
      await renderSidecars();
      const jobs = await Store.listCustomerJobs();
      const filtered = historyFilter === 'completed'
        ? jobs.filter((job) => ['rated', 'cancelled'].includes(job.status))
        : jobs.filter((job) => !['rated', 'cancelled'].includes(job.status));
      document.getElementById('history-list').innerHTML = filtered.length ? filtered.map(renderHistoryCard).join('') : '<div class="empty-state"><div class="empty-state-text">No jobs in this view yet.</div></div>';
      document.querySelectorAll('#history-list .history-card').forEach((card) => {
        card.addEventListener('click', () => openTrackedJob(card.dataset.jobId));
      });
      goTo('history', { replace: !!(options && options.replace) });
    } catch (error) {
      showError(error);
    } finally {
      setScreenBusy(false);
    }
  }

  function openCustomerAuthScreen(intent, mode, options) {
    closeMobileMenu();
    authScreenIntent = intent || 'default';
    setAuthMode(wantsPasswordReset() ? 'reset' : (mode || 'login'));
    applyAuthScreenContext();
    goTo('customer-auth', {
      replace: !!(options && options.replace),
      routeData: { intent: authScreenIntent, mode: authMode }
    });
  }

  function applyAuthScreenContext() {
    const heading = document.getElementById('auth-heading');
    const sub = document.getElementById('auth-sub');
    const title = document.getElementById('customer-auth-title');
    if (!heading || !sub) return;
    if (authMode === 'verify') {
      if (title) title.textContent = 'Verify Email';
      heading.textContent = 'Enter your email code';
      sub.textContent = 'Use the 6-digit code from your email to finish your account on this page.';
      return;
    }
    if (authMode === 'reset') {
      if (title) title.textContent = 'Reset Password';
      heading.textContent = 'Choose your new password';
      sub.textContent = 'Use a fresh password with at least 8 characters. Once saved, you can sign in again immediately.';
      return;
    }
    if (authScreenIntent === 'tracking') {
      if (title) title.textContent = 'Sign In';
      heading.textContent = 'Login to track your jobs';
      sub.textContent = 'Sign in to see previous bookings, payment proofs, receipts, and live status updates.';
      return;
    }
    if (authScreenIntent === 'dashboard') {
      if (title) title.textContent = authMode === 'register' ? 'Create Account' : 'Sign In';
      heading.textContent = authMode === 'register' ? 'Create your customer dashboard' : 'Sign in to your customer dashboard';
      sub.textContent = 'Manage active jobs, history, saved addresses, and account details in one place.';
      return;
    }
    if (authScreenIntent === 'claim-guest') {
      if (title) title.textContent = 'Create Account';
      heading.textContent = 'Create your customer dashboard';
      sub.textContent = 'Create an account for future dashboards, faster repeat bookings, and easier tracking across devices.';
      return;
    }
    if (title) title.textContent = authMode === 'register' ? 'Create Account' : 'Sign In';
    heading.textContent = 'Save your job and continue';
    sub.textContent = 'Your account keeps your jobs, payment proofs, receipts, and ratings in one secure place.';
  }

  async function openDashboard(options) {
    closeMobileMenu();
    if (!Store.getCurrentProfile()) {
      openCustomerAuthScreen('default', 'login', { replace: !!(options && options.replace) });
      return;
    }

    const profile = Store.getCurrentProfile();
    const role = profile.role;
    const electrician = Store.getCurrentElectrician();

    // Add debug logs
    console.log('Current user ID:', profile.id);
    console.log('Profile role:', role);
    console.log('Electrician record found:', !!electrician);
    if (electrician) {
      console.log('Electrician status:', electrician.status);
    }

    let destination;
    if (role === 'admin') {
      destination = '/admin.html';
    } else if (role === 'electrician' || electrician) {
      if (electrician && electrician.status === 'approved') {
        destination = '/electrician.html';
      } else {
        destination = '/electrician.html#pending';
      }
    } else {
      // Customer - stay on current page and load dashboard
      destination = null;
    }

    console.log('Resolved destination:', destination);

    if (destination) {
      window.location.href = destination;
      return;
    }

    try {
      setScreenBusy(true, 'Loading your dashboard...');
      renderDashboardLoading();
      await loadSavedAddresses();
      await renderSidecars();
      await renderDashboard();
      goTo('dashboard', { replace: !!(options && options.replace) });
    } catch (error) {
      showError(error);
    } finally {
      setScreenBusy(false);
    }
  }

  async function renderDashboard() {
    const profile = Store.getCurrentProfile() || {};
    const jobs = await Store.listCustomerJobs();
    const activeJobs = jobs.filter((job) => !['rated', 'cancelled'].includes(job.status)).slice(0, 3);
    const recentJobs = jobs.slice(0, 4);

    document.getElementById('dashboard-name').textContent = profile.full_name || 'Customer';
    document.getElementById('dashboard-sub').textContent = activeJobs.length
      ? activeJobs.length + ' active job(s) tracked in one place.'
      : 'Book fast, then manage jobs, history, and referrals from one clean dashboard.';

    document.getElementById('dashboard-active-jobs').innerHTML = activeJobs.length
      ? activeJobs.map(renderDashboardJobCard).join('')
      : '<div class="empty-state"><div class="empty-state-text">No active jobs right now.</div></div>';
    document.querySelectorAll('#dashboard-active-jobs .history-card').forEach((card) => {
      card.addEventListener('click', () => openTrackedJob(card.dataset.jobId));
    });

    document.getElementById('dashboard-history-preview').innerHTML = recentJobs.length
      ? recentJobs.map(renderHistoryCard).join('')
      : '<div class="empty-state"><div class="empty-state-text">No previous jobs yet.</div></div>';
    document.querySelectorAll('#dashboard-history-preview .history-card').forEach((card) => {
      card.addEventListener('click', () => openTrackedJob(card.dataset.jobId));
    });

    const latestJob = jobs[0] || null;
    document.getElementById('dashboard-addresses').innerHTML = [
      ['Latest area', latestJob ? latestJob.locationLabel || latestJob.serviceArea || '--' : '--'],
      ['Service city', latestJob ? latestJob.serviceArea || '--' : 'Port Harcourt'],
      ['Booking mode', latestJob ? 'Guided booking' : 'Ready when you are']
    ].map(renderMiniMetaRow).join('');

    document.getElementById('dashboard-account').innerHTML = [
      ['Name', profile.full_name || '--'],
      ['Email', profile.email || (Store.getSession() && Store.getSession().user && Store.getSession().user.email) || '--'],
      ['Phone', profile.phone || draft.guestPhone || '--']
    ].map(renderMiniMetaRow).join('');
  }

  function renderDashboardJobCard(job) {
    const subtitle = job.assignedElectrician
      ? 'Assigned to ' + job.assignedElectrician.name
      : job.needsManualAssignment
        ? 'Manual dispatch review'
        : 'Automatic matching in progress';
    return '<div class="history-card dashboard-job-card" data-job-id="' + job.id + '">' +
      '<div class="history-card-date">' + escapeHtml(job.ticket) + '</div>' +
      '<div class="history-card-title">' + escapeHtml(humanizeIssueCategory(job.issueCategory)) + '</div>' +
      '<div class="history-card-sub">' + escapeHtml(subtitle) + '</div>' +
      '<div class="history-card-badge badge badge-blue">' + escapeHtml(job.statusLabel) + '</div>' +
    '</div>';
  }

  async function handleCustomerSignOut() {
    await Store.signOut();
    currentJob = null;
    currentTrackedTicket = null;
    refreshWelcomeActions();
    resetDraft();
    goTo('welcome', { replace: true });
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

  function renderDashboardLoading() {
    const stack = [
      '<div class="skeleton-card"></div>',
      '<div class="skeleton-card"></div>'
    ].join('');
    document.getElementById('dashboard-active-jobs').innerHTML = stack;
    document.getElementById('dashboard-history-preview').innerHTML = stack;
    document.getElementById('dashboard-addresses').innerHTML = '<div class="skeleton-stack"><div class="skeleton-line long"></div><div class="skeleton-line medium"></div><div class="skeleton-line short"></div></div>';
    document.getElementById('dashboard-account').innerHTML = '<div class="skeleton-stack"><div class="skeleton-line medium"></div><div class="skeleton-line long"></div><div class="skeleton-line medium"></div></div>';
  }

  function renderHistoryLoading() {
    document.getElementById('history-list').innerHTML = [
      '<div class="skeleton-card"></div>',
      '<div class="skeleton-card"></div>',
      '<div class="skeleton-card"></div>'
    ].join('');
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

  async function handleTrackingSupport() {
    if (!currentJob) return;
    if (currentJob.isGuest && !Store.getCurrentProfile()) {
      openCustomerAuthScreen('tracking', 'login');
      showNotice('Sign in or create an account to contact support about this booking.');
      return;
    }
    await openChat();
  }

  function copyTrackingTicket(button) {
    const ticket = button && button.dataset ? button.dataset.copyTicket : '';
    if (!ticket) return;
    const markCopied = () => {
      button.classList.add('is-copied');
      setTimeout(() => button.classList.remove('is-copied'), 1100);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(ticket).then(markCopied).catch(markCopied);
    } else {
      markCopied();
    }
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
    draft.country = DEFAULT_COUNTRY;
    draft.state = '';
    draft.city = '';
    draft.streetAddress = '';
    draft.landmark = '';
    draft.latitude = null;
    draft.longitude = null;
    draft.addressSource = '';
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
    if (document.getElementById('service-area-select')) document.getElementById('service-area-select').value = '';
    if (document.getElementById('manual-country')) document.getElementById('manual-country').value = DEFAULT_COUNTRY;
    if (document.getElementById('manual-state')) document.getElementById('manual-state').value = '';
    if (document.getElementById('manual-city')) document.getElementById('manual-city').value = '';
    if (document.getElementById('manual-street-address')) document.getElementById('manual-street-address').value = '';
    if (document.getElementById('manual-landmark')) document.getElementById('manual-landmark').value = '';
    document.getElementById('problem-category').value = '';
    document.getElementById('problem-desc').value = '';
    if (document.getElementById('review-phone')) document.getElementById('review-phone').value = '';
    if (document.getElementById('detected-location-text')) document.getElementById('detected-location-text').textContent = 'Finding your location...';
    if (document.getElementById('manual-location-sheet')) document.getElementById('manual-location-sheet').style.display = 'none';
    document.getElementById('auth-referral-code').value = '';
    authScreenIntent = 'default';
    applyAuthScreenContext();
    document.getElementById('dispute-type').value = '';
    document.getElementById('dispute-details').value = '';
    document.getElementById('desc-count').textContent = '0';
    renderPhotoPreviews();
    updateAvailabilityCard();
    renderIssueSelect();
    updateReviewButton();
    window.sessionStorage.removeItem(CUSTOMER_DRAFT_KEY);
  }

  function persistDraftState() {
    try {
      window.sessionStorage.setItem(CUSTOMER_DRAFT_KEY, JSON.stringify({
        serviceArea: draft.serviceArea,
        locationLabel: draft.locationLabel,
        country: draft.country,
        state: draft.state,
        city: draft.city,
        streetAddress: draft.streetAddress,
        landmark: draft.landmark,
        latitude: draft.latitude,
        longitude: draft.longitude,
        addressSource: draft.addressSource,
        issueCategory: draft.issueCategory,
        issueLabel: draft.issueLabel,
        issueKey: draft.issueKey,
        urgency: draft.urgency,
        requiresAssessment: draft.requiresAssessment,
        materialHandling: draft.materialHandling,
        note: draft.note,
        guestPhone: draft.guestPhone
      }));
    } catch (error) {
      // Session draft recovery is a convenience only.
    }
  }

  function hydrateDraftState() {
    try {
      const raw = window.sessionStorage.getItem(CUSTOMER_DRAFT_KEY);
      if (!raw) return;
      const stored = JSON.parse(raw);
      draft.serviceArea = stored.serviceArea || '';
      draft.locationLabel = stored.locationLabel || '';
      draft.country = stored.country || DEFAULT_COUNTRY;
      draft.state = stored.state || '';
      draft.city = stored.city || '';
      draft.streetAddress = stored.streetAddress || '';
      draft.landmark = stored.landmark || '';
      draft.latitude = stored.latitude == null ? null : Number(stored.latitude);
      draft.longitude = stored.longitude == null ? null : Number(stored.longitude);
      draft.addressSource = stored.addressSource || '';
      draft.issueCategory = stored.issueCategory || '';
      draft.issueLabel = stored.issueLabel || '';
      draft.issueKey = stored.issueKey || '';
      draft.urgency = stored.urgency || 'today';
      draft.requiresAssessment = stored.requiresAssessment !== false;
      draft.materialHandling = stored.materialHandling || 'voltfriq_supplied';
      draft.note = stored.note || '';
      draft.guestPhone = stored.guestPhone || '';
      renderManualAddressControls();
      updateManualLocationSummary();
    } catch (error) {
      // Ignore broken draft snapshots.
    }
  }

  function refreshWelcomeActions() {
    const profile = Store.getCurrentProfile();
    const loginButton = document.getElementById('btn-welcome-login');
    const mobileLoginButton = document.getElementById('btn-mobile-login');
    const mobileInlineLoginButton = document.getElementById('btn-mobile-login-inline');
    const signupButton = document.getElementById('btn-welcome-signup');
    const mobileSignupButton = document.getElementById('btn-mobile-signup');
    const mobileInlineSignupButton = document.getElementById('btn-mobile-signup-inline');
    const dashboardButton = document.getElementById('btn-open-dashboard');
    const mobileDashboardButton = document.getElementById('btn-mobile-dashboard');
    const mobileInlineDashboardButton = document.getElementById('btn-mobile-dashboard-inline');
    const dashboardHeroButton = document.getElementById('btn-open-dashboard-hero');
    const trackButton = document.getElementById('btn-track-job');
    const mobileTrackButton = document.getElementById('btn-mobile-track');
    const mobileInlineTrackButton = document.getElementById('btn-mobile-track-inline');
    const historyButton = document.getElementById('btn-assigned-history');

    if (loginButton) {
      loginButton.textContent = profile ? 'Dashboard' : 'Login';
    }
    if (mobileLoginButton) {
      mobileLoginButton.textContent = profile ? 'Open Dashboard' : 'Sign In';
      mobileLoginButton.style.display = profile ? 'none' : '';
    }
    if (mobileInlineLoginButton) {
      mobileInlineLoginButton.textContent = profile ? 'Open Dashboard' : 'Sign In';
      mobileInlineLoginButton.style.display = profile ? 'none' : '';
    }
    if (signupButton) {
      signupButton.style.display = profile ? 'none' : '';
    }
    if (mobileSignupButton) {
      mobileSignupButton.style.display = profile ? 'none' : '';
    }
    if (mobileInlineSignupButton) {
      mobileInlineSignupButton.style.display = profile ? 'none' : '';
    }
    if (dashboardButton) {
      dashboardButton.style.display = profile ? '' : 'none';
    }
    if (mobileDashboardButton) {
      mobileDashboardButton.style.display = profile ? '' : 'none';
    }
    if (mobileInlineDashboardButton) {
      mobileInlineDashboardButton.style.display = profile ? '' : 'none';
    }
    if (dashboardHeroButton) {
      dashboardHeroButton.style.display = profile ? '' : 'none';
    }
    if (trackButton) {
      trackButton.textContent = currentJob ? 'Open Active Job' : 'Track Job';
    }
    if (mobileTrackButton) {
      mobileTrackButton.textContent = currentJob ? 'Open Active Job' : 'Track Job';
    }
    if (mobileInlineTrackButton) {
      mobileInlineTrackButton.textContent = currentJob ? 'Open Active Job' : 'Track Job';
    }
    if (historyButton) {
      historyButton.title = profile ? 'Dashboard History' : 'Track History';
    }
  }

  async function renderSidecars() {
    try {
      const [notifications, walletSummary, referralSummary] = await Promise.all([
        Store.listNotifications(),
        Store.getWalletSummary(),
        Store.getReferralSummary()
      ]);
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
    const baseIssues = ISSUE_OPTIONS.map((issue) => {
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
    const extraIssues = invoiceItems
      .filter((item, index) => !usedInvoiceIndexes.has(index))
      .map((item) => normalizeIssue({
        issue_type: item.issue_type,
        value: item.value || inferSkillCategory(item.issue_type),
        description: item.description,
        estimated_fee_min: item.estimated_fee_min,
        estimated_fee_max: item.estimated_fee_max
      }));
    return baseIssues.concat(extraIssues);
  }

  function normalizeIssue(issue) {
    const issueType = issue.issue_type || 'Other';
    const value = issue.value || inferSkillCategory(issueType);
    return {
      ...issue,
      key: slugifyIssue(issueType + '-' + value),
      issue_type: issueType,
      value,
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
      value: item.value || item.category || null,
      description: item.description || item.short_description || item.note || item.details || '',
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

  function focusCustomerScreen(screen) {
    window.setTimeout(() => {
      let target = null;
      if (screen === 'service-area') {
        target = addressMode === 'manual'
          ? document.getElementById('manual-street-address')
          : document.getElementById('location-option-gps');
      } else if (screen === 'problem') {
        target = document.getElementById('problem-desc');
      } else if (screen === 'details') {
        target = document.getElementById('btn-details-review');
      } else if (screen === 'match') {
        target = document.getElementById('review-phone') || document.getElementById('btn-continue-match');
      } else if (screen === 'appearance-fee') {
        target = document.getElementById('assessment-receipt-upload');
      } else if (screen === 'payment') {
        target = document.getElementById('payment-reference');
      } else if (screen === 'confirm-work') {
        target = document.getElementById('confirm-checkbox');
      } else if (screen === 'rating') {
        target = document.getElementById('rating-comment');
      }
      if (target && typeof target.focus === 'function') {
        target.focus({ preventScroll: true });
      }
    }, 90);
  }

  async function withButtonLoading(buttonId, loadingText, work) {
    const button = document.getElementById(buttonId);
    const originalText = button ? button.textContent : '';
    const originalHtml = button ? button.innerHTML : '';
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
        button.innerHTML = originalHtml || originalText;
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
    if (authError) {
      authError.classList.remove('is-success');
      authError.style.display = 'none';
      authError.textContent = '';
    }
    document.querySelectorAll('.flow-error').forEach((error) => {
      error.style.display = 'none';
      error.textContent = '';
    });
  }

  function showError(error) {
    const message = typeof error === 'string'
      ? error
      : error && error.message
        ? error.message
        : 'Something went wrong.';
    const authError = document.getElementById('auth-error');
    const activeScreen = document.querySelector('.screen.active');
    if (activeScreen && activeScreen.id !== 'screen-customer-auth') {
      const body = activeScreen.querySelector('.screen-body') || activeScreen;
      let flowError = body.querySelector('.flow-error');
      if (!flowError) {
        flowError = document.createElement('div');
        flowError.className = 'flow-error';
        flowError.setAttribute('role', 'alert');
        body.insertBefore(flowError, body.firstElementChild || null);
      }
      flowError.textContent = message;
      flowError.style.display = 'block';
      return;
    }
    if (!authError) return;
    authError.classList.remove('is-success');
    authError.style.display = 'block';
    authError.textContent = message;
  }

  function showNotice(message) {
    const authError = document.getElementById('auth-error');
    authError.classList.add('is-success');
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

  function escapeAttribute(value) {
    return escapeHtml(value);
  }
})();
