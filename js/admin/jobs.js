  function renderTrust() {
    const openAppeals = currentAppeals.filter((appeal) => appeal.status === 'open');
    const watchlisted = currentElectricians.filter((electrician) => electrician.watchlist);
    const poorPerformance = currentElectricians.filter((electrician) => Number(electrician.negative_rating_count || 0) > 0 || Number(electrician.average_rating || 5) < 3.5);

    $('#appeals-list').innerHTML = openAppeals.length ? openAppeals.map(appealCard).join('') : emptyState('No open appeals right now.');
    $('#watchlist-list').innerHTML = watchlisted.length ? watchlisted.map(electricianCard).join('') : emptyState('No VoltFriqs are on watchlist.');
    $('#quality-list').innerHTML = poorPerformance.length ? poorPerformance.map(electricianCard).join('') : emptyState('No poor performance cases right now.');

    $('#appeals-list').querySelectorAll('[data-appeal-action]').forEach((button) => {
      button.addEventListener('click', async (event) => {
        event.stopPropagation();
        const approved = button.dataset.appealAction === 'approve';
        const note = approved
          ? 'Appeal approved. VoltFriq restored on watchlist.'
          : 'Appeal rejected after admin review.';
        await withButtonLoading(button.id, approved ? 'Approving...' : 'Rejecting...', async () => {
          await Store.resolveElectricianAppeal(button.dataset.appealId, approved, note);
          await loadData({ sections: ['electricians', 'appeals'] });
          renderTrust();
        });
      });
    });

    $('#appeals-list').querySelectorAll('.admin-job-card[data-elec-id]').forEach((card) => {
      card.addEventListener('click', () => openElectricianDetail(card.dataset.elecId));
    });
    $('#watchlist-list').querySelectorAll('.admin-job-card').forEach((card) => {
      card.addEventListener('click', () => openElectricianDetail(card.dataset.elecId));
    });
    $('#quality-list').querySelectorAll('.admin-job-card').forEach((card) => {
      card.addEventListener('click', () => openElectricianDetail(card.dataset.elecId));
    });
  }

  async function openElectricianDetail(electricianId) {
    const finishLoading = showAdminLoading('Syncing operations...');
    try {
      selectedElectrician = currentElectricians.find((electrician) => electrician.id === electricianId);
      if (!selectedElectrician) {
        await loadData({ sections: ['electricians', 'jobs', 'appeals'] });
        selectedElectrician = currentElectricians.find((electrician) => electrician.id === electricianId);
      }
      if (!selectedElectrician) {
        showLoginError('Electrician profile could not be found. Refresh the electricians list and try again.');
        navigateTo('admin-electricians', { replace: true });
        return;
      }
      await Store.hydrateElectricianDocuments(selectedElectrician).catch(() => selectedElectrician);

      const docs = (selectedElectrician.electrician_documents || []).map((documentItem) => {
        const href = documentItem.signedUrl || '';
        const link = href ? '<a class="admin-inline-link" href="' + escapeAttribute(href) + '" target="_blank" rel="noreferrer">View file</a>' : 'No file';
        return '<div class="admin-file-row"><div><div class="admin-file-name">' + escapeHtml(documentLabel(documentItem.document_type)) + '</div><div class="admin-file-meta">' + escapeHtml(documentItem.status || 'pending') + '</div></div><div>' + link + '</div></div>';
      }).join('') || '<div class="admin-empty-inline">No documents uploaded.</div>';
      const certifications = (selectedElectrician.electrician_certifications || []).length
        ? (selectedElectrician.electrician_certifications || []).map((certification) => {
            const pieces = [certification.title || 'Certification'];
            if (certification.issuer) pieces.push(certification.issuer);
            if (certification.license_number) pieces.push('License: ' + certification.license_number);
            return [pieces[0], pieces.slice(1).join(' · ') || 'Submitted during onboarding'];
          })
        : [['Certifications', 'No structured certifications submitted']];

      $('#elec-detail-body').innerHTML =
        infoCard('Electrician profile', [
          ['Name', selectedElectrician.profile && selectedElectrician.profile.full_name ? selectedElectrician.profile.full_name : 'VoltFriq'],
          ['Phone', selectedElectrician.profile && selectedElectrician.profile.phone ? selectedElectrician.profile.phone : '--'],
          ['Status', selectedElectrician.status],
          ['Level', selectedElectrician.level_badge || 'Verified Pro'],
          ['Watchlist', selectedElectrician.watchlist ? 'Yes' : 'No'],
          ['Negative ratings', String(selectedElectrician.negative_rating_count || 0)],
          ['Suspension reason', selectedElectrician.suspended_reason || '--'],
          ['Availability', selectedElectrician.availability_status || 'offline'],
          ['Experience', String(selectedElectrician.years_experience || 0) + ' years'],
          ['Service areas', (selectedElectrician.service_areas || []).join(', ') || '--'],
          ['Onboarding score', selectedElectrician.onboarding_score ? Number(selectedElectrician.onboarding_score).toFixed(0) + '%' : '--'],
          ['Onboarding review', selectedElectrician.onboarding_review_status || 'pending']
        ]) +
        electricianActionsCard(selectedElectrician) +
        electricianAssignmentQueueCard(selectedElectrician) +
        infoCard('Trust history', electricianTrustRows(selectedElectrician)) +
        electricianActivityCard(selectedElectrician) +
        appealsCard(selectedElectrician) +
        infoCard('Skills', (selectedElectrician.electrician_skills || []).length
          ? selectedElectrician.electrician_skills.map((skill) => [humanizeIssue(skill.category), 'Matched skill'])
          : [['Skills', 'No skills listed']]) +
        infoCard('Certifications', certifications) +
        '<div class="admin-info-card"><div class="admin-info-card-title">Documents</div>' + docs + '</div>';

      bindElectricianAction('btn-approve-elec', electricianId, 'approved');
      bindElectricianAction('btn-reject-elec', electricianId, 'rejected');
      bindElectricianAction('btn-suspend-elec', electricianId, 'suspended');
      bindWatchlistAction('btn-add-watchlist', electricianId, true);
      bindWatchlistAction('btn-remove-watchlist', electricianId, false);
      bindElectricianAssignmentQueue(electricianId);
      navigateTo('admin-elec-detail', {
        routeData: { electricianId: electricianId }
      });
    } finally {
      finishLoading();
    }
  }

  function renderJobs() {
    const jobs = currentJobs.filter((job) => {
      if (currentFilter.jobs === 'matching') return job.status === 'matching';
      if (currentFilter.jobs === 'assigned') return job.status === 'assigned';
      if (currentFilter.jobs === 'accepted') return job.status === 'accepted';
      if (currentFilter.jobs === 'payment_pending_verification') return ['assessment_payment_pending_verification', 'work_payment_pending_verification'].includes(job.status);
      if (currentFilter.jobs === 'payment_confirmed') return job.status === 'payment_confirmed';
      if (currentFilter.jobs === 'in_progress') return ['en_route', 'on_site', 'work_in_progress', 'electrician_completed', 'customer_confirmed', 'payout_pending'].includes(job.status);
      if (currentFilter.jobs === 'completed') return isCompletedJob(job);
      if (currentFilter.jobs === 'cancelled') return job.status === 'cancelled';
      return true;
    });

    $('#jobs-list').innerHTML = jobs.length ? jobs.map(jobCard).join('') : emptyState('No jobs in this filter.');
    bindJobCards('#jobs-list', openJobDetail);
    bindFilterTabs('#jobs-filter-tabs', 'jobs');
  }

  async function openJobDetail(jobId) {
    const finishLoading = showAdminLoading('Syncing operations...');
    try {
      selectedJob = await Store.getJob(jobId);
      upsertCurrentJob(selectedJob);
      $('#job-detail-title').textContent = selectedJob.ticket;
      $('#job-detail-body').innerHTML =
        infoCard('Job summary', [
          ['Status', selectedJob.statusLabel],
          ['Issue', humanizeIssue(selectedJob.issueCategory)],
          ['Urgency', humanizeUrgency(selectedJob.urgency)],
          ['Area', selectedJob.serviceArea],
          ['Description', selectedJob.description || 'No customer note']
        ]) +
        infoCard('People', [
          ['Customer', selectedJob.customer && selectedJob.customer.name ? selectedJob.customer.name : '--'],
          ['Customer phone', selectedJob.customer && selectedJob.customer.phone ? selectedJob.customer.phone : '--'],
          ['Electrician', selectedJob.assignedElectrician ? selectedJob.assignedElectrician.name : 'Unassigned'],
          ['Electrician phone', selectedJob.assignedElectrician ? selectedJob.assignedElectrician.phone : '--']
        ]) +
        infoCard('Customer behavior history', customerTrustRows(selectedJob.customer)) +
        infoCard('Customer request history', customerHistoryRows(selectedJob)) +
        infoCard('Two-sided reviews', reviewRows(selectedJob)) +
        photoCard(selectedJob.photos) +
        paymentVerificationCard(selectedJob) +
        payoutCard(selectedJob) +
        assignmentSummaryCard(selectedJob) +
  	      timelineCard(selectedJob.internalEvents && selectedJob.internalEvents.length ? selectedJob.internalEvents : selectedJob.timeline) +
        '<div class="admin-chat-wrap"><div class="admin-chat-header">Job Chat</div><div id="admin-job-chat" class="chat-container" style="flex:1;min-height:0"></div></div>';

      bindPaymentButtons(selectedJob);
      bindPayoutButtons(selectedJob);
      bindQuickReassignButton(selectedJob);
      navigateTo('admin-job-detail', {
        routeData: { ticket: selectedJob.ticket }
      });
      await Chat.init('admin-job-chat', selectedJob.id, 'admin', (Store.getCurrentProfile() || {}).full_name || 'Admin');
    } finally {
      finishLoading();
    }
  }
