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
  let bookingSubmitInFlight = false;
  let bookingConfirmationTimer = null;

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

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }

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

    on('manual-street-address', 'input', () => {
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
        showError('Enter an address before continuing, or use current location.');
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
        let metadata = {};
        try {
          if (currentJob.isGuest) {
            metadata = { phone_confirmation: promptForGuestPhoneConfirmation() };
          }
        } catch (error) {
          showError(error);
          return;
        }
        Store.updateJobStatus(currentJob.id, 'cancelled', 'Customer cancelled the job.', metadata)
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
        const upload = event.target.closest('#btn-guest-photo-upload');
        if (upload) {
          const input = document.getElementById('guest-photo-input');
          if (input) input.click();
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
      trackingDetails.addEventListener('change', (event) => {
        if (event.target && event.target.id === 'guest-photo-input') {
          uploadGuestTrackingPhotos(event.target);
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
