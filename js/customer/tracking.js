  async function resumeLatestJob(options) {
    if (!Store.getCurrentProfile() && Store.getGuestAccess()) {
      try {
        const guestJob = await Store.getGuestJob(Store.getGuestAccess().jobId, Store.getGuestAccess().accessToken);
        if (guestJob && !['rated', 'cancelled'].includes(guestJob.status)) {
          await openTrackedJob(guestJob.id, { replace: !!(options && options.replace) });
          return;
        }
      } catch (error) {
        Store.clearGuestAccess();
      }
    }
    const jobs = await Store.listCustomerJobs();
    const active = jobs.find((job) => !['rated', 'cancelled'].includes(job.status));
    if (active) {
      await openTrackedJob(active.id, { replace: !!(options && options.replace) });
      return;
    }
    if (jobs[0]) {
      currentJob = jobs[0];
    }
    if (options && options.preferTracking) {
      goTo('welcome', { replace: !!options.replace });
      return;
    }
    goTo('welcome', { replace: !!(options && options.replace) });
  }

  async function openTrackedJob(jobId, options) {
    currentJob = await Store.getJob(jobId);
    currentTrackedTicket = currentJob.ticket || null;
    bindJobSubscription(jobId);
    routeJob(currentJob, false, options);
    refreshWelcomeActions();
    renderSidecars();
    return currentJob;
  }

  async function openTrackedJobByTicket(ticket, options) {
    const cleanTicket = String(ticket || '').trim().toUpperCase();
    if (!cleanTicket) return null;

    if (!Store.getCurrentProfile() && Store.getGuestAccess()) {
      try {
        const guestJob = await Store.getGuestJob(Store.getGuestAccess().jobId, Store.getGuestAccess().accessToken);
        if (guestJob && String(guestJob.ticket || '').toUpperCase() === cleanTicket) {
          return openTrackedJob(guestJob.id, options);
        }
      } catch (error) {
        Store.clearGuestAccess();
      }
    }

    const jobs = Store.getCurrentProfile()
      ? await Store.listCustomerJobs()
      : [];
    const match = jobs.find((job) => String(job.ticket || '').toUpperCase() === cleanTicket);
    if (!match) return null;
    return openTrackedJob(match.id, options);
  }

  function bindJobSubscription(jobId) {
    if (jobSubscription) jobSubscription.unsubscribe();
    jobSubscription = Store.subscribeToJob(jobId, async (job) => {
      currentJob = job;
       currentTrackedTicket = job.ticket || currentTrackedTicket;
      routeJob(job, true, { routeData: { ticket: job.ticket || currentTrackedTicket }, replace: true });
      renderSidecars();
      if (chatOpen) {
        await Chat.render();
      }
    });
  }

  function routeJob(job, preserveScreen, options) {
    const routeOptions = Object.assign({}, options || {}, {
      routeData: { ticket: job.ticket || currentTrackedTicket }
    });
    renderAssigned(job);

    if (job.status === 'assessment_fee_pending' || job.status === 'assessment_payment_pending_verification' || job.status === 'assessment_confirmed') {
      renderAssessmentFee(job);
      if (!preserveScreen && ['assessment_fee_pending', 'assessment_payment_pending_verification'].includes(job.status)) goTo('appearance-fee', routeOptions);
      if (job.status === 'assessment_confirmed' && !preserveScreen) goTo('assigned', routeOptions);
      return;
    }

    if (job.status === 'quoted') {
      renderQuoteScreen(job);
      if (!preserveScreen) goTo('quotation', routeOptions);
      return;
    }

    if (job.status === 'quote_accepted' || job.status === 'work_payment_pending_verification' || job.status === 'payment_confirmed') {
      renderPaymentScreen(job);
      if (!preserveScreen && ['quote_accepted', 'work_payment_pending_verification'].includes(job.status)) goTo('payment', routeOptions);
      if (job.status === 'payment_confirmed' && !preserveScreen) goTo('assigned', routeOptions);
      return;
    }

    if (job.status === 'electrician_completed' || job.status === 'customer_confirmed' || job.status === 'payout_pending') {
      renderConfirmScreen(job);
      if (!preserveScreen && job.status === 'electrician_completed') goTo('confirm-work', routeOptions);
      if (!preserveScreen && ['customer_confirmed', 'payout_pending'].includes(job.status)) goTo('assigned', routeOptions);
      return;
    }

    if (job.status === 'payout_complete') {
      if (job.isGuest) {
        renderDoneScreen(job);
        if (!preserveScreen) goTo('done', routeOptions);
        return;
      }
      renderRatingScreen(job);
      if (!preserveScreen) goTo('rating', routeOptions);
      return;
    }

    if (job.status === 'rated') {
      renderDoneScreen(job);
      if (!preserveScreen) goTo('done', routeOptions);
      return;
    }

    if (!preserveScreen) goTo('assigned', routeOptions);
  }

  function renderAssigned(job) {
    currentTrackedTicket = job.ticket || currentTrackedTicket;
    currentJob = job;
    renderTrackingHero(job);
    renderTrackingProgress(job);
    renderTrackingDetails(job);
  }

  function renderTrackingHero(job) {
    const title = document.getElementById('tracking-hero-title');
    const sub = document.getElementById('tracking-hero-sub');
    const note = document.getElementById('tracking-hero-note');
    if (!title || !sub || !note) return;

    if (job && job.assignedElectrician) {
      title.textContent = 'Your VoltFriq has been assigned';
      sub.textContent = job.assignedElectrician.name
        ? job.assignedElectrician.name + ' is attached to this booking.'
        : 'A verified electrician is attached to this booking.';
      note.textContent = 'Keep this page open for the next job update.';
      return;
    }

    title.textContent = 'Booking confirmed';
    sub.textContent = 'Pairing you with a VoltFriq';
    note.textContent = 'Finding a verified electrician near you.';
  }

  function getTrackingStageIndex(job) {
    const status = (job && job.status) || 'matching';
    if (['rated', 'payout_complete', 'payout_pending', 'customer_confirmed', 'electrician_completed'].includes(status)) return 4;
    if (['en_route', 'on_site', 'work_in_progress'].includes(status)) return 3;
    if ([
      'assigned',
      'accepted',
      'assessment_fee_pending',
      'assessment_payment_pending_verification',
      'assessment_confirmed',
      'quoted',
      'quote_accepted',
      'work_payment_pending_verification',
      'payment_confirmed'
    ].includes(status)) return 2;
    return 1;
  }

  function renderTrackingProgress(job) {
    const container = document.getElementById('tracking-progress');
    if (!container) return;
    const activeIndex = getTrackingStageIndex(job);
    const submittedTime = formatTrackingTime(job && job.createdAt);
    const screen = document.getElementById('screen-assigned');
    if (screen) screen.classList.toggle('is-pairing', activeIndex === 1);
    const steps = [
      { title: 'Submitted', sub: submittedTime, icon: 'check' },
      { title: 'Pairing', sub: activeIndex === 1 ? 'Finding VoltFriq' : 'Done', icon: 'bolt' },
      { title: 'Assigned', sub: activeIndex >= 2 ? 'Done' : 'Pending', icon: 'person' },
      { title: 'On the way', sub: activeIndex >= 3 ? 'In progress' : 'Pending', icon: 'car' },
      { title: 'Completed', sub: activeIndex >= 4 ? 'Done' : 'Pending', icon: 'flag' }
    ];
    container.innerHTML = steps.map((step, index) => {
      const state = index < activeIndex ? 'done' : index === activeIndex ? 'active' : 'pending';
      const side = state === 'done'
        ? '<span class="tracking-step-side tracking-step-side-done">Done</span>'
        : state === 'active'
          ? '<span class="tracking-step-side tracking-step-side-active" aria-hidden="true"><i></i><i></i><i></i></span>'
          : '';
      return '<div class="tracking-step is-' + state + '">' +
          '<div class="tracking-step-icon">' + trackingIcon(step.icon) + '</div>' +
          '<div class="tracking-step-copy"><strong>' + escapeHtml(step.title) + '</strong><span>' + escapeHtml(step.sub) + '</span></div>' +
          side +
        '</div>';
    }).join('');
  }

  function renderTrackingDetails(job) {
    const container = document.getElementById('tracking-details');
    if (!container) return;
    const issue = getTrackingIssueLabel(job);
    const location = (job && (job.locationLabel || job.serviceArea)) || 'Selected service area';
    const ticket = (job && job.ticket) || currentTrackedTicket || 'VFQ-PENDING';
    const urgency = formatUrgencyLabel((job && job.urgency) || 'emergency');
    const serviceType = getTrackingServiceType(job);
    const estimate = getTrackingEstimate(job);
    const assessment = getTrackingAssessmentValue(job);
    const detailsState = trackingDetailsExpanded ? ' is-expanded' : '';
    const assignedName = job && job.assignedElectrician && job.assignedElectrician.name;
    const headline = assignedName ? 'VoltFriq assigned' : 'Pairing you with a VoltFriq';
    const reassurance = assignedName
      ? (String(assignedName).trim() + ' is connected to your booking.')
      : 'Finding a verified electrician near you.';
    const contactCta = shouldShowTrackingContact(job)
      ? '<button class="tracking-contact-btn" id="btn-tracking-contact" type="button">' + trackingIcon('message') + '<span>Contact Us</span></button>'
      : '';
    container.innerHTML = [
      '<div class="tracking-detail-main">',
        '<span class="tracking-detail-icon" aria-hidden="true">' + trackingIcon('socket') + '</span>',
        '<div class="tracking-detail-copy">',
          '<h3>' + escapeHtml(headline) + '</h3>',
          '<p>' + escapeHtml(reassurance) + '</p>',
        '</div>',
      '</div>',
      '<button class="tracking-detail-toggle" id="btn-toggle-tracking-details" type="button">' + escapeHtml(trackingDetailsExpanded ? 'Hide details' : 'View details') + '</button>',
      contactCta,
      '<div class="tracking-detail-metrics' + detailsState + '">',
        '<div class="tracking-metric"><span>Service type</span><strong>' + escapeHtml(serviceType) + '</strong><em>' + escapeHtml(urgency) + '</em><small>' + escapeHtml(issue) + '</small></div>',
        '<div class="tracking-metric"><span>Location</span><strong>' + escapeHtml(location) + '</strong></div>',
        '<div class="tracking-metric"><span>Estimated price</span><strong>' + escapeHtml(estimate) + '</strong><small>After assessment</small></div>',
        '<div class="tracking-metric"><span>Assessment visit</span><strong>' + escapeHtml(assessment) + '</strong></div>',
        '<div class="tracking-metric tracking-metric-ticket"><span>Ticket ID</span><strong>' + escapeHtml(ticket) + '</strong><button class="tracking-copy-ticket" type="button" data-copy-ticket="' + escapeAttribute(ticket) + '" aria-label="Copy ticket ID">' + trackingIcon('copy') + '</button></div>',
      '</div>'
    ].join('');
  }

  function shouldShowTrackingContact(job) {
    if (!job) return false;
    return ['accepted', 'en_route', 'on_site', 'work_in_progress', 'electrician_completed'].includes(job.status);
  }

  function getTrackingIssueLabel(job) {
    if (!job) return 'Electrical service';
    return humanizeIssueCategory(job.issueCategory) || job.issueCategory || 'Electrical service';
  }

  function getTrackingServiceType(job) {
    const issue = job ? getIssueOption(job.issueCategory, getTrackingIssueLabel(job)) : null;
    const service = (issue && issue.value) || (job && inferSkillCategory(job.issueCategory)) || 'Electrical work';
    return String(service).replace(/\s+issue$/i, '').replace(/^General Installation$/i, 'Installation');
  }

  function getTrackingEstimate(job) {
    const issue = job ? getIssueOption(job.issueCategory, getTrackingIssueLabel(job)) : null;
    const min = issue ? Number(issue.estimated_fee_min || 0) : 0;
    if (min) return Store.formatCurrency(min) + '+';
    return getIssueEstimate(job && job.issueCategory, getTrackingIssueLabel(job));
  }

  function getTrackingAssessmentValue(job) {
    const settings = Store.getSettings();
    const assessmentStatuses = ['assessment_fee_pending', 'assessment_payment_pending_verification', 'assessment_confirmed'];
    const amount = job && assessmentStatuses.includes(job.status) ? Number(settings.assessment_fee || 0) : 0;
    return Store.formatCurrency(amount);
  }

  function formatTrackingTime(value) {
    if (!value) return 'Submitted';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return 'Submitted';
    return date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  }

  function trackingIcon(name) {
    const icons = {
      check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.35" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12 4 4L19 6"/></svg>',
      bolt: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M13 2 4 14h6l-1 8 9-12h-6l1-8Z"/></svg>',
      person: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.05" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="3.4"/><path d="M5.5 20a6.5 6.5 0 0 1 13 0"/></svg>',
      car: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.05" stroke-linecap="round" stroke-linejoin="round"><path d="M5 11 7 5h10l2 6"/><path d="M4 11h16v7H4z"/><path d="M7 18v2"/><path d="M17 18v2"/><circle cx="8" cy="15" r="1"/><circle cx="16" cy="15" r="1"/></svg>',
      flag: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.05" stroke-linecap="round" stroke-linejoin="round"><path d="M5 21V4"/><path d="M5 4h11l-1.5 4L16 12H5"/></svg>',
      socket: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="4" width="14" height="16" rx="3"/><path d="M9 9v2"/><path d="M15 9v2"/><path d="M10 16h4"/></svg>',
      message: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.05" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a4 4 0 0 1-4 4H8l-5 3V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4z"/></svg>',
      copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.05" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="8" width="11" height="11" rx="2"/><path d="M5 16H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>'
    };
    return icons[name] || '';
  }

