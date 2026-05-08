  function setAuthMode(mode) {
    authMode = mode;
    const isVerify = mode === 'verify';
    document.getElementById('tab-login').classList.toggle('active', mode === 'login');
    document.getElementById('tab-register').classList.toggle('active', mode === 'register');
    document.querySelector('.auth-tabs').style.display = isVerify ? 'none' : '';
    document.getElementById('auth-name-group').style.display = mode === 'register' ? 'block' : 'none';
    document.getElementById('auth-referral-group').style.display = mode === 'register' ? 'block' : 'none';
    document.getElementById('auth-password').closest('.form-group').style.display = isVerify ? 'none' : 'block';
    document.getElementById('auth-token-group').style.display = isVerify ? 'block' : 'none';
    document.getElementById('btn-auth-forgot').style.display = mode === 'login' ? '' : 'none';
    document.getElementById('btn-auth-resend').style.display = isVerify ? '' : 'none';
    document.getElementById('btn-auth-submit').textContent = mode === 'register'
      ? 'Create Account'
      : isVerify
        ? 'Verify Email'
      : mode === 'reset'
        ? 'Update Password'
        : 'Login';
    clearError();
  }

  async function handleAuthSubmit() {
    const email = document.getElementById('auth-contact').value.trim();
    const password = document.getElementById('auth-password').value.trim();
    const name = document.getElementById('auth-name').value.trim();
    const referralCode = document.getElementById('auth-referral-code').value.trim();

    await withButtonLoading('btn-auth-submit', authMode === 'register' ? 'Creating Account...' : authMode === 'verify' ? 'Verifying Email...' : authMode === 'reset' ? 'Updating Password...' : 'Signing In...', async () => {
      if (authMode === 'verify') {
        await verifyCustomerSignupCode();
        return;
      }

      if (authMode === 'reset') {
        if (!password) {
          throw new Error('Enter your new password to finish the reset.');
        }
        await Store.updatePassword(password);
        setAuthMode('login');
        applyAuthScreenContext();
        window.history.replaceState({}, '', '/login');
        showNotice('Password updated. You can now sign in with the new password.');
        document.getElementById('auth-password').value = '';
        return;
      }

      if (!email || !password) {
        throw new Error('Enter your email and password to continue.');
      }
      if (authMode === 'register') {
        if (!name) throw new Error('Enter your full name to create the account.');
        pendingCustomerSignup = {
          email: email,
          password: password,
          fullName: name,
          phone: draft.guestPhone || '',
          primaryServiceArea: draft.serviceArea || draft.locationLabel || '',
          latitude: draft.latitude,
          longitude: draft.longitude,
          referralCode: referralCode
        };
        const signupResult = await Store.signUpCustomer(pendingCustomerSignup);
        if (signupResult && signupResult.user && !signupResult.session) {
          setAuthMode('verify');
          applyAuthScreenContext();
          document.getElementById('auth-password').value = '';
          document.getElementById('auth-token').value = '';
          showNotice('We sent a 6-digit code to your email. Enter it here to continue.');
          return;
        }
      } else {
        await Store.signIn(email, password);
      }

      await continueAfterCustomerAuth();
    });
  }

  async function verifyCustomerSignupCode() {
    const payload = pendingCustomerSignup || {};
    const email = (payload.email || document.getElementById('auth-contact').value).trim();
    const token = document.getElementById('auth-token').value.replace(/\D/g, '');
    if (!email || token.length !== 6) {
      throw new Error('Enter the 6-digit code from your email.');
    }
    await Store.verifySignupOtp(email, token);
    if (pendingCustomerSignup) {
      await Store.finishCustomerSignup(pendingCustomerSignup);
    }
    pendingCustomerSignup = null;
    document.getElementById('auth-token').value = '';
    showNotice('Email verified. Opening your account...');
    await continueAfterCustomerAuth();
  }

  async function handleCustomerSignupResend() {
    const payload = pendingCustomerSignup || {};
    const email = (payload.email || document.getElementById('auth-contact').value).trim();
    if (!email) {
      showError('Enter your email first so we can resend the code.');
      return;
    }
    await withButtonLoading('btn-auth-resend', 'Resending...', async () => {
      await Store.resendSignupOtp(email, '/login?verify=signup');
      showNotice('A fresh 6-digit code has been sent to your email.');
    });
  }

  async function continueAfterCustomerAuth() {
    if (hasDraftLocation() && draft.issueCategory) {
      await continueFromMatch();
      return;
    }
    if (authScreenIntent === 'tracking' || authScreenIntent === 'dashboard' || authScreenIntent === 'claim-guest') {
      await openDashboard();
      return;
    }
    await resumeLatestJob();
  }

  async function handleCustomerPasswordResetRequest() {
    const email = document.getElementById('auth-contact').value.trim();
    if (!email) {
      showError('Enter your email first so we know where to send the reset link.');
      return;
    }
    await withButtonLoading('btn-auth-forgot', 'Sending Reset Link...', async () => {
      await Store.requestPasswordReset(email, '/login?reset=1');
      showNotice('Reset link sent. Open the email on this device, then choose a new password.');
    });
  }

  async function continueFromMatch() {
    if (bookingSubmitInFlight) return;
    if (draft.addressSource === 'manual' || addressMode === 'manual') {
      syncManualAddressDraft();
    }
    const bookingLocation = getFinalBookingLocation();
    if (!bookingLocation.locationLabel) {
      goTo('service-area');
      showError('Choose a location before submitting.');
      return;
    }
    if (!draft.issueCategory) {
      goTo('problem');
      showError('Select the issue before submitting.');
      return;
    }
    const profile = Store.getCurrentProfile();
    const profileHasPhone = profile && isValidPhone(profile.phone);
    if (!profileHasPhone && !isValidPhone(draft.guestPhone)) {
      renderMatch();
      goTo('match');
      showError('Enter your mobile number before submitting.');
      return;
    }
    if (!profile && uploadedFiles.length) {
      showError('Photos can be added after your booking is confirmed.');
      return;
    }

    bookingSubmitInFlight = true;
    try {
      await withButtonLoading('btn-continue-match', 'Creating Booking...', async () => {
        if (profile && !profileHasPhone) {
          await Store.updateProfile({ phone: draft.guestPhone });
        }
        const bookingPayload = {
          serviceArea: bookingLocation.serviceArea,
          locationLabel: bookingLocation.locationLabel,
          latitude: bookingLocation.latitude,
          longitude: bookingLocation.longitude,
          issueCategory: draft.issueCategory,
          urgency: draft.urgency,
          note: draft.note,
          requiresAssessment: draft.requiresAssessment,
          materialHandling: draft.materialHandling,
          photos: uploadedFiles,
          phone: draft.guestPhone
        };
        let job = Store.getCurrentProfile()
          ? await Store.createBooking(bookingPayload)
          : await Store.createGuestBooking(bookingPayload);
        if (!Store.getCurrentProfile() && job && job.dispatchOtpRequired) {
          try {
            job = await completeGuestDispatchVerification(job, bookingPayload.phone);
          } catch (error) {
            job.dispatchVerificationError = error && error.message ? error.message : 'Phone verification is still needed before dispatch.';
            showError(error);
          }
        }
        finishNewBooking(job);
      });
    } finally {
      bookingSubmitInFlight = false;
    }
  }

  async function completeGuestDispatchVerification(job, phone) {
    showNotice('Sending a verification code to your phone...');
    const delivery = await Store.prepareGuestDispatchOtp(job.id, phone || '');
    const challengeId = delivery.challengeId || delivery.challenge_id;
    const maskedPhone = delivery.maskedPhone || delivery.masked_phone || 'your phone';
    if (!challengeId) {
      throw new Error('Could not start phone verification for dispatch.');
    }
    const code = await promptForDispatchOtp(maskedPhone);
    showNotice('Verifying your phone...');
    const verifiedJob = await Store.confirmGuestDispatchOtp(job.id, challengeId, code);
    showNotice('Phone verified. Pairing you with a VoltFriq now.');
    return verifiedJob || job;
  }

  function promptForDispatchOtp(maskedPhone) {
    return new Promise((resolve, reject) => {
      let modal = document.getElementById('dispatch-otp-modal');
      if (!modal) {
        modal = document.createElement('div');
        modal.id = 'dispatch-otp-modal';
        modal.className = 'dispatch-otp-backdrop';
        document.body.appendChild(modal);
      }
      modal.innerHTML = [
        '<form class="dispatch-otp-panel" id="dispatch-otp-form">',
          '<div class="dispatch-otp-copy">',
            '<strong>Verify your phone</strong>',
            '<span>Enter the 6-digit code sent to ' + escapeHtml(maskedPhone || 'your phone') + ' so we can start pairing you with a VoltFriq.</span>',
          '</div>',
          '<input id="dispatch-otp-code" class="dispatch-otp-input" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="000000" aria-label="Dispatch verification code">',
          '<div class="dispatch-otp-actions">',
            '<button class="btn-ghost" type="button" id="dispatch-otp-cancel">Later</button>',
            '<button class="btn-primary" type="submit">Verify</button>',
          '</div>',
        '</form>'
      ].join('');
      modal.style.display = 'grid';
      const input = document.getElementById('dispatch-otp-code');
      const form = document.getElementById('dispatch-otp-form');
      const cancel = document.getElementById('dispatch-otp-cancel');
      const cleanup = () => {
        modal.style.display = 'none';
        modal.innerHTML = '';
      };
      input.focus();
      input.addEventListener('input', () => {
        input.value = input.value.replace(/\D/g, '').slice(0, 6);
      });
      form.addEventListener('submit', (event) => {
        event.preventDefault();
        const code = input.value.replace(/\D/g, '');
        if (code.length !== 6) {
          input.classList.add('has-error');
          input.focus();
          return;
        }
        cleanup();
        resolve(code);
      });
      cancel.addEventListener('click', () => {
        cleanup();
        reject(new Error('Enter the 6-digit code to start dispatch.'));
      });
    });
  }

  function finishNewBooking(job) {
    if (!job || !job.id) return;
    currentJob = job;
    currentTrackedTicket = job.ticket || currentTrackedTicket;
    bindJobSubscription(job.id);
    routeJob(job, false, { routeData: { ticket: job.ticket || currentTrackedTicket } });
    showBookingConfirmation(job);
    refreshWelcomeActions();
    renderSidecars();
    Store.getJob(job.id).then((freshJob) => {
      if (!freshJob || !currentJob || freshJob.id !== currentJob.id) return;
      currentJob = freshJob;
      currentTrackedTicket = freshJob.ticket || currentTrackedTicket;
      routeJob(freshJob, true, { routeData: { ticket: freshJob.ticket || currentTrackedTicket }, replace: true });
      refreshWelcomeActions();
    }).catch(() => {});
  }

  function showBookingConfirmation(job) {
    let toast = document.getElementById('booking-confirmation-toast');
    if (!toast) {
      toast = document.createElement('div');
      toast.id = 'booking-confirmation-toast';
      toast.className = 'booking-confirmation-toast';
      toast.setAttribute('role', 'status');
      toast.setAttribute('aria-live', 'polite');
      document.body.appendChild(toast);
    }
    const ticket = job && job.ticket ? 'Ticket ' + escapeHtml(job.ticket) + ' is now live.' : 'Your request is now live.';
    const uploadNote = job && job.photoUploadWarning ? ' Your booking is saved; we could not attach the photos just now.' : '';
    const pairingNote = job && job.dispatchOtpRequired && !job.guest_dispatch_verified_at && job.status === 'requested'
      ? ' Verify your phone to start pairing.'
      : ' We are matching you with a verified VoltFriq now.';
    toast.innerHTML = [
      '<span class="booking-confirmation-icon" aria-hidden="true">',
        '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="m8.5 12.2 2.2 2.2 4.8-5"/></svg>',
      '</span>',
      '<span class="booking-confirmation-copy">',
        '<strong>Thank you. Your booking is confirmed.</strong>',
        '<small>' + ticket + escapeHtml(pairingNote) + escapeHtml(uploadNote) + '</small>',
      '</span>'
    ].join('');
    toast.classList.add('is-visible');
    if (bookingConfirmationTimer) window.clearTimeout(bookingConfirmationTimer);
    bookingConfirmationTimer = window.setTimeout(() => {
      toast.classList.remove('is-visible');
    }, 8500);
  }
