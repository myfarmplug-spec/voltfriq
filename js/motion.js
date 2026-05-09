const DEFAULT_LOADING_TEXT = 'Transmitting...';

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

function setButtonLoading(button, message) {
  if (!button) return () => {};
  const originalHtml = button.innerHTML;
  const originalDisabled = button.disabled;
  const originalBusy = button.getAttribute('aria-busy');

  button.disabled = true;
  button.classList.add('is-loading', 'vf-operational-action');
  button.setAttribute('aria-busy', 'true');
  button.innerHTML = loadingMarkup(message, 'sm');

  return () => {
    button.innerHTML = originalHtml;
    button.disabled = originalDisabled;
    button.classList.remove('is-loading', 'vf-operational-action');
    if (originalBusy === null) {
      button.removeAttribute('aria-busy');
    } else {
      button.setAttribute('aria-busy', originalBusy);
    }
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
  loadingMarkup,
  normalizeLoadingText,
  setButtonLoading,
  setStatusLoading,
  clearStatusLoading
};

if (typeof window !== 'undefined') {
  window.VoltFriqMotion = VoltFriqMotion;
}

export default VoltFriqMotion;
