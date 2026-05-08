(function () {
  'use strict';

  if (!('serviceWorker' in navigator)) return;
  window.addEventListener('load', function () {
    navigator.serviceWorker.register('/sw.js').catch(function () {
      // Offline fallback is progressive enhancement; the app should keep running if registration fails.
    });
  });
}());
