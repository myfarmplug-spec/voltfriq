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
      showError('Choose a Nigerian location before continuing.');
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
