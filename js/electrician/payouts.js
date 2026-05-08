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

  async function toggleDashboardAvailability() {
    const electrician = Store.getCurrentElectrician();
    if (!electrician) return;
    const nextStatus = electrician.availability_status === 'available' ? 'offline' : 'available';
    await withButtonLoading('btn-dash-toggle-availability', nextStatus === 'available' ? 'Going available...' : 'Going offline...', async () => {
      await Store.updateCurrentElectrician({ availability_status: nextStatus });
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
    if (Store.getServiceAreas) return Store.getServiceAreas();
    return Array.isArray(settings.service_areas) ? settings.service_areas.filter(Boolean) : [];
  }

  function renderElectricianAddressControls() {
    renderSelectOptions('reg-country', [DEFAULT_COUNTRY], getElementValue('reg-country') || DEFAULT_COUNTRY, 'Select country');
    renderSelectOptions('reg-state', SUPPORTED_STATES, getElementValue('reg-state'), 'Select state');
    renderElectricianCityOptions();
  }

  function renderElectricianCityOptions() {
    const state = getElementValue('reg-state');
    const currentCity = getElementValue('reg-city');
    const cities = CITY_OPTIONS[state] || [];
    renderSelectOptions('reg-city', cities, currentCity, 'Select city or LGA');
  }

  function renderSelectOptions(id, options, currentValue, placeholder) {
    const select = document.getElementById(id);
    if (!select) return '';
    const safeOptions = (options || []).filter(Boolean);
    const cleanValue = String(currentValue || '').trim();
    select.innerHTML = '<option value="">' + escapeHtml(placeholder || 'Select') + '</option>' +
      safeOptions.map((option) => '<option value="' + escapeAttribute(option) + '">' + escapeHtml(option) + '</option>').join('');
    if (cleanValue && safeOptions.some((option) => option.toLowerCase() === cleanValue.toLowerCase())) {
      const match = safeOptions.find((option) => option.toLowerCase() === cleanValue.toLowerCase());
      select.value = match;
      return match;
    }
    if (id === 'reg-country' && !cleanValue) {
      select.value = DEFAULT_COUNTRY;
      return DEFAULT_COUNTRY;
    }
    select.value = '';
    return '';
  }

  function getElementValue(id) {
    const element = document.getElementById(id);
    return element ? String(element.value || '').trim() : '';
  }

  function getElectricianAddressDraft() {
    const country = getElementValue('reg-country') || DEFAULT_COUNTRY;
    const state = getElementValue('reg-state');
    const city = getElementValue('reg-city');
    const streetAddress = getElementValue('reg-street-address');
    const closestServiceArea = getElementValue('reg-location');
    const locationLabel = [streetAddress, city, state, country].filter(Boolean).join(', ');
    const inferredServiceArea = Store.inferServiceAreaFromAddress
      ? Store.inferServiceAreaFromAddress({
          serviceArea: closestServiceArea,
          locationLabel,
          streetAddress,
          city,
          state,
          country
        })
      : '';
    const serviceArea = closestServiceArea || inferredServiceArea;
    return {
      country,
      state,
      city,
      streetAddress,
      street_address: streetAddress,
      closestServiceArea: serviceArea,
      locationLabel,
      location_label: locationLabel,
      baseLocationLabel: locationLabel,
      base_location_label: locationLabel,
      serviceAreas: serviceArea ? [serviceArea] : []
    };
  }

  function renderLocationSelect(areas) {
    const locationSelect = document.getElementById('reg-location');
    if (!locationSelect) return '';
    const currentValue = locationSelect.value;
    const safeAreas = (areas || []).filter(Boolean);
    const address = getElectricianAddressDraft();
    const inferredValue = address.closestServiceArea || '';
    locationSelect.innerHTML = '<option value="">Select closest service area</option>' +
      safeAreas.map((area) => '<option value="' + escapeAttribute(area) + '">' + escapeHtml(area) + '</option>').join('');
    if (currentValue && safeAreas.some((area) => area.toLowerCase() === currentValue.toLowerCase())) {
      const match = safeAreas.find((area) => area.toLowerCase() === currentValue.toLowerCase());
      locationSelect.value = match;
      return match;
    }
    if (inferredValue && safeAreas.some((area) => area.toLowerCase() === inferredValue.toLowerCase())) {
      const match = safeAreas.find((area) => area.toLowerCase() === inferredValue.toLowerCase());
      locationSelect.value = match;
      return match;
    }
    locationSelect.value = '';
    return '';
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

  function urgencyBadgeClass(value) {
    if (value === 'emergency') return 'badge-red';
    if (value === 'today') return 'badge-yellow';
    return 'badge-blue';
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

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }

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
    if (cleaned === '/electric' || cleaned === '/electrician') return '/electricians/login';
    if (cleaned.indexOf('/electric/') === 0) return '/electricians/' + cleaned.slice('/electric/'.length);
    if (cleaned.indexOf('/electrician/') === 0) return '/electricians/' + cleaned.slice('/electrician/'.length);
    return cleaned || '/electricians/login';
  }

  return {
    openChat,
    closeChat
  };
})();
