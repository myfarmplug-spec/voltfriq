/* ─── VOLTFRIQ OCEAN — SCREEN NAVIGATION + ROUTING ───────────────── */

let currentScreen = null;
let screenHistory = [];
let routeConfig = null;
let routePopstateBound = false;
let handlingRoutePopstate = false;
let navigationTransitionId = 0;
const NAVIGATION_ACTIVATION_DELAY_MS = 80;

function getScreenKey(element) {
  if (!element || !element.id) return null;
  return element.id.replace(/^screen-/, '');
}

function normalizeRouteResult(result) {
  if (!result) return null;
  if (typeof result === 'string') return { screen: result, data: null };
  if (!result.screen) return null;
  return {
    screen: result.screen,
    data: result.data || null
  };
}

function configureRoutes(config) {
  routeConfig = Object.assign({
    defaultScreen: null,
    routes: {},
    pathParser: null,
    pathResolver: null,
    titleResolver: null,
    onRouteActivated: null
  }, config || {});

  if (!routePopstateBound && typeof window !== 'undefined') {
    routePopstateBound = true;
    window.addEventListener('popstate', handleRoutePopstate);
  }
}

function getCurrentRouteState() {
  if (!routeConfig || typeof window === 'undefined') return null;

  if (typeof routeConfig.pathParser === 'function') {
    const parsed = normalizeRouteResult(routeConfig.pathParser(window.location.pathname));
    if (parsed) return parsed;
  }

  const directMatch = Object.entries(routeConfig.routes || {}).find((entry) => entry[1] === window.location.pathname);
  if (directMatch) {
    return { screen: directMatch[0], data: null };
  }

  if (routeConfig.defaultScreen) {
    return { screen: routeConfig.defaultScreen, data: null };
  }

  return null;
}

function routePathForScreen(screen, routeData) {
  if (!routeConfig) return null;
  if (typeof routeConfig.pathResolver === 'function') {
    return routeConfig.pathResolver(screen, routeData || null);
  }
  return (routeConfig.routes || {})[screen] || null;
}

function routeTitleForScreen(screen, routeData) {
  if (!routeConfig || typeof routeConfig.titleResolver !== 'function') return document.title;
  return routeConfig.titleResolver(screen, routeData || null) || document.title;
}

function startNavigationLoading(message) {
  if (typeof window === 'undefined' || !window.VoltFriqMotion || typeof window.VoltFriqMotion.showGlobalLoading !== 'function') {
    return () => {};
  }
  return window.VoltFriqMotion.showGlobalLoading(message || 'Routing...');
}

function screenExists(id) {
  return !!document.getElementById(`screen-${id}`);
}

function delayNavigationActivation(callback, finishLoading) {
  if (typeof window === 'undefined') {
    callback(finishLoading);
    return;
  }
  const transitionId = ++navigationTransitionId;
  window.setTimeout(() => {
    if (transitionId !== navigationTransitionId) {
      finishLoading();
      return;
    }
    callback(finishLoading);
  }, NAVIGATION_ACTIVATION_DELAY_MS);
}

function syncRoute(screen, options) {
  if (!routeConfig || typeof window === 'undefined') return;

  const routeData = options && options.routeData ? options.routeData : null;
  const path = routePathForScreen(screen, routeData);
  const title = routeTitleForScreen(screen, routeData);
  const state = {
    screen,
    routeData,
    stack: screenHistory.slice()
  };

  if (title) {
    document.title = title;
  }

  if (!path) return;

  if (options && options.replace) {
    window.history.replaceState(state, title || '', path);
    return;
  }

  window.history.pushState(state, title || '', path);
}

