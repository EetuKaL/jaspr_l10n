
function getLocale() {
  // 1) html lang="fi" -> "fi"
  const lang = document.documentElement.getAttribute('lang');
  if (lang) return lang.split('-')[0].toLowerCase();

  // 2) fallback: browser language
  const nav = navigator.language || 'en';
  return nav.split('-')[0].toLowerCase();
}

export function hydrateI18n(root = document) {
  const t = createT(getLocale());

  root.querySelectorAll('[data-i18n]').forEach((el) => {
    const key = el.getAttribute('data-i18n');

    let params = {};
    const raw = el.getAttribute('data-i18n-params');
    if (raw) {
      try {
        params = JSON.parse(raw);
      } catch {
        params = {};
      }
    }

    // Fill text safely (no HTML injection)
    el.textContent = t(key, params);
  });
}

// run automatically on load
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => hydrateI18n());
} else {
  hydrateI18n();
}