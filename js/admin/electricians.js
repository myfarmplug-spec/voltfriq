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
      card.addEventListener('click', () => openElectricianDetail(card.dataset.elecId));
    });
    bindFilterTabs('#elec-filter-tabs', 'electricians');
  }

  function renderRegisteredUsers() {
    const countBadge = document.getElementById('registered-user-count');
    if (countBadge) countBadge.textContent = String(currentCustomers.length);
    const list = document.getElementById('customer-list');
    if (!list) return;
    list.innerHTML = currentCustomers.length ? currentCustomers.map(customerCard).join('') : emptyState('No registered users yet.');
  }