function activateScreen(id, options) {
  const next = document.getElementById(`screen-${id}`);
  if (!next) return false;

  const fallbackPrev = document.querySelector('.screen.active');
  const prevId = currentScreen || getScreenKey(fallbackPrev);
  const prev = prevId ? document.getElementById(`screen-${prevId}`) : null;
  const restoreStack = options && Array.isArray(options.restoreStack) ? options.restoreStack.slice() : null;
  const skipStackPush = !!(options && options.skipStackPush);

  document.querySelectorAll('.screen.active').forEach((screen) => {
    if (screen === next) return;
    screen.classList.add('prev');
    screen.classList.remove('active');
    setTimeout(() => screen.classList.remove('prev'), 400);
  });

  next.classList.add('active');
  next.classList.remove('is-energy-entering');
  if (!window.matchMedia || !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    requestAnimationFrame(() => {
      next.classList.add('is-energy-entering');
      setTimeout(() => next.classList.remove('is-energy-entering'), 420);
    });
  }
  next.scrollTop = 0;

  if (restoreStack) {
    screenHistory = restoreStack;
  } else if (prev && prev !== next && prevId && prevId !== id && !skipStackPush) {
    screenHistory.push(prevId);
  }

  currentScreen = id;
  return true;
}

function goTo(id, options) {
  if (!screenExists(id)) return;
  const finishLoading = startNavigationLoading('Routing...');
  delayNavigationActivation((finish) => {
    const activated = activateScreen(id, options || {});
    if (!activated) {
      finish();
      return;
    }
    try {
      if (routeConfig && !handlingRoutePopstate && !(options && options.skipRoute)) {
        syncRoute(id, options || {});
      }
    } finally {
      finish();
    }
  }, finishLoading);
}

function handleRoutePopstate(event) {
  if (!routeConfig) return;

  const state = event && event.state ? event.state : null;
  const route = state && state.screen
    ? { screen: state.screen, data: state.routeData || null }
    : getCurrentRouteState();

  if (!route || !route.screen) return;

  if (!screenExists(route.screen)) return;
  const finishLoading = startNavigationLoading('Routing...');
  delayNavigationActivation((finish) => {
    const activated = activateScreen(route.screen, {
      restoreStack: state && Array.isArray(state.stack) ? state.stack : [],
      skipStackPush: true
    });
    if (!activated) {
      finish();
      return;
    }

    const title = routeTitleForScreen(route.screen, route.data);
    if (title) {
      document.title = title;
    }

    if (typeof routeConfig.onRouteActivated === 'function') {
      handlingRoutePopstate = true;
      try {
        Promise.resolve(routeConfig.onRouteActivated({
          screen: route.screen,
          data: route.data || null,
          source: 'popstate'
        })).finally(() => {
          handlingRoutePopstate = false;
          finish();
        });
      } catch (error) {
        handlingRoutePopstate = false;
        finish();
        throw error;
      }
    } else {
      finish();
    }
  }, finishLoading);
}

function goBack() {
  if (routeConfig && screenHistory.length > 0 && typeof window !== 'undefined' && window.history.length > 1) {
    window.history.back();
    return;
  }

  if (routeConfig && routeConfig.defaultScreen && currentScreen && currentScreen !== routeConfig.defaultScreen) {
    goTo(routeConfig.defaultScreen, { replace: true });
    screenHistory = [];
    return;
  }

  if (screenHistory.length > 0) {
    const prevId = screenHistory.pop();
    const curr = document.getElementById(`screen-${currentScreen}`);
    const prev = document.getElementById(`screen-${prevId}`);
    const finishLoading = curr || prev ? startNavigationLoading('Routing...') : () => {};
    delayNavigationActivation((finish) => {
      if (curr) {
        curr.classList.remove('active');
        curr.classList.add('prev');
        setTimeout(() => curr.classList.remove('prev'), 400);
      }
      if (prev) {
        prev.classList.add('active');
        prev.scrollTop = 0;
      }
      currentScreen = prevId;
      finish();
    }, finishLoading);
  }
}

// Format currency
function fmt(n) {
  return '₦' + Number(n).toLocaleString();
}

// Format date
function fmtDate(d) {
  return new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

// Time ago
function timeAgo(ts) {
  const diff = Date.now() - ts;
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return 'Just now';
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  return `${days}d ago`;
}

if (typeof window !== 'undefined') {
  Object.assign(window, {
    configureRoutes,
    getCurrentRouteState,
    goTo,
    goBack,
    fmt,
    fmtDate,
    timeAgo
  });
  Object.defineProperty(window, 'currentScreen', {
    configurable: true,
    get() {
      return currentScreen;
    },
    set(value) {
      currentScreen = value;
    }
  });
}

export {
  configureRoutes,
  getCurrentRouteState,
  goTo,
  goBack,
  fmt,
  fmtDate,
  timeAgo
};
