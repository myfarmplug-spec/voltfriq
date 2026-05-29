  async function finishCustomerSignup(payload, userId) {
    const client = requireClient();
    await hydrateSession();
    const profileId = userId || (state.session && state.session.user && state.session.user.id) || (state.profile && state.profile.id);
    if (!profileId) throw new Error('Verify your email before finishing this account.');

    const profileUpdate = await client
      .from('profiles')
      .update({
        role: 'customer',
        full_name: payload.fullName,
        phone: payload.phone || null
      })
      .eq('id', profileId);
    if (profileUpdate.error) throw normalizeError(profileUpdate.error, 'Could not save your profile.');

    await ensureCustomerRecord(profileId);
    const customerUpdate = await client.from('customers')
      .update({
        primary_service_area: payload.primaryServiceArea || null,
        latitude: payload.latitude || null,
        longitude: payload.longitude || null
      })
      .eq('profile_id', profileId);
    if (customerUpdate.error) throw normalizeError(customerUpdate.error, 'Could not update your customer record.');

    await hydrateSession();
    if (payload.referralCode) {
      await linkReferralCode(payload.referralCode);
      await hydrateSession();
    }
    return {
      profile: state.profile,
      customer: state.customer
    };
  }

  async function signUpCustomer(payload) {
    const client = requireClient();
    const signUp = await client.auth.signUp({
      email: payload.email,
      password: payload.password,
      options: {
        emailRedirectTo: customerSignupRedirectUrl(),
        data: {
          requested_role: 'customer',
          role: 'customer',
          full_name: payload.fullName,
          phone: payload.phone || '',
          primary_service_area: payload.primaryServiceArea || '',
          latitude: payload.latitude == null ? null : payload.latitude,
          longitude: payload.longitude == null ? null : payload.longitude
        }
      }
    });
    if (signUp.error) throw normalizeError(signUp.error, 'Customer signup failed.');
    if (signUp.data.user && signUp.data.session) {
      await finishCustomerSignup(payload, signUp.data.user.id);
    }
    return signUp.data;
  }

  async function finishElectricianSignup(payload, userId) {
    const client = requireClient();
    await hydrateSession();
    const profileId = userId || (state.session && state.session.user && state.session.user.id) || (state.profile && state.profile.id);
    if (!profileId) throw new Error('Verify your email before finishing this application.');

    await ensureProfile({
      id: profileId,
      email: payload.email,
      user_metadata: {
        requested_role: 'electrician',
        full_name: payload.fullName,
        phone: payload.phone || ''
      }
    });

    let avatarUrl = null;
    if (payload.profilePhoto) {
      avatarUrl = await uploadFile('avatars', payload.profilePhoto, profileId + '/profile');
    }

    const profileUpdate = await client.from('profiles')
      .update({
        role: 'electrician',
        full_name: payload.fullName,
        phone: payload.phone || '',
        avatar_url: avatarUrl
      })
      .eq('id', profileId);
    if (profileUpdate.error) throw normalizeError(profileUpdate.error, 'Could not save the electrician profile.');

    const electricianPayload = {
      profile_id: profileId,
      status: 'pending',
      onboarding_completed: false,
      years_experience: payload.yearsExperience || 0,
      service_areas: payload.serviceAreas || [],
      location_label: payload.locationLabel || payload.baseLocationLabel || payload.base_location_label || null,
      latitude: payload.latitude || null,
      longitude: payload.longitude || null,
      bank_name: payload.bankName || '',
      bank_account_number: payload.bankAccountNumber || '',
      bank_account_name: payload.bankAccountName || '',
      availability_status: payload.availabilityStatus || 'available',
      onboarding_score: payload.onboardingValidationScore || 0,
      onboarding_review_status: payload.onboardingReviewStatus || 'pending',
      onboarding_feedback: payload.onboardingFeedback || null,
      onboarding_answers: payload.onboardingAnswers || []
    };

    const existingElectrician = await client
      .from('electricians')
      .select('id,status')
      .eq('profile_id', profileId)
      .maybeSingle();
    if (existingElectrician.error) throw normalizeError(existingElectrician.error, 'Could not load the electrician account.');

    const electricianWritePayload = Object.assign({}, electricianPayload, {
      status: existingElectrician.data && existingElectrician.data.status ? existingElectrician.data.status : 'pending'
    });

    let electricianInsert = existingElectrician.data
      ? await client
        .from('electricians')
        .update(electricianWritePayload)
        .eq('profile_id', profileId)
        .select('*')
        .single()
      : await client
        .from('electricians')
        .insert(electricianWritePayload)
        .select('*')
        .single();

    if (electricianInsert.error && isMissingSchemaError(electricianInsert.error)) {
      const legacyElectricianPayload = {
          profile_id: electricianPayload.profile_id,
          status: electricianWritePayload.status,
          years_experience: electricianPayload.years_experience,
          service_areas: electricianPayload.service_areas,
          location_label: electricianPayload.location_label,
          latitude: electricianPayload.latitude,
          longitude: electricianPayload.longitude,
          bank_name: electricianPayload.bank_name,
          bank_account_number: electricianPayload.bank_account_number,
          bank_account_name: electricianPayload.bank_account_name,
          availability_status: electricianPayload.availability_status
      };
      electricianInsert = existingElectrician.data
        ? await client
          .from('electricians')
          .update(legacyElectricianPayload)
          .eq('profile_id', profileId)
          .select('*')
          .single()
        : await client
          .from('electricians')
          .insert(legacyElectricianPayload)
          .select('*')
          .single();
    }

    if (electricianInsert.error) throw normalizeError(electricianInsert.error, 'Could not create the electrician account.');

    const electricianId = electricianInsert.data.id;
    const skills = (payload.skills || []).map((skill) => ({
      electrician_id: electricianId,
      category: skill
    }));
    if (skills.length) {
      const skillsResult = await client.from('electrician_skills').upsert(skills, { onConflict: 'electrician_id,category' });
      if (skillsResult.error) throw normalizeError(skillsResult.error, 'Could not save electrician skills.');
    }

    const certifications = (payload.certifications || [])
      .filter((item) => item && item.title)
      .map((item) => ({
        electrician_id: electricianId,
        title: item.title,
        license_number: item.licenseNumber || null,
        issuer: item.issuer || null
      }));
    if (certifications.length) {
      const certificationsResult = await client.from('electrician_certifications').insert(certifications);
      if (certificationsResult.error && !isMissingSchemaError(certificationsResult.error)) {
        throw normalizeError(certificationsResult.error, 'Could not save certifications.');
      }
    }

    const documents = [];
    for (let index = 0; index < (payload.documents || []).length; index += 1) {
      const documentItem = payload.documents[index];
      let filePath = null;
      let fileUrl = null;
      if (documentItem.file) {
        if (typeof payload.onDocumentUploadProgress === 'function') {
          payload.onDocumentUploadProgress(documentItem.type, { status: 'uploading', progress: 20 });
        }
        filePath = await uploadFile('electricianDocuments', documentItem.file, profileId + '/' + electricianId + '/' + index);
        fileUrl = filePath;
        if (typeof payload.onDocumentUploadProgress === 'function') {
          payload.onDocumentUploadProgress(documentItem.type, { status: 'uploaded', progress: 100 });
        }
      }
      documents.push({
        electrician_id: electricianId,
        document_type: documentItem.type,
        file_path: filePath,
        file_url: fileUrl,
        status: 'pending'
      });
    }
    if (documents.length) {
      const documentsResult = await client.from('electrician_documents').insert(documents);
      if (documentsResult.error) throw normalizeError(documentsResult.error, 'Could not save electrician documents.');
    }

    await hydrateSession();
    return {
      profile: state.profile,
      electrician: state.electrician
    };
  }

  async function signUpElectrician(payload) {
    const client = requireClient();
    const signUp = await client.auth.signUp({
      email: payload.email,
      password: payload.password,
      options: {
        emailRedirectTo: electricianSignupRedirectUrl(),
        data: {
          requested_role: 'electrician',
          role: 'electrician',
          full_name: payload.fullName,
          phone: payload.phone || '',
          country: payload.country || 'Nigeria',
          state: payload.state || '',
          city: payload.city || '',
          street_address: payload.street_address || payload.streetAddress || '',
          location_label: payload.locationLabel || '',
          base_location_label: payload.baseLocationLabel || payload.base_location_label || payload.locationLabel || '',
          years_experience: payload.yearsExperience || 0,
          availability_status: payload.availabilityStatus || 'available',
          service_areas: payload.serviceAreas || [],
          latitude: payload.latitude == null ? null : payload.latitude,
          longitude: payload.longitude == null ? null : payload.longitude,
          bank_name: payload.bankName || '',
          bank_account_number: payload.bankAccountNumber || '',
          bank_account_name: payload.bankAccountName || '',
          skills: payload.skills || [],
          onboarding_score: payload.onboardingValidationScore || 0,
          onboarding_review_status: payload.onboardingReviewStatus || 'pending',
          onboarding_feedback: payload.onboardingFeedback || null,
          onboarding_answers: payload.onboardingAnswers || []
        }
      }
    });
    if (signUp.error) throw normalizeError(signUp.error, 'Electrician signup failed.');
    if (signUp.data.user && signUp.data.session) {
      await finishElectricianSignup(payload, signUp.data.user.id);
    }
    return signUp.data;
  }

  async function signIn(email, password) {
    const client = requireClient();
    const result = await client.auth.signInWithPassword({ email, password });
    if (result.error) throw normalizeError(result.error, 'Login failed.');
    await hydrateSession(result.data);
    return result.data;
  }

  async function requestPasswordReset(email, redirectTo) {
    const client = requireClient();
    const result = await client.auth.resetPasswordForEmail(email, {
      redirectTo: siteUrlForPath(redirectTo || '/login?reset=1')
    });
    if (result.error) throw normalizeError(result.error, 'Could not send the reset link.');
    return true;
  }

  async function verifySignupOtp(email, token) {
    const client = requireClient();
    const result = await client.auth.verifyOtp({
      email: String(email || '').trim(),
      token: String(token || '').replace(/\D/g, ''),
      type: 'signup'
    });
    if (result.error) throw normalizeError(result.error, 'Could not verify this email code.');
    await hydrateSession();
    return result.data;
  }

  async function resendSignupOtp(email, redirectTo) {
    const client = requireClient();
    const result = await client.auth.resend({
      type: 'signup',
      email: String(email || '').trim(),
      options: {
        emailRedirectTo: siteUrlForPath(redirectTo || '/login?verify=signup')
      }
    });
    if (result.error) throw normalizeError(result.error, 'Could not resend the email code.');
    return true;
  }

  async function updatePassword(nextPassword) {
    const client = requireClient();
    if (!nextPassword || nextPassword.length < 8) {
      throw new Error('Enter a new password with at least 8 characters.');
    }
    const result = await client.auth.updateUser({ password: nextPassword });
    if (result.error) throw normalizeError(result.error, 'Could not update the password.');
    await hydrateSession();
    return result.data;
  }

  async function signOut() {
    const client = ensureClient();
    if (!client) return;
    await client.auth.signOut();
    state.session = null;
    state.profile = null;
    state.profileLoadError = null;
    state.customer = null;
    state.electrician = null;
    state.wallet = null;
  }

  async function updateProfile(fields) {
    const client = ensureClient();
    if (!state.profile) throw new Error('No active profile');
    const result = await withAuthLockRetry(() => client
      .from('profiles')
      .update(fields)
      .eq('id', state.profile.id)
      .select('*')
      .single());
    if (result.error) throw normalizeError(result.error, 'Profile update failed.');
    state.profile = result.data;
    return state.profile;
  }

  async function ensureProfile(user) {
    const client = ensureClient();
    const profilePayload = {
      id: user.id,
      email: user.email || '',
      role: normalizeSignupRole(user.user_metadata && (user.user_metadata.requested_role || user.user_metadata.role)),
      full_name: (user.user_metadata && user.user_metadata.full_name) || user.email || '',
      phone: (user.user_metadata && user.user_metadata.phone) || null
    };

    let result = await withAuthLockRetry(() => client.rpc('ensure_app_account_for_current_user'));
    if (result.error && isMissingSchemaError(result.error)) {
      result = await withAuthLockRetry(() => client.rpc('ensure_profile_for_current_user'));
    }
    if (result.error) throw normalizeError(result.error, 'Could not load your profile.');
    return result.data || profilePayload;
  }

  async function ensureCustomerRecord(profileId) {
    const client = ensureClient();
    const check = await withAuthLockRetry(() => client
      .from('customers')
      .select('id')
      .eq('profile_id', profileId)
      .maybeSingle());
    if (check.error) throw normalizeError(check.error, 'Could not load your customer account.');
    if (check.data) return check.data;
    const created = await withAuthLockRetry(() => client
      .from('customers')
      .insert({ profile_id: profileId })
      .select('id')
      .single());
    if (created.error) throw normalizeError(created.error, 'Could not create your customer account.');
    return created.data;
  }

  async function ensureWalletRecord(profileId) {
    const client = ensureClient();
    const check = await client
      .from('wallets')
      .select('id')
      .eq('profile_id', profileId)
      .maybeSingle();
    if (check.error) throw normalizeError(check.error, 'Could not load your wallet.');
    if (check.data) return check.data;
    const created = await client
      .from('wallets')
      .insert({ profile_id: profileId })
      .select('id')
      .single();
    if (created.error) throw normalizeError(created.error, 'Could not create your wallet.');
    return created.data;
  }

  function validateFile(file, options) {
    if (!file) throw new Error('No file selected.');
    const maxBytes = options && options.maxBytes ? options.maxBytes : 5 * 1024 * 1024;
    const acceptedPrefixes = options && options.acceptedPrefixes ? options.acceptedPrefixes : [];
    const acceptedTypes = options && options.acceptedTypes ? options.acceptedTypes : [];
    if (file.size > maxBytes) {
      throw new Error('File is too large. Keep uploads under ' + Math.round(maxBytes / (1024 * 1024)) + 'MB.');
    }
    if (acceptedTypes.length && acceptedTypes.indexOf(file.type) === -1 && !acceptedPrefixes.some((prefix) => file.type.indexOf(prefix) === 0)) {
      throw new Error('Unsupported file type.');
    }
  }

  async function uploadFile(bucketKey, file, prefix) {
    const client = ensureClient();
    validateFile(file, {
      maxBytes: bucketKey === 'paymentProofs' ? 8 * 1024 * 1024 : 5 * 1024 * 1024,
      acceptedTypes: ['application/pdf'],
      acceptedPrefixes: ['image/']
    });
    const bucket = (config().storageBuckets && config().storageBuckets[bucketKey]) || STORAGE_PATHS[bucketKey] || bucketKey;
    const ext = file.name && file.name.includes('.') ? file.name.slice(file.name.lastIndexOf('.')) : '';
    const filePath = prefix + '-' + Date.now() + ext;
    const uploadResult = await withAuthLockRetry(() => client.storage.from(bucket).upload(filePath, file, {
      cacheControl: '3600',
      upsert: false
    }));
    if (uploadResult.error) throw normalizeError(uploadResult.error, 'File upload failed.');
    return uploadResult.data.path;
  }
