	  async function listCustomerJobs() {
	    const client = ensureClient();
	    const customerId = state.customer && state.customer.id;
    if (!customerId) {
      const guest = getGuestAccess();
      if (!guest || !guest.jobId || !guest.accessToken) return [];
      try {
        return [await getGuestJob(guest.jobId, guest.accessToken)];
      } catch (error) {
        clearGuestAccess();
        return [];
      }
    }
    const result = await client.rpc('customer_job_payload', { p_job_id: null });
    if (result.error) throw normalizeError(result.error, 'Could not load customer jobs.');
	    const jobs = payloadRows(result.data).map(normalizeJob);
	    await Promise.all(jobs.map((job) => hydrateOperationalEvents(job).then(hydrateProtectedAssets)));
	    return jobs;
	  }

  async function listElectricianJobs() {
    const client = ensureClient();
    const electricianId = state.electrician && state.electrician.id;
    if (!electricianId) return [];
    const result = await client.rpc('electrician_job_payload', { p_job_id: null });
    if (result.error) throw normalizeError(result.error, 'Could not load assigned jobs.');
	    const jobs = payloadRows(result.data).map(normalizeJob);
	    await Promise.all(jobs.map((job) => hydrateOperationalEvents(job).then(hydrateProtectedAssets)));
	    return jobs;
	  }

  async function listAdminJobs(options) {
    const client = ensureClient();
    const result = await client.rpc('admin_job_payload', { p_job_id: null });
    if (result.error) throw normalizeError(result.error, 'Could not load admin jobs.');
    const jobs = payloadRows(result.data).map(normalizeJob);
    if (!options || options.includeProtectedAssets !== false) {
      await Promise.all(jobs.map(hydrateProtectedAssets));
    }
    return jobs;
  }

	  async function getJob(jobId) {
    const client = ensureClient();
    const guest = getGuestAccess();
    if (!state.profile && guest && guest.jobId === jobId && guest.accessToken) {
      return getGuestJob(jobId, guest.accessToken);
    }
    const rpcName = state.profile && state.profile.role === 'admin'
      ? 'admin_job_payload'
      : state.profile && state.profile.role === 'electrician'
        ? 'electrician_job_payload'
        : 'customer_job_payload';
    const result = await client.rpc(rpcName, { p_job_id: jobId });
	    if (result.error) throw normalizeError(result.error, 'Could not load the job details.');
	    const row = payloadRows(result.data)[0];
	    if (!row) throw new Error('Job not found.');
	    const job = normalizeJob(row);
	    await hydrateOperationalEvents(job);
	    return hydrateProtectedAssets(job);
	  }

  function payloadRows(payload) {
    if (Array.isArray(payload)) return payload;
    if (!payload) return [];
    return [payload];
  }

  async function previewMatches(input) {
    const client = ensureClient();
    const result = await client.rpc('find_matching_electricians', {
      p_service_area: input.serviceArea || null,
      p_issue_category: input.issueCategory,
      p_latitude: input.latitude || null,
      p_longitude: input.longitude || null,
      p_limit: input.limit || 5
    });
    if (result.error) throw normalizeError(result.error, 'Could not load the nearest available VoltFriqs.');
    return (result.data || []).map((row) => ({
      id: row.electrician_id,
      profileId: row.profile_id,
      name: row.full_name,
      phone: row.phone,
      avatar: row.avatar_url,
      serviceAreas: row.service_areas || [],
      experience: row.years_experience,
      rating: Number(row.average_rating || 0),
      jobsCompleted: Number(row.completed_jobs || 0),
      distance: Number(row.distance_km || 0).toFixed(1),
      averageResponseSeconds: row.average_response_seconds == null ? null : Number(row.average_response_seconds),
      lastAssignedAt: row.last_assigned_at || null,
      levelBadge: row.level_badge || 'Verified Pro',
      watchlist: !!row.watchlist,
      negativeRatingCount: Number(row.negative_rating_count || 0),
      levelRank: Number(row.level_rank || 1)
    }));
  }

  async function createBooking(input) {
    const client = ensureClient();
    if (!state.profile || state.profile.role !== 'customer') {
      throw new Error('Please sign in with a customer account before booking.');
    }
    await ensureCustomerRecord(state.profile.id);
    const photoPaths = [];
    for (let index = 0; index < (input.photos || []).length; index += 1) {
      photoPaths.push(await uploadFile('jobPhotos', input.photos[index], 'job-photos/' + state.profile.id + '/' + index));
    }
    const result = await withAuthLockRetry(() => client.rpc('create_customer_job', {
      p_service_area: input.serviceArea,
      p_location_label: input.locationLabel || input.serviceArea,
      p_latitude: input.latitude || null,
      p_longitude: input.longitude || null,
      p_issue_category: input.issueCategory,
      p_urgency: normalizeUrgency(input.urgency),
      p_customer_note: input.note || '',
      p_requires_assessment: !!input.requiresAssessment,
      p_material_handling: input.materialHandling || 'voltfriq_supplied',
      p_photo_paths: photoPaths
    }));
    if (result.error) throw normalizeError(result.error, 'Could not create the booking.');
    if (!result.data || !result.data.id) {
      throw new Error('Booking was created, but tracking details were not returned.');
    }
    return normalizeJob(result.data);
  }
