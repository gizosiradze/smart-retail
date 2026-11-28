/* Smart Retail · reports browser errors to our own database (public.sr_report_error)
 * Nothing leaves our Supabase project. No personal data: message, first stack lines, page path (no query), browser.
 * Never throws and never blocks the page: a failed report is dropped. Same error is reported once per page load. */
(function () {
  var CFG = window.SR_CONFIG || {};
  if (!CFG.url || !CFG.anonKey || window.EMB) return;
  var p = location.pathname, SRC = p.indexOf('/superadmin') === 0 ? 'superadmin' : p.indexOf('/app') === 0 ? 'app' : 'home';
  var seen = {}, sent = 0, MAX = 10;
  function report(msg, stack) {
    try {
      msg = String(msg || '').slice(0, 500);
      if (!msg || sent >= MAX) return;
      if (/^Script error\.?$|ResizeObserver loop|Load failed$|Failed to fetch$|NetworkError|AbortError/i.test(msg)) return; // offline / noise
      var k = msg + '|' + String(stack || '').split('\n')[1];
      if (seen[k]) return;
      seen[k] = 1; sent++;
      fetch(CFG.url + '/rest/v1/rpc/sr_report_error', {
        method: 'POST', keepalive: true,
        headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + CFG.anonKey, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p: { source: SRC, message: msg, stack: String(stack || '').slice(0, 1500), path: p, ua: navigator.userAgent } })
      }).catch(function () {});
    } catch (_) {}
  }
  addEventListener('error', function (e) {
    if (e.target && e.target !== window) return;           // broken <img>/<script> tags are not code errors
    report(e.message, e.error && e.error.stack);
  });
  addEventListener('unhandledrejection', function (e) {
    var r = e.reason; report('Unhandled promise: ' + (r && r.message || r), r && r.stack);
  });
  window.srReportError = report;                           // for try/catch places that want to report on purpose
})();
