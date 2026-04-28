/* ─── VOLTFRIQ OCEAN — SHARED DATA STORE ─────────────────────────── */
/* localStorage-backed state shared across Customer / Electrician / Admin portals */

const Store = (() => {
  const PREFIX = 'vfo_';
  const channel = typeof BroadcastChannel !== 'undefined'
    ? new BroadcastChannel('vfo-sync')
    : null;

  const DEFAULT_SETTINGS = {
    defaultAssessmentFee: 5000,
    defaultBillingMode: 'fixed',
    defaultPayoutMode: 'platform-hold',
    largeContractThreshold: 100000,
    bankName: 'First Bank of Nigeria',
    accountNumber: '3012845678',
    accountName: 'Voltfriq Services Ltd',
    categories: [
      'Power outage', 'Wiring issue', 'Tripped breaker', 'Light fitting',
      'Socket repair', 'Generator', 'CCTV Installation', 'Solar Installation',
      'General Installation', 'Security Alarm', 'Inverter', 'Other'
    ],
    serviceAreas: [
      'Lekki Phase 1',
      'Victoria Island',
      'Ikeja',
      'Surulere',
      'Yaba',
      'Ajah'
    ],
    badRatingStars: [1, 2],
    badRatingThreshold: 3,
    badRatingAction: 'suspend',
    requiredElectricianFields: [
      'location',
      'experience',
      'serviceAreas',
      'expertise',
      'payoutDetails'
    ],
    requiredDocuments: [
      { id: 'gov-id', label: 'Government ID', type: 'upload' },
      { id: 'license', label: 'Trade license or certification', type: 'upload' },
      { id: 'bio', label: 'Short professional bio', type: 'text' }
    ],
    onboardingConfig: {
      mode: 'virtual',
      videoUrl: 'https://example.com/voltfriq-onboarding',
      livePrompt: 'Ask about safety, customer communication, and diagnosis.',
      virtualPrompt: 'Review the safety process, customer etiquette, and reporting format.',
      welcomeNote: 'Transparent work, safety-first decisions, and clear reporting are required on every job.'
    },
    rankingWeights: {
      rating: 50,
      jobs: 30,
      distance: 20,
      expertise: 70
    }
  };

  const DEFAULT_PRICE_LIST = [
    { id: 'wp-1', service: 'Replacement of lamp holder (very low heights)', price: 1500 },
    { id: 'wp-2', service: 'Replacement of lamp holder (short heights)', price: 3500 },
    { id: 'wp-3', service: 'Replacement of lamp holder (with ladder for short heights)', price: 5500 },
    { id: 'wp-4', service: 'Replacement of lamp holder (high ceiling)', price: 5000 },
    { id: 'wp-5', service: 'Replacement of wall sockets', price: 1500 },
    { id: 'wp-6', service: 'Replacement of wires inside building (short distance)', price: 3000 },
    { id: 'wp-7', service: 'Replacement of wires inside building (long distance)', price: 5000 },
    { id: 'wp-8', service: 'Replacement of light switches', price: 2000 },
    { id: 'wp-9', service: 'Replacement of house control panel', price: 15000 },
    { id: 'wp-10', service: 'Replacement of breaker (single pole)', price: 2000 },
    { id: 'wp-11', service: 'Replacement of breaker (multiple poles)', price: 4000 },
    { id: 'wp-12', service: 'Installation of knife switch (power change over/power transfer switch)', price: 5000 },
    { id: 'wp-13', service: 'Installation of change box/power transfer switch', price: 5000 },
    { id: 'wp-14', service: 'Installation of cut out fuse (per fuse)', price: 3000 },
    { id: 'wp-15', service: 'Power control room (pole to house — grid & generator to control room/board)', price: 35000 },
    { id: 'wp-16', service: 'Pole to pole tensioning/wiring', price: 8000 },
    { id: 'wp-17', service: 'Installation of automatic pump switch', price: 8000 }
  ];

  function _key(k) {
    return PREFIX + k;
  }

  function get(key, fallback) {
    try {
      const raw = localStorage.getItem(_key(key));
      return raw ? JSON.parse(raw) : (fallback !== undefined ? fallback : null);
    } catch (err) {
      return fallback !== undefined ? fallback : null;
    }
  }

  function set(key, value) {
    localStorage.setItem(_key(key), JSON.stringify(value));
    if (channel) {
      channel.postMessage({ type: 'update', key, value });
    }
  }

  function remove(key) {
    localStorage.removeItem(_key(key));
    if (channel) {
      channel.postMessage({ type: 'remove', key });
    }
  }

  function onUpdate(callback) {
    if (channel) {
      channel.addEventListener('message', (event) => callback(event.data));
    }
  }

  function uid() {
    return Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  }

  function ticketId() {
    return 'VFQ-' + Date.now().toString(36).toUpperCase().slice(-6);
  }

  function uniqueStrings(list) {
    return Array.from(new Set((list || [])
      .map((item) => String(item || '').trim())
      .filter(Boolean)));
  }

  function clampNumber(value, fallback) {
    const num = Number(value);
    return Number.isFinite(num) ? num : fallback;
  }

  function normalizeSettings(input) {
    const src = input || {};
    const onboardingConfig = Object.assign({}, DEFAULT_SETTINGS.onboardingConfig, src.onboardingConfig || {});
    const rankingWeights = Object.assign({}, DEFAULT_SETTINGS.rankingWeights, src.rankingWeights || {});
    const requiredDocuments = Array.isArray(src.requiredDocuments) && src.requiredDocuments.length
      ? src.requiredDocuments.map((doc, index) => ({
          id: doc.id || ('doc-' + index),
          label: String(doc.label || doc.name || 'Required document').trim(),
          type: doc.type === 'text' ? 'text' : 'upload'
        })).filter((doc) => doc.label)
      : DEFAULT_SETTINGS.requiredDocuments.slice();

    return {
      defaultAssessmentFee: clampNumber(src.defaultAssessmentFee || src.defaultAppearanceFee, DEFAULT_SETTINGS.defaultAssessmentFee),
      defaultBillingMode: src.defaultBillingMode === 'per-second' ? 'per-second' : 'fixed',
      defaultPayoutMode: src.defaultPayoutMode === 'direct-to-electrician' ? 'direct-to-electrician' : 'platform-hold',
      largeContractThreshold: clampNumber(src.largeContractThreshold, DEFAULT_SETTINGS.largeContractThreshold),
      bankName: String(src.bankName || DEFAULT_SETTINGS.bankName).trim(),
      accountNumber: String(src.accountNumber || DEFAULT_SETTINGS.accountNumber).trim(),
      accountName: String(src.accountName || DEFAULT_SETTINGS.accountName).trim(),
      categories: uniqueStrings(src.categories && src.categories.length ? src.categories : DEFAULT_SETTINGS.categories),
      serviceAreas: uniqueStrings(src.serviceAreas && src.serviceAreas.length ? src.serviceAreas : DEFAULT_SETTINGS.serviceAreas),
      badRatingStars: Array.isArray(src.badRatingStars) && src.badRatingStars.length ? src.badRatingStars.map(Number).filter(Number.isFinite) : DEFAULT_SETTINGS.badRatingStars.slice(),
      badRatingThreshold: clampNumber(src.badRatingThreshold, DEFAULT_SETTINGS.badRatingThreshold),
      badRatingAction: src.badRatingAction === 'remove' ? 'remove' : 'suspend',
      requiredElectricianFields: uniqueStrings(src.requiredElectricianFields && src.requiredElectricianFields.length ? src.requiredElectricianFields : DEFAULT_SETTINGS.requiredElectricianFields),
      requiredDocuments,
      onboardingConfig,
      rankingWeights
    };
  }

  function inferServiceArea(location, settings) {
    const serviceAreas = settings.serviceAreas || DEFAULT_SETTINGS.serviceAreas;
    const lower = String(location || '').toLowerCase();
    const found = serviceAreas.find((area) => lower.includes(String(area).toLowerCase()));
    return found || serviceAreas[0];
  }

  function normalizePayoutDetails(details, fallback) {
    const src = details || {};
    return {
      bankName: String(src.bankName || fallback.bankName || '').trim(),
      accountNumber: String(src.accountNumber || fallback.accountNumber || '').trim(),
      accountName: String(src.accountName || fallback.accountName || '').trim()
    };
  }

  function normalizeSkillList(electrician) {
    const rawSkills = electrician.skills || electrician.expertise || [];
    return rawSkills.map((skill) => {
      if (typeof skill === 'string') {
        return { name: skill, status: 'approved' };
      }
      return {
        name: String(skill.name || '').trim(),
        status: skill.status || 'pending'
      };
    }).filter((skill) => skill.name);
  }

  function normalizeDocuments(rawDocuments, requiredDocuments) {
    const documents = Array.isArray(rawDocuments) ? rawDocuments : [];
    return requiredDocuments.map((doc) => {
      const existing = documents.find((entry) => entry.id === doc.id) || {};
      return {
        id: doc.id,
        label: doc.label,
        type: doc.type,
        value: existing.value || '',
        submittedAt: existing.submittedAt || null,
        status: existing.status || 'pending'
      };
    });
  }

  function normalizeElectrician(input, settings) {
    const src = input || {};
    const resolvedSettings = settings || getSettings();
    const skills = normalizeSkillList(src);
    const approvedSkills = skills.filter((skill) => skill.status === 'approved').map((skill) => skill.name);
    const expertise = uniqueStrings(src.expertise && src.expertise.length ? src.expertise : approvedSkills.length ? approvedSkills : skills.map((skill) => skill.name));
    const serviceAreas = uniqueStrings(src.serviceAreas && src.serviceAreas.length ? src.serviceAreas : [inferServiceArea(src.location, resolvedSettings)]);
    const normalized = {
      id: src.id || ('elec-' + uid()),
      name: src.name || 'Unknown Electrician',
      first: src.first || String(src.name || 'VoltFriq').split(' ')[0],
      email: src.email || '',
      phone: src.phone || '',
      password: src.password || 'demo123',
      avatar: src.avatar || '👷',
      distance: clampNumber(src.distance, 1.2),
      rating: clampNumber(src.rating, 0),
      jobs: clampNumber(src.jobs, clampNumber(src.jobsCompleted, 0)),
      jobsCompleted: clampNumber(src.jobsCompleted, clampNumber(src.jobs, 0)),
      totalRatings: clampNumber(src.totalRatings, clampNumber(src.jobs, 0)),
      specialty: src.specialty || expertise[0] || 'General Electrical',
      expertise,
      skills: skills.length ? skills : expertise.map((name) => ({ name, status: 'approved' })),
      rate: clampNumber(src.rate, 3500),
      perSecondRate: clampNumber(src.perSecondRate, Math.round((clampNumber(src.rate, 3500) / 3600) * 100) / 100),
      location: src.location || serviceAreas[0] || '',
      serviceAreas,
      experience: src.experience || '0 years',
      certifications: src.certifications || '',
      documents: normalizeDocuments(src.documents, resolvedSettings.requiredDocuments),
      payoutDetails: normalizePayoutDetails(src.payoutDetails, {
        bankName: src.bankName || resolvedSettings.bankName,
        accountNumber: src.accountNumber || '0000000000',
        accountName: src.accountName || src.name || 'VoltFriq Electrician'
      }),
      status: src.status || 'active',
      onboardingStatus: src.onboardingStatus || (src.status === 'pending' ? 'pending-review' : 'approved'),
      onboardingMode: src.onboardingMode || resolvedSettings.onboardingConfig.mode,
      onboardingAnswers: Array.isArray(src.onboardingAnswers) ? src.onboardingAnswers : [],
      joinedDate: src.joinedDate || new Date().toISOString().slice(0, 10),
      refId: src.refId || null,
      badRatingCount: clampNumber(src.badRatingCount, 0),
      warningCount: clampNumber(src.warningCount, 0),
      rankScore: clampNumber(src.rankScore, 0),
      availabilityStatus: src.availabilityStatus || (src.status === 'active' ? 'available' : 'offline')
    };

    if (normalized.status === 'active' && normalized.onboardingStatus !== 'approved') {
      normalized.onboardingStatus = 'approved';
    }

    return normalized;
  }

  function normalizeQuote(rawQuote, job) {
    const src = rawQuote || {};
    const items = (src.items || src.laborItems || []).map((item) => ({
      description: String(item.description || item.name || '').trim(),
      amount: clampNumber(item.amount, 0)
    })).filter((item) => item.description);
    const materials = (src.materials || []).map((item) => ({
      name: String(item.name || item.description || '').trim(),
      quantity: clampNumber(item.quantity, 1),
      unitPrice: clampNumber(item.unitPrice, 0)
    })).filter((item) => item.name);

    const fixedLaborTotal = items.reduce((sum, item) => sum + item.amount, 0);
    const materialTotal = materials.reduce((sum, item) => sum + (item.quantity * item.unitPrice), 0);
    const laborTotal = job.billingModeSnapshot === 'per-second'
      ? computePerSecondLaborTotal(job)
      : fixedLaborTotal;
    const customerMaterialTotal = job.materialHandling === 'self-procured' ? 0 : materialTotal;
    const customerPayableTotal = laborTotal + customerMaterialTotal;

    return {
      findings: src.findings || '',
      measurements: src.measurements || '',
      items,
      materials,
      fixedLaborTotal,
      materialTotal,
      laborTotal,
      customerMaterialTotal,
      customerPayableTotal,
      createdAt: src.createdAt || null,
      requiresAssessment: !!src.requiresAssessment
    };
  }

  function normalizeTimeline(rawTimeline, fallbackStatus, createdAt) {
    const timeline = Array.isArray(rawTimeline) ? rawTimeline.slice() : [];
    if (!timeline.length && fallbackStatus) {
      timeline.push({
        status: fallbackStatus,
        timestamp: createdAt || Date.now(),
        note: 'Job created'
      });
    }
    return timeline.map((entry) => ({
      status: entry.status || fallbackStatus || 'requested',
      timestamp: entry.timestamp || createdAt || Date.now(),
      note: entry.note || ''
    }));
  }

  function mapLegacyStatus(status) {
    const map = {
      pending: 'requested',
      'fee-pending': 'assessment-pending',
      'fee-paid': 'matched',
      assigned: 'matched',
      'en-route': 'matched',
      'on-site': 'matched',
      assessed: 'matched',
      quoted: 'quoted',
      accepted: 'quote-accepted',
      paid: 'payment-pending',
      'work-done': 'electrician-complete',
      completed: 'payout-complete',
      declined: 'cancelled'
    };
    return map[status] || status || 'requested';
  }

  function inferVisitStage(src) {
    if (src.visitStage) return src.visitStage;
    if (src.workTimer && src.workTimer.running) return 'work-started';
    if (src.workTimer && src.workTimer.stoppedAt) return 'work-stopped';
    if (src.status === 'quoted') return 'assessment-submitted';
    if (src.status === 'electrician-confirmed' || src.status === 'work-done') return 'work-stopped';
    if (src.status === 'on-site') return 'on-site';
    if (src.status === 'en-route') return 'en-route';
    if (src.status === 'accepted') return 'accepted';
    return 'awaiting-acceptance';
  }

  function normalizeWorkTimer(rawTimer, electrician) {
    const perSecondRate = clampNumber(rawTimer && rawTimer.perSecondRate, electrician ? electrician.perSecondRate : 0);
    return {
      running: !!(rawTimer && rawTimer.running),
      startedAt: rawTimer && rawTimer.startedAt ? rawTimer.startedAt : null,
      stoppedAt: rawTimer && rawTimer.stoppedAt ? rawTimer.stoppedAt : null,
      accumulatedMs: clampNumber(rawTimer && rawTimer.accumulatedMs, 0),
      perSecondRate
    };
  }

  function normalizeJob(input, settings, electricians) {
    const src = input || {};
    const resolvedSettings = settings || getSettings();
    const electricList = electricians || getElectricians();
    const issueCategories = uniqueStrings(src.issueCategories && src.issueCategories.length ? src.issueCategories : src.categories);
    const assignedElectricianId = src.assignedElectricianId || src.electricianId || src.assignedElectrician || null;
    const assignedElectrician = assignedElectricianId
      ? electricList.find((electrician) => electrician.id === assignedElectricianId) || null
      : null;
    const billingModeSnapshot = src.billingModeSnapshot === 'per-second'
      ? 'per-second'
      : (src.billingModeSnapshot || resolvedSettings.defaultBillingMode);
    const payoutModeSnapshot = src.payoutModeSnapshot === 'direct-to-electrician'
      ? 'direct-to-electrician'
      : (src.payoutModeSnapshot || resolvedSettings.defaultPayoutMode);
    const status = mapLegacyStatus(src.status);
    const createdAt = src.createdAt || Date.now();
    const ticket = src.ticket || src.ticketId || ticketId();
    const ratePerSecondSnapshot = clampNumber(
      src.ratePerSecondSnapshot,
      assignedElectrician ? assignedElectrician.perSecondRate : 0.97
    );

    const job = {
      id: src.id || uid(),
      ticket,
      customerId: src.customerId || null,
      customerName: src.customerName || 'Customer',
      customerContact: src.customerContact || src.customerPhone || '',
      serviceArea: src.serviceArea || inferServiceArea(src.location, resolvedSettings),
      availabilityCount: clampNumber(src.availabilityCount, 0),
      issueCategories,
      categories: issueCategories.slice(),
      description: src.description || '',
      location: src.location || src.serviceArea || '',
      urgency: src.urgency || 'today',
      photos: Array.isArray(src.photos) ? src.photos.slice() : [],
      status,
      visitStage: inferVisitStage(src),
      createdAt,
      updatedAt: src.updatedAt || createdAt,
      assignedElectricianId,
      electricianId: assignedElectricianId,
      electricianName: src.electricianName || (assignedElectrician ? assignedElectrician.name : null),
      recommendedElectricianId: src.recommendedElectricianId || assignedElectricianId,
      candidateElectricianIds: Array.isArray(src.candidateElectricianIds) ? src.candidateElectricianIds.slice() : [],
      assessmentRequested: src.assessmentRequested !== undefined ? !!src.assessmentRequested : !!src.appearanceFee,
      assessmentFeeSnapshot: clampNumber(src.assessmentFeeSnapshot || src.appearanceFee, resolvedSettings.defaultAssessmentFee),
      assessmentFeePaid: !!src.assessmentFeePaid || !!src.feePaidAt,
      assessmentRequestedAt: src.assessmentRequestedAt || null,
      assessmentFeePaidAt: src.assessmentFeePaidAt || src.feePaidAt || null,
      billingModeSnapshot,
      payoutModeSnapshot,
      materialHandling: src.materialHandling === 'self-procured' ? 'self-procured' : 'voltfriq-supplied',
      materialPaymentConfirmed: !!src.materialPaymentConfirmed,
      paymentConfirmedAt: src.paymentConfirmedAt || src.paidAt || null,
      paymentProof: src.paymentProof || null,
      workTimer: normalizeWorkTimer(src.workTimer, assignedElectrician),
      ratePerSecondSnapshot,
      quote: null,
      quoteAcceptedAt: src.quoteAcceptedAt || src.quotationAcceptedAt || null,
      quoteRequestedWithoutAssessment: !!src.quoteRequestedWithoutAssessment,
      receipt: src.receipt || null,
      payoutState: src.payoutState || 'awaiting-payment',
      customerConfirmed: !!src.customerConfirmed,
      customerConfirmedAt: src.customerConfirmedAt || null,
      electricianConfirmed: !!src.electricianConfirmed,
      electricianConfirmedAt: src.electricianConfirmedAt || null,
      rating: src.rating || null,
      ratingComment: src.ratingComment || null,
      ratedAt: src.ratedAt || null,
      timeline: normalizeTimeline(src.timeline, status, createdAt)
    };

    job.quote = normalizeQuote(src.quote || src.quotation, job);

    if (job.status === 'requested' && assignedElectricianId) {
      job.status = job.assessmentRequested ? 'assessment-pending' : 'matched';
    }
    if (job.status === 'quote-accepted' && !job.paymentConfirmedAt) {
      job.status = 'payment-pending';
    }
    if (job.status === 'payment-pending' && job.visitStage === 'work-started') {
      job.status = 'work-in-progress';
    }
    if (job.status === 'electrician-complete' && job.customerConfirmed) {
      job.status = 'payout-complete';
    }
    if (job.status === 'payout-complete' && job.rating) {
      job.status = 'rated';
    }
    if (job.materialHandling === 'self-procured' && job.quote) {
      job.quote.customerMaterialTotal = 0;
      job.quote.customerPayableTotal = job.quote.laborTotal;
    }

    return job;
  }

  function getJobs() {
    return (get('jobs', []) || []).map((job) => normalizeJob(job));
  }

  function saveJob(job) {
    const settings = getSettings();
    const electricians = getElectricians();
    const normalized = normalizeJob(job, settings, electricians);
    const jobs = get('jobs', []) || [];
    const index = jobs.findIndex((entry) => entry.id === normalized.id);
    if (index >= 0) {
      jobs[index] = normalized;
    } else {
      jobs.push(normalized);
    }
    set('jobs', jobs);
    return normalized;
  }

  function getJob(id) {
    const raw = (get('jobs', []) || []).find((job) => job.id === id);
    return raw ? normalizeJob(raw) : null;
  }

  function getElectricians() {
    const settings = getSettings();
    return (get('electricians', []) || []).map((electrician) => normalizeElectrician(electrician, settings));
  }

  function saveElectrician(electrician) {
    const settings = getSettings();
    const normalized = normalizeElectrician(electrician, settings);
    const list = get('electricians', []) || [];
    const index = list.findIndex((entry) => entry.id === normalized.id);
    if (index >= 0) {
      list[index] = normalized;
    } else {
      list.push(normalized);
    }
    set('electricians', list);
    return normalized;
  }

  function getElectrician(id) {
    const settings = getSettings();
    const raw = (get('electricians', []) || []).find((electrician) => electrician.id === id);
    return raw ? normalizeElectrician(raw, settings) : null;
  }

  function getCustomers() {
    return get('customers', []) || [];
  }

  function saveCustomer(customer) {
    const list = getCustomers();
    const normalized = Object.assign({
      id: 'cust-' + uid(),
      name: 'Customer',
      contact: '',
      password: '',
      isGuest: false,
      createdAt: Date.now()
    }, customer || {});
    const index = list.findIndex((entry) => entry.id === normalized.id);
    if (index >= 0) {
      list[index] = normalized;
    } else {
      list.push(normalized);
    }
    set('customers', list);
    return normalized;
  }

  function getCustomer(id) {
    return getCustomers().find((customer) => customer.id === id) || null;
  }

  function getChat(jobId) {
    return get('chat_' + jobId, []) || [];
  }

  function addChatMessage(jobId, message) {
    const messages = getChat(jobId);
    const payload = Object.assign({
      id: uid(),
      timestamp: Date.now()
    }, message || {});
    messages.push(payload);
    set('chat_' + jobId, messages);
    return payload;
  }

  function getSettings() {
    return normalizeSettings(get('settings', DEFAULT_SETTINGS));
  }

  function saveSettings(settings) {
    const normalized = normalizeSettings(settings);
    set('settings', normalized);
    return normalized;
  }

  function getPriceList() {
    return get('priceList', DEFAULT_PRICE_LIST) || [];
  }

  function savePriceList(list) {
    set('priceList', list || []);
  }

  function addPriceItem(service, price) {
    const list = getPriceList();
    list.push({ id: 'wp-' + uid(), service, price: Number(price) });
    savePriceList(list);
    return list;
  }

  function updatePriceItem(id, service, price) {
    const list = getPriceList();
    const index = list.findIndex((item) => item.id === id);
    if (index >= 0) {
      list[index].service = service;
      list[index].price = Number(price);
    }
    savePriceList(list);
    return list;
  }

  function deletePriceItem(id) {
    const list = getPriceList().filter((item) => item.id !== id);
    savePriceList(list);
    return list;
  }

  function getAvailableElectricians(serviceArea) {
    const area = String(serviceArea || '').trim();
    return getElectricians().filter((electrician) => {
      if (electrician.status !== 'active') return false;
      if (electrician.onboardingStatus !== 'approved') return false;
      if (electrician.availabilityStatus === 'offline') return false;
      if (!area) return true;
      return electrician.serviceAreas.includes(area);
    });
  }

  function countAvailableElectricians(serviceArea) {
    return getAvailableElectricians(serviceArea).length;
  }

  function rankElectricians(serviceArea, issueCategories) {
    const settings = getSettings();
    const issues = uniqueStrings(issueCategories);
    return getAvailableElectricians(serviceArea).map((electrician) => {
      const expertise = electrician.expertise || [];
      const expertiseMatches = issues.filter((issue) => expertise.includes(issue));
      const distanceScore = Math.max(0, 10 - clampNumber(electrician.distance, 10));
      const score =
        (expertiseMatches.length * settings.rankingWeights.expertise) +
        (clampNumber(electrician.rating, 0) * settings.rankingWeights.rating) +
        (clampNumber(electrician.jobsCompleted || electrician.jobs, 0) * settings.rankingWeights.jobs / 10) +
        (distanceScore * settings.rankingWeights.distance);
      return Object.assign({}, electrician, {
        expertiseMatches,
        rankScore: Math.round(score * 100) / 100,
        matchReason: expertiseMatches.length
          ? 'Best fit for ' + expertiseMatches.join(', ')
          : 'Strong rating and response history in ' + (serviceArea || 'your area')
      });
    }).sort((a, b) => {
      if (b.expertiseMatches.length !== a.expertiseMatches.length) {
        return b.expertiseMatches.length - a.expertiseMatches.length;
      }
      if (b.rating !== a.rating) return b.rating - a.rating;
      if ((b.jobsCompleted || b.jobs) !== (a.jobsCompleted || a.jobs)) {
        return (b.jobsCompleted || b.jobs) - (a.jobsCompleted || a.jobs);
      }
      return a.distance - b.distance;
    });
  }

  function getRecommendedElectrician(serviceArea, issueCategories) {
    return rankElectricians(serviceArea, issueCategories)[0] || null;
  }

  function getPayoutDestination(job) {
    const settings = getSettings();
    if (job.payoutModeSnapshot === 'direct-to-electrician' && job.assignedElectricianId) {
      const electrician = getElectrician(job.assignedElectricianId);
      if (electrician) {
        return Object.assign({
          label: electrician.name + ' payout account'
        }, electrician.payoutDetails);
      }
    }
    return {
      label: 'Voltfriq holding account',
      bankName: settings.bankName,
      accountNumber: settings.accountNumber,
      accountName: settings.accountName
    };
  }

  function computePerSecondLaborTotal(job) {
    if (!job || !job.workTimer) return 0;
    const timer = job.workTimer;
    const liveDuration = timer.running && timer.startedAt ? (Date.now() - timer.startedAt) : 0;
    const totalMs = clampNumber(timer.accumulatedMs, 0) + Math.max(0, liveDuration);
    const amount = (totalMs / 1000) * clampNumber(timer.perSecondRate || job.ratePerSecondSnapshot, 0);
    return Math.round(amount);
  }

  function refreshJobFinancials(job) {
    const normalized = normalizeJob(job);
    normalized.quote = normalizeQuote(normalized.quote, normalized);
    if (normalized.quote) {
      normalized.quote.laborTotal = normalized.billingModeSnapshot === 'per-second'
        ? computePerSecondLaborTotal(normalized)
        : normalized.quote.fixedLaborTotal;
      normalized.quote.customerMaterialTotal = normalized.materialHandling === 'self-procured'
        ? 0
        : normalized.quote.materialTotal;
      normalized.quote.customerPayableTotal = normalized.quote.laborTotal + normalized.quote.customerMaterialTotal;
    }
    return normalized;
  }

  function addTimelineEvent(job, status, note) {
    const next = refreshJobFinancials(job);
    next.updatedAt = Date.now();
    if (!Array.isArray(next.timeline)) next.timeline = [];
    next.timeline.push({
      status,
      timestamp: Date.now(),
      note: note || ''
    });
    return next;
  }

  function startWorkTimer(job) {
    const next = refreshJobFinancials(job);
    if (next.billingModeSnapshot !== 'per-second') return next;
    if (next.workTimer.running) return next;
    next.workTimer.running = true;
    next.workTimer.startedAt = Date.now();
    next.workTimer.stoppedAt = null;
    next.visitStage = 'work-started';
    if (next.status === 'payment-pending') {
      next.status = 'work-in-progress';
    }
    return addTimelineEvent(next, next.status, 'Electrician started timer-based work');
  }

  function stopWorkTimer(job) {
    const next = refreshJobFinancials(job);
    if (next.billingModeSnapshot !== 'per-second') return next;
    if (next.workTimer.running && next.workTimer.startedAt) {
      next.workTimer.accumulatedMs += Math.max(0, Date.now() - next.workTimer.startedAt);
    }
    next.workTimer.running = false;
    next.workTimer.stoppedAt = Date.now();
    next.workTimer.startedAt = null;
    next.visitStage = 'work-stopped';
    next.quote = normalizeQuote(next.quote, next);
    return addTimelineEvent(next, next.status, 'Electrician stopped timer-based work');
  }

  function createReceipt(job, reference, note) {
    const next = refreshJobFinancials(job);
    const destination = getPayoutDestination(next);
    return {
      amount: next.quote ? next.quote.customerPayableTotal : 0,
      laborAmount: next.quote ? next.quote.laborTotal : 0,
      materialAmount: next.quote ? next.quote.customerMaterialTotal : 0,
      materialHandling: next.materialHandling,
      payoutMode: next.payoutModeSnapshot,
      billingMode: next.billingModeSnapshot,
      reference: reference || ('TRF-' + Date.now().toString(36).toUpperCase()),
      date: Date.now(),
      destinationLabel: destination.label,
      ticket: next.ticket,
      note: note || ''
    };
  }

  function applyRatingToElectrician(job, rating) {
    if (!job || !job.assignedElectricianId) return null;
    const electrician = getElectrician(job.assignedElectricianId);
    if (!electrician) return null;
    const settings = getSettings();
    const totalRatings = clampNumber(electrician.totalRatings, 0);
    const existingRating = clampNumber(electrician.rating, 0);

    electrician.rating = totalRatings > 0
      ? Math.round((((existingRating * totalRatings) + rating) / (totalRatings + 1)) * 10) / 10
      : rating;
    electrician.totalRatings = totalRatings + 1;
    electrician.jobsCompleted = clampNumber(electrician.jobsCompleted, electrician.jobs) + 1;
    electrician.jobs = electrician.jobsCompleted;

    if ((settings.badRatingStars || []).includes(Number(rating))) {
      electrician.badRatingCount += 1;
      electrician.warningCount += 1;
      if (electrician.badRatingCount >= settings.badRatingThreshold) {
        electrician.status = settings.badRatingAction === 'remove' ? 'removed' : 'suspended';
        electrician.availabilityStatus = 'offline';
      }
    }

    return saveElectrician(electrician);
  }

  function getSuggestedQuestions(expertise, prompt) {
    const lead = expertise && expertise.length ? expertise[0] : 'General Installation';
    const topics = [
      'What are the first safety checks you complete before starting ' + lead + ' work?',
      'How do you explain a quotation clearly to a customer who wants full transparency?',
      'When should a remote diagnosis become an on-site assessment?',
      'How do you document materials, findings, and final completion for future reference?'
    ];
    if (prompt) {
      topics.push('Admin focus: ' + prompt);
    }
    return topics;
  }

  function seedIfEmpty() {
    const settings = saveSettings(get('settings', DEFAULT_SETTINGS));

    if (!get('priceList')) {
      set('priceList', DEFAULT_PRICE_LIST);
    }

    if (!get('admin')) {
      set('admin', {
        email: 'admin@voltfriq.com',
        password: 'admin123',
        name: 'VoltFriq Admin'
      });
    }

    const existingElectricians = get('electricians', []);
    if (!existingElectricians || !existingElectricians.length) {
      const demoElectricians = [
        {
          id: 'elec-1',
          name: 'James Okafor',
          first: 'James',
          email: 'james@email.com',
          phone: '08012345678',
          avatar: '👷',
          distance: 0.4,
          rating: 4.9,
          jobs: 128,
          specialty: 'Residential Wiring',
          expertise: ['Power outage', 'Wiring issue', 'Tripped breaker', 'Light fitting', 'Socket repair'],
          rate: 3500,
          location: 'Lekki Phase 1',
          serviceAreas: ['Lekki Phase 1', 'Ajah'],
          experience: '8 years',
          certifications: 'Federal trade certification',
          payoutDetails: {
            bankName: 'GTBank',
            accountNumber: '0021458890',
            accountName: 'James Okafor'
          },
          documents: [
            { id: 'gov-id', value: 'Uploaded National ID', submittedAt: Date.now(), status: 'approved' },
            { id: 'license', value: 'Uploaded wiring certificate', submittedAt: Date.now(), status: 'approved' },
            { id: 'bio', value: 'Residential wiring specialist focused on transparent reporting.', submittedAt: Date.now(), status: 'approved' }
          ],
          status: 'active',
          onboardingStatus: 'approved',
          onboardingMode: 'virtual',
          password: 'demo123',
          joinedDate: '2024-01-15',
          availabilityStatus: 'available'
        },
        {
          id: 'elec-2',
          name: 'Amaka Eze',
          first: 'Amaka',
          email: 'amaka@email.com',
          phone: '08023456789',
          avatar: '👩‍🔧',
          distance: 0.8,
          rating: 4.8,
          jobs: 94,
          specialty: 'Solar & Inverter',
          expertise: ['Solar Installation', 'Inverter', 'General Installation'],
          rate: 4000,
          location: 'Victoria Island',
          serviceAreas: ['Victoria Island', 'Lekki Phase 1'],
          experience: '6 years',
          certifications: 'Solar installation technician',
          payoutDetails: {
            bankName: 'Access Bank',
            accountNumber: '0123380009',
            accountName: 'Amaka Eze'
          },
          documents: [
            { id: 'gov-id', value: 'Uploaded National ID', submittedAt: Date.now(), status: 'approved' },
            { id: 'license', value: 'Uploaded solar certification', submittedAt: Date.now(), status: 'approved' },
            { id: 'bio', value: 'Solar and inverter expert with strong reporting discipline.', submittedAt: Date.now(), status: 'approved' }
          ],
          status: 'active',
          onboardingStatus: 'approved',
          onboardingMode: 'virtual',
          password: 'demo123',
          joinedDate: '2024-03-20',
          availabilityStatus: 'available'
        },
        {
          id: 'elec-3',
          name: 'Chidi Nwosu',
          first: 'Chidi',
          email: 'chidi@email.com',
          phone: '08034567890',
          avatar: '🧑‍🔧',
          distance: 1.2,
          rating: 4.7,
          jobs: 61,
          specialty: 'CCTV & Security',
          expertise: ['CCTV Installation', 'Security Alarm'],
          rate: 3000,
          location: 'Ikeja',
          serviceAreas: ['Ikeja', 'Yaba'],
          experience: '5 years',
          certifications: 'Security systems installer',
          payoutDetails: {
            bankName: 'Zenith Bank',
            accountNumber: '0032231104',
            accountName: 'Chidi Nwosu'
          },
          documents: [
            { id: 'gov-id', value: 'Uploaded National ID', submittedAt: Date.now(), status: 'approved' },
            { id: 'license', value: 'Uploaded installer certificate', submittedAt: Date.now(), status: 'approved' },
            { id: 'bio', value: 'Security and CCTV specialist for homes and small businesses.', submittedAt: Date.now(), status: 'approved' }
          ],
          status: 'active',
          onboardingStatus: 'approved',
          onboardingMode: 'virtual',
          password: 'demo123',
          joinedDate: '2024-06-10',
          availabilityStatus: 'available'
        },
        {
          id: 'elec-4',
          name: 'Bola Adeyemi',
          first: 'Bola',
          email: 'bola@email.com',
          phone: '08045678901',
          avatar: '👷‍♂️',
          distance: 1.9,
          rating: 4.6,
          jobs: 42,
          specialty: 'Generator / Standby',
          expertise: ['Generator', 'General Installation'],
          rate: 3500,
          location: 'Surulere',
          serviceAreas: ['Surulere', 'Yaba'],
          experience: '7 years',
          certifications: 'Generator installation certificate',
          payoutDetails: {
            bankName: 'UBA',
            accountNumber: '1012456701',
            accountName: 'Bola Adeyemi'
          },
          documents: [
            { id: 'gov-id', value: 'Uploaded National ID', submittedAt: Date.now(), status: 'approved' },
            { id: 'license', value: 'Uploaded generator certificate', submittedAt: Date.now(), status: 'approved' },
            { id: 'bio', value: 'Generator and standby system specialist.', submittedAt: Date.now(), status: 'approved' }
          ],
          status: 'active',
          onboardingStatus: 'approved',
          onboardingMode: 'virtual',
          password: 'demo123',
          joinedDate: '2024-08-01',
          availabilityStatus: 'available'
        },
        {
          id: 'elec-5',
          name: 'Emeka Obi',
          first: 'Emeka',
          email: 'emeka@email.com',
          phone: '08056789012',
          avatar: '🧑‍🔧',
          distance: 2.4,
          rating: 4.5,
          jobs: 37,
          specialty: 'Commercial Wiring',
          expertise: ['General Installation', 'Wiring issue'],
          rate: 4500,
          location: 'Yaba',
          serviceAreas: ['Yaba', 'Ikeja'],
          experience: '10 years',
          certifications: 'Commercial electrical systems',
          payoutDetails: {
            bankName: 'First Bank',
            accountNumber: '3009988123',
            accountName: 'Emeka Obi'
          },
          documents: [
            { id: 'gov-id', value: 'Uploaded National ID', submittedAt: Date.now(), status: 'approved' },
            { id: 'license', value: 'Uploaded commercial certificate', submittedAt: Date.now(), status: 'approved' },
            { id: 'bio', value: 'Commercial electrical repair and installation specialist.', submittedAt: Date.now(), status: 'approved' }
          ],
          status: 'active',
          onboardingStatus: 'approved',
          onboardingMode: 'virtual',
          password: 'demo123',
          joinedDate: '2024-09-15',
          availabilityStatus: 'available'
        }
      ];
      set('electricians', demoElectricians.map((electrician) => normalizeElectrician(electrician, settings)));
    } else {
      set('electricians', existingElectricians.map((electrician) => normalizeElectrician(electrician, settings)));
    }

    const existingJobs = get('jobs', []);
    if (existingJobs && existingJobs.length) {
      set('jobs', existingJobs.map((job) => normalizeJob(job, settings, getElectricians())));
    }
  }

  return {
    get,
    set,
    remove,
    onUpdate,
    uid,
    ticketId,
    getJobs,
    saveJob,
    getJob,
    getElectricians,
    saveElectrician,
    getElectrician,
    getCustomers,
    saveCustomer,
    getCustomer,
    getChat,
    addChatMessage,
    getSettings,
    saveSettings,
    getPriceList,
    savePriceList,
    addPriceItem,
    updatePriceItem,
    deletePriceItem,
    getAvailableElectricians,
    countAvailableElectricians,
    rankElectricians,
    getRecommendedElectrician,
    getPayoutDestination,
    computePerSecondLaborTotal,
    refreshJobFinancials,
    addTimelineEvent,
    startWorkTimer,
    stopWorkTimer,
    createReceipt,
    applyRatingToElectrician,
    getSuggestedQuestions,
    seedIfEmpty
  };
})();

Store.seedIfEmpty();
