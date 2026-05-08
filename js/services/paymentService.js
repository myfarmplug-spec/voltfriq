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
        ? 'guest/' + jobId + '/' + guestTokenPrefix(guest.accessToken) + '/' + payload.paymentType
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

