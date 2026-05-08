  function renderRegistrationOptions() {
    const settings = Store.getSettings();
    const selectedAreas = activeChipValues('#reg-service-areas .chip.active', 'area');
    const serviceAreas = getRegistrationServiceAreas(settings);
    renderElectricianAddressControls();
    const selectedLocation = renderLocationSelect(serviceAreas);

    document.getElementById('reg-service-areas').innerHTML = serviceAreas.length
      ? serviceAreas.map((area) => {
          const lowerArea = area.toLowerCase();
          const shouldActivate = selectedAreas.some((selected) => selected.toLowerCase() === lowerArea)
            || (selectedLocation && selectedLocation.toLowerCase() === lowerArea)
            || serviceAreas.length === 1;
          return chipMarkup('area', area, shouldActivate);
        }).join('')
      : '<div class="expertise-empty">No service areas are configured yet.</div>';

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
    const required = ['reg-name', 'reg-phone', 'reg-email', 'reg-password', 'reg-country', 'reg-state', 'reg-city', 'reg-street-address', 'reg-location'];
    const missing = required.some((id) => !document.getElementById(id).value.trim());
    if (missing) {
      showError('Complete your personal details and full service address before continuing.');
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
      const address = getElectricianAddressDraft();
      const chosenServiceAreas = activeChipValues('#reg-service-areas .chip.active', 'area');

      pendingElectricianSignupPayload = {
        fullName: document.getElementById('reg-name').value.trim(),
        phone: document.getElementById('reg-phone').value.trim(),
        email: document.getElementById('reg-email').value.trim(),
        password: document.getElementById('reg-password').value.trim(),
        country: address.country,
        state: address.state,
        city: address.city,
        streetAddress: address.streetAddress,
        street_address: address.street_address,
        locationLabel: address.locationLabel,
        location_label: address.location_label,
        baseLocationLabel: address.baseLocationLabel,
        base_location_label: address.base_location_label,
        yearsExperience: parseInt(document.getElementById('reg-experience').value, 10) || 0,
        availabilityStatus: document.getElementById('reg-availability-status').value || 'available',
        serviceAreas: chosenServiceAreas.length ? chosenServiceAreas : address.serviceAreas,
        service_areas: chosenServiceAreas.length ? chosenServiceAreas : address.serviceAreas,
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
      persistPendingElectricianSignup(pendingElectricianSignupPayload);
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

      clearPendingElectricianSignup();
      await resumeSession({ screen: 'elec-dashboard', data: null, source: 'signup' });
    });
  }

  async function verifyPendingElectricianSignup() {
    const payload = loadPendingElectricianSignup();
    if (!payload || !payload.email) {
      showError('Restart the application so we can verify the right email.');
      return;
    }
    await withButtonLoading('btn-pending-verify', 'Verifying...', async () => {
      const token = document.getElementById('pending-token').value.replace(/\D/g, '');
      if (token.length !== 6) throw new Error('Enter the 6-digit code from your email.');
      await Store.verifySignupOtp(payload.email, token);
      await Store.finishElectricianSignup(payload);
      clearPendingElectricianSignup();
      document.getElementById('pending-token').value = '';
      await resumeSession({ screen: 'elec-dashboard', data: null, source: 'signup' });
    });
  }

  async function resendPendingElectricianSignupCode() {
    const payload = loadPendingElectricianSignup();
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
    const payload = loadPendingElectricianSignup() || {};
    const row = electrician || {};
    const isRejected = row.status === 'rejected';
    const documentCount = (row.electrician_documents || []).length;
    const missingDocuments = !isRejected && !(options && options.verificationRequired) && !documentCount;
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
          : missingDocuments
            ? 'Your account was created, but document uploads are missing on this device. Admin may request documents before approval.'
            : 'You will be able to receive nearby requests after admin approval.';
    }
    if (summary) {
      const serviceAreas = row.service_areas && row.service_areas.length ? row.service_areas : payload.serviceAreas || [];
      summary.innerHTML = [
        ['Name', profile.full_name || payload.fullName || '--'],
        ['Phone', profile.phone || payload.phone || '--'],
        ['Location', row.location_label || payload.locationLabel || payload.location_label || '--'],
        ['Status', row.status || 'pending'],
        ['Availability', row.availability_status || payload.availabilityStatus || 'available'],
        ['Service areas', serviceAreas.join(', ') || '--'],
        ['Documents', documentCount ? documentCount + ' uploaded' : 'Missing']
      ].map(profileRow).join('');
    }
  }

