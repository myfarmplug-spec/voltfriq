  async function openBookingRoute(targetScreen, options) {
    hydrateDraftState();

    if (!hasDraftLocation()) {
      goTo('service-area', { replace: options && options.replace });
      focusCustomerScreen('service-area');
      if (targetScreen !== 'service-area') {
        persistDraftState();
      }
      return;
    }

    if (targetScreen === 'service-area') {
      goTo('service-area', { replace: options && options.replace });
      focusCustomerScreen('service-area');
      return;
    }

    if (!draft.issueCategory) {
      goTo('problem', { replace: options && options.replace });
      focusCustomerScreen('problem');
      return;
    }

    if (targetScreen === 'problem') {
      goTo('problem', { replace: options && options.replace });
      focusCustomerScreen('problem');
      return;
    }

    if (targetScreen === 'details') {
      goTo('details', { replace: options && options.replace });
      focusCustomerScreen('details');
      return;
    }

    if (targetScreen === 'match') {
      renderMatch();
      goTo('match', { replace: options && options.replace });
      focusCustomerScreen('match');
      return;
    }
  }

  function normalizePath(pathname) {
    const raw = String(pathname || '/').trim();
    if (!raw) return '/';
    const cleaned = raw.replace(/\/+$/, '');
    return cleaned || '/';
  }

  function showConfigurationMessage() {
    document.getElementById('auth-error').style.display = 'block';
    document.getElementById('auth-error').textContent = 'Supabase is not configured yet.';
  }

  function renderSettings() {
    const areas = getConfiguredServiceAreas();
    setInputValue('manual-street-address', draft.streetAddress);
    renderLocationDatalist(areas);
    renderIssueSelect();
  }

  function getConfiguredServiceAreas() {
    if (Store.getServiceAreas) return Store.getServiceAreas();
    const settings = Store.getSettings();
    return Array.isArray(settings.service_areas) ? settings.service_areas.filter(Boolean) : [];
  }

  function renderLocationDatalist(areas) {
    let datalist = document.getElementById('service-area-options');
    if (!datalist) {
      datalist = document.createElement('datalist');
      datalist.id = 'service-area-options';
      document.body.appendChild(datalist);
    }
    datalist.innerHTML = (areas || []).map((area) => '<option value="' + escapeAttribute(area) + '"></option>').join('');
  }

  function renderManualAddressControls() {
    setInputValue('manual-street-address', draft.streetAddress);
  }

  function setInputValue(id, value) {
    const input = document.getElementById(id);
    if (input && document.activeElement !== input) input.value = value || '';
  }

  function getElementValue(id) {
    const element = document.getElementById(id);
    return element ? String(element.value || '').trim() : '';
  }

  function syncServiceAreaSelect(value) {
    draft.serviceArea = String(value || '').trim();
  }

  async function startBooking() {
    closeMobileMenu();
    resetDraft();
    goTo('service-area');
    focusCustomerScreen('service-area');
    setAddressMode('gps', { autoStarted: true });
  }

  function setAddressMode(mode, options) {
    addressMode = mode === 'manual' ? 'manual' : 'gps';
    document.querySelectorAll('#address-mode-tabs [data-address-mode]').forEach((button) => {
      button.classList.toggle('active', button.dataset.addressMode === addressMode);
    });

    togglePanel('address-entry-panel', addressMode === 'manual');

    if (addressMode === 'gps' && !draft.latitude && !draft.longitude) {
      useCurrentLocation(!!(options && options.autoStarted));
    }
    if (addressMode === 'manual') {
      if (!draft.country) draft.country = DEFAULT_COUNTRY;
      renderManualAddressControls();
      syncManualAddressDraft();
      window.setTimeout(() => {
        const input = document.getElementById('manual-street-address');
        if (input) input.focus();
      }, 80);
    }
  }

  function togglePanel(id, visible) {
    const panel = document.getElementById(id);
    if (!panel) return;
    panel.hidden = !visible;
    panel.style.display = visible ? '' : 'none';
  }

  function applyAddressSelection(address, source) {
    const normalized = Store.selectDraftAddress ? Store.selectDraftAddress(address) : address;
    const label = normalized.locationLabel || normalized.addressText || normalized.label || '';
    draft.locationLabel = label;
    draft.serviceArea = label;
    draft.latitude = normalized.latitude == null ? null : Number(normalized.latitude);
    draft.longitude = normalized.longitude == null ? null : Number(normalized.longitude);
    draft.addressSource = source || normalized.source || 'gps';
    syncServiceAreaSelect(label);
    persistDraftState();
    updateAvailabilityCard();
  }

  function syncManualAddressDraft() {
    const streetAddress = getElementValue('manual-street-address');

    draft.country = DEFAULT_COUNTRY;
    draft.state = '';
    draft.city = '';
    draft.streetAddress = streetAddress;
    draft.landmark = '';

    if (streetAddress) {
      draft.addressSource = 'manual';
      draft.latitude = null;
      draft.longitude = null;
    }

    const manualLabel = composeManualLocationLabel();
    if (manualLabel) {
      draft.locationLabel = manualLabel;
    } else if (draft.addressSource === 'manual') {
      draft.locationLabel = '';
    }
    const inferredServiceArea = Store.inferServiceAreaFromAddress
      ? Store.inferServiceAreaFromAddress({
          locationLabel: manualLabel,
          streetAddress,
          country: DEFAULT_COUNTRY
        })
      : '';
    draft.serviceArea = inferredServiceArea || manualServiceAreaFallback();
    persistDraftState();
  }

  function composeManualLocationLabel() {
    if (!draft.streetAddress) return '';
    return String(draft.streetAddress || '').trim();
  }

  function manualServiceAreaFallback() {
    return draft.locationLabel || draft.streetAddress || '';
  }

  function hasManualAddress() {
    return Boolean(draft.streetAddress);
  }

  function bindChoiceRow(id, callback) {
    const container = document.getElementById(id);
    if (!container) return;
    container.addEventListener('click', (event) => {
      const pill = event.target.closest('.choice-pill');
      if (!pill) return;
      container.querySelectorAll('.choice-pill').forEach((item) => item.classList.remove('active'));
      pill.classList.add('active');
      callback(pill.dataset.value);
    });
  }

  async function useCurrentLocation(autoStarted) {
    if (!navigator.geolocation) {
      setAddressMode('manual');
      return;
    }

    navigator.geolocation.getCurrentPosition(async (position) => {
      const latitude = position.coords.latitude;
      const longitude = position.coords.longitude;
      const readableLocation = await reverseGeocode(latitude, longitude);
      const fallbackLabel = 'GPS location (' + latitude.toFixed(4) + ', ' + longitude.toFixed(4) + ')';
      applyAddressSelection({
        label: 'Current location',
        addressText: readableLocation || fallbackLabel,
        locationLabel: readableLocation || fallbackLabel,
        latitude,
        longitude
      }, 'gps');
    }, () => {
      setAddressMode('manual');
      updateAvailabilityCard();
    }, {
      enableHighAccuracy: true,
      timeout: 12000,
      maximumAge: 60000
    });
  }

  async function reverseGeocode(latitude, longitude) {
    try {
      const response = await fetch('https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=' + encodeURIComponent(latitude) + '&longitude=' + encodeURIComponent(longitude) + '&localityLanguage=en');
      if (!response.ok) return '';
      const data = await response.json();
      const parts = [
        data.locality,
        data.city && data.city !== data.locality ? data.city : '',
        data.principalSubdivision
      ].filter(Boolean);
      return Array.from(new Set(parts)).join(', ');
    } catch (error) {
      return '';
    }
  }

  function handlePhotoSelect(event) {
    const files = Array.from(event.target.files || []);
    const validFiles = files.filter((file) => file.type.indexOf('image/') === 0 && file.size <= 5 * 1024 * 1024);
    const availableSlots = 3 - uploadedFiles.length;
    uploadedFiles = uploadedFiles.concat(validFiles.slice(0, availableSlots));
    if (validFiles.length !== files.length) {
      showError(new Error('Only image uploads under 5MB are allowed.'));
    }
    renderPhotoPreviews();
    persistDraftState();
    event.target.value = '';
  }

  function renderPhotoPreviews() {
    const list = document.getElementById('photo-previews');
    list.innerHTML = uploadedFiles.map((file, index) => {
      return '<div class="photo-preview">' +
        '<div style="padding:14px 10px;font-size:12px;font-weight:600;line-height:1.4;">' + escapeHtml(file.name) + '</div>' +
        '<button class="photo-remove" data-index="' + index + '">&times;</button>' +
      '</div>';
    }).join('');

    list.querySelectorAll('.photo-remove').forEach((button) => {
      button.addEventListener('click', () => {
        uploadedFiles.splice(parseInt(button.dataset.index, 10), 1);
        renderPhotoPreviews();
        persistDraftState();
      });
    });
  }

  function updateAvailabilityCard() {
    if (addressMode === 'manual' || draft.addressSource === 'manual') {
      syncManualAddressDraft();
    }
    const bookingLocation = getFinalBookingLocation();
    const hasLocation = Boolean(bookingLocation.locationLabel);
    const continueButton = document.getElementById('btn-area-continue');
    if (continueButton) continueButton.disabled = !hasLocation;
    persistDraftState();
  }

  function getFinalBookingLocation() {
    if (draft.addressSource === 'manual' || addressMode === 'manual') {
      syncManualAddressDraft();
    }
    const locationLabel = String(draft.locationLabel || composeManualLocationLabel() || '').trim();
    const inferredServiceArea = Store.inferServiceAreaFromAddress
      ? Store.inferServiceAreaFromAddress({
          serviceArea: draft.serviceArea,
          locationLabel,
          streetAddress: draft.streetAddress,
          landmark: draft.landmark,
          city: draft.city,
          state: draft.state,
          country: draft.country
        })
      : '';
    const serviceArea = String(draft.serviceArea || inferredServiceArea || manualServiceAreaFallback() || locationLabel).trim();
    return {
      locationLabel,
      serviceArea,
      latitude: draft.latitude == null ? null : draft.latitude,
      longitude: draft.longitude == null ? null : draft.longitude
    };
  }

  function hasDraftLocation() {
    return Boolean(getFinalBookingLocation().locationLabel);
  }

