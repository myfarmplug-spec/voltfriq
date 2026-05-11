  function renderRequests() {
	    const jobs = currentJobs.filter((job) => {
	      if (currentFilter.requests === 'matching') return job.status === 'matching' && !job.needsManualAssignment;
	      if (currentFilter.requests === 'manual') return job.needsManualAssignment || isStuckJob(job) || !job.assignedElectricianId;
	      if (currentFilter.requests === 'failed') return job.status === 'matching' && Number(job.dispatchAttempts || 0) >= 3;
	      if (currentFilter.requests === 'timeout') return isExpiredAssignment(job) || hasTimeoutTimeline(job);
	      if (currentFilter.requests === 'rejected') return hasRejectedTimeline(job);
	      return job.status === 'matching' || job.status === 'assigned' || job.needsManualAssignment || hasRejectedTimeline(job) || hasTimeoutTimeline(job) || isExpiredAssignment(job);
	    });

    $('#requests-list').innerHTML = jobs.length ? jobs.map(dispatchJobCard).join('') : emptyState('No jobs in the dispatch queue.');
    bindJobCards('#requests-list', openRequestDetail);
    bindFilterTabs('#requests-filter-tabs', 'requests');
  }

  async function openRequestDetail(jobId) {
    const finishLoading = showAdminLoading('Syncing operations...');
    try {
      selectedJob = await Store.getJob(jobId);
      const matches = await Store.previewMatches({
        serviceArea: selectedJob.serviceArea,
        issueCategory: selectedJob.issueCategory,
        latitude: selectedJob.latitude,
        longitude: selectedJob.longitude,
        limit: 8
      });

      $('#request-detail-body').innerHTML =
        infoCard('Customer', [
          ['Ticket', selectedJob.ticket],
          ['Customer', selectedJob.customer && selectedJob.customer.name ? selectedJob.customer.name : '--'],
          ['Phone', selectedJob.customer && selectedJob.customer.phone ? selectedJob.customer.phone : '--'],
          ['Area', selectedJob.serviceArea],
          ['Issue type', humanizeIssue(selectedJob.issueCategory)],
          ['Urgency', humanizeUrgency(selectedJob.urgency)]
        ]) +
        infoCard('Dispatch status', [
          ['Job status', selectedJob.statusLabel],
          ['Assigned electrician', selectedJob.assignedElectrician ? selectedJob.assignedElectrician.name : 'Unassigned'],
          ['Matching note', nextAction(selectedJob)],
          ['Dispatch attempts', String(selectedJob.dispatchAttempts || 0)]
        ]) +
        photoCard(selectedJob.photos) +
        assignmentCard(matches, selectedJob) +
  	      timelineCard(selectedJob.internalEvents && selectedJob.internalEvents.length ? selectedJob.internalEvents : selectedJob.timeline);

      bindAssignmentControls(selectedJob);
      navigateTo('admin-request-detail', {
        routeData: { ticket: selectedJob.ticket }
      });
    } finally {
      finishLoading();
    }
  }
