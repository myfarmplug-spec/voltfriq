  async function createGuestBooking(input) {
    const client = ensureClient();
    const phone = String(input.phone || '').trim();
    if (!phone) throw new Error('Enter your mobile number before submitting.');
    const photos = Array.isArray(input.photos) ? input.photos : [];
    if (photos.length) throw new Error('Photos can be added after your booking is confirmed.');
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

  async function uploadGuestJobPhotos(jobId, files) {
    const guest = getGuestAccess();
    const selectedFiles = Array.from(files || []);
    if (!guest || guest.jobId !== jobId || !guest.accessToken) {
      throw new Error('Open this booking from its tracking link before adding photos.');
    }
    if (!selectedFiles.length || selectedFiles.length > 3) {
      throw new Error('Add up to 3 photos only.');
    }
    const encodedFiles = [];
    for (const file of selectedFiles) {
      validateFile(file, {
        maxBytes: 2 * 1024 * 1024,
        acceptedTypes: ['image/jpeg', 'image/png', 'image/webp']
      });
      encodedFiles.push({
        name: file.name || 'photo',
        type: file.type,
        data: await readFileAsBase64(file)
      });
    }
    const response = await fetch('/api/guest-photo-upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jobId,
        accessToken: guest.accessToken,
        files: encodedFiles
      })
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || !payload.ok) {
      throw new Error(payload.error || 'Could not upload photos.');
    }
    const row = payload.job || {};
    row.id = row.id || jobId;
    row.is_guest = true;
    return hydrateProtectedAssets(normalizeJob(row));
  }

  function readFileAsBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result || '').replace(/^data:[^,]+,/, ''));
      reader.onerror = () => reject(new Error('Could not read the selected photo.'));
      reader.readAsDataURL(file);
    });
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
