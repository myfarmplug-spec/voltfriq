/* ─── VOLTFRIQ — SUPABASE BACKEND SERVICE ───────────────────────── */

const Store = (() => {
  const DEFAULT_SERVICE_AREAS = [
    'Abia', 'Adamawa', 'Akwa Ibom', 'Anambra', 'Bauchi', 'Bayelsa',
    'Benue', 'Borno', 'Cross River', 'Delta', 'Ebonyi', 'Edo',
    'Ekiti', 'Enugu', 'FCT', 'Gombe', 'Imo', 'Jigawa', 'Kaduna',
    'Kano', 'Katsina', 'Kebbi', 'Kogi', 'Kwara', 'Lagos', 'Nasarawa',
    'Niger', 'Ogun', 'Ondo', 'Osun', 'Oyo', 'Plateau', 'Rivers',
    'Sokoto', 'Taraba', 'Yobe', 'Zamfara'
  ];
  const LEGACY_LAGOS_AREAS = ['Lekki Phase 1', 'Victoria Island', 'Ikeja', 'Surulere', 'Yaba', 'Ajah'];
  const LEGACY_PORT_HARCOURT_AREAS = [
    'GRA, Port Harcourt', 'Old GRA, Port Harcourt', 'New GRA, Port Harcourt',
    'D-Line, Port Harcourt', 'Trans Amadi, Port Harcourt', 'Woji, Port Harcourt',
    'Rumuola, Port Harcourt', 'Rumuodomaya, Port Harcourt', 'Rumuokoro, Port Harcourt',
    'Rumuigbo, Port Harcourt', 'Ada George, Port Harcourt', 'Eliozu, Port Harcourt',
    'Elelenwo, Port Harcourt', 'Mile 1, Port Harcourt', 'Mile 3, Port Harcourt',
    'Choba, Port Harcourt', 'Owerri Municipal', 'Owerri North', 'Owerri West',
    'Orlu', 'Okigwe'
  ];
  const REQUEST_TIMEOUT_MS = 45000;

  const DEFAULT_SETTINGS = {
    assessment_fee: 0,
    service_areas: DEFAULT_SERVICE_AREAS.slice(),
    supported_states: DEFAULT_SERVICE_AREAS.slice(),
    supported_cities: [],
    launch_cities: [],
    disabled_service_areas: [],
    issue_categories: [],
    ranking_weights: {},
    platform_bank_name: '',
    platform_account_number: '',
    platform_account_name: '',
    payment_configuration: {
      active_provider: 'manual',
      preferred_provider: '',
      providers: {
        manual: {
          enabled: true
        },
        paystack: {
          enabled: false,
          public_key: '',
          secret_key: '',
          webhook_secret: '',
          subaccount_code: ''
        },
        remita: {
          enabled: false,
          merchant_id: '',
          service_type_id: '',
          api_key: '',
          gateway_url: ''
        }
      }
    },
    workmanship_prices: [],
    trust_settings: {
      negative_rating_limit: 3,
      negative_rating_max_score: 2,
      watchlist_rank_penalty_km: 8,
      rising_jobs: 3,
      trusted_jobs: 10,
      top_rated_jobs: 25,
      elite_jobs: 60
    }
  };
  const DEFAULT_EXPERTISE_CATEGORIES = [
    'Light fitting',
    'Socket repair',
    'Wiring issue',
    'Inverter',
    'Generator',
    'Tripped breaker',
    'General Installation',
    'Inspection',
    'Solar',
    'Other'
  ];

  const STATUS_LABELS = {
    requested: 'Requested',
    matching: 'Matching',
    assigned: 'Assigned',
    accepted: 'Accepted',
    assessment_fee_pending: 'Assessment Fee Pending',
    assessment_payment_pending_verification: 'Assessment Verification',
    assessment_confirmed: 'Assessment Confirmed',
    en_route: 'En Route',
    on_site: 'On Site',
    quoted: 'Quoted',
    quote_accepted: 'Quote Accepted',
    work_payment_pending_verification: 'Payment Verification',
    payment_confirmed: 'Payment Confirmed',
    work_in_progress: 'Work In Progress',
    electrician_completed: 'Electrician Completed',
    customer_confirmed: 'Customer Confirmed',
    payout_pending: 'Payout Pending',
    payout_complete: 'Payout Complete',
    rated: 'Rated',
    cancelled: 'Cancelled'
  };

  const STORAGE_PATHS = {
    avatar: 'avatars',
    electricianDocument: 'electrician-documents',
    jobPhoto: 'job-photos',
    paymentProof: 'payment-proofs'
  };

  const PAYMENT_STATUS_LABELS = {
    submitted: 'Pending Verification',
    verified: 'Verified',
    rejected: 'Rejected'
  };

  const state = {
    client: null,
    configured: false,
    session: null,
    profile: null,
    profileLoadError: null,
    customer: null,
    electrician: null,
    wallet: null,
    guestAccess: null,
    settings: DEFAULT_SETTINGS,
    expertiseCategories: DEFAULT_EXPERTISE_CATEGORIES.slice(),
    authListenersBound: false
  };

  let hydrationPromise = null;
  let authHydrationTimer = null;

  const GUEST_ACCESS_KEY = 'voltfriq_guest_job_access';
  const GUEST_DEVICE_KEY = 'voltfriq_guest_device_id';

  function config() {
    return window.VOLTFRIQ_CONFIG || {};
  }

  function isLocalHostname(hostname) {
    return ['localhost', '127.0.0.1', '0.0.0.0'].includes(String(hostname || '').toLowerCase());
  }

  function parseUrl(value) {
    try {
      return new URL(value);
    } catch (error) {
      return null;
    }
  }

  function normalizeSiteUrl(value) {
    const clean = String(value || '').trim().replace(/\/+$/, '');
    if (!clean) return '';
    if (/^https?:\/\//i.test(clean)) return clean;
    if (/^(localhost|127\.0\.0\.1|0\.0\.0\.0)(:|\/|$)/i.test(clean)) return 'http://' + clean;
    return 'https://' + clean;
  }

  function getPublicSiteUrl() {
    const configured = normalizeSiteUrl(config().publicSiteUrl);
    const currentOrigin = (typeof window !== 'undefined' && window.location && window.location.origin)
      ? window.location.origin
      : 'https://www.voltfriq.com';
    const configuredUrl = parseUrl(configured);
    const currentUrl = parseUrl(currentOrigin);

    if (currentUrl && isLocalHostname(currentUrl.hostname)) {
      return currentOrigin.replace(/\/+$/, '');
    }

    if (configuredUrl && isLocalHostname(configuredUrl.hostname) && currentUrl && !isLocalHostname(currentUrl.hostname)) {
      return currentOrigin.replace(/\/+$/, '');
    }

    return (configured || currentOrigin || 'https://www.voltfriq.com').replace(/\/+$/, '');
  }

  function siteUrlForPath(path) {
    const value = String(path || '/').trim() || '/';
    if (/^https?:\/\//i.test(value)) return value;
    return getPublicSiteUrl() + (value.charAt(0) === '/' ? value : '/' + value);
  }

  function loadGuestAccess() {
    try {
      const raw = window.localStorage.getItem(GUEST_ACCESS_KEY);
      state.guestAccess = raw ? JSON.parse(raw) : null;
    } catch (error) {
      state.guestAccess = null;
    }
    return state.guestAccess;
  }

  function saveGuestAccess(access) {
    state.guestAccess = access || null;
    try {
      if (state.guestAccess) {
        window.localStorage.setItem(GUEST_ACCESS_KEY, JSON.stringify(state.guestAccess));
      } else {
        window.localStorage.removeItem(GUEST_ACCESS_KEY);
      }
    } catch (error) {
      // Tracking still works for this session even if local storage is unavailable.
    }
    return state.guestAccess;
  }

  function getGuestAccess() {
    return state.guestAccess || loadGuestAccess();
  }

  function clearGuestAccess() {
    return saveGuestAccess(null);
  }

  function getGuestDeviceId() {
    try {
      const existing = window.localStorage.getItem(GUEST_DEVICE_KEY);
      if (existing) return existing;
      const generated = window.crypto && window.crypto.randomUUID
        ? window.crypto.randomUUID()
        : 'guest-' + Date.now() + '-' + Math.random().toString(36).slice(2);
      window.localStorage.setItem(GUEST_DEVICE_KEY, generated);
      return generated;
    } catch (error) {
      return 'guest-session-' + Date.now() + '-' + Math.random().toString(36).slice(2);
    }
  }

  function guestTokenPrefix(accessToken) {
    return String(accessToken || '').slice(0, 16);
  }

  function normalizeAddress(address) {
    const raw = address || {};
    const addressText = String(raw.addressText || raw.address_text || raw.locationLabel || raw.location_label || raw.serviceArea || raw.service_area || '').trim();
    const label = String(raw.label || addressText || 'Saved address').trim();
    const latitude = raw.latitude === '' || raw.latitude == null ? null : Number(raw.latitude);
    const longitude = raw.longitude === '' || raw.longitude == null ? null : Number(raw.longitude);
    return {
      id: raw.id || null,
      label: label || 'Saved address',
      addressText,
      locationLabel: String(raw.locationLabel || raw.location_label || addressText).trim(),
      latitude: Number.isFinite(latitude) ? latitude : null,
      longitude: Number.isFinite(longitude) ? longitude : null,
      lastUsedAt: raw.lastUsedAt || raw.last_used_at || new Date().toISOString()
    };
  }

  function selectDraftAddress(address) {
    return normalizeAddress(address);
  }

  function normalizeError(error, fallbackMessage) {
    if (isAuthLockError(error)) {
      return new Error('Your secure session refreshed. Please try again.');
    }
    if (isBookingTimelineProfileError(error)) {
      return new Error('We are finishing your booking setup. Please try again in a moment.');
    }
    if (!error) return new Error(fallbackMessage || 'Something went wrong.');
    if (error instanceof Error && error.message) return error;
    if (typeof error === 'string') return new Error(error);
    if (error.message) return new Error(error.message);
    return new Error(fallbackMessage || 'Something went wrong.');
  }

  function isAuthLockError(error) {
    const message = String((error && error.message) || error || '').toLowerCase();
    return message.includes('auth-token') && message.includes('lock') && (
      message.includes('stole it') || message.includes('navigator lock') || message.includes('released')
    );
  }

  function isBookingTimelineProfileError(error) {
    const message = String((error && error.message) || error || '').toLowerCase();
    return message.includes('job_timeline')
      && message.includes('actor_profile_id')
      && message.includes('foreign key');
  }

  function wait(ms) {
    return new Promise((resolve) => window.setTimeout(resolve, ms));
  }

  async function withAuthLockRetry(work) {
    let lastError = null;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      try {
        const result = await work();
        if (result && result.error && isAuthLockError(result.error)) {
          lastError = result.error;
          if (attempt === 2) break;
          await wait(220 + (attempt * 280));
          continue;
        }
        return result;
      } catch (error) {
        lastError = error;
        if (!isAuthLockError(error) || attempt === 2) break;
        await wait(220 + (attempt * 280));
      }
    }
    throw lastError;
  }

  function isMissingSchemaError(error) {
    const message = String((error && error.message) || error || '').toLowerCase();
    return message.includes('does not exist')
      || message.includes('could not find the table')
      || message.includes('schema cache')
      || message.includes('column')
      || message.includes('relation');
  }

  function requireRole(role) {
    if (!state.profile || state.profile.role !== role) {
      throw new Error('You do not have permission to perform this action.');
    }
  }

  function ensureClient() {
    if (state.client) return state.client;
    if (!window.supabase || !config().supabaseUrl || !config().supabaseAnonKey) {
      return null;
    }
    state.client = window.supabase.createClient(config().supabaseUrl, config().supabaseAnonKey, {
      global: {
        fetch: fetchWithTimeout
      },
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true
      }
    });
    state.configured = true;
    return state.client;
  }

  function fetchWithTimeout(input, init) {
    const controller = new AbortController();
    const timeoutId = window.setTimeout(() => {
      controller.abort(new Error('Request timed out. Check your connection and try again.'));
    }, REQUEST_TIMEOUT_MS);
    const nextInit = Object.assign({}, init || {}, { signal: controller.signal });

    if (init && init.signal) {
      if (init.signal.aborted) {
        window.clearTimeout(timeoutId);
        return fetch(input, init);
      }
      init.signal.addEventListener('abort', () => controller.abort(init.signal.reason), { once: true });
    }

    return fetch(input, nextInit)
      .catch((error) => {
        if (controller.signal.aborted) {
          throw new Error('Request timed out. Check your connection and try again.');
        }
        throw error;
      })
      .finally(() => window.clearTimeout(timeoutId));
  }

  function requireClient() {
    const client = ensureClient();
    if (!client) {
      throw new Error('VoltFriq could not start its secure connection. Refresh and try again.');
    }
    return client;
  }

  function isConfigured() {
    return !!ensureClient();
  }

  async function init() {
    const client = ensureClient();
    loadGuestAccess();
    installGuestUploadRetryQueue();
    if (!client) {
      state.configured = false;
      return { configured: false };
    }

    if (!state.authListenersBound) {
      state.authListenersBound = true;
      client.auth.onAuthStateChange((_event, session) => {
        if (authHydrationTimer) window.clearTimeout(authHydrationTimer);
        authHydrationTimer = window.setTimeout(() => {
          authHydrationTimer = null;
          hydrateSession(session).catch(() => {});
        }, 0);
      });
    }

    await hydrateSession();
    await loadSettings();
    await loadExpertiseCategories();
    return {
      configured: true,
      profile: state.profile,
      customer: state.customer,
      electrician: state.electrician,
      wallet: state.wallet
    };
  }

  async function hydrateSession(seed) {
    if (hydrationPromise) {
      try {
        await hydrationPromise;
      } catch (error) {
        // A fresh hydration attempt below can recover from transient auth lock races.
      }
    }

    const nextHydration = doHydrateSession(seed);
    hydrationPromise = nextHydration;
    try {
      return await nextHydration;
    } finally {
      if (hydrationPromise === nextHydration) {
        hydrationPromise = null;
      }
    }
  }

  async function doHydrateSession(seed) {
    const client = ensureClient();
    if (!client) return null;

    const seedSession = seed && seed.access_token
      ? seed
      : seed && seed.session && seed.session.access_token
        ? seed.session
        : null;
    const seedUser = seed && seed.user
      ? seed.user
      : seedSession && seedSession.user
        ? seedSession.user
        : null;

    if (seedSession) {
      state.session = seedSession;
    } else {
      const sessionResult = await withAuthLockRetry(() => client.auth.getSession());
      state.session = sessionResult.data.session || null;
    }
    if (!state.session) {
      state.profile = null;
      state.profileLoadError = null;
      state.customer = null;
      state.electrician = null;
      state.wallet = null;
      return null;
    }

    const userResult = seedUser ? null : await withAuthLockRetry(() => client.auth.getUser());
    const user = seedUser || (userResult && userResult.data.user);
    if (!user) {
      state.profile = null;
      state.profileLoadError = null;
      state.customer = null;
      state.electrician = null;
      state.wallet = null;
      return null;
    }

    const ensuredProfile = await ensureProfile(user);
    let profileReadError = null;
    let profileResult = null;
    try {
      profileResult = await withAuthLockRetry(() => client
        .from('profiles')
        .select('*')
        .eq('id', user.id)
        .maybeSingle());
    } catch (error) {
      profileReadError = normalizeError(error, 'Could not read your profile.');
    }
    if (profileResult && profileResult.error) {
      profileReadError = normalizeError(profileResult.error, 'Could not read your profile.');
    }

    const nextProfile = (profileResult && profileResult.data) || ensuredProfile || null;
    state.profileLoadError = nextProfile
      ? null
      : profileReadError || new Error('No profile was returned for this account.');
    let nextCustomer = null;
    let nextElectrician = null;
    let nextWallet = null;

    if (nextProfile && nextProfile.role === 'customer') {
      await ensureCustomerRecord(nextProfile.id);
      const customerResult = await withAuthLockRetry(() => client
        .from('customers')
        .select('*')
        .eq('profile_id', nextProfile.id)
        .maybeSingle());
      nextCustomer = customerResult.data || null;
    }

    if (nextProfile) {
      await ensureWalletRecord(nextProfile.id);
      const walletResult = await withAuthLockRetry(() => client
        .from('wallets')
        .select('*')
        .eq('profile_id', nextProfile.id)
        .maybeSingle());
      nextWallet = walletResult.data || null;
    }

    if (nextProfile && nextProfile.role === 'electrician') {
      const electricianResult = await withAuthLockRetry(() => client
        .from('electricians')
        .select('*, electrician_skills(category), electrician_documents(*), electrician_certifications(*)')
        .eq('profile_id', nextProfile.id)
        .maybeSingle());
      nextElectrician = electricianResult.data || null;
    }

    state.profile = nextProfile;
    state.customer = nextCustomer;
    state.electrician = nextElectrician;
    state.wallet = nextWallet;

    return state.profile;
  }

  function getSession() {
    return state.session;
  }

  function getCurrentProfile() {
    return state.profile;
  }

  function getProfileLoadError() {
    return state.profileLoadError;
  }

  function getCurrentCustomer() {
    return state.customer;
  }

  function getCurrentElectrician() {
    return state.electrician;
  }

  function getCurrentWallet() {
    return state.wallet;
  }

  async function loadSettings() {
    const client = ensureClient();
    if (!client) return DEFAULT_SETTINGS;
    const result = await client
      .from('admin_settings')
      .select('*')
      .order('updated_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    state.settings = normalizeSettings(Object.assign({}, DEFAULT_SETTINGS, result.data || {}));
    return state.settings;
  }

  function getSettings() {
    return state.settings;
  }

  function normalizeSettings(settings) {
    const next = Object.assign({}, settings || {});
    const areas = Array.isArray(next.service_areas) ? next.service_areas.map((area) => String(area || '').trim()).filter(Boolean) : [];
    const normalizedAreas = areas.map((area) => area.toLowerCase());
    const legacyAreas = LEGACY_LAGOS_AREAS.concat(LEGACY_PORT_HARCOURT_AREAS).map((legacy) => legacy.toLowerCase());
    const legacyOnly = areas.length > 0 && areas.every((area) => legacyAreas.includes(area.toLowerCase()));
    const hasNigeriaWideCoverage = DEFAULT_SERVICE_AREAS.every((stateName) => normalizedAreas.includes(stateName.toLowerCase()));
    next.service_areas = (!areas.length || legacyOnly || !hasNigeriaWideCoverage)
      ? DEFAULT_SERVICE_AREAS.slice()
      : areas;
    next.supported_states = Array.isArray(next.supported_states) && next.supported_states.length
      ? next.supported_states.map((item) => String(item || '').trim()).filter(Boolean)
      : DEFAULT_SERVICE_AREAS.slice();
    next.supported_cities = Array.isArray(next.supported_cities) ? next.supported_cities.map((item) => String(item || '').trim()).filter(Boolean) : [];
    next.launch_cities = Array.isArray(next.launch_cities) ? next.launch_cities.map((item) => String(item || '').trim()).filter(Boolean) : [];
    next.disabled_service_areas = Array.isArray(next.disabled_service_areas) ? next.disabled_service_areas.map((item) => String(item || '').trim()).filter(Boolean) : [];
    const paymentConfig = next.payment_configuration || {};
    next.payment_configuration = {
      active_provider: paymentConfig.active_provider || 'manual',
      preferred_provider: paymentConfig.preferred_provider || '',
      providers: {
        manual: Object.assign({}, DEFAULT_SETTINGS.payment_configuration.providers.manual, paymentConfig.providers && paymentConfig.providers.manual || {}),
        paystack: Object.assign({}, DEFAULT_SETTINGS.payment_configuration.providers.paystack, paymentConfig.providers && paymentConfig.providers.paystack || {}),
        remita: Object.assign({}, DEFAULT_SETTINGS.payment_configuration.providers.remita, paymentConfig.providers && paymentConfig.providers.remita || {})
      }
    };
    return next;
  }

  function normalizeLocationText(value) {
    return String(value || '')
      .toLowerCase()
      .replace(/&/g, ' and ')
      .replace(/[^a-z0-9]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  function addressSearchText(input) {
    if (typeof input === 'string') return normalizeLocationText(input);
    const raw = input || {};
    return normalizeLocationText([
      raw.serviceArea,
      raw.service_area,
      raw.locationLabel,
      raw.location_label,
      raw.streetAddress,
      raw.street_address,
      raw.landmark,
      raw.city,
      raw.state,
      raw.country
    ].filter(Boolean).join(' '));
  }

  function areaName(area) {
    return String(area || '').split(',')[0].trim();
  }

  function inferServiceAreaFromAddress(input) {
    const text = addressSearchText(input);
    const areas = getServiceAreas();
    if (!text || !areas.length) return '';
    const explicit = String((input && (input.serviceArea || input.service_area || input.closestServiceArea)) || '').trim();
    if (explicit) {
      const explicitMatch = areas.find((area) => area.toLowerCase() === explicit.toLowerCase());
      if (explicitMatch) return explicitMatch;
    }

    const keywords = DEFAULT_SERVICE_AREAS.concat(state.settings && Array.isArray(state.settings.supported_cities) ? state.settings.supported_cities : []);
    let best = { area: '', score: 0 };
    areas.forEach((area) => {
      const normalizedArea = normalizeLocationText(area);
      const normalizedAreaName = normalizeLocationText(areaName(area));
      let score = 0;
      if (text.includes(normalizedArea)) score += 120;
      if (normalizedAreaName && text.includes(normalizedAreaName)) score += 100;
      if (normalizedAreaName && normalizedAreaName.split(' ').every((word) => text.includes(word))) score += 60;
      keywords.forEach((keyword) => {
        const normalizedKeyword = normalizeLocationText(keyword);
        if (normalizedKeyword && text.includes(normalizedKeyword) && normalizedArea.includes(normalizedKeyword)) {
          score += 150;
        }
      });
      if (input && input.city && normalizedArea.includes(normalizeLocationText(input.city))) score += 12;
      if (input && input.state && normalizedArea.includes(normalizeLocationText(input.state))) score += 8;
      if (score > best.score) best = { area, score };
    });

    return best.score >= 20 ? best.area : '';
  }

  function getServiceAreas() {
    return (state.settings && Array.isArray(state.settings.service_areas) && state.settings.service_areas.length)
      ? state.settings.service_areas.slice()
      : DEFAULT_SERVICE_AREAS.slice();
  }

  async function loadExpertiseCategories() {
    const client = ensureClient();
    if (!client) return state.expertiseCategories;
    const result = await client
      .from('expertise_categories')
      .select('*')
      .order('label', { ascending: true });
    if (!result.error && result.data && result.data.length) {
      state.expertiseCategories = result.data.map((item) => item.label).filter(Boolean);
      return state.expertiseCategories;
    }
    state.expertiseCategories = (state.settings.issue_categories || []).filter(Boolean).length
      ? state.settings.issue_categories.filter(Boolean)
      : DEFAULT_EXPERTISE_CATEGORIES.slice();
    return state.expertiseCategories;
  }

  function getExpertiseCategories() {
    return state.expertiseCategories && state.expertiseCategories.length
      ? state.expertiseCategories.slice()
      : DEFAULT_EXPERTISE_CATEGORIES.slice();
  }

  function getStatusLabel(status) {
    return STATUS_LABELS[status] || status || 'Unknown';
  }

  function getPaymentStatusLabel(status) {
    return PAYMENT_STATUS_LABELS[status] || status || 'Unknown';
  }

  function normalizeSignupRole(role) {
    const value = String(role || '').trim().toLowerCase();
    if (['electrician', 'voltfriq', 'volt_friq', 'volt-friq'].includes(value)) return 'electrician';
    return 'customer';
  }

  function getRoleHome(role) {
    const value = String(role || '').trim().toLowerCase();
    if (value === 'admin') return '/admin/dashboard';
    if (['electrician', 'voltfriq', 'volt_friq', 'volt-friq'].includes(value)) return '/electricians/dashboard';
    return '/dashboard';
  }

  function customerSignupRedirectUrl() {
    return siteUrlForPath('/login?verify=signup');
  }

  function electricianSignupRedirectUrl() {
    return siteUrlForPath('/electricians/login?verify=signup');
  }
