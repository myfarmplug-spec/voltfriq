/* ─── VOLTFRIQ OCEAN — SCREEN NAVIGATION ──────────────────────────── */

let currentScreen = null;
const screenHistory = [];

function getScreenKey(element) {
  if (!element || !element.id) return null;
  return element.id.replace(/^screen-/, '');
}

function goTo(id) {
  const next = document.getElementById(`screen-${id}`);
  if (!next) return;

  const fallbackPrev = document.querySelector('.screen.active');
  const prevId = currentScreen || getScreenKey(fallbackPrev);
  const prev = prevId ? document.getElementById(`screen-${prevId}`) : null;

  document.querySelectorAll('.screen.active').forEach((screen) => {
    if (screen === next) return;
    screen.classList.add('prev');
    screen.classList.remove('active');
    setTimeout(() => screen.classList.remove('prev'), 400);
  });

  next.classList.add('active');
  next.scrollTop = 0;

  if (prev && prev !== next && prevId && prevId !== id) {
    screenHistory.push(prevId);
  }
  currentScreen = id;
}

function goBack() {
  if (screenHistory.length > 0) {
    const prevId = screenHistory.pop();
    const curr = document.getElementById(`screen-${currentScreen}`);
    const prev = document.getElementById(`screen-${prevId}`);
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
