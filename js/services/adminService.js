	  async function createDispute(jobId, issueType, details, phoneConfirmation) {
	    const client = ensureClient();
	    const guest = getGuestAccess();
	    if (!state.profile && guest && guest.jobId === jobId && guest.accessToken) {
	      const actionToken = await issueGuestActionToken(jobId, 'dispute', phoneConfirmation || '');
	      const guestResult = await client.rpc('create_guest_dispute', {
	        p_job_id: jobId,
	        p_access_token: guest.accessToken,
	        p_issue_type: issueType,
	        p_details: details || null,
	        p_phone_confirmation: null,
	        p_action_token: actionToken
	      });
	      if (guestResult.error) throw normalizeError(guestResult.error, 'Could not report the issue.');
	      return guestResult.data;
	    }
	    const result = await client.rpc('create_dispute', {
	      p_job_id: jobId,
	      p_issue_type: issueType,
      p_details: details || null
    });
    if (result.error) throw normalizeError(result.error, 'Could not report the issue.');
    return result.data;
  }

	  async function listDisputes() {
    const client = ensureClient();
    if (!state.profile) return [];
    let query = client
      .from('disputes')
      .select(`
        *,
	        jobs(ticket, service_area, status),
	        customer:customers(*, profile:profiles(full_name, phone)),
	        guest_customer:guest_customers(*),
	        electrician:electricians(*, profile:profiles(full_name, phone))
      `)
      .order('created_at', { ascending: false });
    if (state.profile.role === 'customer') {
      query = query.eq('customer_id', state.customer && state.customer.id);
    } else if (state.profile.role === 'electrician') {
      query = query.eq('electrician_id', state.electrician && state.electrician.id);
    }
    const result = await query;
	    if (result.error) throw normalizeError(result.error, 'Could not load disputes.');
	    return result.data || [];
	  }

	  async function getPublicJobEvents(jobId, accessToken) {
	    const client = ensureClient();
	    const result = await client.rpc('get_public_job_events', {
	      p_job_id: jobId,
	      p_access_token: accessToken || null
	    });
	    if (result.error) throw normalizeError(result.error, 'Could not load job progress.');
	    return (result.data || []).map(normalizeJobEvent);
	  }

	  async function getAdminJobEvents(jobId) {
	    requireRole('admin');
	    const client = ensureClient();
	    const result = await client.rpc('get_admin_job_events', {
	      p_job_id: jobId || null
	    });
	    if (result.error) throw normalizeError(result.error, 'Could not load internal job events.');
	    return (result.data || []).map(normalizeJobEvent);
	  }

	  async function getOperationalSummary() {
	    const client = ensureClient();
	    if (!state.profile || state.profile.role !== 'admin') {
	      return defaultOperationalSummary();
	    }
	    const result = await client.rpc('admin_operational_summary');
	    if (result.error) throw normalizeError(result.error, 'Could not load operational metrics.');
	    return normalizeOperationalSummary(result.data || {});
	  }

	  async function getOperationalQueues() {
	    const client = ensureClient();
	    if (!state.profile || state.profile.role !== 'admin') {
	      return defaultOperationalQueues();
	    }
	    const result = await client.rpc('admin_operational_queues');
	    if (result.error) throw normalizeError(result.error, 'Could not load operational queues.');
	    return normalizeOperationalQueues(result.data || {});
	  }

	  async function retryDispatchJob(jobId) {
	    requireRole('admin');
	    const client = ensureClient();
	    const result = await client.rpc('admin_retry_dispatch_job', {
	      p_job_id: jobId
	    });
	    if (result.error) throw normalizeError(result.error, 'Could not retry dispatch safely.');
	    return getJob(result.data.id);
	  }

	  async function reconcileJobState(jobId) {
	    requireRole('admin');
	    const client = ensureClient();
	    const result = await client.rpc('admin_reconcile_job_state', {
	      p_job_id: jobId
	    });
	    if (result.error) throw normalizeError(result.error, 'Could not reconcile job state.');
	    return getJob(result.data.id);
	  }

	  async function resolveOperationalAlert(alertId, note) {
	    requireRole('admin');
	    const client = ensureClient();
	    const result = await client.rpc('admin_resolve_operational_alert', {
	      p_alert_id: alertId,
	      p_note: note || null
	    });
	    if (result.error) throw normalizeError(result.error, 'Could not resolve operational alert.');
	    return result.data;
	  }

  async function resolveDispute(disputeId, status, resolutionAction, resolutionNote) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.rpc('resolve_dispute', {
      p_dispute_id: disputeId,
      p_status: status,
      p_resolution_action: resolutionAction || null,
      p_resolution_note: resolutionNote || null
    });
    if (result.error) throw normalizeError(result.error, 'Could not resolve the dispute.');
    return result.data;
  }

  async function listAppeals() {
    const client = ensureClient();
    if (!state.profile) return [];
    let query = client
      .from('electrician_appeals')
      .select(`
        *,
        electrician:electricians(
          *,
          profile:profiles(full_name, phone, avatar_url),
          electrician_skills(category)
        )
      `)
      .order('created_at', { ascending: false });
    if (state.profile.role === 'electrician') {
      query = query.eq('electrician_id', state.electrician && state.electrician.id);
    }
    const result = await query;
    if (result.error) throw normalizeError(result.error, 'Could not load suspension appeals.');
    return result.data || [];
  }

  async function submitElectricianAppeal(payload) {
    const client = ensureClient();
    let supportingPath = null;
    if (payload && payload.file) {
      supportingPath = await uploadFile('electricianDocuments', payload.file, 'appeals/' + (state.electrician && state.electrician.id || state.profile.id));
    }
    const result = await client.rpc('submit_electrician_appeal', {
      p_appeal_note: payload && payload.note ? payload.note : '',
      p_supporting_file_path: supportingPath
    });
    if (result.error) throw normalizeError(result.error, 'Could not submit your appeal.');
    return result.data;
  }

  async function resolveElectricianAppeal(appealId, approved, adminNote) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.rpc('resolve_electrician_appeal', {
      p_appeal_id: appealId,
      p_approved: !!approved,
      p_admin_note: adminNote || null
    });
    if (result.error) throw normalizeError(result.error, 'Could not resolve the appeal.');
    return result.data;
  }

  async function listPaymentsNeedingVerification() {
    const client = ensureClient();
    const result = await client
      .from('job_payments')
      .select('*, jobs(*)')
      .eq('status', 'submitted')
      .order('created_at', { ascending: false });
    if (result.error) throw normalizeError(result.error, 'Could not load the payment verification queue.');
    return result.data || [];
  }

  async function markWorkStarted(jobId) {
    return updateJobStatus(jobId, 'work_in_progress', 'VoltFriq started work.');
  }

  async function markWorkCompleted(jobId) {
    return updateJobStatus(jobId, 'electrician_completed', 'VoltFriq marked work complete.');
  }

  async function markCustomerConfirmed(jobId, metadata) {
    return updateJobStatus(jobId, 'customer_confirmed', 'Customer confirmed the work.', metadata || {});
  }

  async function markPayoutComplete(jobId) {
    requireRole('admin');
    return updateJobStatus(jobId, 'payout_complete', 'Payout released.');
  }

  async function submitRating(jobId, score, comment, behaviorTags) {
    const client = ensureClient();
    const result = await client.rpc('submit_rating', {
      p_job_id: jobId,
      p_score: score,
      p_comment: comment || null,
      p_behavior_tags: behaviorTags || []
    });
    if (result.error) throw normalizeError(result.error, 'Could not save the rating.');
    return result.data;
  }

  async function submitCustomerReview(jobId, score, comment, behaviorTags) {
    const client = ensureClient();
    const result = await client.rpc('submit_customer_review', {
      p_job_id: jobId,
      p_score: score,
      p_comment: comment || null,
      p_behavior_tags: behaviorTags || []
    });
    if (result.error) throw normalizeError(result.error, 'Could not save the customer review.');
    return result.data;
  }

  async function saveSettings(nextSettings) {
    const client = ensureClient();
    const current = await loadSettings();
    const payload = Object.assign({}, current, nextSettings);
    const query = current.id
      ? client.from('admin_settings').update(payload).eq('id', current.id).select('*').single()
      : client.from('admin_settings').insert(payload).select('*').single();
    const result = await query;
    if (result.error) throw normalizeError(result.error, 'Could not save admin settings.');
    state.settings = normalizeSettings(Object.assign({}, DEFAULT_SETTINGS, result.data));
    return state.settings;
  }

  async function saveExpertiseCategory(label, currentLabel) {
    requireRole('admin');
    const client = ensureClient();
    const cleanLabel = String(label || '').trim();
    if (!cleanLabel) throw new Error('Enter an expertise category.');
    if (currentLabel && currentLabel !== cleanLabel) {
      const existing = await client.from('expertise_categories').delete().eq('label', currentLabel);
      if (existing.error && !isMissingSchemaError(existing.error)) throw normalizeError(existing.error, 'Could not update expertise category.');
    }
    const result = await client
      .from('expertise_categories')
      .upsert({ label: cleanLabel }, { onConflict: 'label' })
      .select('*')
      .single();
    let categories;
    if (result.error && isMissingSchemaError(result.error)) {
      categories = Array.from(new Set([].concat(state.settings.issue_categories || [], [cleanLabel]).filter(Boolean)));
      state.expertiseCategories = categories.slice();
    } else if (result.error) {
      throw normalizeError(result.error, 'Could not save expertise category.');
    } else {
      categories = await loadExpertiseCategories();
    }
    await saveSettings({ issue_categories: categories });
    return result.data || { label: cleanLabel };
  }

  async function removeExpertiseCategory(label) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.from('expertise_categories').delete().eq('label', label);
    let categories;
    if (result.error && isMissingSchemaError(result.error)) {
      categories = (state.settings.issue_categories || []).filter((item) => item !== label);
      state.expertiseCategories = categories.slice();
    } else if (result.error) {
      throw normalizeError(result.error, 'Could not remove expertise category.');
    } else {
      categories = await loadExpertiseCategories();
    }
    await saveSettings({ issue_categories: categories });
    return true;
  }

  async function addJobMessage(jobId, senderRole, content, messageType) {
    const client = ensureClient();
    if (!state.profile) throw new Error('No active profile');
    const result = await client
      .from('job_messages')
      .insert({
        job_id: jobId,
        sender_profile_id: state.profile.id,
        sender_role: senderRole,
        message_type: messageType || 'text',
        content: content
      })
      .select('*')
      .single();
    if (result.error) throw normalizeError(result.error, 'Could not send the message.');
    return result.data;
  }

  async function getJobMessages(jobId) {
    const client = ensureClient();
    const result = await client
      .from('job_messages')
      .select('*, sender:profiles(full_name)')
      .eq('job_id', jobId)
      .order('created_at', { ascending: true });
    if (result.error) throw normalizeError(result.error, 'Could not load job messages.');
    return result.data || [];
  }

  function subscribeToJob(jobId, callback) {
    const client = ensureClient();
    if (!client) return { unsubscribe() {} };
    const guest = getGuestAccess();
    if (!state.profile && guest && guest.jobId === jobId && guest.accessToken) {
      let closed = false;
      const refresh = async () => {
        if (closed) return;
        callback(await getGuestJob(jobId, guest.accessToken));
      };
      const channel = client.channel('guest-job-watch-' + jobId)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'jobs', filter: 'id=eq.' + jobId }, refresh)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'job_quotes', filter: 'job_id=eq.' + jobId }, refresh)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'job_payments', filter: 'job_id=eq.' + jobId }, refresh)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'job_timeline', filter: 'job_id=eq.' + jobId }, refresh)
        .subscribe();
      const pollId = window.setInterval(() => refresh().catch(() => {}), 12000);
      return {
        unsubscribe() {
          closed = true;
          window.clearInterval(pollId);
          client.removeChannel(channel);
        }
      };
    }
    const channel = client.channel('job-watch-' + jobId)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'jobs', filter: 'id=eq.' + jobId }, async () => {
        callback(await getJob(jobId));
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_quotes', filter: 'job_id=eq.' + jobId }, async () => {
        callback(await getJob(jobId));
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_payments', filter: 'job_id=eq.' + jobId }, async () => {
        callback(await getJob(jobId));
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_timeline', filter: 'job_id=eq.' + jobId }, async () => {
        callback(await getJob(jobId));
      })
      .subscribe();
    return {
      unsubscribe() {
        client.removeChannel(channel);
      }
    };
  }

  function subscribeToMessages(jobId, callback) {
    const client = ensureClient();
    if (!client) return { unsubscribe() {} };
    const channel = client.channel('job-messages-' + jobId)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_messages', filter: 'job_id=eq.' + jobId }, async () => {
        callback(await getJobMessages(jobId));
      })
      .subscribe();
    return {
      unsubscribe() {
        client.removeChannel(channel);
      }
    };
  }

  function subscribeToNotifications(callback) {
    const client = ensureClient();
    if (!client || !state.profile) return { unsubscribe() {} };
    const channel = client.channel('notifications-' + state.profile.id)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'notifications', filter: 'profile_id=eq.' + state.profile.id }, async () => {
        callback(await listNotifications());
      })
      .subscribe();
    return {
      unsubscribe() {
        client.removeChannel(channel);
      }
    };
  }

	  function subscribeToPortalFeed(callback) {
	    const client = ensureClient();
	    if (!client) return { unsubscribe() {} };
	    const channel = client.channel('portal-feed-' + Math.random().toString(36).slice(2, 8))
	      .on('postgres_changes', { event: '*', schema: 'public', table: 'jobs' }, callback)
	      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_events' }, callback)
	      .on('postgres_changes', { event: '*', schema: 'public', table: 'electricians' }, callback)
	      .on('postgres_changes', { event: '*', schema: 'public', table: 'job_payments' }, callback)
	      .on('postgres_changes', { event: '*', schema: 'public', table: 'ratings' }, callback)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'electrician_appeals' }, callback)
      .subscribe();
    return {
      unsubscribe() {
        client.removeChannel(channel);
      }
	    };
	  }

	  async function hydrateOperationalEvents(job) {
	    if (!job || !job.id) return job;
	    try {
	      if (state.profile && state.profile.role === 'admin') {
	        const events = await getAdminJobEvents(job.id);
	        job.internalEvents = events;
	        job.timeline = events.filter((event) => event.publicMessage).map(publicEventAsTimeline);
	        job.lastTimeline = job.timeline.length ? job.timeline[job.timeline.length - 1] : job.lastTimeline;
	        return job;
	      }

	      const guest = getGuestAccess();
	      const accessToken = !state.profile && guest && guest.jobId === job.id ? guest.accessToken : null;
	      const events = await getPublicJobEvents(job.id, accessToken);
	      job.timeline = events.map(publicEventAsTimeline);
	      job.lastTimeline = job.timeline.length ? job.timeline[job.timeline.length - 1] : job.lastTimeline;
	    } catch (error) {
	      if (state.profile && state.profile.role === 'admin') throw error;
	    }
	    return job;
	  }

  async function listNotifications() {
    const client = ensureClient();
    if (!state.profile) return [];
    const result = await client
      .from('notifications')
      .select('*')
      .eq('profile_id', state.profile.id)
      .order('created_at', { ascending: false })
      .limit(20);
    if (result.error) throw normalizeError(result.error, 'Could not load notifications.');
    return result.data || [];
  }

  async function markNotificationRead(notificationId) {
    const client = ensureClient();
    const result = await client
      .from('notifications')
      .update({ read_at: new Date().toISOString() })
      .eq('id', notificationId);
    if (result.error) throw normalizeError(result.error, 'Could not mark the notification as read.');
  }

  function normalizeUrgency(urgency) {
    if (urgency === 'this-week' || urgency === 'scheduled') return 'this_week';
    return urgency || 'today';
  }

  function formatCurrency(amount) {
    return '₦' + Number(amount || 0).toLocaleString();
  }

  function getPublicStorageUrl(bucketKey, path) {
    const client = ensureClient();
    if (!client || !path) return '';
    const bucket = (config().storageBuckets && config().storageBuckets[bucketKey]) || STORAGE_PATHS[bucketKey] || bucketKey;
    const result = client.storage.from(bucket).getPublicUrl(path);
    return result && result.data ? result.data.publicUrl || '' : '';
  }

  async function createSignedStorageUrl(bucketKey, path, expiresIn) {
    const client = ensureClient();
    if (!client || !path) return '';
    const bucket = (config().storageBuckets && config().storageBuckets[bucketKey]) || STORAGE_PATHS[bucketKey] || bucketKey;
    const result = await client.storage.from(bucket).createSignedUrl(path, expiresIn || 900);
    if (result.error) return '';
    return result.data && result.data.signedUrl ? result.data.signedUrl : '';
  }

  async function hydrateProtectedAssets(job) {
    if (!job) return job;
    await Promise.all((job.photos || []).map(async (photo) => {
      if (photo.file_path) {
        photo.url = await createSignedStorageUrl('jobPhotos', photo.file_path);
      }
    }));
    if (job.latestPayment && job.latestPayment.proof_path) {
      job.latestPayment.proofUrl = await createSignedStorageUrl('paymentProofs', job.latestPayment.proof_path);
    }
    return job;
  }

  function mapQuote(rawQuotes) {
    if (rawQuotes && !Array.isArray(rawQuotes)) {
      return {
        id: rawQuotes.id || null,
        findings: '',
        measurements: '',
        items: [],
        laborTotal: Number(rawQuotes.labor_total || rawQuotes.laborTotal || 0),
        materialTotal: Number(rawQuotes.material_total || rawQuotes.materialTotal || 0),
        total: Number(rawQuotes.total || rawQuotes.grand_total || rawQuotes.grandTotal || 0)
      };
    }
    const quotes = rawQuotes || [];
    const current = quotes.length ? quotes[quotes.length - 1] : null;
    if (!current) {
      return {
        id: null,
        findings: '',
        measurements: '',
        items: [],
        laborTotal: 0,
        materialTotal: 0,
        total: 0
      };
    }
    const items = (current.quote_items || []).map((item) => ({
      id: item.id,
      itemType: item.item_type,
      description: item.description,
      quantity: Number(item.quantity || 1),
      unitPrice: Number(item.unit_price || 0),
      lineTotal: Number(item.line_total || 0)
    }));
    return {
      id: current.id,
      findings: current.findings || '',
      measurements: current.measurements || '',
      items,
      laborTotal: Number(current.labor_total || 0),
      materialTotal: Number(current.material_total || 0),
      total: Number(current.grand_total || 0)
    };
  }

	  function normalizeJob(row) {
    const customerProfile = row.customer && row.customer.profile ? row.customer.profile : {};
    const guestCustomer = row.guest_customer || row.guestCustomer || null;
    const assignedElectricianRow = row.assigned_electrician || null;
    const electricianProfile = assignedElectricianRow && assignedElectricianRow.profile ? assignedElectricianRow.profile : {};
    const quote = mapQuote(row.quote_summary || row.job_quotes);
    const paymentRows = Array.isArray(row.job_payments)
      ? row.job_payments
      : row.payment_status
        ? [{ status: row.payment_status }]
        : [];
    const payments = paymentRows.slice().sort((a, b) => new Date(b.created_at || 0) - new Date(a.created_at || 0));
	    const timelineRows = Array.isArray(row.progress_timeline)
	      ? row.progress_timeline
	      : Array.isArray(row.job_events)
	        ? row.job_events
	        : Array.isArray(row.job_timeline)
	          ? row.job_timeline
	          : [];
	    const timeline = timelineRows
	      .map((entry) => entry.event_type ? publicEventAsTimeline(normalizeJobEvent(entry)) : entry)
	      .sort((a, b) => new Date(a.created_at || 0) - new Date(b.created_at || 0));
    const reviews = row.ratings || [];
    const electricianReview = reviews.find((rating) => rating.review_direction === 'customer_to_electrician') || reviews[0] || null;
    const customerReview = reviews.find((rating) => rating.review_direction === 'electrician_to_customer') || null;
    const lastTimeline = timeline.length ? timeline[timeline.length - 1] : null;
    return {
      id: row.id,
      ticket: row.ticket,
      customerId: row.customer_id,
      guestCustomerId: row.guest_customer_id || null,
      isGuest: !!row.is_guest || (!row.customer_id && !!(row.guest_customer_id || guestCustomer)),
      assignedElectricianId: row.assigned_electrician_id,
      serviceArea: row.service_area,
      locationLabel: row.location_label,
      latitude: row.latitude,
      longitude: row.longitude,
      issueCategory: row.issue_category,
      issueCategories: [row.issue_category],
      urgency: row.urgency === 'this_week' ? 'this-week' : row.urgency,
      description: row.customer_note || '',
      status: row.status,
      statusLabel: getStatusLabel(row.status),
      requiresAssessment: !!row.requires_assessment,
      materialHandling: row.material_handling || 'voltfriq_supplied',
      candidateQueue: row.candidate_queue || [],
      attemptedElectricianIds: row.attempted_electrician_ids || [],
      dispatchAttempts: Number(row.dispatch_attempts || 0),
      lastDispatchAt: row.last_dispatch_at,
      customer: row.customer ? {
        id: row.customer.id,
        profileId: row.customer.profile_id,
        name: customerProfile.full_name || '',
        phone: customerProfile.phone || '',
        primaryServiceArea: row.customer.primary_service_area || '',
        trustSummary: {
          averageBehaviorRating: Number(row.customer.average_behavior_rating || 0),
          totalBehaviorRatings: Number(row.customer.total_behavior_ratings || 0),
          completedRequests: Number(row.customer.completed_requests || 0),
          cancellationCount: Number(row.customer.cancellation_count || 0),
          noShowReports: Number(row.customer.no_show_reports || 0),
          disputeCount: Number(row.customer.dispute_count || 0),
          paymentIssueCount: Number(row.customer.payment_issue_count || 0),
          status: row.customer.trust_status || 'clear',
          notes: row.customer.trust_notes || ''
        }
      } : guestCustomer ? {
        id: guestCustomer.id,
        profileId: null,
        name: 'Guest customer',
        phone: guestCustomer.phone || '',
        primaryServiceArea: guestCustomer.location_label || '',
        trustSummary: {
          averageBehaviorRating: 0,
          totalBehaviorRatings: 0,
          completedRequests: 0,
          cancellationCount: 0,
          noShowReports: 0,
          disputeCount: 0,
          paymentIssueCount: 0,
          status: 'guest',
          notes: 'Guest booking'
        }
      } : null,
	      createdAt: row.created_at,
	      updatedAt: row.updated_at,
	      assignmentExpiresAt: row.assignment_expires_at,
	      acceptedAt: row.accepted_at,
	      lastDispatchAt: row.last_dispatch_at,
	      customerConfirmedAt: row.customer_confirmed_at,
	      electricianCompletedAt: row.electrician_completed_at,
      assignedElectrician: assignedElectricianRow ? {
        id: assignedElectricianRow.id || null,
        name: assignedElectricianRow.display_name || assignedElectricianRow.name || electricianProfile.full_name || 'VoltFriq',
        phone: electricianProfile.phone || '',
        avatar: assignedElectricianRow.avatar_url || electricianProfile.avatar_url || '',
        rating: Number(assignedElectricianRow.rating || assignedElectricianRow.average_rating || 0),
        totalRatings: Number(assignedElectricianRow.total_ratings || 0),
        responseRate: Number(assignedElectricianRow.response_rate || 0),
        jobsCompleted: Number(assignedElectricianRow.completed_jobs || 0),
        levelBadge: assignedElectricianRow.level_badge || 'Verified Pro',
        watchlist: !!assignedElectricianRow.watchlist,
        watchlistReason: assignedElectricianRow.watchlist_reason || '',
        negativeRatingCount: Number(assignedElectricianRow.negative_rating_count || 0),
        suspendedReason: assignedElectricianRow.suspended_reason || '',
        serviceAreas: assignedElectricianRow.service_areas || [],
        skills: (assignedElectricianRow.electrician_skills || []).map((skill) => skill.category),
        latitude: assignedElectricianRow.latitude,
        longitude: assignedElectricianRow.longitude,
        locationLabel: assignedElectricianRow.location_label || '',
        badges: buildTrustBadges(assignedElectricianRow)
      } : null,
      photos: (row.job_photos || []).map((photo) => Object.assign({}, photo, {
        url: getPublicStorageUrl('jobPhotos', photo.file_path)
      })),
      quote,
      payments: payments.map((payment) => Object.assign({}, payment, {
        statusLabel: getPaymentStatusLabel(payment.status)
      })),
      latestPayment: payments[0] ? Object.assign({}, payments[0], {
        statusLabel: getPaymentStatusLabel(payments[0].status)
      }) : null,
	      timeline: timeline,
	      internalEvents: Array.isArray(row.job_events) ? row.job_events.map(normalizeJobEvent) : [],
	      lastTimeline: lastTimeline,
      needsManualAssignment: row.status === 'matching' && !row.assigned_electrician_id && Number(row.dispatch_attempts || 0) > 0 && !(row.candidate_queue || []).length,
      reviews: reviews,
      rating: electricianReview,
      electricianReview: electricianReview,
	      customerReview: customerReview
	    };
	  }

	  function normalizeJobEvent(row) {
	    return {
	      id: row.id,
	      jobId: row.job_id,
	      eventType: row.event_type,
	      actorRole: row.actor_role || '',
	      actorId: row.actor_id || null,
	      publicMessage: row.public_message || row.note || '',
	      internalNote: row.internal_note || '',
	      metadata: row.metadata || {},
	      created_at: row.created_at,
	      createdAt: row.created_at
	    };
	  }

	  function publicEventAsTimeline(event) {
	    return {
	      id: event.id,
	      status: statusForEventType(event.eventType),
	      event_type: event.eventType,
	      note: event.publicMessage || 'Status updated.',
	      created_at: event.createdAt || event.created_at,
	      metadata: event.metadata || {}
	    };
	  }

	  function statusForEventType(eventType) {
	    const map = {
	      JOB_CREATED: 'requested',
	      PAIRING_STARTED: 'matching',
	      ELECTRICIAN_ASSIGNED: 'assigned',
	      ASSIGNMENT_ACCEPTED: 'accepted',
	      ASSIGNMENT_REJECTED: 'matching',
	      ASSIGNMENT_EXPIRED: 'matching',
	      PAYMENT_SUBMITTED: 'work_payment_pending_verification',
	      PAYMENT_VERIFIED: 'payment_confirmed',
	      WORK_STARTED: 'work_in_progress',
	      WORK_COMPLETED: 'electrician_completed',
	      CUSTOMER_CONFIRMED: 'customer_confirmed',
	      DISPUTE_OPENED: 'customer_confirmed',
	      JOB_CANCELLED: 'cancelled',
	      QUOTE_SUBMITTED: 'quoted',
	      PAYOUT_RELEASED: 'payout_complete',
	      RATING_SUBMITTED: 'rated',
	      JOB_UPDATED: 'matching'
	    };
	    return map[eventType] || 'matching';
	  }

	  function defaultOperationalSummary() {
	    return {
	      queues: {
	        pendingPayments: 0,
	        pendingElectricians: 0,
	        stuckPairingJobs: 0,
	        failedPairingJobs: 0,
	        openDisputes: 0,
	        expiredAssignments: 0,
	        snapshotDriftJobs: 0,
	        predictiveAlerts: 0,
	        criticalAlerts: 0
	      },
	      metrics: {
	        averageTimeToAssignSeconds: 0,
	        averageTimeToAcceptSeconds: 0,
	        rejectionRate: 0,
	        paymentVerificationDelaySeconds: 0,
	        stuckJobsCount: 0,
	        dispatchRetries7d: 0,
	        uploadFailures24h: 0,
	        disputeRate30d: 0,
	        electricianResponseQuality: 100,
	        snapshotDriftJobs: 0,
	        predictiveAlerts: 0,
	        automationFailures24h: 0,
	        automationLastRunAgeSeconds: 0,
	        eventReplayLastRunAgeSeconds: 0,
	        eventReplayFailures24h: 0,
	        systemHealthScore: 100
	      }
	    };
	  }

	  function defaultOperationalQueues() {
	    return {
	      pendingPayments: [],
		      pendingElectricians: [],
		      stuckJobs: [],
		      failedPairingJobs: [],
		      snapshotDriftJobs: [],
		      predictiveAlerts: [],
		      paymentBacklog: [],
	      openDisputes: [],
	      expiredAssignments: [],
	      highRejectionElectricians: [],
	      uploadFailures: [],
	      eventReplayRuns: [],
	      alerts: []
	    };
	  }

	  function normalizeOperationalSummary(payload) {
	    const rawQueues = payload.queues || {};
	    const rawMetrics = payload.metrics || {};
	    return {
	      queues: {
	        pendingPayments: Number(rawQueues.pending_payments || rawQueues.pendingPayments || 0),
	        pendingElectricians: Number(rawQueues.pending_electricians || rawQueues.pendingElectricians || 0),
	        stuckPairingJobs: Number(rawQueues.stuck_pairing_jobs || rawQueues.stuckPairingJobs || 0),
	        failedPairingJobs: Number(rawQueues.failed_pairing_jobs || rawQueues.failedPairingJobs || 0),
	        openDisputes: Number(rawQueues.open_disputes || rawQueues.openDisputes || 0),
	        expiredAssignments: Number(rawQueues.expired_assignments || rawQueues.expiredAssignments || 0),
	        snapshotDriftJobs: Number(rawQueues.snapshot_drift_jobs || rawQueues.snapshotDriftJobs || 0),
	        predictiveAlerts: Number(rawQueues.predictive_alerts || rawQueues.predictiveAlerts || 0),
	        criticalAlerts: Number(rawQueues.critical_alerts || rawQueues.criticalAlerts || 0)
	      },
	      metrics: {
	        averageTimeToAssignSeconds: Number(rawMetrics.average_time_to_assign_seconds || rawMetrics.averageTimeToAssignSeconds || 0),
	        averageTimeToAcceptSeconds: Number(rawMetrics.average_time_to_accept_seconds || rawMetrics.averageTimeToAcceptSeconds || 0),
	        rejectionRate: Number(rawMetrics.rejection_rate || rawMetrics.rejectionRate || 0),
	        paymentVerificationDelaySeconds: Number(rawMetrics.payment_verification_delay_seconds || rawMetrics.paymentVerificationDelaySeconds || 0),
	        stuckJobsCount: Number(rawMetrics.stuck_jobs_count || rawMetrics.stuckJobsCount || 0),
	        dispatchRetries7d: Number(rawMetrics.dispatch_retries_7d || rawMetrics.dispatchRetries7d || 0),
	        uploadFailures24h: Number(rawMetrics.upload_failures_24h || rawMetrics.uploadFailures24h || 0),
	        disputeRate30d: Number(rawMetrics.dispute_rate_30d || rawMetrics.disputeRate30d || 0),
	        electricianResponseQuality: Number(rawMetrics.electrician_response_quality || rawMetrics.electricianResponseQuality || 0),
	        snapshotDriftJobs: Number(rawMetrics.snapshot_drift_jobs || rawMetrics.snapshotDriftJobs || 0),
	        predictiveAlerts: Number(rawMetrics.predictive_alerts || rawMetrics.predictiveAlerts || 0),
	        automationFailures24h: Number(rawMetrics.automation_failures_24h || rawMetrics.automationFailures24h || 0),
	        automationLastRunAgeSeconds: Number(rawMetrics.automation_last_run_age_seconds || rawMetrics.automationLastRunAgeSeconds || 0),
	        eventReplayLastRunAgeSeconds: Number(rawMetrics.event_replay_last_run_age_seconds || rawMetrics.eventReplayLastRunAgeSeconds || 0),
	        eventReplayFailures24h: Number(rawMetrics.event_replay_failures_24h || rawMetrics.eventReplayFailures24h || 0),
	        systemHealthScore: Number(rawMetrics.system_health_score || rawMetrics.systemHealthScore || 0)
	      }
	    };
	  }

	  function normalizeOperationalQueues(payload) {
	    return {
	      pendingPayments: Array.isArray(payload.pending_payments) ? payload.pending_payments : [],
		      pendingElectricians: Array.isArray(payload.pending_electricians) ? payload.pending_electricians : [],
		      stuckJobs: Array.isArray(payload.stuck_jobs) ? payload.stuck_jobs : [],
		      failedPairingJobs: Array.isArray(payload.failed_pairing_jobs) ? payload.failed_pairing_jobs : [],
		      snapshotDriftJobs: Array.isArray(payload.snapshot_drift_jobs) ? payload.snapshot_drift_jobs : [],
		      predictiveAlerts: Array.isArray(payload.predictive_alerts) ? payload.predictive_alerts : [],
		      paymentBacklog: Array.isArray(payload.payment_backlog) ? payload.payment_backlog : [],
	      openDisputes: Array.isArray(payload.open_disputes) ? payload.open_disputes : [],
	      expiredAssignments: Array.isArray(payload.expired_assignments) ? payload.expired_assignments : [],
	      highRejectionElectricians: Array.isArray(payload.high_rejection_electricians) ? payload.high_rejection_electricians : [],
	      uploadFailures: Array.isArray(payload.upload_failures) ? payload.upload_failures : [],
	      eventReplayRuns: Array.isArray(payload.event_replay_runs) ? payload.event_replay_runs : [],
	      alerts: Array.isArray(payload.alerts) ? payload.alerts : []
	    };
	  }

	  function buildTrustBadges(electrician) {
    const badges = [electrician.level_badge || 'Verified Pro'];
    if (Number(electrician.average_rating || 0) >= 4.7 && Number(electrician.total_ratings || 0) >= 5 && badges.indexOf('Top Rated') === -1) {
      badges.push('Top Rated');
    }
    if (Number(electrician.response_rate || 0) >= 85) {
      badges.push('Fast Responder');
    }
    return badges;
  }

  return {
    init,
    isConfigured,
    getSession,
    getCurrentProfile,
    getCurrentCustomer,
    getCurrentElectrician,
    getCurrentWallet,
    getGuestAccess,
    clearGuestAccess,
    getPublicSiteUrl,
    siteUrlForPath,
    selectDraftAddress,
    getRoleHome,
    getSettings,
    getServiceAreas,
    inferServiceAreaFromAddress,
    getStatusLabel,
    getPaymentStatusLabel,
    formatCurrency,
    getPublicStorageUrl,
    createSignedStorageUrl,
    signUpCustomer,
    finishCustomerSignup,
    signUpElectrician,
    finishElectricianSignup,
    signIn,
    requestPasswordReset,
    verifySignupOtp,
    resendSignupOtp,
    updatePassword,
    signOut,
    updateProfile,
    listCustomerJobs,
    listElectricianJobs,
    listAdminJobs,
    getJob,
    getGuestJob,
    issueGuestActionToken,
    requestGuestOtp,
    verifyGuestOtp,
    prepareGuestDispatchOtp,
    confirmGuestDispatchOtp,
    uploadGuestJobPhotos,
    previewMatches,
    createBooking,
    createGuestBooking,
    acceptAssignedJob,
    rejectAssignedJob,
    updateJobStatus,
    submitQuote,
    acceptQuote,
    submitPaymentProof,
    verifyPayment,
    setManualAssignment,
    rerunAutomaticAssignment,
    setElectricianStatus,
    setElectricianWatchlist,
    updateCurrentElectrician,
    replaceCurrentElectricianSkills,
    listElectricians,
    hydrateElectricianDocuments,
    getWalletSummary,
    getReferralSummary,
	    linkReferralCode,
	    createDispute,
	    listDisputes,
	    getPublicJobEvents,
		    getAdminJobEvents,
		    getOperationalSummary,
		    getOperationalQueues,
		    retryDispatchJob,
		    reconcileJobState,
		    resolveOperationalAlert,
		    resolveDispute,
    listAppeals,
    submitElectricianAppeal,
    resolveElectricianAppeal,
    listPaymentsNeedingVerification,
    markWorkStarted,
    markWorkCompleted,
    markCustomerConfirmed,
    markPayoutComplete,
    submitRating,
    submitCustomerReview,
    loadSettings,
    loadExpertiseCategories,
    getExpertiseCategories,
    saveExpertiseCategory,
    removeExpertiseCategory,
    saveSettings,
    addJobMessage,
    getJobMessages,
    subscribeToJob,
    subscribeToMessages,
    subscribeToNotifications,
    subscribeToPortalFeed,
    listNotifications,
    markNotificationRead
  };
})();
