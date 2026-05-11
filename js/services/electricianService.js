  async function setManualAssignment(jobId, electricianId) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.rpc('dispatch_job', {
      p_job_id: jobId,
      p_manual_electrician_id: electricianId
    });
    if (result.error) throw normalizeError(result.error, 'Could not reassign the VoltFriq.');
    return getJob(result.data.id);
  }

  async function rerunAutomaticAssignment(jobId) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.rpc('dispatch_job', {
      p_job_id: jobId,
      p_manual_electrician_id: null
    });
    if (result.error) throw normalizeError(result.error, 'Could not assign the next available VoltFriq.');
    return getJob(result.data.id);
  }

  async function setElectricianStatus(electricianId, status) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.rpc('admin_set_electrician_status', {
      p_electrician_id: electricianId,
      p_status: status,
      p_reason: status === 'suspended' ? 'Suspended by admin.' : null
    });
    if (result.error) throw normalizeError(result.error, 'Could not update the electrician status.');
    return result.data;
  }

  async function setElectricianWatchlist(electricianId, watchlist, reason) {
    requireRole('admin');
    const client = ensureClient();
    const result = await client.rpc('admin_set_electrician_watchlist', {
      p_electrician_id: electricianId,
      p_watchlist: !!watchlist,
      p_reason: reason || null
    });
    if (result.error) throw normalizeError(result.error, 'Could not update the VoltFriq watchlist status.');
    return result.data;
  }

  async function updateCurrentElectrician(fields) {
    const client = ensureClient();
    if (!state.electrician) throw new Error('No electrician profile loaded.');
    const result = await client
      .from('electricians')
      .update(fields)
      .eq('id', state.electrician.id)
      .select('*, electrician_skills(category), electrician_documents(*)')
      .single();
    if (result.error) throw normalizeError(result.error, 'Could not update the electrician profile.');
    state.electrician = result.data;
    return state.electrician;
  }

  async function replaceCurrentElectricianSkills(skills) {
    const client = ensureClient();
    if (!state.electrician) throw new Error('No electrician profile loaded.');

    const removeResult = await client
      .from('electrician_skills')
      .delete()
      .eq('electrician_id', state.electrician.id);
    if (removeResult.error) throw normalizeError(removeResult.error, 'Could not update skills.');

    const nextSkills = (skills || []).map((category) => ({
      electrician_id: state.electrician.id,
      category
    }));
    if (nextSkills.length) {
      const addResult = await client.from('electrician_skills').insert(nextSkills);
      if (addResult.error) throw normalizeError(addResult.error, 'Could not save the selected skills.');
    }

    const refreshed = await client
      .from('electricians')
      .select('*, electrician_skills(category), electrician_documents(*)')
      .eq('id', state.electrician.id)
      .single();
    if (refreshed.error) throw normalizeError(refreshed.error, 'Could not refresh the electrician profile.');

    state.electrician = refreshed.data;
    return state.electrician;
  }

  async function listElectricians(filter, options) {
    const client = ensureClient();
    let query = client
      .from('electricians')
      .select('*, profile:profiles(full_name, phone, avatar_url), electrician_skills(category), electrician_documents(*), electrician_certifications(*)')
      .order('created_at', { ascending: false });
    if (filter && filter !== 'all') {
      query = query.eq('status', filter);
    }
    const result = await query;
    if (result.error) throw normalizeError(result.error, 'Could not load electricians.');
    const electricians = result.data || [];
    if (!options || options.includeDocumentUrls !== false) {
      await Promise.all(electricians.map(hydrateElectricianDocuments));
    }
    return electricians;
  }

  async function listCustomers() {
    requireRole('admin');
    const client = ensureClient();
    const result = await client
      .from('customers')
      .select('*, profile:profiles(full_name, phone, avatar_url)')
      .order('created_at', { ascending: false });
    if (result.error) throw normalizeError(result.error, 'Could not load registered users.');
    return result.data || [];
  }

  async function hydrateElectricianDocuments(electrician) {
    if (!electrician) return electrician;
    const docs = electrician.electrician_documents || [];
    await Promise.all(docs.map(async (documentItem) => {
      if (documentItem.file_path && !documentItem.signedUrl) {
        documentItem.signedUrl = await createSignedStorageUrl('electricianDocuments', documentItem.file_path);
      }
    }));
    return electrician;
  }

  async function getWalletSummary() {
    const client = ensureClient();
    if (!state.profile) return { wallet: null, transactions: [] };
    await ensureWalletRecord(state.profile.id);
    const walletResult = await client
      .from('wallets')
      .select('*')
      .eq('profile_id', state.profile.id)
      .single();
    if (walletResult.error) throw normalizeError(walletResult.error, 'Could not load wallet balance.');
    state.wallet = walletResult.data;

    const txResult = await client
      .from('wallet_transactions')
      .select('*')
      .eq('profile_id', state.profile.id)
      .order('created_at', { ascending: false })
      .limit(20);
    if (txResult.error) throw normalizeError(txResult.error, 'Could not load wallet activity.');
    return {
      wallet: state.wallet,
      transactions: txResult.data || []
    };
  }

  async function getReferralSummary() {
    const client = ensureClient();
    if (!state.profile) return { profile: null, referrals: [] };
    const result = await client
      .from('referrals')
      .select('*')
      .or('referrer_profile_id.eq.' + state.profile.id + ',referred_profile_id.eq.' + state.profile.id)
      .order('created_at', { ascending: false });
    if (result.error) throw normalizeError(result.error, 'Could not load referrals.');
    return {
      profile: state.profile,
      referrals: result.data || []
    };
  }

  async function linkReferralCode(referralCode) {
    const client = ensureClient();
    if (!referralCode) return null;
    const result = await client.rpc('link_referral_code', {
      p_referral_code: referralCode.trim().toUpperCase()
    });
    if (result.error) throw normalizeError(result.error, 'Could not apply the referral code.');
    return result.data;
  }
