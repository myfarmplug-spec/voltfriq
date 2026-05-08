  function renderDisputes() {
    $('#disputes-list').innerHTML = currentDisputes.length ? currentDisputes.map((dispute) => {
      const job = dispute.jobs || {};
      const customerName = dispute.customer && dispute.customer.profile ? dispute.customer.profile.full_name : 'Customer';
      const electricianName = dispute.electrician && dispute.electrician.profile ? dispute.electrician.profile.full_name : 'Unassigned';
      return '<div class="admin-job-card" data-dispute-id="' + dispute.id + '" data-job-id="' + escapeAttribute(dispute.job_id) + '">' +
        cardHeader(dispute.issue_type || 'Dispute', dispute.status || 'open', dispute.status === 'open' ? 'status-rejected' : 'status-completed') +
        cardMetaRow((job.ticket || 'Job') + ' · ' + (job.service_area || '--')) +
        cardMetaRow('Customer: ' + customerName) +
        cardMetaRow('Electrician: ' + electricianName) +
        '<div class="admin-dispute-copy">' + escapeHtml(dispute.details || 'No extra details added.') + '</div>' +
        '<div class="admin-action-row">' +
          '<button class="btn-secondary btn-full" data-dispute-action="refund" data-dispute-id="' + dispute.id + '">Mark Refund Review</button>' +
          '<button class="btn-secondary btn-full" data-dispute-action="penalize" data-dispute-id="' + dispute.id + '">Penalize Electrician</button>' +
          '<button class="btn-primary btn-full" data-dispute-action="resolve" data-dispute-id="' + dispute.id + '">Resolve</button>' +
        '</div>' +
      '</div>';
    }).join('') : emptyState('No disputes have been raised.');

    $('#disputes-list').querySelectorAll('[data-dispute-action]').forEach((button) => {
      button.addEventListener('click', async (event) => {
        event.stopPropagation();
        const action = button.dataset.disputeAction;
        const note = action === 'refund'
          ? 'Customer refund requires manual follow-up.'
          : action === 'penalize'
            ? 'Electrician performance penalty recorded for review.'
            : 'Dispute resolved by admin.';
        await resolveDisputeAction(button.dataset.disputeId, action === 'resolve' ? 'resolved' : 'under_review', action, note);
      });
    });

    $('#disputes-list').querySelectorAll('.admin-job-card').forEach((card) => {
      card.addEventListener('click', async () => {
        await openJobDetail(card.dataset.jobId);
      });
    });
  }

