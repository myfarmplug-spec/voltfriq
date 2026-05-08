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
    normalized.dispatchOtpRequired = !!(payload.dispatch_otp_required || payload.dispatchOtpRequired);
    normalized.dispatchVerification = payload.dispatch_verification || payload.dispatchVerification || null;
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

  async function issueGuestActionToken(jobId, actionType, phoneConfirmation) {
    const client = ensureClient();
    const guest = getGuestAccess();
    if (!guest || guest.jobId !== jobId || !guest.accessToken) {
      throw new Error('Open this booking from its tracking link before continuing.');
    }
    const result = await client.rpc('issue_guest_action_token', {
      p_job_id: jobId,
      p_access_token: guest.accessToken,
      p_action_type: actionType,
      p_phone_confirmation: phoneConfirmation || ''
    });
    if (result.error) throw normalizeError(result.error, 'Could not confirm this guest action.');
    const payload = result.data || {};
    const token = payload.action_token || payload.actionToken;
    if (!token) throw new Error('Could not confirm this guest action.');
    return token;
  }

  async function requestGuestOtp(jobId, actionType, phoneConfirmation, clientFingerprint) {
    const client = ensureClient();
    const guest = getGuestAccess();
    if (!guest || guest.jobId !== jobId || !guest.accessToken) {
      throw new Error('Open this booking from its tracking link before continuing.');
    }
    const result = await client.rpc('request_guest_otp', {
      p_job_id: jobId,
      p_access_token: guest.accessToken,
      p_action_type: actionType,
      p_phone_confirmation: phoneConfirmation || '',
      p_client_fingerprint: clientFingerprint || getGuestDeviceId()
    });
    if (result.error) throw normalizeError(result.error, 'Could not request a guest OTP.');
    return result.data || {};
  }

  async function verifyGuestOtp(jobId, actionType, challengeId, otpCode) {
    const client = ensureClient();
    const guest = getGuestAccess();
    if (!guest || guest.jobId !== jobId || !guest.accessToken) {
      throw new Error('Open this booking from its tracking link before continuing.');
    }
    const result = await client.rpc('verify_guest_otp', {
      p_job_id: jobId,
      p_access_token: guest.accessToken,
      p_action_type: actionType,
      p_challenge_id: challengeId,
      p_otp_code: otpCode || ''
    });
    if (result.error) throw normalizeError(result.error, 'Could not verify the guest OTP.');
    return result.data || {};
  }

  async function prepareGuestDispatchOtp(jobId, phoneConfirmation, clientFingerprint) {
    const guest = getGuestAccess();
    if (!guest || guest.jobId !== jobId || !guest.accessToken) {
      throw new Error('Open this booking from its tracking link before continuing.');
    }
    const response = await fetch('/api/guest-dispatch-otp', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jobId,
        accessToken: guest.accessToken,
        phoneConfirmation: phoneConfirmation || guest.phone || '',
        clientFingerprint: clientFingerprint || getGuestDeviceId()
      })
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || !payload.ok) {
      throw new Error(payload.error || 'Could not send dispatch verification code.');
    }
    return {
      challenge_id: payload.challengeId || payload.challenge_id,
      challengeId: payload.challengeId || payload.challenge_id,
      masked_phone: payload.maskedPhone || payload.masked_phone,
      maskedPhone: payload.maskedPhone || payload.masked_phone,
      delivery_status: payload.deliveryStatus || payload.delivery_status || 'sent',
      deliveryStatus: payload.deliveryStatus || payload.delivery_status || 'sent'
    };
  }

  async function confirmGuestDispatchOtp(jobId, challengeId, otpCode) {
    const guest = getGuestAccess();
    if (!guest || guest.jobId !== jobId || !guest.accessToken) {
      throw new Error('Open this booking from its tracking link before continuing.');
    }
    await verifyGuestOtp(jobId, 'dispatch_confirm', challengeId, otpCode);
    return getGuestJob(jobId, guest.accessToken);
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
      const safeMetadata = Object.assign({}, metadata || {});
      const actionType = nextStatus === 'cancelled'
        ? 'cancel_job'
        : nextStatus === 'customer_confirmed'
          ? 'customer_confirmed'
          : '';
      const actionToken = actionType
        ? await issueGuestActionToken(jobId, actionType, safeMetadata.phone_confirmation || safeMetadata.phoneConfirmation || '')
        : null;
      delete safeMetadata.phone_confirmation;
      delete safeMetadata.phoneConfirmation;
      const guestResult = await client.rpc('update_guest_job_status', {
        p_job_id: jobId,
        p_access_token: guest.accessToken,
        p_next_status: nextStatus,
        p_note: note || null,
        p_metadata: safeMetadata,
        p_action_token: actionToken
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
