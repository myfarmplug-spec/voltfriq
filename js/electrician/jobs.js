  async function openJob(jobId) {
    const finishLoading = showElectricianLoading('Syncing dashboard...');
    try {
      currentJob = await Store.getJob(jobId);
      bindJobSubscription(jobId);
      renderJobDetail();
      goTo('elec-job-detail', {
        routeData: { ticket: currentJob.ticket }
      });
      return currentJob;
    } finally {
      finishLoading();
    }
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
