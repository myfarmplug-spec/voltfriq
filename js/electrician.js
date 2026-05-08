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

  function renderRegistrationOptions() {
    const settings = Store.getSettings();
    const selectedAreas = activeChipValues('#reg-service-areas .chip.active', 'area');
    const serviceAreas = getRegistrationServiceAreas(settings);
    const usingFallbackArea = !(Array.isArray(settings.service_areas) && settings.service_areas.filter(Boolean).length);
    renderLocationDatalist(serviceAreas);

    document.getElementById('reg-service-areas').innerHTML = serviceAreas.length
      ? serviceAreas.map((area) => {
          const shouldActivate = selectedAreas.includes(area) || (usingFallbackArea && serviceAreas.length === 1) || serviceAreas.length === 1;
          return chipMarkup('area', area, shouldActivate);
        }).join('')
      : '<div class="expertise-empty">Enter your main location in Step 1 to continue.</div>';

    document.getElementById('reg-service-areas').onclick = toggleChip;

    document.getElementById('reg-photo').onclick = () => {
      const input = document.getElementById('reg-photo-input') || createHiddenFileInput('reg-photo-input');
      input.click();
    };

    createHiddenFileInput('reg-photo-input').onchange = (event) => {
      pendingProfilePhoto = event.target.files && event.target.files[0] ? event.target.files[0] : null;
      document.getElementById('reg-photo').innerHTML = '<span class="photo-icon' + (pendingProfilePhoto ? ' is-uploaded' : '') + '">✓</span><span>' + (pendingProfilePhoto ? pendingProfilePhoto.name : 'Tap to upload photo') + '</span>';
    };

    if (!selectedExpertise.length) {
      selectedExpertise = [];
    }
    renderExpertiseSelected();
    renderExpertiseOptions();
    renderCertificationList();
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

  function renderExpertiseSelected() {
    const container = document.getElementById('reg-selected-expertise');
    container.innerHTML = selectedExpertise.length
      ? selectedExpertise.map((skill) => '<button class="expertise-chip" type="button" data-remove-expertise="' + escapeHtml(skill) + '">' + escapeHtml(humanizeIssue(skill)) + '<span aria-hidden="true">&times;</span></button>').join('')
      : '<div class="expertise-empty">Select one or more expertise areas.</div>';
    container.querySelectorAll('[data-remove-expertise]').forEach((button) => {
      button.onclick = () => {
        selectedExpertise = selectedExpertise.filter((skill) => skill !== button.dataset.removeExpertise);
        renderExpertiseSelected();
        renderExpertiseOptions();
      };
    });
  }

  function renderExpertiseOptions() {
    const query = document.getElementById('reg-expertise-search').value.trim().toLowerCase();
    const options = getRegistrationSkillOptions(Store.getSettings())
      .filter((skill) => !selectedExpertise.includes(skill))
      .filter((skill) => !query || humanizeIssue(skill).toLowerCase().indexOf(query) !== -1 || skill.toLowerCase().indexOf(query) !== -1);
    const container = document.getElementById('reg-expertise-options');
    container.innerHTML = options.length
      ? options.map((skill) => '<button class="expertise-option" type="button" data-expertise-option="' + escapeHtml(skill) + '">' + escapeHtml(humanizeIssue(skill)) + '</button>').join('')
      : '<div class="expertise-no-match">No matching expertise found.</div>';
    container.querySelectorAll('[data-expertise-option]').forEach((button) => {
      button.onclick = () => {
        selectedExpertise = selectedExpertise.concat([button.dataset.expertiseOption]);
        document.getElementById('reg-expertise-search').value = '';
        renderExpertiseSelected();
        renderExpertiseOptions();
      };
    });
  }

  function addCertificationEntry() {
    certificationEntries.push({ id: 'cert-' + Date.now(), title: '', licenseNumber: '', issuer: '' });
    renderCertificationList();
  }

  function renderCertificationList() {
    const container = document.getElementById('reg-certification-list');
    if (!certificationEntries.length) {
      container.innerHTML = '<div class="certification-empty">Add only the certifications you actually hold.</div>';
      return;
    }
    container.innerHTML = certificationEntries.map((entry, index) => {
      return '<div class="certification-card">' +
        '<div class="certification-grid">' +
          '<input class="form-input" data-cert-title="' + index + '" placeholder="Certification title" value="' + escapeAttribute(entry.title) + '" />' +
          '<input class="form-input" data-cert-license="' + index + '" placeholder="License number (optional)" value="' + escapeAttribute(entry.licenseNumber) + '" />' +
          '<input class="form-input" data-cert-issuer="' + index + '" placeholder="Issuer" value="' + escapeAttribute(entry.issuer) + '" />' +
        '</div>' +
        '<button class="btn-ghost certification-remove" type="button" data-cert-remove="' + index + '">Remove</button>' +
      '</div>';
    }).join('');
    container.querySelectorAll('[data-cert-title], [data-cert-license], [data-cert-issuer]').forEach((field) => {
      field.oninput = () => syncCertificationEntries();
    });
    container.querySelectorAll('[data-cert-remove]').forEach((button) => {
      button.onclick = () => {
        certificationEntries.splice(Number(button.dataset.certRemove), 1);
        renderCertificationList();
      };
    });
  }

  function syncCertificationEntries() {
    certificationEntries = certificationEntries.map((entry, index) => ({
      id: entry.id,
      title: (document.querySelector('[data-cert-title="' + index + '"]') || {}).value || '',
      licenseNumber: (document.querySelector('[data-cert-license="' + index + '"]') || {}).value || '',
      issuer: (document.querySelector('[data-cert-issuer="' + index + '"]') || {}).value || ''
    }));
  }

  function renderDocumentFields() {
    const container = document.getElementById('reg-document-fields');
    container.innerHTML =
      '<div class="document-group">' +
        '<div class="document-group-title">Government ID <span class="document-group-meta">Required</span></div>' +
        renderDocumentCard('government_id', 'Government ID', true) +
      '</div>' +
      '<div class="document-group">' +
        '<div class="document-group-title">Proof of Address <span class="document-group-meta">One required</span></div>' +
        renderDocumentCard('bank_proof', 'Bank detail proof', false) +
        '<div class="document-group-or">OR</div>' +
        renderDocumentCard('utility_bill', 'Light bill', false) +
      '</div>' +
      '<div class="document-group">' +
        '<div class="document-group-title">Trade License <span class="document-group-meta">Optional</span></div>' +
        renderDocumentCard('certification', 'Trade license / certification', false) +
      '</div>';
    bindDocumentInputs();
    renderDocumentCards();
  }

  function renderOnboardingQuestions() {
    document.getElementById('onboarding-question-list').innerHTML = SAFETY_QUESTIONS.map((question) => {
      const chosen = validationAnswers[question.id] || [];
      return '<div class="elec-question-card">' +
        '<div class="elec-question-title">' + question.prompt + '</div>' +
        '<div class="validation-options">' + question.options.map((option) => {
          const active = chosen.includes(option.id) ? ' active' : '';
          return '<button class="validation-option' + active + '" type="button" data-question-id="' + question.id + '" data-option-id="' + option.id + '">' + option.label + '</button>';
        }).join('') + '</div>' +
        '<div class="validation-question-feedback">' + questionFeedback(question.id) + '</div>' +
      '</div>';
    }).join('');
    document.querySelectorAll('[data-question-id]').forEach((button) => {
      button.onclick = () => toggleValidationAnswer(button.dataset.questionId, button.dataset.optionId);
    });
    renderValidationFeedback();
  }

  function toggleValidationAnswer(questionId, optionId) {
    const current = validationAnswers[questionId] || [];
    validationAnswers[questionId] = current.includes(optionId)
      ? current.filter((value) => value !== optionId)
      : current.concat([optionId]);
    renderOnboardingQuestions();
  }

  function questionFeedback(questionId) {
    const question = SAFETY_QUESTIONS.find((item) => item.id === questionId);
    const selected = validationAnswers[questionId] || [];
    if (!question || !selected.length) return 'Select all answers that apply.';
    const score = scoreQuestion(question, selected);
    if (score === 1) return 'Correct';
    if (score > 0) return 'Partially correct';
    return 'Incorrect';
  }

  function renderValidationFeedback() {
    const feedback = document.getElementById('validation-feedback');
    if (!allValidationQuestionsAnswered()) {
      feedback.className = 'validation-feedback';
      feedback.textContent = 'Answer each question to complete validation.';
      return;
    }
    const result = computeValidationResult();
    feedback.className = 'validation-feedback ' + (result.percentage >= VALIDATION_PASS_THRESHOLD ? 'is-good' : 'is-review');
    feedback.textContent = result.percentage >= VALIDATION_PASS_THRESHOLD
      ? 'Good understanding of safety practices'
      : 'Needs review';
  }

  function allValidationQuestionsAnswered() {
    return SAFETY_QUESTIONS.every((question) => (validationAnswers[question.id] || []).length);
  }

  function computeValidationResult() {
    const answers = SAFETY_QUESTIONS.map((question) => {
      const selected = validationAnswers[question.id] || [];
      const score = scoreQuestion(question, selected);
      return {
        question: question.prompt,
        selected,
        score
      };
    });
    const percentage = Math.round((answers.reduce((sum, item) => sum + item.score, 0) / SAFETY_QUESTIONS.length) * 100);
    return { percentage, answers };
  }

  function scoreQuestion(question, selected) {
    const correct = question.options.filter((option) => option.correct).map((option) => option.id);
    const wrongSelections = selected.filter((id) => correct.indexOf(id) === -1);
    const correctSelections = selected.filter((id) => correct.indexOf(id) !== -1);
    if (!selected.length) return 0;
    if (!wrongSelections.length && correctSelections.length === correct.length) return 1;
    if (!wrongSelections.length && correctSelections.length) return 0.5;
    if (wrongSelections.length && correctSelections.length) return 0.25;
    return 0;
  }

  function renderDocumentCard(type, label, required) {
    return '<div class="doc-field-card" data-doc-card="' + type + '">' +
      '<div class="doc-field-top"><div class="doc-field-label">' + label + (required ? ' <span class="optional">(Required)</span>' : '') + '</div><button class="btn-ghost doc-remove-btn" type="button" data-doc-remove="' + type + '">Remove</button></div>' +
      '<div class="doc-field-help">Images and PDF accepted.</div>' +
      '<div class="doc-field-body" data-doc-body="' + type + '"></div>' +
      '<input class="doc-upload" id="doc-upload-' + type + '" data-document-type="' + type + '" type="file" accept="image/*,application/pdf" style="display:none" />' +
      '<div class="doc-field-actions"><button class="btn-secondary btn-full" type="button" data-doc-trigger="' + type + '">Upload</button></div>' +
    '</div>';
  }

  function bindDocumentInputs() {
    document.querySelectorAll('[data-doc-trigger]').forEach((button) => {
      button.onclick = () => document.getElementById('doc-upload-' + button.dataset.docTrigger).click();
    });
    document.querySelectorAll('#reg-document-fields .doc-upload').forEach((field) => {
      field.onchange = (event) => {
        const file = event.target.files && event.target.files[0] ? event.target.files[0] : null;
        if (!file) return;
        const previewUrl = file.type.indexOf('image/') === 0 ? URL.createObjectURL(file) : null;
        documentUploads[field.dataset.documentType] = { file, previewUrl, progress: 100, status: 'ready' };
        renderDocumentCards();
      };
    });
    document.querySelectorAll('[data-doc-remove]').forEach((button) => {
      button.onclick = () => {
        removeDocumentUpload(button.dataset.docRemove);
      };
    });
  }

  function renderDocumentCards() {
    Object.keys({
      government_id: true,
      bank_proof: true,
      utility_bill: true,
      certification: true
    }).forEach((type) => {
      const body = document.querySelector('[data-doc-body="' + type + '"]');
      if (!body) return;
      const item = documentUploads[type];
      if (!item) {
        body.innerHTML = '<div class="doc-empty-state">No file selected yet.</div>';
        return;
      }
      body.innerHTML =
        (item.previewUrl ? '<img class="doc-preview-image" src="' + item.previewUrl + '" alt="' + type + ' preview" />' : '<div class="doc-preview-file">PDF</div>') +
        '<div class="doc-file-meta"><strong>' + escapeHtml(item.file.name) + '</strong><span>' + escapeHtml(item.status === 'uploading' ? 'Uploading...' : item.status === 'uploaded' ? 'Uploaded' : 'Ready to upload') + '</span></div>' +
        '<div class="doc-progress"><span style="width:' + Number(item.progress || 0) + '%"></span></div>';
    });
  }

  function removeDocumentUpload(type) {
    const item = documentUploads[type];
    if (item && item.previewUrl) {
      URL.revokeObjectURL(item.previewUrl);
    }
    delete documentUploads[type];
    const input = document.getElementById('doc-upload-' + type);
    if (input) input.value = '';
    renderDocumentCards();
  }

  function handleDocumentUploadProgress(type, progress) {
    if (!documentUploads[type]) return;
    documentUploads[type].progress = progress.progress || 0;
    documentUploads[type].status = progress.status || 'ready';
    renderDocumentCards();
  }

  function nextRegistrationStepOne() {
    const required = ['reg-name', 'reg-phone', 'reg-email', 'reg-password', 'reg-location'];
    const missing = required.some((id) => !document.getElementById(id).value.trim());
    if (missing) {
      showError('Complete your personal details before continuing.');
      return;
    }
    renderRegistrationOptions();
    goTo('elec-reg-2');
  }

  async function nextRegistrationStepTwo() {
    let serviceAreas = activeChipValues('#reg-service-areas .chip.active', 'area');
    const fallbackLocation = document.getElementById('reg-location').value.trim();
    if (!serviceAreas.length && fallbackLocation) {
      serviceAreas = [fallbackLocation];
    }
    if (!serviceAreas.length) {
      showError('Choose at least one service area before continuing.');
      return;
    }
    await Store.loadExpertiseCategories().catch(() => null);
    renderExpertiseOptions();
    goTo('elec-reg-3');
  }

  function nextRegistrationStepThree() {
    const experience = document.getElementById('reg-experience').value;
    syncCertificationEntries();
    if (!experience || !selectedExpertise.length) {
      showError('Add your experience and skill set before continuing.');
      return;
    }
    if (!allValidationQuestionsAnswered()) {
      showError('Answer every safety validation question before continuing.');
      return;
    }
    selectedSkills = selectedExpertise.slice();
    goTo('elec-reg-4');
  }

  function nextRegistrationStepFour() {
    if (!documentUploads.government_id || !(documentUploads.bank_proof || documentUploads.utility_bill)) {
      showError('Upload Government ID and at least one proof of address before continuing.');
      return;
    }
    goTo('elec-reg-5');
  }

  async function submitApplication() {
    await withButtonLoading('btn-submit-application', 'Submitting Application...', async () => {
      if (!document.getElementById('reg-onboarding-confirm').checked) {
        throw new Error('Confirm the onboarding rules before submitting your application.');
      }

      if (!allValidationQuestionsAnswered()) {
        throw new Error('Answer every safety validation question before submitting.');
      }

      syncCertificationEntries();
      const documents = Object.keys(documentUploads).map((type) => ({
        type,
        file: documentUploads[type].file
      })).filter((documentItem) => documentItem.file);
      if (!documentUploads.government_id || !(documentUploads.bank_proof || documentUploads.utility_bill)) {
        throw new Error('Upload Government ID and at least one proof of address before submitting.');
      }

      if (!document.getElementById('reg-payout-bank').value.trim() || !document.getElementById('reg-payout-account-number').value.trim() || !document.getElementById('reg-payout-account-name').value.trim()) {
        throw new Error('Add payout bank details before submitting.');
      }

      const validation = computeValidationResult();

      pendingElectricianSignupPayload = {
        fullName: document.getElementById('reg-name').value.trim(),
        phone: document.getElementById('reg-phone').value.trim(),
        email: document.getElementById('reg-email').value.trim(),
        password: document.getElementById('reg-password').value.trim(),
        locationLabel: document.getElementById('reg-location').value.trim(),
        yearsExperience: parseInt(document.getElementById('reg-experience').value, 10) || 0,
        availabilityStatus: document.getElementById('reg-availability-status').value || 'available',
        serviceAreas: activeChipValues('#reg-service-areas .chip.active', 'area'),
        skills: selectedExpertise.slice(),
        bankName: document.getElementById('reg-payout-bank').value.trim(),
        bankAccountNumber: document.getElementById('reg-payout-account-number').value.trim(),
        bankAccountName: document.getElementById('reg-payout-account-name').value.trim(),
        profilePhoto: pendingProfilePhoto,
        documents: documents,
        certifications: certificationEntries.filter((item) => item.title.trim()).map((item) => ({
          title: item.title.trim(),
          licenseNumber: item.licenseNumber.trim(),
          issuer: item.issuer.trim()
        })),
        onboardingValidationScore: validation.percentage,
        onboardingReviewStatus: validation.percentage >= VALIDATION_PASS_THRESHOLD ? 'passed' : 'needs_review',
        onboardingFeedback: validation.percentage >= VALIDATION_PASS_THRESHOLD ? 'Good understanding of safety practices' : 'Needs review',
        onboardingAnswers: validation.answers,
        onDocumentUploadProgress: handleDocumentUploadProgress
      };
      const signupResult = await Store.signUpElectrician(pendingElectricianSignupPayload);

      const pendingAccount = Store.getCurrentElectrician() || { id: (signupResult && signupResult.user && signupResult.user.id) || 'pending' };
      if (signupResult && signupResult.user && !signupResult.session) {
        renderPendingDashboard({
          id: pendingAccount.id,
          status: 'pending',
          service_areas: pendingElectricianSignupPayload.serviceAreas,
          availability_status: pendingElectricianSignupPayload.availabilityStatus
        }, { verificationRequired: true });
        goTo('elec-pending');
        return;
      }

      pendingElectricianSignupPayload = null;
      await resumeSession({ screen: 'elec-dashboard', data: null, source: 'signup' });
    });
  }

  async function verifyPendingElectricianSignup() {
    const payload = pendingElectricianSignupPayload;
    if (!payload || !payload.email) {
      showError('Restart the application so we can verify the right email.');
      return;
    }
    await withButtonLoading('btn-pending-verify', 'Verifying...', async () => {
      const token = document.getElementById('pending-token').value.replace(/\D/g, '');
      if (token.length !== 6) throw new Error('Enter the 6-digit code from your email.');
      await Store.verifySignupOtp(payload.email, token);
      await Store.finishElectricianSignup(payload);
      pendingElectricianSignupPayload = null;
      document.getElementById('pending-token').value = '';
      await resumeSession({ screen: 'elec-dashboard', data: null, source: 'signup' });
    });
  }

  async function resendPendingElectricianSignupCode() {
    const payload = pendingElectricianSignupPayload;
    if (!payload || !payload.email) {
      showError('Restart the application so we can resend the right email code.');
      return;
    }
    await withButtonLoading('btn-pending-resend', 'Resending...', async () => {
      await Store.resendSignupOtp(payload.email, '/electricians/login?verify=signup');
      showNotice('A fresh 6-digit code has been sent to your email.');
    });
  }

  async function refreshPendingDashboard() {
    await withButtonLoading('btn-pending-refresh', 'Refreshing...', async () => {
      await Store.init();
      await resumeSession({ screen: 'elec-dashboard', data: null, source: 'refresh' });
    });
  }

  function renderPendingDashboard(electrician, options) {
    const profile = Store.getCurrentProfile() || {};
    const payload = pendingElectricianSignupPayload || {};
    const row = electrician || {};
    const isRejected = row.status === 'rejected';
    const verifyCard = document.getElementById('pending-verify-card');
    const summary = document.getElementById('pending-dashboard-summary');
    const note = document.getElementById('pending-status-note');
    const ref = document.getElementById('pending-ref-id');

    document.querySelector('.elec-pending-title').textContent = isRejected ? 'Application Needs Review' : 'Pending Dashboard';
    document.querySelector('.elec-pending-sub').textContent = isRejected
      ? 'Your onboarding has not been approved yet. VoltFriq support will contact you.'
      : 'Your VoltFriq account is under review. You can stay signed in here while admin completes approval.';
    if (ref) ref.textContent = String(row.id || 'pending').slice(0, 8).toUpperCase();
    if (verifyCard) verifyCard.style.display = options && options.verificationRequired ? 'block' : 'none';
    if (note) {
      note.textContent = options && options.verificationRequired
        ? 'Verify your email to complete setup. Your dashboard will remain pending until admin approval.'
        : isRejected
          ? 'Contact VoltFriq support if you need help with your application or account status.'
          : 'You will be able to receive nearby requests after admin approval.';
    }
    if (summary) {
      summary.innerHTML = [
        ['Name', profile.full_name || payload.fullName || '--'],
        ['Phone', profile.phone || payload.phone || '--'],
        ['Status', row.status || 'pending'],
        ['Availability', row.availability_status || payload.availabilityStatus || 'available'],
        ['Service areas', (row.service_areas || payload.serviceAreas || []).join(', ') || '--']
      ].map(profileRow).join('');
    }
  }

  async function loadDashboard() {
    try {
      renderDashboardLoading();
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
    goTo('elec-job-detail', {
      routeData: { ticket: currentJob.ticket }
    });
    return currentJob;
  }

  async function openJobByTicket(ticket) {
    const cleanTicket = String(ticket || '').trim().toUpperCase();
    const jobs = currentJobs.length ? currentJobs : await Store.listElectricianJobs();
    const match = jobs.find((job) => String(job.ticket || '').toUpperCase() === cleanTicket);
    if (!match) return null;
    return openJob(match.id);
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
    goTo('elec-assessment', {
      routeData: { ticket: currentJob ? currentJob.ticket : null }
    });
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
    goTo('elec-confirm', {
      routeData: { ticket: currentJob ? currentJob.ticket : null }
    });
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
    goTo('elec-chat', {
      routeData: { ticket: currentJob.ticket }
    });
    await Chat.init('elec-chat-container', currentJob.id, 'electrician', (Store.getCurrentProfile() || {}).full_name || 'VoltFriq');
  }

  function closeChat() {
    chatOpen = false;
    if (currentJob) {
      goTo('elec-job-detail', {
        routeData: { ticket: currentJob.ticket }
      });
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
    window.location.href = '/electricians/login';
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

  function getRegistrationServiceAreas(settings) {
    const configured = Array.isArray(settings.service_areas) ? settings.service_areas.filter(Boolean) : [];
    const fallbackLocation = document.getElementById('reg-location') ? document.getElementById('reg-location').value.trim() : '';
    const areas = configured.slice();
    if (fallbackLocation && !areas.some((area) => area.toLowerCase() === fallbackLocation.toLowerCase())) {
      areas.unshift(fallbackLocation);
    }
    return areas.length ? areas : [];
  }

  function renderLocationDatalist(areas) {
    let datalist = document.getElementById('electrician-service-area-options');
    if (!datalist) {
      datalist = document.createElement('datalist');
      datalist.id = 'electrician-service-area-options';
      document.body.appendChild(datalist);
    }
    datalist.innerHTML = (areas || []).map((area) => '<option value="' + escapeAttribute(area) + '"></option>').join('');
    const locationInput = document.getElementById('reg-location');
    if (locationInput) locationInput.setAttribute('list', 'electrician-service-area-options');
  }

  function getRegistrationSkillOptions(settings) {
    const configured = Store.getExpertiseCategories ? Store.getExpertiseCategories().filter(Boolean) : [];
    if (configured.length) return configured;
    const fallbackSettings = Array.isArray(settings.issue_categories) ? settings.issue_categories.filter(Boolean) : [];
    if (fallbackSettings.length) return fallbackSettings;
    return DEFAULT_SKILL_OPTIONS;
  }

  function chipMarkup(type, label, active = false) {
    return '<button type="button" class="chip' + (active ? ' active' : '') + '" data-' + type + '="' + escapeAttribute(label) + '">' + escapeHtml(label) + '</button>';
  }

  function toggleChip(event) {
    const chip = event.target.closest('.chip');
    if (chip) chip.classList.toggle('active');
  }

  function activeChipValues(selector, key) {
    return Array.from(document.querySelectorAll(selector)).map((chip) => chip.dataset[key]).filter(Boolean);
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
      showError(error.message || 'Action failed.');
      return null;
    } finally {
      if (button) {
        button.innerHTML = originalHtml || originalText;
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

  function escapeAttribute(value) {
    return escapeHtml(value).replace(/`/g, '&#96;');
  }

  function showError(message) {
    const loginError = document.getElementById('login-error');
    if (currentScreen === 'elec-login' && loginError) {
      loginError.classList.remove('is-success');
      loginError.textContent = message;
      loginError.style.display = 'block';
      return;
    }
    const screen = document.querySelector('.screen.active') || document.getElementById('screen-elec-login');
    if (!screen) return;
    let banner = screen.querySelector('.elec-inline-error');
    if (!banner) {
      banner = document.createElement('div');
      banner.className = 'elec-inline-error';
      const target = screen.querySelector('.elec-reg-body, .elec-job-scroll, .elec-dash-scroll, .elec-pending-wrap, .elec-login-content, .elec-confirm-scroll, .elec-profile-scroll, .elec-history-scroll, .elec-appeal-wrap') || screen;
      target.insertBefore(banner, target.firstChild);
    }
    banner.classList.remove('is-success');
    banner.textContent = message;
    banner.style.display = 'block';
    if (typeof banner.scrollIntoView === 'function') {
      banner.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  }

  function clearError() {
    const error = document.getElementById('login-error');
    if (error) {
      error.classList.remove('is-success');
      error.textContent = '';
      error.style.display = 'none';
    }
    document.querySelectorAll('.elec-inline-error').forEach((banner) => {
      banner.classList.remove('is-success');
      banner.textContent = '';
      banner.style.display = 'none';
    });
  }

  document.addEventListener('DOMContentLoaded', init);

  function showNotice(message) {
    const loginError = document.getElementById('login-error');
    if (currentScreen !== 'elec-login') {
      const screen = document.querySelector('.screen.active') || document.getElementById('screen-elec-login');
      if (!screen) return;
      let banner = screen.querySelector('.elec-inline-error');
      if (!banner) {
        banner = document.createElement('div');
        banner.className = 'elec-inline-error';
        const target = screen.querySelector('.elec-reg-body, .elec-job-scroll, .elec-dash-scroll, .elec-pending-wrap, .elec-login-content, .elec-confirm-scroll, .elec-profile-scroll, .elec-history-scroll, .elec-appeal-wrap') || screen;
        target.insertBefore(banner, target.firstChild);
      }
      banner.classList.add('is-success');
      banner.textContent = message;
      banner.style.display = 'block';
      return;
    }
    if (!loginError) return;
    loginError.classList.add('is-success');
    loginError.textContent = message;
    loginError.style.display = 'block';
  }

  function updateLoginRecoveryState() {
    const subtitle = document.querySelector('.elec-login-subtitle');
    const passwordLabel = document.querySelector('.elec-login-form .form-group:nth-child(2) .form-label');
    const passwordInput = document.getElementById('login-password');
    const button = document.getElementById('btn-login');
    const forgot = document.getElementById('btn-login-forgot');
    const apply = document.getElementById('btn-apply');
    if (!subtitle || !passwordLabel || !passwordInput || !button || !forgot || !apply) return;
    if (wantsPasswordReset()) {
      subtitle.textContent = 'Set a New Password';
      passwordLabel.textContent = 'New Password';
      passwordInput.placeholder = 'Enter your new password';
      button.textContent = 'Update Password';
      forgot.style.display = 'none';
      apply.style.display = 'none';
      return;
    }
    subtitle.textContent = 'Electrician Portal';
    passwordLabel.textContent = 'Password';
    passwordInput.placeholder = 'Enter password';
    button.textContent = 'Login';
    forgot.style.display = '';
    apply.style.display = '';
  }

  function renderDashboardLoading() {
    const stack = '<div class="skeleton-card"></div><div class="skeleton-card"></div>';
    [
      ['stat-jobs-month', '...'],
      ['stat-earnings', '...'],
      ['stat-rating', '--'],
      ['stat-payouts', '...']
    ].forEach(([id, value]) => {
      const stat = document.getElementById(id);
      if (stat) stat.textContent = value;
    });
    ['dash-progress-jobs', 'dash-new-assignments', 'dash-accepted-jobs', 'dash-completed-jobs'].forEach((id) => {
      const container = document.getElementById(id);
      if (container) container.innerHTML = stack;
    });
  }

  function normalizeElectricianPath(pathname) {
    const raw = String(pathname || '/electricians/login').trim();
    if (!raw) return '/electricians/login';
    const cleaned = raw.replace(/\/+$/, '');
    return cleaned || '/electricians/login';
  }

  return {
    openChat,
    closeChat
  };
})();
