  function renderAssessmentFee(job) {
    const settings = Store.getSettings();
    document.getElementById('fee-amount').textContent = Store.formatCurrency(settings.assessment_fee || 0);
    document.getElementById('assessment-snapshot').innerHTML = [
      ['Status', job.statusLabel],
      ['Verification', 'Submitted does not mean verified. VoltFriq confirms this payment manually before the inspection visit can continue.'],
      ['Ticket', job.ticket]
    ].map(renderKeyValueRow).join('');
    document.getElementById('fee-bank-name').textContent = settings.platform_bank_name || '';
    document.getElementById('fee-account-number').textContent = settings.platform_account_number || '';
    document.getElementById('fee-account-name').textContent = settings.platform_account_name || '';
    document.getElementById('btn-fee-paid').textContent = job.status === 'assessment_payment_pending_verification'
      ? 'Payment Proof Submitted'
      : 'Submit Assessment Payment Proof';
    document.getElementById('btn-fee-paid').disabled = job.status === 'assessment_payment_pending_verification';
    focusCustomerScreen('appearance-fee');
  }

  function renderQuoteScreen(job) {
    const quote = job.quote;
    document.getElementById('quot-findings').textContent = quote.findings || 'The VoltFriq has prepared the quote.';
    document.getElementById('quot-labour-items').innerHTML = quote.items.filter((item) => item.itemType !== 'material').map(renderQuoteItem).join('') || '<div class="quot-empty">No labour items listed.</div>';
    document.getElementById('quot-material-items').innerHTML = quote.items.filter((item) => item.itemType === 'material').map(renderQuoteItem).join('') || '<div class="quot-empty">No materials listed.</div>';
    document.getElementById('quot-total-amount').textContent = Store.formatCurrency(quote.total || 0);
    document.getElementById('quotation-note').textContent = 'We will verify any payment proof before the job moves into work.';
  }

  function renderQuoteItem(item) {
    return '<div class="quot-item"><span>' + escapeHtml(item.description) + '</span><span>' + Store.formatCurrency(item.lineTotal || 0) + '</span></div>';
  }

  function renderPaymentScreen(job) {
    const settings = Store.getSettings();
    const amount = job.quote && job.quote.total ? job.quote.total : 0;
    document.getElementById('payment-amount').textContent = Store.formatCurrency(amount);
    document.getElementById('payment-note').textContent = 'Upload your payment proof. Submitted means received, not yet verified. Work only moves after VoltFriq confirms the transfer.';
    document.getElementById('payment-snapshot').innerHTML = [
      ['Status', job.statusLabel],
      ['Ticket', job.ticket],
      ['Verification', 'VoltFriq review']
    ].map(renderKeyValueRow).join('');
    document.getElementById('pay-bank-name').textContent = settings.platform_bank_name || '';
    document.getElementById('pay-account-number').textContent = settings.platform_account_number || '';
    document.getElementById('pay-account-name').textContent = settings.platform_account_name || '';
    document.getElementById('btn-payment-paid').textContent = job.status === 'work_payment_pending_verification'
      ? 'Payment Proof Submitted'
      : 'Submit Payment Proof';
    document.getElementById('btn-payment-paid').disabled = job.status === 'work_payment_pending_verification';
    document.getElementById('payment-reference').value = job.ticket || '';
    focusCustomerScreen('payment');
  }

  function renderConfirmScreen(job) {
    const quote = job.quote || { items: [], total: 0 };
    document.getElementById('confirm-items').innerHTML = [
      ['Ticket', job.ticket],
      ['Issue', humanizeIssueCategory(job.issueCategory)],
      ['Current total', Store.formatCurrency(quote.total || 0)]
    ].map(renderKeyValueRow).join('');

    document.getElementById('confirm-elec-status').innerHTML = job.status === 'electrician_completed'
      ? '<span class="dot-live"></span> VoltFriq marked the work complete. Confirm when satisfied.'
      : '<span class="dot-live"></span> Completion confirmed. Waiting for final payout release.';

    document.getElementById('final-settlement-card').innerHTML = [
      ['Job status', job.statusLabel],
      ['Next action', job.status === 'electrician_completed' ? 'Confirm the job' : 'Wait for payout release']
    ].map(renderKeyValueRow).join('');

    const disabled = job.status !== 'electrician_completed';
    document.getElementById('confirm-checkbox').checked = false;
    document.getElementById('confirm-checkbox').disabled = disabled;
    document.getElementById('btn-confirm-complete').disabled = true;
    focusCustomerScreen('confirm-work');
  }

  function renderRatingScreen(job) {
    document.getElementById('rating-comment').value = '';
    document.getElementById('rating-count').textContent = '0';
    document.getElementById('btn-submit-rating').disabled = false;
    ratingValue = 0;
    selectedRatingTags = [];
    document.querySelectorAll('#rating-tags [data-rating-tag]').forEach((tag) => tag.classList.remove('active'));
    updateStars();
    focusCustomerScreen('rating');
  }

  function renderDoneScreen(job) {
    document.getElementById('done-receipt-card').innerHTML = [
      ['Ticket', job.ticket],
      ['Status', Store.getStatusLabel(job.status)],
      ['Area', job.serviceArea]
    ].map(renderKeyValueRow).join('');
  }

  async function acceptCurrentQuote() {
    await withButtonLoading('btn-accept-quote', 'Accepting Quote...', async () => {
      if (!currentJob) return;
      await Store.acceptQuote(currentJob.id);
      await openTrackedJob(currentJob.id);
    });
  }

  async function submitCurrentPayment(paymentType) {
    const buttonId = paymentType === 'assessment_fee' ? 'btn-fee-paid' : 'btn-payment-paid';
    await withButtonLoading(buttonId, 'Uploading Proof...', async () => {
      if (!currentJob) return;
      const file = document.getElementById(paymentType === 'assessment_fee' ? 'assessment-receipt-upload' : 'receipt-upload');
      const amount = paymentType === 'assessment_fee'
        ? Number(Store.getSettings().assessment_fee || 0)
        : Number((currentJob.quote && currentJob.quote.total) || 0);
      if (!file || !file.files || !file.files[0]) {
        throw new Error('Attach your payment proof before submitting.');
      }
      await Store.submitPaymentProof(currentJob.id, {
        paymentType: paymentType,
        amount: amount,
        reference: paymentType === 'assessment_fee' ? '' : document.getElementById('payment-reference').value.trim(),
        file: file && file.files ? file.files[0] : null
      });
      await openTrackedJob(currentJob.id);
    });
  }

  async function confirmCompletion() {
    await withButtonLoading('btn-confirm-complete', 'Confirming...', async () => {
      if (!currentJob) return;
      await Store.markCustomerConfirmed(currentJob.id);
      await openTrackedJob(currentJob.id);
    });
  }

  async function submitRating() {
    await withButtonLoading('btn-submit-rating', 'Submitting Rating...', async () => {
      if (!currentJob || !ratingValue) {
        throw new Error('Select a rating before submitting.');
      }
      await Store.submitRating(currentJob.id, ratingValue, document.getElementById('rating-comment').value.trim(), selectedRatingTags);
      await openTrackedJob(currentJob.id);
    });
  }

