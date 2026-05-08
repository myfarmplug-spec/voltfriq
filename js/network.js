const NETWORK_BANNER_ID = 'voltfriq-network-status';
const REFRESH_DEBOUNCE_MS = 450;
const reconnectTasks = new Map();

export function installNetworkResilience() {
  if (window.__voltfriqNetworkInstalled) return window.VoltFriqNetwork;
  window.__voltfriqNetworkInstalled = true;

  const state = {
    online: navigator.onLine !== false,
    lastOfflineAt: null,
    lastOnlineAt: new Date().toISOString(),
    lastRefreshRequestedAt: null,
    refreshReason: null
  };
  let refreshTimer = null;
  const requestRefresh = (reason) => {
    state.lastRefreshRequestedAt = new Date().toISOString();
    state.refreshReason = reason || 'refresh-requested';
    if (refreshTimer) window.clearTimeout(refreshTimer);
    refreshTimer = window.setTimeout(() => {
      refreshTimer = null;
      window.dispatchEvent(new CustomEvent('voltfriq:refresh-requested', {
        detail: { source: state.refreshReason, network: Object.assign({}, state) }
      }));
    }, REFRESH_DEBOUNCE_MS);
  };
  const api = {
    isOnline: () => state.online,
    getState: () => Object.assign({}, state),
    requestRefresh,
    onReconnect: (name, callback) => {
      if (typeof callback !== 'function') return () => {};
      const key = String(name || 'task-' + reconnectTasks.size);
      reconnectTasks.set(key, callback);
      return () => reconnectTasks.delete(key);
    }
  };

  window.VoltFriqNetwork = api;

  const update = (online, reason) => {
    state.online = online;
    if (online) {
      state.lastOnlineAt = new Date().toISOString();
      document.body.classList.remove('network-offline');
      showNetworkBanner('Back online. Syncing latest job updates...', true);
      window.dispatchEvent(new CustomEvent('voltfriq:network-restored', { detail: { reason } }));
      runReconnectTasks();
      requestRefresh(reason || 'network-restored');
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
  window.addEventListener('pageshow', () => {
    if (state.online) requestRefresh('pageshow');
  });
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && state.online) requestRefresh('tab-visible');
  });

  if (!state.online) update(false, 'initial-offline');
  return api;
}

function runReconnectTasks() {
  const api = window.VoltFriqNetwork;
  if (!api || !api.getState) return;
  reconnectTasks.forEach((callback) => {
    try {
      Promise.resolve(callback(api.getState())).catch((error) => {
        window.setTimeout(() => { throw error; }, 0);
      });
    } catch (error) {
      window.setTimeout(() => { throw error; }, 0);
    }
  });
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
