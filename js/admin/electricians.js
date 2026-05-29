  function renderElectricians() {
    renderRegisteredUsers();
    const statusFilters = ['pending', 'approved', 'rejected', 'suspended'];
    const rows = currentElectricians.filter((electrician) => statusFilters.includes(currentFilter.electricians) ? electrician.status === currentFilter.electricians : true);
    const filteredRows = rows.filter((electrician) => {
      if (currentFilter.electricians === 'active') return electricianHasActiveJob(electrician);
      if (currentFilter.electricians === 'idle') return electrician.status === 'approved' && electrician.availability_status === 'available' && !electricianHasActiveJob(electrician);
      if (currentFilter.electricians === 'offline') return electrician.availability_status !== 'available';
      if (currentFilter.electricians === 'watchlist') return !!electrician.watchlist;
      return true;
    });
    const countBadge = document.getElementById('electrician-count');
    if (countBadge) countBadge.textContent = String(filteredRows.length);
    $('#elec-list').innerHTML = filteredRows.length ? filteredRows.map(electricianCard).join('') : emptyState('No electricians in this view.');
    $('#elec-list').querySelectorAll('.admin-job-card').forEach((card) => {
      card.addEventListener('click', (event) => {
        if (event.target.closest('button, a, input, select, textarea')) return;
        openElectricianDetail(card.dataset.elecId);
      });
    });
    bindElectricianListActions();
    bindFilterTabs('#elec-filter-tabs', 'electricians');
  }

  function bindElectricianListActions() {
    $('#elec-list').querySelectorAll('[data-elec-list-action]').forEach((button) => {
      button.addEventListener('click', async (event) => {
        event.stopPropagation();
        const electricianId = button.dataset.elecId;
        const action = button.dataset.elecListAction;
        if (action === 'open') {
          await openElectricianDetail(electricianId);
          return;
        }
        await withButtonLoading(button.id, action === 'approved' ? 'Approving...' : 'Updating...', async () => {
          await Store.setElectricianStatus(electricianId, action);
          await loadData({ sections: ['electricians', 'jobs', 'appeals'] });
          renderElectricians();
          showAdminNotice(action === 'approved' ? 'Electrician approved and available for assignment.' : 'Electrician status updated.');
        });
      });
    });
  }

  function renderRegisteredUsers() {
    const countBadge = document.getElementById('registered-user-count');
    if (countBadge) countBadge.textContent = String(currentCustomers.length);
    const list = document.getElementById('customer-list');
    if (!list) return;
    list.innerHTML = currentCustomers.length ? currentCustomers.map(customerCard).join('') : emptyState('No registered users yet.');
  }
