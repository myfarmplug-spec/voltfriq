/* ─── VOLTFRIQ — SUPABASE BACKEND SERVICE ───────────────────────── */

const Store = (() => {
  const DEFAULT_SERVICE_AREAS = [
    'GRA, Port Harcourt',
    'Old GRA, Port Harcourt',
    'New GRA, Port Harcourt',
    'D-Line, Port Harcourt',
    'Trans Amadi, Port Harcourt',
    'Woji, Port Harcourt',
    'Rumuola, Port Harcourt',
    'Rumuokoro, Port Harcourt',
    'Rumuigbo, Port Harcourt',
    'Ada George, Port Harcourt',
    'Eliozu, Port Harcourt',
    'Elelenwo, Port Harcourt',
    'Mile 1, Port Harcourt',
    'Mile 3, Port Harcourt',
    'Choba, Port Harcourt'
  ];
  const LEGACY_LAGOS_AREAS = ['Lekki Phase 1', 'Victoria Island', 'Ikeja', 'Surulere', 'Yaba', 'Ajah'];
  const REQUEST_TIMEOUT_MS = 45000;

  const DEFAULT_SETTINGS = {
    assessment_fee: 0,
    service_areas: DEFAULT_SERVICE_AREAS.slice(),
    issue_categories: [],
    ranking_weights: {},
    platform_bank_name: '',
    platform_account_number: '',
    platform_account_name: '',
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
    customer: null,
    electrician: null,
    wallet: null,
    guestAccess: null,
    settings: DEFAULT_SETTINGS,
    expertiseCategories: DEFAULT_EXPERTISE_CATEGORIES.slice(),
    authListenersBound: false,
    dispatchHeartbeatId: null
  };

  const GUEST_ACCESS_KEY = 'voltfriq_guest_job_access';
  const GUEST_ADDRESSES_KEY = 'voltfriq_guest_saved_addresses';

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

  function addressKey(address) {
    const normalized = normalizeAddress(address);
    const text = normalized.addressText.toLowerCase().replace(/\s+/g, ' ').trim();
    const lat = normalized.latitude == null ? '' : normalized.latitude.toFixed(4);
    const lng = normalized.longitude == null ? '' : normalized.longitude.toFixed(4);
    return text + '|' + lat + '|' + lng;
  }

  function loadGuestSavedAddresses() {
    try {
      const raw = window.localStorage.getItem(GUEST_ADDRESSES_KEY);
      const rows = raw ? JSON.parse(raw) : [];
      return Array.isArray(rows) ? rows.map(normalizeAddress).filter((address) => address.addressText) : [];
    } catch (error) {
      return [];
    }
  }

  function saveGuestSavedAddress(address) {
    const normalized = normalizeAddress(address);
    if (!normalized.addressText) return null;
    const key = addressKey(normalized);
    const next = loadGuestSavedAddresses()
      .filter((item) => addressKey(item) !== key);
    next.unshift(Object.assign({}, normalized, {
      id: normalized.id || 'guest-' + Date.now(),
      lastUsedAt: new Date().toISOString()
    }));
    const trimmed = next.slice(0, 6);
    try {
      window.localStorage.setItem(GUEST_ADDRESSES_KEY, JSON.stringify(trimmed));
    } catch (error) {
      // Guest address history is a convenience only.
    }
    return trimmed[0];
  }

  async function listSavedAddresses() {
    const client = ensureClient();
    if (!client || !state.profile || state.profile.role !== 'customer') {
      return loadGuestSavedAddresses();
    }
    const result = await client
      .from('customer_addresses')
      .select('*')
      .eq('profile_id', state.profile.id)
      .order('last_used_at', { ascending: false })
      .limit(8);
    if (result.error) throw normalizeError(result.error, 'Could not load saved addresses.');
    return (result.data || []).map(normalizeAddress);
  }

  async function saveCustomerAddress(address) {
    const client = ensureClient();
    const normalized = normalizeAddress(address);
    if (!normalized.addressText) return null;

    if (!client || !state.profile || state.profile.role !== 'customer') {
      return saveGuestSavedAddress(normalized);
    }

    const existing = await client
      .from('customer_addresses')
      .select('id')
      .eq('profile_id', state.profile.id)
      .eq('address_text', normalized.addressText)
      .limit(1)
      .maybeSingle();
    if (existing.error) throw normalizeError(existing.error, 'Could not check saved addresses.');

    const payload = {
      profile_id: state.profile.id,
      label: normalized.label || 'Saved address',
      address_text: normalized.addressText,
      location_label: normalized.locationLabel || normalized.addressText,
      latitude: normalized.latitude,
      longitude: normalized.longitude,
      last_used_at: new Date().toISOString()
    };

    const query = existing.data
      ? client.from('customer_addresses').update(payload).eq('id', existing.data.id).select('*').single()
      : client.from('customer_addresses').insert(payload).select('*').single();
    const result = await query;
    if (result.error) throw normalizeError(result.error, 'Could not save this address.');
    return normalizeAddress(result.data);
  }

  function selectDraftAddress(address) {
    return normalizeAddress(address);
  }

  function normalizeError(error, fallbackMessage) {
    if (!error) return new Error(fallbackMessage || 'Something went wrong.');
    if (error instanceof Error && error.message) return error;
    if (typeof error === 'string') return new Error(error);
    if (error.message) return new Error(error.message);
    return new Error(fallbackMessage || 'Something went wrong.');
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
    if (!client) {
      state.configured = false;
      return { configured: false };
    }

    if (!state.authListenersBound) {
      state.authListenersBound = true;
      client.auth.onAuthStateChange(async () => {
        await hydrateSession();
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
      const sessionResult = await client.auth.getSession();
      state.session = sessionResult.data.session || null;
    }
    state.profile = null;
    state.customer = null;
    state.electrician = null;
    state.wallet = null;

    if (!state.session) return null;

    const user = seedUser || (await client.auth.getUser()).data.user;
    if (!user) return null;

    await ensureProfile(user);

    const profileResult = await client
      .from('profiles')
      .select('*')
      .eq('id', user.id)
      .maybeSingle();

    state.profile = profileResult.data || null;

    if (state.profile && state.profile.role === 'customer') {
      await ensureCustomerRecord(state.profile.id);
      const customerResult = await client
        .from('customers')
        .select('*')
        .eq('profile_id', state.profile.id)
        .maybeSingle();
      state.customer = customerResult.data || null;
    }

    if (state.profile) {
      await ensureWalletRecord(state.profile.id);
      const walletResult = await client
        .from('wallets')
        .select('*')
        .eq('profile_id', state.profile.id)
        .maybeSingle();
      state.wallet = walletResult.data || null;
    }

    if (state.profile && state.profile.role === 'electrician') {
      const electricianResult = await client
        .from('electricians')
        .select('*, electrician_skills(category), electrician_documents(*), electrician_certifications(*)')
        .eq('profile_id', state.profile.id)
        .maybeSingle();
      state.electrician = electricianResult.data || null;
    }

    return state.profile;
  }

  function getSession() {
    return state.session;
  }

  function getCurrentProfile() {
    return state.profile;
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
    const legacyOnly = areas.length > 0 && areas.every((area) => LEGACY_LAGOS_AREAS.map((legacy) => legacy.toLowerCase()).includes(area.toLowerCase()));
    const hasPortHarcourtArea = normalizedAreas.some((area) => area.includes('port harcourt') || area.includes('phc') || area.includes('gra'));
    next.service_areas = (!areas.length || legacyOnly || !hasPortHarcourtArea)
      ? DEFAULT_SERVICE_AREAS.slice()
      : areas;
    return next;
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

  function startDispatchHeartbeat() {
    if (!config().enableClientDispatchHeartbeat) return;
    if (state.dispatchHeartbeatId) return;
    state.dispatchHeartbeatId = window.setInterval(() => {
      processDispatchQueue().catch(() => {});
    }, 60000);
    processDispatchQueue().catch(() => {});
  }

  function stopDispatchHeartbeat() {
    if (!state.dispatchHeartbeatId) return;
    window.clearInterval(state.dispatchHeartbeatId);
    state.dispatchHeartbeatId = null;
  }

  function getStatusLabel(status) {
    return STATUS_LABELS[status] || status || 'Unknown';
  }

  function getPaymentStatusLabel(status) {
    return PAYMENT_STATUS_LABELS[status] || status || 'Unknown';
  }

  function getRoleHome(role) {
    if (role === 'admin') return '/admin/dashboard';
    if (role === 'electrician') return '/electricians/dashboard';
    return '/dashboard';
  }

  function customerSignupRedirectUrl() {
    return siteUrlForPath('/login?verify=signup');
  }

  function electricianSignupRedirectUrl() {
    return siteUrlForPath('/electricians/login?verify=signup');
  }

  async function finishCustomerSignup(payload, userId) {
    const client = requireClient();
    await hydrateSession();
    const profileId = userId || (state.session && state.session.user && state.session.user.id) || (state.profile && state.profile.id);
    if (!profileId) throw new Error('Verify your email before finishing this account.');

    const profileUpdate = await client
      .from('profiles')
      .update({
        role: 'customer',
        full_name: payload.fullName,
        phone: payload.phone || null
      })
      .eq('id', profileId);
    if (profileUpdate.error) throw normalizeError(profileUpdate.error, 'Could not save your profile.');

    await ensureCustomerRecord(profileId);
    const customerUpdate = await client.from('customers')
      .update({
        primary_service_area: payload.primaryServiceArea || null,
        latitude: payload.latitude || null,
        longitude: payload.longitude || null
      })
      .eq('profile_id', profileId);
    if (customerUpdate.error) throw normalizeError(customerUpdate.error, 'Could not update your customer record.');

    await hydrateSession();
    if (payload.referralCode) {
      await linkReferralCode(payload.referralCode);
      await hydrateSession();
    }
    return {
      profile: state.profile,
      customer: state.customer
    };
  }

  async function signUpCustomer(payload) {
    const client = requireClient();
    const signUp = await client.auth.signUp({
      email: payload.email,
      password: payload.password,
      options: {
        emailRedirectTo: customerSignupRedirectUrl(),
        data: {
          requested_role: 'customer',
          full_name: payload.fullName,
          phone: payload.phone || '',
          primary_service_area: payload.primaryServiceArea || '',
          latitude: payload.latitude == null ? null : payload.latitude,
          longitude: payload.longitude == null ? null : payload.longitude
        }
      }
    });
    if (signUp.error) throw normalizeError(signUp.error, 'Customer signup failed.');
    if (signUp.data.user && signUp.data.session) {
      await finishCustomerSignup(payload, signUp.data.user.id);
    }
    return signUp.data;
  }

  async function finishElectricianSignup(payload, userId) {
    const client = requireClient();
    await hydrateSession();
    const profileId = userId || (state.session && state.session.user && state.session.user.id) || (state.profile && state.profile.id);
    if (!profileId) throw new Error('Verify your email before finishing this application.');

    await ensureProfile({
      id: profileId,
      email: payload.email,
      user_metadata: {
        requested_role: 'electrician',
        full_name: payload.fullName,
        phone: payload.phone || ''
      }
    });

    let avatarUrl = null;
    if (payload.profilePhoto) {
      avatarUrl = await uploadFile('avatars', payload.profilePhoto, profileId + '/profile');
    }

    const profileUpdate = await client.from('profiles')
      .update({
        role: 'electrician',
        full_name: payload.fullName,
        phone: payload.phone || '',
        avatar_url: avatarUrl
      })
      .eq('id', profileId);
    if (profileUpdate.error) throw normalizeError(profileUpdate.error, 'Could not save the electrician profile.');

    const electricianPayload = {
      profile_id: profileId,
      status: 'pending',
      years_experience: payload.yearsExperience || 0,
      service_areas: payload.serviceAreas || [],
      location_label: payload.locationLabel || null,
      latitude: payload.latitude || null,
      longitude: payload.longitude || null,
      bank_name: payload.bankName || '',
      bank_account_number: payload.bankAccountNumber || '',
      bank_account_name: payload.bankAccountName || '',
      availability_status: payload.availabilityStatus || 'available',
      onboarding_score: payload.onboardingValidationScore || 0,
      onboarding_review_status: payload.onboardingReviewStatus || 'pending',
      onboarding_feedback: payload.onboardingFeedback || null,
      onboarding_answers: payload.onboardingAnswers || []
    };

    let electricianInsert = await client
      .from('electricians')
      .upsert(electricianPayload, { onConflict: 'profile_id' })
      .select('*')
      .single();

    if (electricianInsert.error && isMissingSchemaError(electricianInsert.error)) {
      electricianInsert = await client
        .from('electricians')
        .upsert({
          profile_id: electricianPayload.profile_id,
          status: electricianPayload.status,
          years_experience: electricianPayload.years_experience,
          service_areas: electricianPayload.service_areas,
          location_label: electricianPayload.location_label,
          latitude: electricianPayload.latitude,
          longitude: electricianPayload.longitude,
          bank_name: electricianPayload.bank_name,
          bank_account_number: electricianPayload.bank_account_number,
          bank_account_name: electricianPayload.bank_account_name,
          availability_status: electricianPayload.availability_status
        }, { onConflict: 'profile_id' })
        .select('*')
        .single();
    }

    if (electricianInsert.error) throw normalizeError(electricianInsert.error, 'Could not create the electrician account.');

    const electricianId = electricianInsert.data.id;
    const skills = (payload.skills || []).map((skill) => ({
      electrician_id: electricianId,
      category: skill
    }));
    if (skills.length) {
      const skillsResult = await client.from('electrician_skills').upsert(skills, { onConflict: 'electrician_id,category' });
      if (skillsResult.error) throw normalizeError(skillsResult.error, 'Could not save electrician skills.');
    }

    const certifications = (payload.certifications || [])
      .filter((item) => item && item.title)
      .map((item) => ({
        electrician_id: electricianId,
        title: item.title,
        license_number: item.licenseNumber || null,
        issuer: item.issuer || null
      }));
    if (certifications.length) {
      const certificationsResult = await client.from('electrician_certifications').insert(certifications);
      if (certificationsResult.error && !isMissingSchemaError(certificationsResult.error)) {
        throw normalizeError(certificationsResult.error, 'Could not save certifications.');
      }
    }

    const documents = [];
    for (let index = 0; index < (payload.documents || []).length; index += 1) {
      const documentItem = payload.documents[index];
      let filePath = null;
      let fileUrl = null;
      if (documentItem.file) {
        if (typeof payload.onDocumentUploadProgress === 'function') {
          payload.onDocumentUploadProgress(documentItem.type, { status: 'uploading', progress: 20 });
        }
        filePath = await uploadFile('electricianDocuments', documentItem.file, profileId + '/' + electricianId + '/' + index);
        fileUrl = filePath;
        if (typeof payload.onDocumentUploadProgress === 'function') {
          payload.onDocumentUploadProgress(documentItem.type, { status: 'uploaded', progress: 100 });
        }
      }
      documents.push({
        electrician_id: electricianId,
        document_type: documentItem.type,
        file_path: filePath,
        file_url: fileUrl,
        status: 'pending'
      });
    }
    if (documents.length) {
      const documentsResult = await client.from('electrician_documents').insert(documents);
      if (documentsResult.error) throw normalizeError(documentsResult.error, 'Could not save electrician documents.');
    }

    await hydrateSession();
    return {
      profile: state.profile,
      electrician: state.electrician
    };
  }

  async function signUpElectrician(payload) {
    const client = requireClient();
    const signUp = await client.auth.signUp({
      email: payload.email,
      password: payload.password,
      options: {
        emailRedirectTo: electricianSignupRedirectUrl(),
        data: {
          requested_role: 'electrician',
          full_name: payload.fullName,
          phone: payload.phone || '',
          location_label: payload.locationLabel || '',
          years_experience: payload.yearsExperience || 0,
          availability_status: payload.availabilityStatus || 'available',
          service_areas: payload.serviceAreas || [],
          latitude: payload.latitude == null ? null : payload.latitude,
          longitude: payload.longitude == null ? null : payload.longitude,
          bank_name: payload.bankName || '',
          bank_account_number: payload.bankAccountNumber || '',
          bank_account_name: payload.bankAccountName || '',
          skills: payload.skills || [],
          onboarding_score: payload.onboardingValidationScore || 0,
          onboarding_review_status: payload.onboardingReviewStatus || 'pending',
          onboarding_feedback: payload.onboardingFeedback || null,
          onboarding_answers: payload.onboardingAnswers || []
        }
      }
    });
    if (signUp.error) throw normalizeError(signUp.error, 'Electrician signup failed.');
    if (signUp.data.user && signUp.data.session) {
      await finishElectricianSignup(payload, signUp.data.user.id);
    }
    return signUp.data;
  }

  async function signIn(email, password) {
    const client = requireClient();
    const result = await client.auth.signInWithPassword({ email, password });
    if (result.error) throw normalizeError(result.error, 'Login failed.');
    await hydrateSession(result.data);
    return result.data;
  }

  async function requestPasswordReset(email, redirectTo) {
    const client = requireClient();
    const result = await client.auth.resetPasswordForEmail(email, {
      redirectTo: siteUrlForPath(redirectTo || '/login?reset=1')
    });
    if (result.error) throw normalizeError(result.error, 'Could not send the reset link.');
    return true;
  }

  async function verifySignupOtp(email, token) {
    const client = requireClient();
    const result = await client.auth.verifyOtp({
      email: String(email || '').trim(),
      token: String(token || '').replace(/\D/g, ''),
      type: 'signup'
    });
    if (result.error) throw normalizeError(result.error, 'Could not verify this email code.');
    await hydrateSession();
    return result.data;
  }

  async function resendSignupOtp(email, redirectTo) {
    const client = requireClient();
    const result = await client.auth.resend({
      type: 'signup',
      email: String(email || '').trim(),
      options: {
        emailRedirectTo: siteUrlForPath(redirectTo || '/login?verify=signup')
      }
    });
    if (result.error) throw normalizeError(result.error, 'Could not resend the email code.');
    return true;
  }

  async function updatePassword(nextPassword) {
    const client = requireClient();
    if (!nextPassword || nextPassword.length < 8) {
      throw new Error('Enter a new password with at least 8 characters.');
    }
    const result = await client.auth.updateUser({ password: nextPassword });
    if (result.error) throw normalizeError(result.error, 'Could not update the password.');
    await hydrateSession();
    return result.data;
  }

  async function signOut() {
    const client = ensureClient();
    if (!client) return;
    await client.auth.signOut();
    stopDispatchHeartbeat();
    state.session = null;
    state.profile = null;
    state.customer = null;
    state.electrician = null;
    state.wallet = null;
  }

  async function updateProfile(fields) {
    const client = ensureClient();
    if (!state.profile) throw new Error('No active profile');
    const result = await client
      .from('profiles')
      .update(fields)
      .eq('id', state.profile.id)
      .select('*')
      .single();
    if (result.error) throw normalizeError(result.error, 'Profile update failed.');
    state.profile = result.data;
    return state.profile;
  }

  async function ensureProfile(user) {
    const client = ensureClient();
    const profilePayload = {
      id: user.id,
      role: (user.user_metadata && user.user_metadata.requested_role) || 'customer',
      full_name: (user.user_metadata && user.user_metadata.full_name) || user.email || '',
      phone: (user.user_metadata && user.user_metadata.phone) || null
    };

    let result = await client.rpc('ensure_app_account_for_current_user');
    if (result.error && isMissingSchemaError(result.error)) {
      result = await client.rpc('ensure_profile_for_current_user');
    }
    if (result.error) throw normalizeError(result.error, 'Could not load your profile.');
    return result.data || profilePayload;
  }

  async function ensureCustomerRecord(profileId) {
    const client = ensureClient();
    const check = await client
      .from('customers')
      .select('id')
      .eq('profile_id', profileId)
      .maybeSingle();
    if (check.error) throw normalizeError(check.error, 'Could not load your customer account.');
    if (check.data) return check.data;
    const created = await client
      .from('customers')
      .insert({ profile_id: profileId })
      .select('id')
      .single();
    if (created.error) throw normalizeError(created.error, 'Could not create your customer account.');
    return created.data;
  }

  async function ensureWalletRecord(profileId) {
    const client = ensureClient();
    const check = await client
      .from('wallets')
      .select('id')
      .eq('profile_id', profileId)
      .maybeSingle();
    if (check.error) throw normalizeError(check.error, 'Could not load your wallet.');
    if (check.data) return check.data;
    const created = await client
      .from('wallets')
      .insert({ profile_id: profileId })
      .select('id')
      .single();
    if (created.error) throw normalizeError(created.error, 'Could not create your wallet.');
    return created.data;
  }

  function validateFile(file, options) {
    if (!file) throw new Error('No file selected.');
    const maxBytes = options && options.maxBytes ? options.maxBytes : 5 * 1024 * 1024;
    const acceptedPrefixes = options && options.acceptedPrefixes ? options.acceptedPrefixes : [];
    const acceptedTypes = options && options.acceptedTypes ? options.acceptedTypes : [];
    if (file.size > maxBytes) {
      throw new Error('File is too large. Keep uploads under ' + Math.round(maxBytes / (1024 * 1024)) + 'MB.');
    }
    if (acceptedTypes.length && acceptedTypes.indexOf(file.type) === -1 && !acceptedPrefixes.some((prefix) => file.type.indexOf(prefix) === 0)) {
      throw new Error('Unsupported file type.');
    }
  }

  async function uploadFile(bucketKey, file, prefix) {
    const client = ensureClient();
    validateFile(file, {
      maxBytes: bucketKey === 'paymentProofs' ? 8 * 1024 * 1024 : 5 * 1024 * 1024,
      acceptedTypes: ['application/pdf'],
      acceptedPrefixes: ['image/']
    });
    const bucket = (config().storageBuckets && config().storageBuckets[bucketKey]) || STORAGE_PATHS[bucketKey] || bucketKey;
    const ext = file.name && file.name.includes('.') ? file.name.slice(file.name.lastIndexOf('.')) : '';
    const filePath = prefix + '-' + Date.now() + ext;
    const uploadResult = await client.storage.from(bucket).upload(filePath, file, {
      cacheControl: '3600',
      upsert: false
    });
    if (uploadResult.error) throw normalizeError(uploadResult.error, 'File upload failed.');
    return uploadResult.data.path;
  }

  async function listCustomerJobs() {
    const client = ensureClient();
    const customerId = state.customer && state.customer.id;
    if (!customerId) {
      const guest = getGuestAccess();
      if (!guest || !guest.jobId || !guest.accessToken) return [];
      try {
        return [await getGuestJob(guest.jobId, guest.accessToken)];
      } catch (error) {
        clearGuestAccess();
        return [];
      }
    }
    const result = await client
      .from('jobs')
      .select(`
        *,
        assigned_electrician:electricians(
          *,
          profile:profiles(full_name, phone, avatar_url),
          electrician_skills(category)
        ),
        guest_customer:guest_customers(*),
        job_photos(*),
        job_quotes:job_quotes!job_quotes_job_id_fkey(*, quote_items(*)),
        job_payments(*),
        job_timeline(*),
        ratings(*)
      `)
      .eq('customer_id', customerId)
      .order('created_at', { ascending: false });
    if (result.error) throw normalizeError(result.error, 'Could not load customer jobs.');
    const jobs = (result.data || []).map(normalizeJob);
    await Promise.all(jobs.map(hydrateProtectedAssets));
    return jobs;
  }

  async function listElectricianJobs() {
    const client = ensureClient();
    const electricianId = state.electrician && state.electrician.id;
    if (!electricianId) return [];
    const result = await client
      .from('jobs')
      .select(`
        *,
        customer:customers(*, profile:profiles(full_name, phone)),
        guest_customer:guest_customers(*),
        job_photos(*),
        job_quotes:job_quotes!job_quotes_job_id_fkey(*, quote_items(*)),
        job_payments(*),
        job_timeline(*),
        ratings(*)
      `)
      .eq('assigned_electrician_id', electricianId)
      .order('created_at', { ascending: false });
    if (result.error) throw normalizeError(result.error, 'Could not load assigned jobs.');
    const jobs = (result.data || []).map(normalizeJob);
    await Promise.all(jobs.map(hydrateProtectedAssets));
    return jobs;
  }

  async function listAdminJobs(options) {
    const client = ensureClient();
    const result = await client
      .from('jobs')
      .select(`
        *,
        customer:customers(*, profile:profiles(full_name, phone)),
        guest_customer:guest_customers(*),
        assigned_electrician:electricians(
          *,
          profile:profiles(full_name, phone, avatar_url)
        ),
        job_quotes:job_quotes!job_quotes_job_id_fkey(*, quote_items(*)),
        job_payments(*),
        job_timeline(*),
        ratings(*)
      `)
      .order('created_at', { ascending: false });
    if (result.error) throw normalizeError(result.error, 'Could not load admin jobs.');
    const jobs = (result.data || []).map(normalizeJob);
    if (!options || options.includeProtectedAssets !== false) {
      await Promise.all(jobs.map(hydrateProtectedAssets));
    }
    return jobs;
  }

  async function getJob(jobId) {
    const client = ensureClient();
    const guest = getGuestAccess();
    if (!state.profile && guest && guest.jobId === jobId && guest.accessToken) {
      return getGuestJob(jobId, guest.accessToken);
    }
    const result = await client
      .from('jobs')
      .select(`
        *,
        customer:customers(*, profile:profiles(full_name, phone)),
        guest_customer:guest_customers(*),
        assigned_electrician:electricians(
          *,
          profile:profiles(full_name, phone, avatar_url),
          electrician_skills(category),
          electrician_documents(*)
        ),
        job_photos(*),
        job_quotes:job_quotes!job_quotes_job_id_fkey(*, quote_items(*)),
        job_payments(*),
        job_timeline(*),
        ratings(*)
      `)
      .eq('id', jobId)
      .single();
    if (result.error) throw normalizeError(result.error, 'Could not load the job details.');
    return hydrateProtectedAssets(normalizeJob(result.data));
  }

  async function previewMatches(input) {
    const client = ensureClient();
    const result = await client.rpc('find_matching_electricians', {
      p_service_area: input.serviceArea || null,
      p_issue_category: input.issueCategory,
      p_latitude: input.latitude || null,
      p_longitude: input.longitude || null,
      p_limit: input.limit || 5
    });
    if (result.error) throw normalizeError(result.error, 'Could not load the nearest available VoltFriqs.');
    return (result.data || []).map((row) => ({
      id: row.electrician_id,
      profileId: row.profile_id,
      name: row.full_name,
      phone: row.phone,
      avatar: row.avatar_url,
      serviceAreas: row.service_areas || [],
      experience: row.years_experience,
      rating: Number(row.average_rating || 0),
      jobsCompleted: Number(row.completed_jobs || 0),
      distance: Number(row.distance_km || 0).toFixed(1),
      averageResponseSeconds: row.average_response_seconds == null ? null : Number(row.average_response_seconds),
      lastAssignedAt: row.last_assigned_at || null,
      levelBadge: row.level_badge || 'Verified Pro',
      watchlist: !!row.watchlist,
      negativeRatingCount: Number(row.negative_rating_count || 0),
      levelRank: Number(row.level_rank || 1)
    }));
  }

  async function createBooking(input) {
    const client = ensureClient();
    if (!state.profile || state.profile.role !== 'customer') {
      throw new Error('Please sign in with a customer account before booking.');
    }
    await ensureCustomerRecord(state.profile.id);
    const photoPaths = [];
    for (let index = 0; index < (input.photos || []).length; index += 1) {
      photoPaths.push(await uploadFile('jobPhotos', input.photos[index], 'job-photos/' + state.profile.id + '/' + index));
    }
    const result = await client.rpc('create_customer_job', {
      p_service_area: input.serviceArea,
      p_location_label: input.locationLabel || input.serviceArea,
      p_latitude: input.latitude || null,
      p_longitude: input.longitude || null,
      p_issue_category: input.issueCategory,
      p_urgency: normalizeUrgency(input.urgency),
      p_customer_note: input.note || '',
      p_requires_assessment: !!input.requiresAssessment,
      p_material_handling: input.materialHandling || 'voltfriq_supplied',
      p_photo_paths: photoPaths
    });
    if (result.error) throw normalizeError(result.error, 'Could not create the booking.');
    await saveCustomerAddress({
      label: input.locationLabel || input.serviceArea || 'Saved address',
      addressText: input.locationLabel || input.serviceArea,
      locationLabel: input.locationLabel || input.serviceArea,
      latitude: input.latitude || null,
      longitude: input.longitude || null
    }).catch(() => {});
    return getJob(result.data.id);
  }

  async function createGuestBooking(input) {
    const client = ensureClient();
    const phone = String(input.phone || '').trim();
    if (!phone) throw new Error('Enter your mobile number before submitting.');
    const uploadId = (window.crypto && window.crypto.randomUUID ? window.crypto.randomUUID() : Date.now().toString());
    const photoPaths = [];
    for (let index = 0; index < (input.photos || []).length; index += 1) {
      photoPaths.push(await uploadFile('jobPhotos', input.photos[index], 'guest/' + uploadId + '/' + index));
    }
    const result = await client.rpc('create_guest_customer_job', {
      p_phone: phone,
      p_service_area: input.serviceArea,
      p_location_label: input.locationLabel || input.serviceArea,
      p_latitude: input.latitude || null,
      p_longitude: input.longitude || null,
      p_issue_category: input.issueCategory,
      p_urgency: normalizeUrgency(input.urgency),
      p_customer_note: input.note || '',
      p_requires_assessment: !!input.requiresAssessment,
      p_material_handling: input.materialHandling || 'voltfriq_supplied',
      p_photo_paths: photoPaths
    });
    if (result.error) throw normalizeError(result.error, 'Could not create the guest booking.');
    const payload = result.data || {};
    const jobRow = payload.job || payload;
    const accessToken = payload.access_token || payload.accessToken;
    if (!jobRow || !jobRow.id || !accessToken) {
      throw new Error('Booking was created, but tracking access was not returned.');
    }
    saveGuestAccess({ jobId: jobRow.id, accessToken, phone });
    await saveCustomerAddress({
      label: input.locationLabel || input.serviceArea || 'Saved address',
      addressText: input.locationLabel || input.serviceArea,
      locationLabel: input.locationLabel || input.serviceArea,
      latitude: input.latitude || null,
      longitude: input.longitude || null
    }).catch(() => {});
    const normalized = await hydrateProtectedAssets(normalizeJob(jobRow));
    normalized.guestAccessToken = accessToken;
    return normalized;
  }

  async function getGuestJob(jobId, accessToken) {
    const client = ensureClient();
    const result = await client.rpc('get_guest_job', {
      p_job_id: jobId,
      p_access_token: accessToken
    });
    if (result.error) throw normalizeError(result.error, 'Could not load guest job tracking.');
    return hydrateProtectedAssets(normalizeJob(result.data));
  }

  async function acceptAssignedJob(jobId) {
    const client = ensureClient();
    const result = await client.rpc('electrician_accept_job', { p_job_id: jobId });
    if (result.error) throw normalizeError(result.error, 'Could not accept the job.');
    return getJob(result.data.id);
  }

  async function rejectAssignedJob(jobId) {
    const client = ensureClient();
    const result = await client.rpc('electrician_reject_job', { p_job_id: jobId });
    if (result.error) throw normalizeError(result.error, 'Could not reject the job.');
    return getJob(result.data.id);
  }

  async function updateJobStatus(jobId, nextStatus, note, metadata) {
    const client = ensureClient();
    const guest = getGuestAccess();
    if (!state.profile && guest && guest.jobId === jobId) {
      const guestResult = await client.rpc('update_guest_job_status', {
        p_job_id: jobId,
        p_access_token: guest.accessToken,
        p_next_status: nextStatus,
        p_note: note || null,
        p_metadata: metadata || {}
      });
      if (guestResult.error) throw normalizeError(guestResult.error, 'Could not update the job status.');
      return getGuestJob(jobId, guest.accessToken);
    }
    const result = await client.rpc('set_job_status', {
      p_job_id: jobId,
      p_next_status: nextStatus,
      p_note: note || null,
      p_metadata: metadata || {}
    });
    if (result.error) throw normalizeError(result.error, 'Could not update the job status.');
    return getJob(result.data.id);
  }

  async function submitQuote(jobId, quote) {
    const client = ensureClient();
    const items = (quote.items || []).map((item) => ({
      item_type: item.itemType || 'labor',
      description: item.description,
      quantity: item.quantity || 1,
      unit_price: item.unitPrice || 0
    }));
    const result = await client.rpc('submit_job_quote', {
      p_job_id: jobId,
      p_findings: quote.findings || '',
      p_measurements: quote.measurements || '',
      p_items: items
    });
    if (result.error) throw normalizeError(result.error, 'Could not submit the quote.');
    return result.data;
  }

  async function acceptQuote(jobId) {
    return updateJobStatus(jobId, 'quote_accepted', 'Customer accepted the quote.');
  }

  async function submitPaymentProof(jobId, payload) {
    const client = ensureClient();
    const guest = getGuestAccess();
    let proofPath = null;
    if (payload.file) {
      const prefix = !state.profile && guest && guest.jobId === jobId
        ? 'guest/' + jobId + '/' + payload.paymentType
        : 'payments/' + jobId + '/' + payload.paymentType;
      proofPath = await uploadFile('paymentProofs', payload.file, prefix);
    }
    if (!state.profile && guest && guest.jobId === jobId) {
      const guestResult = await client.rpc('submit_guest_payment_proof', {
        p_job_id: jobId,
        p_access_token: guest.accessToken,
        p_payment_type: payload.paymentType,
        p_amount: payload.amount || 0,
        p_reference: payload.reference || '',
        p_proof_path: proofPath
      });
      if (guestResult.error) throw normalizeError(guestResult.error, 'Could not submit payment proof.');
      return guestResult.data;
    }
    const result = await client.rpc('submit_payment_proof', {
      p_job_id: jobId,
      p_payment_type: payload.paymentType,
      p_amount: payload.amount || 0,
      p_reference: payload.reference || '',
      p_proof_path: proofPath
    });
    if (result.error) throw normalizeError(result.error, 'Could not submit payment proof.');
    return result.data;
  }

  async function verifyPayment(paymentId, approved, adminNote) {
    const client = ensureClient();
    const result = await client.rpc('verify_job_payment', {
      p_payment_id: paymentId,
      p_approved: !!approved,
      p_admin_note: adminNote || null
    });
    if (result.error) throw normalizeError(result.error, 'Could not verify the payment.');
    return result.data;
  }

  async function setManualAssignment(jobId, electricianId) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.rpc('dispatch_job', {
      p_job_id: jobId,
      p_manual_electrician_id: electricianId
    });
    if (result.error) throw normalizeError(result.error, 'Could not reassign the VoltFriq.');
    return getJob(result.data.id);
  }

  async function rerunAutomaticAssignment(jobId) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.rpc('dispatch_job', {
      p_job_id: jobId,
      p_manual_electrician_id: null
    });
    if (result.error) throw normalizeError(result.error, 'Could not assign the next available VoltFriq.');
    return getJob(result.data.id);
  }

  async function setElectricianStatus(electricianId, status) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.rpc('admin_set_electrician_status', {
      p_electrician_id: electricianId,
      p_status: status,
      p_reason: status === 'suspended' ? 'Suspended by admin.' : null
    });
    if (result.error) throw normalizeError(result.error, 'Could not update the electrician status.');
    return result.data;
  }

  async function setElectricianWatchlist(electricianId, watchlist, reason) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.rpc('admin_set_electrician_watchlist', {
      p_electrician_id: electricianId,
      p_watchlist: !!watchlist,
      p_reason: reason || null
    });
    if (result.error) throw normalizeError(result.error, 'Could not update the VoltFriq watchlist status.');
    return result.data;
  }

  async function updateCurrentElectrician(fields) {
    const client = ensureClient();
    if (!state.electrician) throw new Error('No electrician profile loaded.');
    const result = await client
      .from('electricians')
      .update(fields)
      .eq('id', state.electrician.id)
      .select('*, electrician_skills(category), electrician_documents(*)')
      .single();
    if (result.error) throw normalizeError(result.error, 'Could not update the electrician profile.');
    state.electrician = result.data;
    return state.electrician;
  }

  async function replaceCurrentElectricianSkills(skills) {
    const client = ensureClient();
    if (!state.electrician) throw new Error('No electrician profile loaded.');

    const removeResult = await client
      .from('electrician_skills')
      .delete()
      .eq('electrician_id', state.electrician.id);
    if (removeResult.error) throw normalizeError(removeResult.error, 'Could not update skills.');

    const nextSkills = (skills || []).map((category) => ({
      electrician_id: state.electrician.id,
      category
    }));
    if (nextSkills.length) {
      const addResult = await client.from('electrician_skills').insert(nextSkills);
      if (addResult.error) throw normalizeError(addResult.error, 'Could not save the selected skills.');
    }

    const refreshed = await client
      .from('electricians')
      .select('*, electrician_skills(category), electrician_documents(*)')
      .eq('id', state.electrician.id)
      .single();
    if (refreshed.error) throw normalizeError(refreshed.error, 'Could not refresh the electrician profile.');

    state.electrician = refreshed.data;
    return state.electrician;
  }

  async function listElectricians(filter, options) {
    const client = ensureClient();
    let query = client
      .from('electricians')
      .select('*, profile:profiles(full_name, phone, avatar_url), electrician_skills(category), electrician_documents(*), electrician_certifications(*)')
      .order('created_at', { ascending: false });
    if (filter && filter !== 'all') {
      query = query.eq('status', filter);
    }
    const result = await query;
    if (result.error) throw normalizeError(result.error, 'Could not load electricians.');
    const electricians = result.data || [];
    if (!options || options.includeDocumentUrls !== false) {
      await Promise.all(electricians.map(hydrateElectricianDocuments));
    }
    return electricians;
  }

  async function hydrateElectricianDocuments(electrician) {
    if (!electrician) return electrician;
    const docs = electrician.electrician_documents || [];
    await Promise.all(docs.map(async (documentItem) => {
      if (documentItem.file_path && !documentItem.signedUrl) {
        documentItem.signedUrl = await createSignedStorageUrl('electricianDocuments', documentItem.file_path);
      }
    }));
    return electrician;
  }

  async function getWalletSummary() {
    const client = ensureClient();
    if (!state.profile) return { wallet: null, transactions: [] };
    await ensureWalletRecord(state.profile.id);
    const walletResult = await client
      .from('wallets')
      .select('*')
      .eq('profile_id', state.profile.id)
      .single();
    if (walletResult.error) throw normalizeError(walletResult.error, 'Could not load wallet balance.');
    state.wallet = walletResult.data;

    const txResult = await client
      .from('wallet_transactions')
      .select('*')
      .eq('profile_id', state.profile.id)
      .order('created_at', { ascending: false })
      .limit(20);
    if (txResult.error) throw normalizeError(txResult.error, 'Could not load wallet activity.');
    return {
      wallet: state.wallet,
      transactions: txResult.data || []
    };
  }

  async function getReferralSummary() {
    const client = ensureClient();
    if (!state.profile) return { profile: null, referrals: [] };
    const result = await client
      .from('referrals')
      .select('*')
      .or('referrer_profile_id.eq.' + state.profile.id + ',referred_profile_id.eq.' + state.profile.id)
      .order('created_at', { ascending: false });
    if (result.error) throw normalizeError(result.error, 'Could not load referrals.');
    return {
      profile: state.profile,
      referrals: result.data || []
    };
  }

  async function linkReferralCode(referralCode) {
    const client = ensureClient();
    if (!referralCode) return null;
    const result = await client.rpc('link_referral_code', {
      p_referral_code: referralCode.trim().toUpperCase()
    });
    if (result.error) throw normalizeError(result.error, 'Could not apply the referral code.');
    return result.data;
  }

  async function createDispute(jobId, issueType, details) {
    const client = ensureClient();
    const result = await client.rpc('create_dispute', {
      p_job_id: jobId,
      p_issue_type: issueType,
      p_details: details || null
    });
    if (result.error) throw normalizeError(result.error, 'Could not report the issue.');
    return result.data;
  }

  async function listDisputes() {
    const client = ensureClient();
    if (!state.profile) return [];
    let query = client
      .from('disputes')
      .select(`
        *,
        jobs(ticket, service_area, status),
        customer:customers(*, profile:profiles(full_name, phone)),
        electrician:electricians(*, profile:profiles(full_name, phone))
      `)
      .order('created_at', { ascending: false });
    if (state.profile.role === 'customer') {
      query = query.eq('customer_id', state.customer && state.customer.id);
    } else if (state.profile.role === 'electrician') {
      query = query.eq('electrician_id', state.electrician && state.electrician.id);
    }
    const result = await query;
    if (result.error) throw normalizeError(result.error, 'Could not load disputes.');
    return result.data || [];
  }

  async function resolveDispute(disputeId, status, resolutionAction, resolutionNote) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.rpc('resolve_dispute', {
      p_dispute_id: disputeId,
      p_status: status,
      p_resolution_action: resolutionAction || null,
      p_resolution_note: resolutionNote || null
    });
    if (result.error) throw normalizeError(result.error, 'Could not resolve the dispute.');
    return result.data;
  }

  async function listAppeals() {
    const client = ensureClient();
    if (!state.profile) return [];
    let query = client
      .from('electrician_appeals')
      .select(`
        *,
        electrician:electricians(
          *,
          profile:profiles(full_name, phone, avatar_url),
          electrician_skills(category)
        )
      `)
      .order('created_at', { ascending: false });
    if (state.profile.role === 'electrician') {
      query = query.eq('electrician_id', state.electrician && state.electrician.id);
    }
    const result = await query;
    if (result.error) throw normalizeError(result.error, 'Could not load suspension appeals.');
    return result.data || [];
  }

  async function submitElectricianAppeal(payload) {
    const client = ensureClient();
    let supportingPath = null;
    if (payload && payload.file) {
      supportingPath = await uploadFile('electricianDocuments', payload.file, 'appeals/' + (state.electrician && state.electrician.id || state.profile.id));
    }
    const result = await client.rpc('submit_electrician_appeal', {
      p_appeal_note: payload && payload.note ? payload.note : '',
      p_supporting_file_path: supportingPath
    });
    if (result.error) throw normalizeError(result.error, 'Could not submit your appeal.');
    return result.data;
  }

  async function resolveElectricianAppeal(appealId, approved, adminNote) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.rpc('resolve_electrician_appeal', {
      p_appeal_id: appealId,
      p_approved: !!approved,
      p_admin_note: adminNote || null
    });
    if (result.error) throw normalizeError(result.error, 'Could not resolve the appeal.');
    return result.data;
  }

  async function listPaymentsNeedingVerification() {
    const client = ensureClient();
    const result = await client
      .from('job_payments')
      .select('*, jobs(*)')
      .eq('status', 'submitted')
      .order('created_at', { ascending: false });
    if (result.error) throw normalizeError(result.error, 'Could not load the payment verification queue.');
    return result.data || [];
  }

  async function markWorkStarted(jobId) {
    return updateJobStatus(jobId, 'work_in_progress', 'VoltFriq started work.');
  }

  async function markWorkCompleted(jobId) {
    return updateJobStatus(jobId, 'electrician_completed', 'VoltFriq marked work complete.');
  }

  async function markCustomerConfirmed(jobId) {
    return updateJobStatus(jobId, 'customer_confirmed', 'Customer confirmed the work.');
  }

  async function markPayoutComplete(jobId) {
    requireRole('admin');
    return updateJobStatus(jobId, 'payout_complete', 'Admin released payout.');
  }

  async function submitRating(jobId, score, comment, behaviorTags) {
    const client = ensureClient();
    const result = await client.rpc('submit_rating', {
      p_job_id: jobId,
      p_score: score,
      p_comment: comment || null,
      p_behavior_tags: behaviorTags || []
    });
    if (result.error) throw normalizeError(result.error, 'Could not save the rating.');
    return result.data;
  }

  async function submitCustomerReview(jobId, score, comment, behaviorTags) {
    const client = ensureClient();
    const result = await client.rpc('submit_customer_review', {
      p_job_id: jobId,
      p_score: score,
      p_comment: comment || null,
      p_behavior_tags: behaviorTags || []
    });
    if (result.error) throw normalizeError(result.error, 'Could not save the customer review.');
    return result.data;
  }

  async function saveSettings(nextSettings) {
    const client = ensureClient();
    const current = await loadSettings();
    const payload = Object.assign({}, current, nextSettings);
    const query = current.id
      ? client.from('admin_settings').update(payload).eq('id', current.id).select('*').single()
      : client.from('admin_settings').insert(payload).select('*').single();
    const result = await query;
    if (result.error) throw normalizeError(result.error, 'Could not save admin settings.');
    state.settings = normalizeSettings(Object.assign({}, DEFAULT_SETTINGS, result.data));
    return state.settings;
  }

  async function saveExpertiseCategory(label, currentLabel) {
    requireRole('admin');
    const client = ensureClient();
    const cleanLabel = String(label || '').trim();
    if (!cleanLabel) throw new Error('Enter an expertise category.');
    if (currentLabel && currentLabel !== cleanLabel) {
      const existing = await client.from('expertise_categories').delete().eq('label', currentLabel);
      if (existing.error && !isMissingSchemaError(existing.error)) throw normalizeError(existing.error, 'Could not update expertise category.');
    }
    const result = await client
      .from('expertise_categories')
      .upsert({ label: cleanLabel }, { onConflict: 'label' })
      .select('*')
      .single();
    let categories;
    if (result.error && isMissingSchemaError(result.error)) {
      categories = Array.from(new Set([].concat(state.settings.issue_categories || [], [cleanLabel]).filter(Boolean)));
      state.expertiseCategories = categories.slice();
    } else if (result.error) {
      throw normalizeError(result.error, 'Could not save expertise category.');
    } else {
      categories = await loadExpertiseCategories();
    }
    await saveSettings({ issue_categories: categories });
    return result.data || { label: cleanLabel };
  }

  async function removeExpertiseCategory(label) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.from('expertise_categories').delete().eq('label', label);
    let categories;
    if (result.error && isMissingSchemaError(result.error)) {
      categories = (state.settings.issue_categories || []).filter((item) => item !== label);
      state.expertiseCategories = categories.slice();
    } else if (result.error) {
      throw normalizeError(result.error, 'Could not remove expertise category.');
    } else {
      categories = await loadExpertiseCategories();
    }
    await saveSettings({ issue_categories: categories });
    return true;
  }

  async function addJobMessage(jobId, senderRole, content, messageType) {
    const client = ensureClient();
    if (!state.profile) throw new Error('No active profile');
    const result = await client
      .from('job_messages')
      .insert({
        job_id: jobId,
        sender_profile_id: state.profile.id,
        sender_role: senderRole,
        message_type: messageType || 'text',
        content: content
      })
      .select('*')
      .single();
    if (result.error) throw normalizeError(result.error, 'Could not send the message.');
    return result.data;
  }

  async function getJobMessages(jobId) {
    const client = ensureClient();
    const result = await client
      .from('job_messages')
      .select('*, sender:profiles(full_name)')
      .eq('job_id', jobId)
      .order('created_at', { ascending: true });
    if (result.error) throw normalizeError(result.error, 'Could not load job messages.');
    return result.data || [];
  }

  function subscribeToJob(jobId, callback) {
    const client = ensureClient();
    if (!client) return { unsubscribe() {} };
    const guest = getGuestAccess();
    if (!state.profile && guest && guest.jobId === jobId && guest.accessToken) {
      let closed = false;
      const refresh = async () => {
        if (closed) return;
        callback(await getGuestJob(jobId, guest.accessToken));
      };
      const channel = client.channel('guest-job-watch-' + jobId)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'jobs', filter: 'id=eq.' + jobId }, refresh)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'job_quotes', filter: 'job_id=eq.' + jobId }, refresh)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'job_payments', filter: 'job_id=eq.' + jobId }, refresh)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'job_timeline', filter: 'job_id=eq.' + jobId }, refresh)
        .subscribe();
      const pollId = window.setInterval(() => refresh().catch(() => {}), 12000);
      return {
        unsubscribe() {
          closed = true;
          window.clearInterval(pollId);
          client.removeChannel(channel);
        }
      };
    }
    const channel = client.channel('job-watch-' + jobId)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'jobs', filter: 'id=eq.' + jobId }, async () => {
        callback(await getJob(jobId));
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_quotes', filter: 'job_id=eq.' + jobId }, async () => {
        callback(await getJob(jobId));
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_payments', filter: 'job_id=eq.' + jobId }, async () => {
        callback(await getJob(jobId));
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_timeline', filter: 'job_id=eq.' + jobId }, async () => {
        callback(await getJob(jobId));
      })
      .subscribe();
    return {
      unsubscribe() {
        client.removeChannel(channel);
      }
    };
  }

  function subscribeToMessages(jobId, callback) {
    const client = ensureClient();
    if (!client) return { unsubscribe() {} };
    const channel = client.channel('job-messages-' + jobId)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_messages', filter: 'job_id=eq.' + jobId }, async () => {
        callback(await getJobMessages(jobId));
      })
      .subscribe();
    return {
      unsubscribe() {
        client.removeChannel(channel);
      }
    };
  }

  function subscribeToNotifications(callback) {
    const client = ensureClient();
    if (!client || !state.profile) return { unsubscribe() {} };
    const channel = client.channel('notifications-' + state.profile.id)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'notifications', filter: 'profile_id=eq.' + state.profile.id }, async () => {
        callback(await listNotifications());
      })
      .subscribe();
    return {
      unsubscribe() {
        client.removeChannel(channel);
      }
    };
  }

  function subscribeToPortalFeed(callback) {
    const client = ensureClient();
    if (!client) return { unsubscribe() {} };
    const channel = client.channel('portal-feed-' + Math.random().toString(36).slice(2, 8))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'jobs' }, callback)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'electricians' }, callback)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_payments' }, callback)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'ratings' }, callback)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'electrician_appeals' }, callback)
      .subscribe();
    return {
      unsubscribe() {
        client.removeChannel(channel);
      }
    };
  }

  async function listNotifications() {
    const client = ensureClient();
    if (!state.profile) return [];
    const result = await client
      .from('notifications')
      .select('*')
      .eq('profile_id', state.profile.id)
      .order('created_at', { ascending: false })
      .limit(20);
    if (result.error) throw normalizeError(result.error, 'Could not load notifications.');
    return result.data || [];
  }

  async function markNotificationRead(notificationId) {
    const client = ensureClient();
    const result = await client
      .from('notifications')
      .update({ read_at: new Date().toISOString() })
      .eq('id', notificationId);
    if (result.error) throw normalizeError(result.error, 'Could not mark the notification as read.');
  }

  async function processDispatchQueue() {
    const client = ensureClient();
    if (!client || !state.session) return 0;
    const result = await client.rpc('process_dispatch_queue');
    if (result.error) throw normalizeError(result.error, 'Could not process the matching queue.');
    return Number(result.data || 0);
  }

  function normalizeUrgency(urgency) {
    if (urgency === 'this-week' || urgency === 'scheduled') return 'this_week';
    return urgency || 'today';
  }

  function formatCurrency(amount) {
    return '₦' + Number(amount || 0).toLocaleString();
  }

  function getPublicStorageUrl(bucketKey, path) {
    const client = ensureClient();
    if (!client || !path) return '';
    const bucket = (config().storageBuckets && config().storageBuckets[bucketKey]) || STORAGE_PATHS[bucketKey] || bucketKey;
    const result = client.storage.from(bucket).getPublicUrl(path);
    return result && result.data ? result.data.publicUrl || '' : '';
  }

  async function createSignedStorageUrl(bucketKey, path, expiresIn) {
    const client = ensureClient();
    if (!client || !path) return '';
    const bucket = (config().storageBuckets && config().storageBuckets[bucketKey]) || STORAGE_PATHS[bucketKey] || bucketKey;
    const result = await client.storage.from(bucket).createSignedUrl(path, expiresIn || 900);
    if (result.error) return '';
    return result.data && result.data.signedUrl ? result.data.signedUrl : '';
  }

  async function hydrateProtectedAssets(job) {
    if (!job) return job;
    await Promise.all((job.photos || []).map(async (photo) => {
      if (photo.file_path) {
        photo.url = await createSignedStorageUrl('jobPhotos', photo.file_path);
      }
    }));
    if (job.latestPayment && job.latestPayment.proof_path) {
      job.latestPayment.proofUrl = await createSignedStorageUrl('paymentProofs', job.latestPayment.proof_path);
    }
    return job;
  }

  function mapQuote(rawQuotes) {
    const quotes = rawQuotes || [];
    const current = quotes.length ? quotes[quotes.length - 1] : null;
    if (!current) {
      return {
        id: null,
        findings: '',
        measurements: '',
        items: [],
        laborTotal: 0,
        materialTotal: 0,
        total: 0
      };
    }
    const items = (current.quote_items || []).map((item) => ({
      id: item.id,
      itemType: item.item_type,
      description: item.description,
      quantity: Number(item.quantity || 1),
      unitPrice: Number(item.unit_price || 0),
      lineTotal: Number(item.line_total || 0)
    }));
    return {
      id: current.id,
      findings: current.findings || '',
      measurements: current.measurements || '',
      items,
      laborTotal: Number(current.labor_total || 0),
      materialTotal: Number(current.material_total || 0),
      total: Number(current.grand_total || 0)
    };
  }

  function normalizeJob(row) {
    const customerProfile = row.customer && row.customer.profile ? row.customer.profile : {};
    const guestCustomer = row.guest_customer || row.guestCustomer || null;
    const electricianProfile = row.assigned_electrician && row.assigned_electrician.profile ? row.assigned_electrician.profile : {};
    const quote = mapQuote(row.job_quotes);
    const payments = (row.job_payments || []).slice().sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    const timeline = (row.job_timeline || []).slice().sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    const reviews = row.ratings || [];
    const electricianReview = reviews.find((rating) => rating.review_direction === 'customer_to_electrician') || reviews[0] || null;
    const customerReview = reviews.find((rating) => rating.review_direction === 'electrician_to_customer') || null;
    const lastTimeline = timeline.length ? timeline[timeline.length - 1] : null;
    return {
      id: row.id,
      ticket: row.ticket,
      customerId: row.customer_id,
      guestCustomerId: row.guest_customer_id || null,
      isGuest: !row.customer_id && !!(row.guest_customer_id || guestCustomer),
      assignedElectricianId: row.assigned_electrician_id,
      serviceArea: row.service_area,
      locationLabel: row.location_label,
      latitude: row.latitude,
      longitude: row.longitude,
      issueCategory: row.issue_category,
      issueCategories: [row.issue_category],
      urgency: row.urgency === 'this_week' ? 'this-week' : row.urgency,
      description: row.customer_note || '',
      status: row.status,
      statusLabel: getStatusLabel(row.status),
      requiresAssessment: !!row.requires_assessment,
      materialHandling: row.material_handling || 'voltfriq_supplied',
      candidateQueue: row.candidate_queue || [],
      attemptedElectricianIds: row.attempted_electrician_ids || [],
      dispatchAttempts: Number(row.dispatch_attempts || 0),
      lastDispatchAt: row.last_dispatch_at,
      customer: row.customer ? {
        id: row.customer.id,
        profileId: row.customer.profile_id,
        name: customerProfile.full_name || '',
        phone: customerProfile.phone || '',
        primaryServiceArea: row.customer.primary_service_area || '',
        trustSummary: {
          averageBehaviorRating: Number(row.customer.average_behavior_rating || 0),
          totalBehaviorRatings: Number(row.customer.total_behavior_ratings || 0),
          completedRequests: Number(row.customer.completed_requests || 0),
          cancellationCount: Number(row.customer.cancellation_count || 0),
          noShowReports: Number(row.customer.no_show_reports || 0),
          disputeCount: Number(row.customer.dispute_count || 0),
          paymentIssueCount: Number(row.customer.payment_issue_count || 0),
          status: row.customer.trust_status || 'clear',
          notes: row.customer.trust_notes || ''
        }
      } : guestCustomer ? {
        id: guestCustomer.id,
        profileId: null,
        name: 'Guest customer',
        phone: guestCustomer.phone || '',
        primaryServiceArea: guestCustomer.location_label || '',
        trustSummary: {
          averageBehaviorRating: 0,
          totalBehaviorRatings: 0,
          completedRequests: 0,
          cancellationCount: 0,
          noShowReports: 0,
          disputeCount: 0,
          paymentIssueCount: 0,
          status: 'guest',
          notes: 'Guest booking'
        }
      } : null,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      assignmentExpiresAt: row.assignment_expires_at,
      customerConfirmedAt: row.customer_confirmed_at,
      electricianCompletedAt: row.electrician_completed_at,
      assignedElectrician: row.assigned_electrician ? {
        id: row.assigned_electrician.id,
        name: electricianProfile.full_name || 'VoltFriq',
        phone: electricianProfile.phone || '',
        avatar: electricianProfile.avatar_url || '',
        rating: Number(row.assigned_electrician.average_rating || 0),
        totalRatings: Number(row.assigned_electrician.total_ratings || 0),
        responseRate: Number(row.assigned_electrician.response_rate || 0),
        jobsCompleted: Number(row.assigned_electrician.completed_jobs || 0),
        levelBadge: row.assigned_electrician.level_badge || 'Verified Pro',
        watchlist: !!row.assigned_electrician.watchlist,
        watchlistReason: row.assigned_electrician.watchlist_reason || '',
        negativeRatingCount: Number(row.assigned_electrician.negative_rating_count || 0),
        suspendedReason: row.assigned_electrician.suspended_reason || '',
        serviceAreas: row.assigned_electrician.service_areas || [],
        skills: (row.assigned_electrician.electrician_skills || []).map((skill) => skill.category),
        latitude: row.assigned_electrician.latitude,
        longitude: row.assigned_electrician.longitude,
        locationLabel: row.assigned_electrician.location_label || '',
        badges: buildTrustBadges(row.assigned_electrician)
      } : null,
      photos: (row.job_photos || []).map((photo) => Object.assign({}, photo, {
        url: getPublicStorageUrl('jobPhotos', photo.file_path)
      })),
      quote,
      payments: payments.map((payment) => Object.assign({}, payment, {
        statusLabel: getPaymentStatusLabel(payment.status)
      })),
      latestPayment: payments[0] ? Object.assign({}, payments[0], {
        statusLabel: getPaymentStatusLabel(payments[0].status)
      }) : null,
      timeline: timeline,
      lastTimeline: lastTimeline,
      needsManualAssignment: row.status === 'matching' && !row.assigned_electrician_id && Number(row.dispatch_attempts || 0) > 0 && !(row.candidate_queue || []).length,
      reviews: reviews,
      rating: electricianReview,
      electricianReview: electricianReview,
      customerReview: customerReview
    };
  }

  function buildTrustBadges(electrician) {
    const badges = [electrician.level_badge || 'Verified Pro'];
    if (Number(electrician.average_rating || 0) >= 4.7 && Number(electrician.total_ratings || 0) >= 5 && badges.indexOf('Top Rated') === -1) {
      badges.push('Top Rated');
    }
    if (Number(electrician.response_rate || 0) >= 85) {
      badges.push('Fast Responder');
    }
    return badges;
  }

  return {
    init,
    isConfigured,
    getSession,
    getCurrentProfile,
    getCurrentCustomer,
    getCurrentElectrician,
    getCurrentWallet,
    getGuestAccess,
    clearGuestAccess,
    getPublicSiteUrl,
    siteUrlForPath,
    listSavedAddresses,
    saveCustomerAddress,
    selectDraftAddress,
    getRoleHome,
    getSettings,
    getServiceAreas,
    getStatusLabel,
    getPaymentStatusLabel,
    formatCurrency,
    getPublicStorageUrl,
    createSignedStorageUrl,
    signUpCustomer,
    finishCustomerSignup,
    signUpElectrician,
    finishElectricianSignup,
    signIn,
    requestPasswordReset,
    verifySignupOtp,
    resendSignupOtp,
    updatePassword,
    signOut,
    updateProfile,
    listCustomerJobs,
    listElectricianJobs,
    listAdminJobs,
    getJob,
    getGuestJob,
    previewMatches,
    createBooking,
    createGuestBooking,
    acceptAssignedJob,
    rejectAssignedJob,
    updateJobStatus,
    submitQuote,
    acceptQuote,
    submitPaymentProof,
    verifyPayment,
    setManualAssignment,
    rerunAutomaticAssignment,
    setElectricianStatus,
    setElectricianWatchlist,
    updateCurrentElectrician,
    replaceCurrentElectricianSkills,
    listElectricians,
    hydrateElectricianDocuments,
    getWalletSummary,
    getReferralSummary,
    linkReferralCode,
    createDispute,
    listDisputes,
    resolveDispute,
    listAppeals,
    submitElectricianAppeal,
    resolveElectricianAppeal,
    listPaymentsNeedingVerification,
    markWorkStarted,
    markWorkCompleted,
    markCustomerConfirmed,
    markPayoutComplete,
    submitRating,
    submitCustomerReview,
    loadSettings,
    loadExpertiseCategories,
    getExpertiseCategories,
    saveExpertiseCategory,
    removeExpertiseCategory,
    saveSettings,
    addJobMessage,
    getJobMessages,
    subscribeToJob,
    subscribeToMessages,
    subscribeToNotifications,
    subscribeToPortalFeed,
    listNotifications,
    markNotificationRead,
    processDispatchQueue
  };
})();
