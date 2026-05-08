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
  let selectedExpertise = [];
  let certificationEntries = [];
  let documentUploads = {};
  let validationAnswers = {};
  let pendingElectricianRoute = null;
  let pendingElectricianSignupPayload = null;
  let electricianReconnectBound = false;
  let electricianReconnectRefreshTimer = null;
  const PENDING_SIGNUP_KEY = 'voltfriq_pending_electrician_signup';
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

  function persistPendingElectricianSignup(payload) {
    if (!payload) return;
    const serializable = {
      fullName: payload.fullName || '',
      phone: payload.phone || '',
      email: payload.email || '',
      country: payload.country || DEFAULT_COUNTRY,
      state: payload.state || '',
      city: payload.city || '',
      streetAddress: payload.streetAddress || payload.street_address || '',
      street_address: payload.street_address || payload.streetAddress || '',
      locationLabel: payload.locationLabel || '',
      location_label: payload.location_label || payload.locationLabel || '',
      baseLocationLabel: payload.baseLocationLabel || payload.base_location_label || payload.locationLabel || payload.location_label || '',
      base_location_label: payload.base_location_label || payload.baseLocationLabel || payload.location_label || payload.locationLabel || '',
      yearsExperience: payload.yearsExperience || 0,
      availabilityStatus: payload.availabilityStatus || 'available',
      serviceAreas: payload.serviceAreas || [],
      service_areas: payload.service_areas || payload.serviceAreas || [],
      skills: payload.skills || [],
      bankName: payload.bankName || '',
      bankAccountNumber: payload.bankAccountNumber || '',
      bankAccountName: payload.bankAccountName || '',
      certifications: payload.certifications || [],
      onboardingValidationScore: payload.onboardingValidationScore || 0,
      onboardingReviewStatus: payload.onboardingReviewStatus || 'pending',
      onboardingFeedback: payload.onboardingFeedback || null,
      onboardingAnswers: payload.onboardingAnswers || []
    };
    try {
      window.localStorage.setItem(PENDING_SIGNUP_KEY, JSON.stringify(serializable));
    } catch (error) {
      // Email verification can still complete in the current tab.
    }
  }

  function loadPendingElectricianSignup() {
    if (pendingElectricianSignupPayload) return pendingElectricianSignupPayload;
    try {
      const raw = window.localStorage.getItem(PENDING_SIGNUP_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch (error) {
      return null;
    }
  }

  function clearPendingElectricianSignup() {
    pendingElectricianSignupPayload = null;
    try {
      window.localStorage.removeItem(PENDING_SIGNUP_KEY);
    } catch (error) {
      // Nothing else to clear.
    }
  }

  const ISSUE_LABELS = {
    'Light fitting': 'Light fitting',
    'Socket repair': 'Socket repair',
    'Wiring issue': 'Wiring',
    Inverter: 'Inverter',
    Generator: 'Generator',
    'Tripped breaker': 'Tripped breaker',
    'General Installation': 'Installation',
    Inspection: 'Inspection',
    Solar: 'Solar',
    Other: 'Other'
  };
  const ISSUE_ESTIMATES = {
    'Light fitting': [4000, 8000],
    'Socket repair': [5000, 8000],
    'Wiring issue': [6000, null],
    Inverter: [15000, null],
    Generator: [15000, null],
    'Tripped breaker': [8000, 12000],
    'General Installation': [8000, null],
    Inspection: [5000, null],
    Solar: [15000, null],
    Other: [5000, null]
  };
  const DEFAULT_SKILL_OPTIONS = Object.keys(ISSUE_LABELS);
  const VALIDATION_PASS_THRESHOLD = 60;
  const ELECTRICIAN_ROUTE_TITLES = {
    'elec-login': 'VoltFriq | Electrician Login',
    'elec-reg-1': 'VoltFriq | Electrician Apply',
    'elec-reg-2': 'VoltFriq | Electrician Apply | Work Areas',
    'elec-reg-3': 'VoltFriq | Electrician Apply | Expertise',
    'elec-reg-4': 'VoltFriq | Electrician Apply | Documents',
    'elec-reg-5': 'VoltFriq | Electrician Apply | Payout Setup',
    'elec-pending': 'VoltFriq | Application Pending',
    'elec-appeal': 'VoltFriq | Appeal Review',
    'elec-dashboard': 'VoltFriq | Electrician Dashboard',
    'elec-job-detail': 'VoltFriq | Job Detail',
    'elec-assessment': 'VoltFriq | Prepare Quote',
    'elec-confirm': 'VoltFriq | Confirm Work',
    'elec-chat': 'VoltFriq | Job Chat',
    'elec-history': 'VoltFriq | Work History',
    'elec-profile': 'VoltFriq | Profile'
  };
  const SAFETY_QUESTIONS = [
    {
      id: 'safe_start',
      prompt: 'How do you make a customer feel safe before starting work?',
      options: [
        { id: 'explain', label: 'Explain the work clearly', correct: true },
        { id: 'start_fast', label: 'Start immediately', correct: false },
        { id: 'power_off', label: 'Turn off main power first', correct: true },
        { id: 'ignore', label: 'Ignore customer concerns', correct: false }
      ]
    },
    {
      id: 'onsite_assessment',
      prompt: 'When should you stop remote diagnosis and request an on-site assessment?',
      options: [
        { id: 'unclear_fault', label: 'When the fault is unclear or unsafe', correct: true },
        { id: 'burn_marks', label: 'When there are burn marks or overheating signs', correct: true },
        { id: 'always_remote', label: 'Keep guessing remotely until it works', correct: false },
        { id: 'skip_visit', label: 'Skip assessment to save time', correct: false }
      ]
    },
    {
      id: 'documenting_work',
      prompt: 'How should you document findings, materials, and completed work?',
      options: [
        { id: 'clear_notes', label: 'Write clear notes and list materials used', correct: true },
        { id: 'photos', label: 'Add photos or readings where helpful', correct: true },
        { id: 'memory_only', label: 'Keep it in memory only', correct: false },
        { id: 'no_customer_update', label: 'Avoid explaining the final work to the customer', correct: false }
      ]
    }
  ];

  async function init() {
    configureElectricianRoutes();
    bindEvents();
    updateLoginRecoveryState();
    pendingElectricianRoute = getCurrentRouteState();
    try {
      const boot = await Store.init();
      if (!boot.configured) {
        showError('The electrician portal is still starting. Refresh the page in a moment.');
        return;
      }

      if (boot.profile && boot.profile.role === 'customer') {
        window.location.href = Store.getRoleHome('customer');
        return;
      }
      if (boot.profile && boot.profile.role === 'admin') {
        window.location.href = Store.getRoleHome('admin');
        return;
      }

      renderRegistrationOptions();
      bindElectricianReconnectRefresh();

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

      if (boot.profile && !wantsPasswordReset()) {
        await resumeSession(pendingElectricianRoute);
      } else {
        await handleElectricianRouteActivation({
          screen: (pendingElectricianRoute && pendingElectricianRoute.screen) || (shouldStartApplication() ? 'elec-reg-1' : 'elec-login'),
          data: pendingElectricianRoute ? pendingElectricianRoute.data : null,
          source: 'initial'
        });
      }
    } catch (error) {
      showError(error.message || 'Could not start the electrician portal.');
    }
  }

  function configureElectricianRoutes() {
    configureRoutes({
      defaultScreen: 'elec-login',
      pathParser: parseElectricianRoute,
      pathResolver: resolveElectricianPath,
      titleResolver: resolveElectricianTitle,
      onRouteActivated: async (route) => {
        await handleElectricianRouteActivation(route);
      }
    });
  }

  function parseElectricianRoute(pathname) {
    const path = normalizeElectricianPath(pathname);
    if (path === '/electricians' || path === '/electricians/login' || path === '/electrician.html') return { screen: 'elec-login' };
    if (path === '/electricians/apply') return { screen: 'elec-reg-1' };
    if (path === '/electricians/pending') return { screen: 'elec-pending' };
    if (path === '/electricians/dashboard') return { screen: 'elec-dashboard' };
    if (path === '/electricians/history') return { screen: 'elec-history' };
    if (path === '/electricians/profile') return { screen: 'elec-profile' };
    if (path.indexOf('/electricians/jobs/') === 0) return { screen: 'elec-job-detail', data: { ticket: decodeURIComponent(path.split('/').pop() || '') } };
    return { screen: 'elec-login' };
  }

  function resolveElectricianPath(screen, routeData) {
    if (screen === 'elec-login') return '/electricians/login';
    if (['elec-reg-1', 'elec-reg-2', 'elec-reg-3', 'elec-reg-4', 'elec-reg-5'].includes(screen)) return '/electricians/apply';
    if (screen === 'elec-pending') return '/electricians/dashboard';
    if (screen === 'elec-appeal') return '/electricians/pending';
    if (screen === 'elec-dashboard') return '/electricians/dashboard';
    if (screen === 'elec-history') return '/electricians/history';
    if (screen === 'elec-profile') return '/electricians/profile';
    if (['elec-job-detail', 'elec-assessment', 'elec-confirm', 'elec-chat'].includes(screen)) {
      const ticket = routeData && routeData.ticket ? routeData.ticket : (currentJob && currentJob.ticket);
      return ticket ? '/electricians/jobs/' + encodeURIComponent(ticket) : '/electricians/dashboard';
    }
    return '/electricians/login';
  }

  function resolveElectricianTitle(screen, routeData) {
    if (['elec-job-detail', 'elec-assessment', 'elec-confirm', 'elec-chat'].includes(screen) && routeData && routeData.ticket) {
      return 'VoltFriq | Job ' + routeData.ticket;
    }
    return ELECTRICIAN_ROUTE_TITLES[screen] || 'VoltFriq | Electrician Portal';
  }

  async function handleElectricianRouteActivation(route) {
    if (!route || !route.screen) return;
    const electrician = Store.getCurrentElectrician();
    const profile = Store.getCurrentProfile();

    if (!profile) {
      if (route.screen === 'elec-reg-1') {
        goTo('elec-reg-1', { replace: route.source !== 'popstate' });
        return;
      }
      goTo('elec-login', { replace: route.source !== 'popstate' });
      return;
    }

    if (!electrician) {
      goTo('elec-login', { replace: route.source !== 'popstate' });
      return;
    }

    if (electrician.status === 'pending' || electrician.status === 'rejected') {
      renderPendingDashboard(electrician);
      goTo('elec-pending', { replace: route.source !== 'popstate' });
      return;
    }

    if (electrician.status === 'suspended') {
      await renderAppealScreen(electrician);
      goTo('elec-appeal', { replace: route.source !== 'popstate' });
      return;
    }

    if (route.screen === 'elec-job-detail' && route.data && route.data.ticket) {
      const job = await openJobByTicket(route.data.ticket);
      if (job) return;
    }

    if (route.screen === 'elec-history') {
      renderHistory();
      goTo('elec-history', { replace: route.source !== 'popstate' });
      return;
    }

    if (route.screen === 'elec-profile') {
      renderProfile();
      goTo('elec-profile', { replace: route.source !== 'popstate' });
      return;
    }

    if (route.screen === 'elec-pending') {
      goTo('elec-dashboard', { replace: true });
      return;
    }

    await loadDashboard();
    goTo('elec-dashboard', { replace: route.source !== 'popstate' });
  }

  function bindEvents() {
    document.getElementById('btn-login').addEventListener('click', handleLogin);
    document.getElementById('btn-login-forgot').addEventListener('click', handleForgotPassword);
    document.getElementById('login-password').addEventListener('keydown', (event) => {
      if (event.key === 'Enter') handleLogin();
    });
    document.getElementById('btn-apply').addEventListener('click', () => goTo('elec-reg-1'));
    document.getElementById('reg-country').addEventListener('change', renderRegistrationOptions);
    document.getElementById('reg-state').addEventListener('change', () => {
      renderElectricianCityOptions();
      renderRegistrationOptions();
    });
    document.getElementById('reg-city').addEventListener('change', renderRegistrationOptions);
    document.getElementById('reg-street-address').addEventListener('input', renderRegistrationOptions);
    document.getElementById('reg-location').addEventListener('change', renderRegistrationOptions);

    document.getElementById('btn-reg-next-1').addEventListener('click', nextRegistrationStepOne);
    document.getElementById('btn-reg-next-2').addEventListener('click', nextRegistrationStepTwo);
    document.getElementById('btn-reg-next-3').addEventListener('click', nextRegistrationStepThree);
    document.getElementById('btn-reg-next-4').addEventListener('click', nextRegistrationStepFour);
    document.getElementById('btn-submit-application').addEventListener('click', submitApplication);
    document.getElementById('btn-add-certification').addEventListener('click', addCertificationEntry);
    document.getElementById('btn-pending-verify').addEventListener('click', verifyPendingElectricianSignup);
    document.getElementById('btn-pending-resend').addEventListener('click', resendPendingElectricianSignupCode);
    document.getElementById('btn-pending-refresh').addEventListener('click', refreshPendingDashboard);
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
    document.getElementById('reg-expertise-search').addEventListener('input', renderExpertiseOptions);

    document.querySelectorAll('.nav-item[data-nav]').forEach((button) => {
      button.addEventListener('click', () => handleNav(button.dataset.nav));
    });
  }

  function bindElectricianReconnectRefresh() {
    if (electricianReconnectBound) return;
    electricianReconnectBound = true;
    const scheduleElectricianRefresh = () => {
      if (electricianReconnectRefreshTimer) window.clearTimeout(electricianReconnectRefreshTimer);
      electricianReconnectRefreshTimer = window.setTimeout(async () => {
        electricianReconnectRefreshTimer = null;
        try {
          if (!Store.getCurrentElectrician || !Store.getCurrentElectrician()) return;
          if (currentJob) {
            currentJob = await Store.getJob(currentJob.id);
            renderJobDetail();
            renderConfirmScreen();
          }
          if (currentScreen === 'elec-dashboard') {
            await loadDashboard();
          }
        } catch (error) {
          console.warn('Electrician refresh after reconnect failed', error);
        }
      }, 600);
    };
    if (window.VoltFriqNetwork && window.VoltFriqNetwork.onReconnect) {
      window.VoltFriqNetwork.onReconnect('electrician-portal-refresh', scheduleElectricianRefresh);
    }
    window.addEventListener('voltfriq:refresh-requested', scheduleElectricianRefresh);
  }

  function shouldStartApplication() {
    const params = new URLSearchParams(window.location.search || '');
    return params.get('apply') === '1' || window.location.hash === '#apply';
  }

  async function resumeSession(route) {
    const electrician = Store.getCurrentElectrician();
    if (!electrician) {
      goTo('elec-login', { replace: true });
      return;
    }

    if (electrician.status === 'pending') {
      renderPendingDashboard(electrician);
      goTo('elec-pending', { replace: true });
      return;
    }
    if (electrician.status === 'suspended') {
      await renderAppealScreen(electrician);
      goTo('elec-appeal', { replace: true });
      return;
    }
    if (electrician.status === 'rejected') {
      renderPendingDashboard(electrician);
      goTo('elec-pending', { replace: true });
      return;
    }

    await loadDashboard();
    await handleElectricianRouteActivation(route || { screen: 'elec-dashboard', data: null, source: 'resume' });
  }

  async function handleLogin() {
    await withButtonLoading('btn-login', wantsPasswordReset() ? 'Updating Password...' : 'Signing In...', async () => {
      const email = document.getElementById('login-email').value.trim();
      const password = document.getElementById('login-password').value.trim();
      if (wantsPasswordReset()) {
        if (!password) throw new Error('Enter your new password to finish the reset.');
        await Store.updatePassword(password);
        window.history.replaceState({}, '', '/electricians/login');
        updateLoginRecoveryState();
        showNotice('Password updated. Sign in with the new password.');
        document.getElementById('login-password').value = '';
        return;
      }
      if (!email || !password) throw new Error('Enter your email and password.');
      await Store.signIn(email, password);
      if ((Store.getCurrentProfile() || {}).role !== 'electrician') {
        throw new Error('This account is not registered as a VoltFriq.');
      }
      await resumeSession(pendingElectricianRoute);
    });
  }

  async function handleForgotPassword() {
    const email = document.getElementById('login-email').value.trim();
    if (!email) {
      showError('Enter your email first so we know where to send the reset link.');
      return;
    }
    await withButtonLoading('btn-login-forgot', 'Sending Reset Link...', async () => {
      await Store.requestPasswordReset(email, '/electricians/login?reset=1');
      showNotice('Reset link sent. Open it on this device, then choose a new password.');
    });
  }
