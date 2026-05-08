  async function createGuestBooking(input) {
    const client = ensureClient();
    const phone = String(input.phone || '').trim();
    if (!phone) throw new Error('Enter your mobile number before submitting.');
    const photos = Array.isArray(input.photos) ? input.photos : [];
    if (photos.length > 3) throw new Error('Add up to 3 photos only.');
    const result = await withAuthLockRetry(() => client.rpc('create_guest_customer_job', {
      p_phone: phone,
      p_service_area: input.serviceArea,
      p_location_label: input.locationLabel || input.serviceArea,
      p_latitude: input.latitude || null,
      p_longitude: input.longitude || null,
      p_issue_category: input.issueCategory,
      p_urgency: normalizeUrgency(input.urgency),
      p_customer_note: input.note || '',
      p_requires_assessment: !!input.requiresAssessment,
      p_material_handling: input.materialHandling || 'voltfriq_supplied',
      p_photo_paths: [],
      p_client_fingerprint: getGuestDeviceId()
    }));
    if (result.error) throw normalizeError(result.error, 'Could not create the guest booking.');
    const payload = result.data || {};
    let jobRow = payload.job || payload;
    const accessToken = payload.access_token || payload.accessToken;
    const jobId = payload.job_id || payload.jobId || (jobRow && jobRow.id);
    if (!jobRow || !jobId || !accessToken) {
      throw new Error('Booking was created, but tracking access was not returned.');
    }
    saveGuestAccess({ jobId, accessToken, phone });

    jobRow.id = jobRow.id || jobId;
    jobRow.is_guest = true;
    const normalized = await hydrateProtectedAssets(normalizeJob(jobRow));
    normalized.guestAccessToken = accessToken;
    if (photos.length) {
      normalized.photoUploadWarning = 'Your booking is saved. We will request photos later if the VoltFriq needs them.';
    }
    return normalized;
  }

  async function getGuestJob(jobId, accessToken) {
    const client = ensureClient();
    const result = await client.rpc('get_guest_job', {
      p_job_id: jobId,
      p_access_token: accessToken
    });
    if (result.error) throw normalizeError(result.error, 'Could not load guest job tracking.');
    const row = result.data || {};
    row.id = row.id || jobId;
    row.is_guest = true;
    return hydrateProtectedAssets(normalizeJob(row));
  }

  async function acceptAssignedJob(jobId) {
    const client = ensureClient();
    const result = await client.rpc('electrician_accept_job', { p_job_id: jobId });
    if (result.error) throw normalizeError(result.error, 'Could not accept the job.');
    return getJob(result.data.id);
  }

  async function rejectAssignedJob(jobId) {
    const client = ensureClient();
    const result = await client.rpc('electrician_reject_job', { p_job_id: jobId });
    if (result.error) throw normalizeError(result.error, 'Could not reject the job.');
    return getJob(result.data.id);
  }

  async function updateJobStatus(jobId, nextStatus, note, metadata) {
    const client = ensureClient();
    const guest = getGuestAccess();
    if (!state.profile && guest && guest.jobId === jobId) {
      const guestResult = await client.rpc('update_guest_job_status', {
        p_job_id: jobId,
        p_access_token: guest.accessToken,
        p_next_status: nextStatus,
        p_note: note || null,
        p_metadata: metadata || {}
      });
      if (guestResult.error) throw normalizeError(guestResult.error, 'Could not update the job status.');
      return getGuestJob(jobId, guest.accessToken);
    }
    const result = await client.rpc('set_job_status', {
      p_job_id: jobId,
      p_next_status: nextStatus,
      p_note: note || null,
      p_metadata: metadata || {}
    });
    if (result.error) throw normalizeError(result.error, 'Could not update the job status.');
    return getJob(result.data.id);
  }

