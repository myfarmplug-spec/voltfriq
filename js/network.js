const NETWORK_BANNER_ID = 'voltfriq-network-status';

export function installNetworkResilience() {
  if (window.__voltfriqNetworkInstalled) return window.VoltFriqNetwork;
  window.__voltfriqNetworkInstalled = true;

  const state = {
    online: navigator.onLine !== false,
    lastOfflineAt: null,
    lastOnlineAt: new Date().toISOString()
  };

  const api = {
    isOnline: () => state.online,
    getState: () => Object.assign({}, state)
  };

  window.VoltFriqNetwork = api;

  const update = (online, reason) => {
    state.online = online;
    if (online) {
      state.lastOnlineAt = new Date().toISOString();
      document.body.classList.remove('network-offline');
      showNetworkBanner('Back online. Syncing latest job updates...', true);
      window.dispatchEvent(new CustomEvent('voltfriq:network-restored', { detail: { reason } }));
      window.setTimeout(hideNetworkBanner, 2600);
    } else {
      state.lastOfflineAt = new Date().toISOString();
      document.body.classList.add('network-offline');
      showNetworkBanner('You are offline. VoltFriq will refresh when your connection returns.', false);
      window.dispatchEvent(new CustomEvent('voltfriq:network-offline', { detail: { reason } }));
    }
  };

  window.addEventListener('online', () => update(true, 'browser-online'));
  window.addEventListener('offline', () => update(false, 'browser-offline'));

  if (!state.online) update(false, 'initial-offline');
  return api;
}

function showNetworkBanner(message, success) {
  let banner = document.getElementById(NETWORK_BANNER_ID);
  if (!banner) {
    banner = document.createElement('div');
    banner.id = NETWORK_BANNER_ID;
    banner.className = 'network-status-banner';
    banner.setAttribute('role', 'status');
    banner.setAttribute('aria-live', 'polite');
    document.body.appendChild(banner);
  }
  banner.classList.toggle('is-success', !!success);
  banner.textContent = message;
  banner.style.display = 'block';
}

function hideNetworkBanner() {
  const banner = document.getElementById(NETWORK_BANNER_ID);
  if (banner) banner.style.display = 'none';
}
