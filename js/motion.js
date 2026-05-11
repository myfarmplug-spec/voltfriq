const DEFAULT_LOADING_TEXT = 'Transmitting...';
const MIN_VISIBLE_LOADING_MS = 700;

let globalLoadingElement = null;
let globalLoadingId = 0;
const globalLoadingTokens = new Map();

function delay(ms) {
  return new Promise((resolve) => globalThis.setTimeout(resolve, ms));
}

function remainingVisibleTime(startedAt, minimumMs) {
  return Math.max(0, minimumMs - (Date.now() - startedAt));
}

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function normalizeLoadingText(message) {
  const clean = String(message || '').trim();
  if (!clean || clean === '...') return 'Routing...';
  if (/^loading\.{0,3}$/i.test(clean)) return DEFAULT_LOADING_TEXT;
  return clean;
}

function loadingMarkup(message, size) {
  const label = normalizeLoadingText(message);
  return '<span class="vf-energy-loader vf-energy-loader--' + (size || 'sm') + '" aria-hidden="true"></span>' +
    '<span class="vf-loading-label">' + escapeHtml(label) + '</span>';
}

function withMinimumVisible(work, minimumMs) {
  const startedAt = Date.now();
  const visibleMs = Number.isFinite(Number(minimumMs)) ? Number(minimumMs) : MIN_VISIBLE_LOADING_MS;
  return Promise.resolve()
    .then(work)
    .finally(() => delay(remainingVisibleTime(startedAt, visibleMs)));
}

function ensureGlobalLoadingElement() {
  if (typeof document === 'undefined') return null;
  if (globalLoadingElement && document.body.contains(globalLoadingElement)) return globalLoadingElement;
  globalLoadingElement = document.createElement('div');
  globalLoadingElement.id = 'vf-global-loader';
  globalLoadingElement.className = 'vf-global-loader';
  globalLoadingElement.setAttribute('role', 'status');
  globalLoadingElement.setAttribute('aria-live', 'polite');
  globalLoadingElement.setAttribute('aria-busy', 'true');
  globalLoadingElement.hidden = true;
  globalLoadingElement.innerHTML = '<div class="vf-global-loader-panel">' +
    loadingMarkup(DEFAULT_LOADING_TEXT, 'lg') +
  '</div>';
  document.body.appendChild(globalLoadingElement);
  return globalLoadingElement;
}

function latestGlobalLoadingToken() {
  const tokens = Array.from(globalLoadingTokens.values());
  return tokens.length ? tokens[tokens.length - 1] : null;
}

function renderGlobalLoading() {
  const element = ensureGlobalLoadingElement();
  if (!element) return;
  const token = latestGlobalLoadingToken();
  if (!token) {
    element.classList.remove('is-active');
    element.hidden = true;
    element.setAttribute('aria-busy', 'false');
    if (typeof document !== 'undefined') {
      document.body.classList.remove('vf-global-loading-active');
    }
    return;
  }
  const panel = element.querySelector('.vf-global-loader-panel');
  if (panel) panel.innerHTML = loadingMarkup(token.message, 'lg');
  element.hidden = false;
  element.setAttribute('aria-busy', 'true');
  element.classList.add('is-active');
  if (typeof document !== 'undefined') {
    document.body.classList.add('vf-global-loading-active');
  }
}

function showGlobalLoading(message, options) {
  if (typeof window === 'undefined' || typeof document === 'undefined') {
    return () => Promise.resolve();
  }
  const minimumMs = options && Number.isFinite(Number(options.minimumMs))
    ? Number(options.minimumMs)
    : MIN_VISIBLE_LOADING_MS;
  const tokenId = ++globalLoadingId;
  const token = {
    id: tokenId,
    startedAt: Date.now(),
    minimumMs,
    message: normalizeLoadingText(message)
  };
  let finishPromise = null;
  globalLoadingTokens.set(tokenId, token);
  renderGlobalLoading();

  return () => {
    if (finishPromise) return finishPromise;
    finishPromise = delay(remainingVisibleTime(token.startedAt, token.minimumMs)).then(() => {
      globalLoadingTokens.delete(token.id);
      renderGlobalLoading();
    });
    return finishPromise;
  };
}

function setButtonLoading(button, message) {
  if (!button) return () => {};
  const originalHtml = button.innerHTML;
  const originalDisabled = button.disabled;
  const originalBusy = button.getAttribute('aria-busy');
  const startedAt = Date.now();
  let restorePromise = null;

  button.disabled = true;
  button.classList.add('is-loading', 'vf-operational-action');
  button.setAttribute('aria-busy', 'true');
  button.innerHTML = loadingMarkup(message, 'sm');

  return () => {
    if (restorePromise) return restorePromise;
    restorePromise = delay(remainingVisibleTime(startedAt, MIN_VISIBLE_LOADING_MS)).then(() => {
      button.innerHTML = originalHtml;
      button.disabled = originalDisabled;
      button.classList.remove('is-loading', 'vf-operational-action');
      if (originalBusy === null) {
        button.removeAttribute('aria-busy');
      } else {
        button.setAttribute('aria-busy', originalBusy);
      }
    });
    return restorePromise;
  };
}

function setStatusLoading(element, message) {
  if (!element) return;
  element.classList.add('vf-status-message', 'is-operating');
  element.setAttribute('aria-busy', 'true');
  element.innerHTML = loadingMarkup(message, 'md');
}

function clearStatusLoading(element) {
  if (!element) return;
  element.classList.remove('vf-status-message', 'is-operating');
  element.removeAttribute('aria-busy');
}

const VoltFriqMotion = {
  MIN_VISIBLE_LOADING_MS,
  loadingMarkup,
  normalizeLoadingText,
  withMinimumVisible,
  showGlobalLoading,
  setButtonLoading,
  setStatusLoading,
  clearStatusLoading
};

if (typeof window !== 'undefined') {
  window.VoltFriqMotion = VoltFriqMotion;
}

export default VoltFriqMotion;
