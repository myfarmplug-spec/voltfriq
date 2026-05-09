  async function showHistory(fromRoute, options) {
    if (!Store.getCurrentProfile()) {
      openCustomerAuthScreen('tracking', 'login', { replace: !!(options && options.replace) });
      return;
    }
    try {
      setScreenBusy(true, 'Routing your job updates...');
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
        sub.textContent = 'Manage active jobs, history, and account details in one place.';
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

    let destination;
    if (role === 'admin') {
      destination = Store.getRoleHome('admin');
    } else if (role === 'electrician') {
      destination = Store.getRoleHome('electrician');
    } else {
      destination = null;
    }

    if (destination) {
      window.location.href = destination;
      return;
    }

    try {
      setScreenBusy(true, 'Syncing your dashboard...');
      renderDashboardLoading();
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
      ['Service area', latestJob ? latestJob.serviceArea || '--' : 'Nigeria'],
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
        ? 'VoltFriq is checking availability'
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
    if (document.getElementById('manual-street-address')) document.getElementById('manual-street-address').value = '';
    document.getElementById('problem-category').value = '';
    document.getElementById('problem-desc').value = '';
    if (document.getElementById('review-phone')) document.getElementById('review-phone').value = '';
    if (document.getElementById('address-entry-panel')) document.getElementById('address-entry-panel').hidden = true;
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
	      const phoneConfirmation = currentJob.isGuest ? promptForGuestPhoneConfirmation() : null;
	      await Store.createDispute(currentJob.id, issueType, document.getElementById('dispute-details').value.trim(), phoneConfirmation);
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
    let restoreButton = () => {};
    if (button && window.VoltFriqMotion) {
      restoreButton = window.VoltFriqMotion.setButtonLoading(button, loadingText);
    } else if (button) {
      const originalHtml = button.innerHTML;
      const wasDisabled = button.disabled;
      button.disabled = true;
      button.textContent = loadingText;
      restoreButton = () => {
        button.innerHTML = originalHtml;
        button.disabled = wasDisabled;
      };
    }
    clearError();
    try {
      return await work();
    } catch (error) {
      showError(error);
      return null;
    } finally {
      restoreButton();
    }
  }

  function setScreenBusy(nextBusy, message) {
    screenBusy = nextBusy;
    if (!nextBusy) return;
    clearError();
    const authError = document.getElementById('auth-error');
    authError.style.display = 'block';
    if (window.VoltFriqMotion) {
      window.VoltFriqMotion.setStatusLoading(authError, message || 'Transmitting...');
    } else {
      authError.textContent = message || 'Transmitting...';
    }
  }

  function clearError() {
    if (screenBusy) screenBusy = false;
    const authError = document.getElementById('auth-error');
    if (authError) {
      authError.classList.remove('is-success');
      if (window.VoltFriqMotion) window.VoltFriqMotion.clearStatusLoading(authError);
      authError.style.display = 'none';
      authError.textContent = '';
    }
    document.querySelectorAll('.flow-error').forEach((error) => {
      if (window.VoltFriqMotion) window.VoltFriqMotion.clearStatusLoading(error);
      error.style.display = 'none';
      error.textContent = '';
    });
  }

  function showError(error) {
    const rawMessage = typeof error === 'string'
      ? error
      : error && error.message
        ? error.message
        : 'Something went wrong.';
    const message = friendlyCustomerError(rawMessage);
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

  function friendlyCustomerError(message) {
    const text = String(message || '').trim();
    const lower = text.toLowerCase();
    if (lower.includes('auth-token') && lower.includes('lock') && (lower.includes('stole it') || lower.includes('released'))) {
      return 'Your secure session refreshed while we were booking. Please tap Submit Booking once more.';
    }
    if (lower.includes('job_timeline') && lower.includes('actor_profile_id') && lower.includes('foreign key')) {
      return 'We are finishing your booking setup. Please tap Submit Booking once more in a moment.';
    }
    if (lower.includes('customer profile not found')) {
      return 'Your account setup is finishing. Please tap Submit Booking again in a moment.';
    }
    if (lower.includes('sms provider') || lower.includes('dispatch verification code')) {
      return 'We saved your booking, but could not send the phone verification code. Please try again in a moment.';
    }
    return text || 'Something went wrong.';
  }

  async function uploadGuestTrackingPhotos(input) {
    try {
      if (!currentJob || !input || !input.files || !input.files.length) return;
      setScreenBusy(true, 'Transmitting photos...');
      const job = await Store.uploadGuestJobPhotos(currentJob.id, Array.from(input.files));
      currentJob = job;
      showNotice('Photos added to your booking.');
      renderAssigned(job);
    } catch (error) {
      if (error && error.queued) {
        showNotice(error.message);
      } else {
        showError(error);
      }
    } finally {
      if (input) input.value = '';
      setScreenBusy(false);
    }
  }

  function promptForGuestPhoneConfirmation() {
    const value = window.prompt('Confirm the last 4 digits of the phone number used for this booking.');
    if (!value || value.replace(/\D/g, '').length < 4) {
      throw new Error('Confirm the phone number used for this booking.');
    }
    return value.replace(/\D/g, '').slice(-4);
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
