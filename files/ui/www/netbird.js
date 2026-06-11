/**
 * netbird: NetBird settings page for the GL.iNet 4.x admin panel.
 *
 * Injected into the GL SPA via nginx body filter. Adds a "NetBird" entry
 * under the Applications menu group and renders a settings page inside the
 * SPA's content area, keeping the sidebar/topbar mounted. The URL hash is
 * deliberately never changed: an unknown route would make the Vue router
 * unmount the whole layout. Talks to /usr/lib/oui-httpd/rpc/netbird via /rpc.
 *
 * Injection pattern based on gl-tailscale-fix (GPL-3.0).
 */
(function() {
'use strict';

var PAGE_ID = 'netbird-page';
var MENU_ID = 'netbird-menu-item';
var VERSION = '{{VERSION}}';
var POLL_MS = 4000;

// ---------------------------------------------------------------- RPC ----

function rpc(method, params) {
  var token = (document.cookie.match(/Admin-Token=([^;]+)/) || [])[1] || '';
  return fetch('/rpc', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({
      jsonrpc: '2.0', id: Date.now(),
      method: 'call',
      params: [token, 'netbird', method, params || {}]
    })
  }).then(function(r) { return r.json(); })
    .then(function(d) {
      if (d.error) throw new Error(d.error.message || 'RPC error');
      return d.result || {};
    });
}

// -------------------------------------------------------------- Styles ----

function injectStyles() {
  if (document.getElementById('nb-styles')) return;
  var style = document.createElement('style');
  style.id = 'nb-styles';
  style.textContent = [
    '#netbird-page { padding: 20px; max-width: 860px; }',
    '.nb-card { background: #fff; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); margin-bottom: 16px; overflow: hidden; }',
    '.nb-card-header { display: flex; justify-content: space-between; align-items: center; padding: 14px 18px; border-bottom: 1px solid #ebebf0; font-size: 15px; font-weight: 600; color: #303133; }',
    '.nb-badge { font-size: 11px; font-weight: 400; color: #a0a0a3; }',
    '.nb-row { display: flex; justify-content: space-between; align-items: center; padding: 13px 18px; border-bottom: 1px solid #ebebf0; min-height: 48px; font-size: 14px; color: #303133; }',
    '.nb-row:last-child { border-bottom: none; }',
    '.nb-label { display: flex; align-items: center; gap: 6px; }',
    '.nb-value { display: flex; align-items: center; gap: 10px; color: #606266; font-size: 13px; }',
    '.nb-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: #a0a0a3; margin-right: 6px; flex-shrink: 0; }',
    '.nb-dot.is-ok { background: #00c8b5; }',
    '.nb-dot.is-warn { background: #e6a23c; }',
    '.nb-dot.is-err { background: #f56c6c; }',
    '.nb-btn { padding: 6px 18px; border-radius: 16px; border: 1px solid #5272f7; background: #5272f7; color: #fff; font-size: 13px; cursor: pointer; transition: opacity 0.15s; }',
    '.nb-btn:hover { opacity: 0.85; }',
    '.nb-btn:disabled { opacity: 0.45; cursor: not-allowed; }',
    '.nb-btn.nb-btn-plain { background: transparent; color: #5272f7; }',
    '.nb-btn.nb-btn-danger { border-color: #f56c6c; background: transparent; color: #f56c6c; }',
    '.nb-btn.nb-btn-danger:hover { background: #f56c6c; color: #fff; opacity: 1; }',
    '.nb-toggle { position: relative; display: inline-block; width: 36px; height: 22px; border-radius: 11px; background: #a0a0a3; cursor: pointer; transition: background 0.2s; flex-shrink: 0; }',
    '.nb-toggle.is-on { background: #00c8b5; }',
    '.nb-toggle.is-disabled { opacity: 0.5; cursor: not-allowed; }',
    '.nb-toggle::after { content: ""; position: absolute; width: 18px; height: 18px; border-radius: 50%; background: #fff; top: 2px; left: 2px; transition: transform 0.2s; }',
    '.nb-toggle.is-on::after { transform: translateX(14px); }',
    '.nb-input { width: 100%; box-sizing: border-box; padding: 8px 12px; border: 1px solid #dcdfe6; border-radius: 6px; font-size: 13px; color: #303133; background: #fff; outline: none; }',
    '.nb-input:focus { border-color: #5272f7; }',
    '.nb-form-row { padding: 10px 18px; }',
    '.nb-form-label { font-size: 13px; color: #606266; margin-bottom: 6px; }',
    '.nb-actions { display: flex; gap: 10px; padding: 14px 18px; align-items: center; flex-wrap: wrap; }',
    '.nb-hint { font-size: 12px; color: #a0a0a3; padding: 0 18px 12px; line-height: 1.5; }',
    '.nb-log { margin: 0 18px 14px; padding: 10px 12px; background: #1e1e24; color: #c9c9d1; font-family: monospace; font-size: 11px; line-height: 1.5; border-radius: 6px; max-height: 220px; overflow: auto; white-space: pre-wrap; word-break: break-all; }',
    '.nb-log a { color: #7da2ff; }',
    '.nb-status-msg { font-size: 12px; margin-left: 4px; }',
    '.nb-status-msg.is-ok { color: #00c8b5; }',
    '.nb-status-msg.is-err { color: #f56c6c; }',
    '.nb-peers-table { width: 100%; border-collapse: collapse; font-size: 12px; }',
    '.nb-peers-table th, .nb-peers-table td { text-align: left; padding: 8px 18px; border-bottom: 1px solid #ebebf0; color: #606266; font-weight: 400; }',
    '.nb-peers-table th { color: #909399; font-size: 11px; text-transform: uppercase; }',
    '.nb-footer { font-size: 11px; color: #a0a0a3; text-align: center; padding: 4px 0 16px; }',
    '.nb-footer a { color: #5272f7; text-decoration: none; }',
    '.nb-banner { margin: 0 0 16px; padding: 12px 16px; border-radius: 8px; background: #fdf3e7; border-left: 3px solid #e6a23c; color: #856404; font-size: 13px; line-height: 1.5; }',
    /* dark mode */
    '.nb-dark .nb-card { background: #26262e; box-shadow: 0 2px 8px rgba(0,0,0,0.3); }',
    '.nb-dark .nb-card-header { color: #b9b9bd; border-bottom-color: rgba(145,149,170,0.15); }',
    '.nb-dark .nb-row { color: #9195aa; border-bottom-color: rgba(145,149,170,0.15); }',
    '.nb-dark .nb-value { color: #9195aa; }',
    '.nb-dark .nb-input { background: #1e1e24; border-color: #44444e; color: #b9b9bd; }',
    '.nb-dark .nb-form-label { color: #9195aa; }',
    '.nb-dark .nb-peers-table th, .nb-dark .nb-peers-table td { border-bottom-color: rgba(145,149,170,0.15); color: #9195aa; }',
    '.nb-dark .nb-banner { background: rgba(230,162,60,0.12); }'
  ].join('\n');
  document.head.appendChild(style);
}

// --------------------------------------------------------------- State ----

var st = {
  installed: false,
  enabled: false,
  running: false,
  version: 'unknown',
  status: null,
  up_in_progress: false
};
var active = false;          // our page currently shown
var prevActiveItem = null;   // SPA menu item that was highlighted before ours
var pollTimer = null;
var logTimer = null;
var hiddenSiblings = [];
var containerObserver = null;
var busy = false;            // a connect/disconnect/service action running

// Defensive getters over `netbird status --json` (field names vary slightly
// across netbird versions).
function g(obj) {
  for (var i = 1; i < arguments.length; i++) {
    if (obj && obj[arguments[i]] !== undefined) return obj[arguments[i]];
  }
  return undefined;
}
function mgmtConnected() {
  var m = g(st.status || {}, 'management');
  return !!(m && g(m, 'connected'));
}
function nbIp() { return g(st.status || {}, 'netbirdIp', 'netbirdIP', 'ip') || '-'; }
function nbFqdn() { return g(st.status || {}, 'fqdn', 'domain') || '-'; }
function peersInfo() {
  var p = g(st.status || {}, 'peers') || {};
  return {
    total: g(p, 'total') || 0,
    connected: g(p, 'connected') || 0,
    details: g(p, 'details') || []
  };
}

// ------------------------------------------------------------ Build UI ----

function el(tag, cls, text) {
  var e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function statusRow(label, valueId) {
  var row = el('div', 'nb-row');
  row.appendChild(el('div', 'nb-label', label));
  var v = el('div', 'nb-value');
  v.id = valueId;
  v.textContent = '-';
  row.appendChild(v);
  return row;
}

function buildPage() {
  var page = el('div');
  page.id = PAGE_ID;
  if (localStorage.getItem('theme') === 'dark') page.classList.add('nb-dark');

  // Not-installed banner placeholder
  var banner = el('div', 'nb-banner');
  banner.id = 'nb-banner';
  banner.style.display = 'none';
  page.appendChild(banner);

  // ---- Status card ----
  var card = el('div', 'nb-card');
  var head = el('div', 'nb-card-header');
  head.appendChild(el('span', null, 'NetBird'));
  var badge = el('span', 'nb-badge');
  badge.id = 'nb-version-badge';
  badge.textContent = 'netbird-glx2000 v' + VERSION;
  head.appendChild(badge);
  card.appendChild(head);

  // Daemon row with start/stop button
  var drow = el('div', 'nb-row');
  drow.appendChild(el('div', 'nb-label', 'Daemon'));
  var dval = el('div', 'nb-value');
  dval.id = 'nb-daemon-value';
  drow.appendChild(dval);
  card.appendChild(drow);

  // Autostart toggle
  var arow = el('div', 'nb-row');
  arow.appendChild(el('div', 'nb-label', 'Start on boot'));
  var toggle = el('div', 'nb-toggle');
  toggle.id = 'nb-autostart-toggle';
  toggle.setAttribute('role', 'switch');
  toggle.addEventListener('click', onToggleAutostart);
  arow.appendChild(toggle);
  card.appendChild(arow);

  card.appendChild(statusRow('Management connection', 'nb-mgmt-value'));
  card.appendChild(statusRow('NetBird IP', 'nb-ip-value'));
  card.appendChild(statusRow('Hostname (FQDN)', 'nb-fqdn-value'));
  card.appendChild(statusRow('Peers', 'nb-peers-value'));
  card.appendChild(statusRow('Client version', 'nb-clientver-value'));
  page.appendChild(card);

  // ---- Connect card ----
  var ccard = el('div', 'nb-card');
  var chead = el('div', 'nb-card-header');
  chead.appendChild(el('span', null, 'Connection'));
  ccard.appendChild(chead);

  var f1 = el('div', 'nb-form-row');
  f1.appendChild(el('div', 'nb-form-label', 'Setup key (leave empty for browser SSO login)'));
  var keyInput = el('input', 'nb-input');
  keyInput.id = 'nb-setup-key';
  keyInput.type = 'password';
  keyInput.placeholder = 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX';
  keyInput.autocomplete = 'off';
  f1.appendChild(keyInput);
  ccard.appendChild(f1);

  var f2 = el('div', 'nb-form-row');
  f2.appendChild(el('div', 'nb-form-label', 'Management URL (leave empty for https://api.netbird.io)'));
  var urlInput = el('input', 'nb-input');
  urlInput.id = 'nb-mgmt-url';
  urlInput.type = 'text';
  urlInput.placeholder = 'https://netbird.example.com';
  urlInput.autocomplete = 'off';
  f2.appendChild(urlInput);
  ccard.appendChild(f2);

  var actions = el('div', 'nb-actions');
  var connectBtn = el('button', 'nb-btn', 'Connect');
  connectBtn.id = 'nb-connect-btn';
  connectBtn.addEventListener('click', onConnect);
  actions.appendChild(connectBtn);
  var disconnectBtn = el('button', 'nb-btn nb-btn-danger', 'Disconnect');
  disconnectBtn.id = 'nb-disconnect-btn';
  disconnectBtn.addEventListener('click', onDisconnect);
  actions.appendChild(disconnectBtn);
  var msg = el('span', 'nb-status-msg');
  msg.id = 'nb-action-msg';
  actions.appendChild(msg);
  ccard.appendChild(actions);

  ccard.appendChild(el('div', 'nb-hint',
    'With a setup key the router enrolls headlessly. Without one, a login URL ' +
    'appears in the output below — open it in your browser to authorize this router.'));

  var log = el('pre', 'nb-log');
  log.id = 'nb-up-log';
  log.style.display = 'none';
  ccard.appendChild(log);
  page.appendChild(ccard);

  // ---- Peers card ----
  var pcard = el('div', 'nb-card');
  pcard.id = 'nb-peers-card';
  pcard.style.display = 'none';
  var phead = el('div', 'nb-card-header');
  phead.appendChild(el('span', null, 'Peers'));
  pcard.appendChild(phead);
  var tbl = el('table', 'nb-peers-table');
  tbl.id = 'nb-peers-table';
  pcard.appendChild(tbl);
  page.appendChild(pcard);

  // Footer
  var footer = el('div', 'nb-footer');
  footer.innerHTML = 'NetBird for GL-X2000 — maintained at ' +
    '<a href="https://github.com/AndreaF17/netbird-glinet-integration" target="_blank" rel="noopener">AndreaF17/netbird-glinet-integration</a>' +
    ' · <a href="https://github.com/AndreaF17/netbird-glinet-integration/issues" target="_blank" rel="noopener">report an issue</a>' +
    ' · <a href="https://netbird.io" target="_blank" rel="noopener">netbird.io</a>';
  page.appendChild(footer);

  return page;
}

// ----------------------------------------------------------- Rendering ----

function setDot(elId, state, text) {
  var v = document.getElementById(elId);
  if (!v) return;
  v.innerHTML = '';
  var dot = el('span', 'nb-dot' + (state ? ' ' + state : ''));
  v.appendChild(dot);
  v.appendChild(document.createTextNode(text));
}

function refreshUI() {
  var page = document.getElementById(PAGE_ID);
  if (!page) return;

  // banner
  var banner = document.getElementById('nb-banner');
  if (banner) {
    if (!st.installed) {
      banner.textContent = 'The netbird binary was not found at /usr/sbin/netbird. Reinstall the package.';
      banner.style.display = '';
    } else {
      banner.style.display = 'none';
    }
  }

  // daemon row
  var dval = document.getElementById('nb-daemon-value');
  if (dval) {
    dval.innerHTML = '';
    var dot = el('span', 'nb-dot' + (st.running ? ' is-ok' : ' is-err'));
    dval.appendChild(dot);
    dval.appendChild(document.createTextNode(st.running ? 'Running' : 'Stopped'));
    var btn = el('button', 'nb-btn nb-btn-plain', st.running ? 'Stop' : 'Start');
    btn.disabled = busy;
    btn.addEventListener('click', function() {
      doService(st.running ? 'stop' : 'start');
    });
    dval.appendChild(btn);
  }

  // autostart
  var toggle = document.getElementById('nb-autostart-toggle');
  if (toggle) {
    toggle.classList.toggle('is-on', st.enabled);
    toggle.classList.toggle('is-disabled', busy);
    toggle.setAttribute('aria-checked', st.enabled ? 'true' : 'false');
  }

  // status rows
  if (st.running && mgmtConnected()) {
    setDot('nb-mgmt-value', 'is-ok', 'Connected');
  } else if (st.running) {
    setDot('nb-mgmt-value', 'is-warn', st.up_in_progress ? 'Connecting…' : 'Disconnected');
  } else {
    setDot('nb-mgmt-value', 'is-err', 'Daemon stopped');
  }

  var ipv = document.getElementById('nb-ip-value');
  if (ipv) ipv.textContent = st.running ? nbIp() : '-';
  var fqv = document.getElementById('nb-fqdn-value');
  if (fqv) fqv.textContent = st.running ? nbFqdn() : '-';

  var p = peersInfo();
  var pv = document.getElementById('nb-peers-value');
  if (pv) pv.textContent = st.running ? (p.connected + ' / ' + p.total + ' connected') : '-';

  var cv = document.getElementById('nb-clientver-value');
  if (cv) cv.textContent = st.version || 'unknown';

  // buttons
  var connectBtn = document.getElementById('nb-connect-btn');
  if (connectBtn) {
    connectBtn.disabled = busy || st.up_in_progress || !st.installed;
    connectBtn.textContent = st.up_in_progress ? 'Connecting…' : 'Connect';
  }
  var disconnectBtn = document.getElementById('nb-disconnect-btn');
  if (disconnectBtn) disconnectBtn.disabled = busy || !st.running || !mgmtConnected();

  // peers table
  var pcard = document.getElementById('nb-peers-card');
  var tbl = document.getElementById('nb-peers-table');
  if (pcard && tbl) {
    if (st.running && p.details.length > 0) {
      pcard.style.display = '';
      tbl.innerHTML = '';
      var thead = el('tr');
      ['Peer', 'NetBird IP', 'Status'].forEach(function(h) {
        thead.appendChild(el('th', null, h));
      });
      tbl.appendChild(thead);
      p.details.forEach(function(peer) {
        var tr = el('tr');
        tr.appendChild(el('td', null, g(peer, 'fqdn', 'hostname') || '?'));
        tr.appendChild(el('td', null, g(peer, 'netbirdIp', 'netbirdIP', 'ip') || '?'));
        var stx = g(peer, 'status', 'connectionStatus') || '?';
        var td = el('td');
        var ok = String(stx).toLowerCase() === 'connected';
        td.appendChild(el('span', 'nb-dot' + (ok ? ' is-ok' : '')));
        td.appendChild(document.createTextNode(stx));
        tr.appendChild(td);
        tbl.appendChild(tr);
      });
    } else {
      pcard.style.display = 'none';
    }
  }

  // dark mode sync
  var isDark = localStorage.getItem('theme') === 'dark';
  page.classList.toggle('nb-dark', isDark);
}

// -------------------------------------------------------------- Data ----

function fetchStatus() {
  rpc('get_status', {}).then(function(res) {
    if (res.err_code) return;
    st.installed = !!res.installed;
    st.enabled = !!res.enabled;
    st.running = !!res.running;
    st.version = res.version || 'unknown';
    st.status = res.status || null;
    st.up_in_progress = !!res.up_in_progress;
    refreshUI();
    if (st.up_in_progress) startLogPolling();
  }).catch(function() {});
}

function startPolling() {
  if (pollTimer) return;
  fetchStatus();
  pollTimer = setInterval(function() {
    if (active) fetchStatus();
  }, POLL_MS);
}

function stopPolling() {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  stopLogPolling();
}

function startLogPolling() {
  if (logTimer) return;
  var poll = function() {
    rpc('get_up_log', {}).then(function(res) {
      var log = document.getElementById('nb-up-log');
      if (log && res.log) {
        log.style.display = '';
        // linkify URLs (SSO login flow prints one)
        log.innerHTML = '';
        var parts = String(res.log).split(/(https?:\/\/[^\s]+)/g);
        parts.forEach(function(part) {
          if (/^https?:\/\//.test(part)) {
            var a = document.createElement('a');
            a.href = part;
            a.target = '_blank';
            a.rel = 'noopener';
            a.textContent = part;
            log.appendChild(a);
          } else {
            log.appendChild(document.createTextNode(part));
          }
        });
        log.scrollTop = log.scrollHeight;
      }
      if (!res.in_progress) {
        stopLogPolling();
        setMsg('', '');
        fetchStatus();
      }
    }).catch(function() {});
  };
  poll();
  logTimer = setInterval(poll, 2000);
}

function stopLogPolling() {
  if (logTimer) { clearInterval(logTimer); logTimer = null; }
}

// ------------------------------------------------------------- Actions ----

function setMsg(text, cls) {
  var m = document.getElementById('nb-action-msg');
  if (!m) return;
  m.textContent = text;
  m.className = 'nb-status-msg' + (cls ? ' ' + cls : '');
}

function onConnect() {
  if (busy || st.up_in_progress) return;
  var key = (document.getElementById('nb-setup-key') || {}).value || '';
  var url = (document.getElementById('nb-mgmt-url') || {}).value || '';
  key = key.trim();
  url = url.trim();
  if (key && !/^[A-Za-z0-9-]+$/.test(key)) {
    setMsg('Setup key may only contain letters, digits and dashes.', 'is-err');
    return;
  }
  if (url && !/^https?:\/\/[^\s'"`;|&<>\\]+$/.test(url)) {
    setMsg('Management URL looks invalid.', 'is-err');
    return;
  }
  busy = true;
  setMsg('Starting…', '');
  refreshUI();
  rpc('up', {setup_key: key, management_url: url}).then(function(res) {
    busy = false;
    if (res.err_code) {
      setMsg(res.err_msg || 'Failed to start', 'is-err');
      refreshUI();
      return;
    }
    st.up_in_progress = true;
    setMsg('Connecting…', '');
    refreshUI();
    startLogPolling();
  }).catch(function(e) {
    busy = false;
    setMsg(e.message || 'RPC failed', 'is-err');
    refreshUI();
  });
}

function onDisconnect() {
  if (busy) return;
  busy = true;
  setMsg('Disconnecting…', '');
  refreshUI();
  rpc('down', {}).then(function(res) {
    busy = false;
    if (res.err_code) {
      setMsg(res.err_msg || 'Failed', 'is-err');
    } else {
      setMsg('Disconnected.', 'is-ok');
    }
    setTimeout(fetchStatus, 1500);
  }).catch(function(e) {
    busy = false;
    setMsg(e.message || 'RPC failed', 'is-err');
    refreshUI();
  });
}

function onToggleAutostart() {
  if (busy) return;
  doService(st.enabled ? 'disable' : 'enable');
}

function doService(action) {
  busy = true;
  refreshUI();
  rpc('service', {action: action}).then(function(res) {
    busy = false;
    if (res.err_code) setMsg(res.err_msg || 'Action failed', 'is-err');
    setTimeout(fetchStatus, 800);
  }).catch(function() {
    busy = false;
    setTimeout(fetchStatus, 800);
  });
}

// ------------------------------------------------- Page mount/unmount ----

function findContentContainer() {
  var c = document.querySelector('.el-main')
    || document.querySelector('main')
    || document.querySelector('#app .app-main')
    || document.querySelector('#app .main-content');
  if (c) return c;
  // Fallback: the content area is the widest sibling of the sidebar column.
  // Never fall back to #app itself — hiding its children would remove the
  // sidebar/topbar (the SPA chrome must stay).
  var aside = document.querySelector('.el-aside, aside, .sidebar, .nav-side');
  if (aside && aside.parentNode) {
    var sibs = aside.parentNode.children;
    for (var i = 0; i < sibs.length; i++) {
      if (sibs[i] !== aside && sibs[i].offsetWidth > aside.offsetWidth) {
        return sibs[i];
      }
    }
  }
  return null;
}

function mountPage() {
  if (document.getElementById(PAGE_ID)) return;
  var container = findContentContainer();
  if (!container) return;

  injectStyles();

  // Hide whatever the SPA currently renders in the content area
  hiddenSiblings = [];
  Array.prototype.forEach.call(container.children, function(child) {
    if (child.id === PAGE_ID) return;
    if (child.style.display !== 'none') {
      hiddenSiblings.push(child);
      child.style.display = 'none';
    }
  });

  container.appendChild(buildPage());

  // Vue may re-render the content area while we're active (e.g. the router
  // reacting to the unknown route) — keep hiding anything that appears.
  if (!containerObserver) {
    containerObserver = new MutationObserver(function() {
      if (!active) return;
      var c = findContentContainer();
      if (!c) return;
      Array.prototype.forEach.call(c.children, function(child) {
        if (child.id !== PAGE_ID && child.style.display !== 'none') {
          hiddenSiblings.push(child);
          child.style.display = 'none';
        }
      });
      if (!document.getElementById(PAGE_ID)) {
        c.appendChild(buildPage());
        refreshUI();
      }
    });
    containerObserver.observe(container, {childList: true});
  }

  startPolling();
  refreshUI();
}

function unmountPage() {
  var page = document.getElementById(PAGE_ID);
  if (page && page.parentNode) page.parentNode.removeChild(page);
  hiddenSiblings.forEach(function(elm) {
    try { elm.style.display = ''; } catch (e) {}
  });
  hiddenSiblings = [];
  if (containerObserver) { containerObserver.disconnect(); containerObserver = null; }
  stopPolling();
}

// --------------------------------------------------- Menu integration ----

// Known Applications-group entries (English UI) used to locate the submenu.
// Deliberately excludes Cloud Services entries (goodcloud, astrowarp): the
// Cloud Services <ul> precedes Applications in the DOM and would match first.
var APP_ITEM_NAMES = ['tailscale', 'zerotier', 'dynamic dns', 'ddns',
                      'plug-ins', 'plugins', 'network storage',
                      'adguard home', 'tor'];

function findAppsSubmenuList() {
  // Strategy 1: a submenu <ul> containing a known Applications item
  var uls = document.querySelectorAll('ul');
  for (var i = 0; i < uls.length; i++) {
    var lis = uls[i].querySelectorAll(':scope > li');
    for (var j = 0; j < lis.length; j++) {
      var txt = (lis[j].textContent || '').trim().toLowerCase();
      for (var k = 0; k < APP_ITEM_NAMES.length; k++) {
        if (txt === APP_ITEM_NAMES[k]) return uls[i];
      }
    }
  }
  // Strategy 2: an Element UI submenu whose title says Applications
  var subs = document.querySelectorAll('.el-submenu, .el-sub-menu');
  for (var s = 0; s < subs.length; s++) {
    var title = subs[s].querySelector('.el-submenu__title, .el-sub-menu__title');
    if (title && /application/i.test(title.textContent || '')) {
      var ul = subs[s].querySelector('ul');
      if (ul) return ul;
    }
  }
  return null;
}

function setMenuActive(on) {
  var item = document.getElementById(MENU_ID);
  if (!item) return;
  item.classList.toggle('is-active', on);
  if (on) {
    // Move the highlight from the SPA's current item to ours; remember it
    // so it can be restored when our page closes without navigation.
    var cur = document.querySelector('li.el-menu-item.is-active, li.is-active');
    if (cur && cur.id !== MENU_ID) {
      prevActiveItem = cur;
      cur.classList.remove('is-active');
    }
  } else if (prevActiveItem) {
    if (prevActiveItem.isConnected) prevActiveItem.classList.add('is-active');
    prevActiveItem = null;
  }
}

function injectMenuItem() {
  if (document.getElementById(MENU_ID)) return;
  var ul = findAppsSubmenuList();
  if (!ul) return;
  var template = ul.querySelector(':scope > li');
  if (!template) return;

  var item = template.cloneNode(true);
  item.id = MENU_ID;
  item.classList.remove('is-active');
  // Replace the deepest text with "NetBird", keep structure/icons
  var target = item;
  while (target.children.length > 0) {
    // descend into the child that carries the label text
    var next = null;
    for (var i = 0; i < target.children.length; i++) {
      if ((target.children[i].textContent || '').trim()) { next = target.children[i]; break; }
    }
    if (!next) break;
    target = next;
  }
  target.textContent = 'NetBird';

  // Cloned nodes carry no Vue listeners — attach ours. Capture phase +
  // stopPropagation keeps Element UI's menu handler from seeing the click.
  item.addEventListener('click', function(e) {
    e.preventDefault();
    e.stopPropagation();
    activate();
  }, true);

  ul.appendChild(item);
}

// ------------------------------------------------------------ Routing ----

function activate() {
  if (active) return;
  active = true;
  setMenuActive(true);
  mountPage();
  setTimeout(mountPage, 250); // retry once in case the SPA was mid-render
}

function deactivate() {
  if (!active) return;
  active = false;
  setMenuActive(false);
  unmountPage();
}

function onHashChange() {
  // Any SPA navigation while our page is shown ends our session; the Vue
  // router re-renders the content area and we get out of its way.
  deactivate();
}

// A click on any other (leaf) menu item ends our session cleanly — needed
// for the case where the user clicks the item of the page that is hidden
// underneath ours: same route, so no hashchange fires.
document.addEventListener('click', function(e) {
  if (!active) return;
  var li = e.target.closest ? e.target.closest('li') : null;
  if (!li || li.id === MENU_ID) return;
  if (li.querySelector('ul')) return; // group header: expands/collapses only
  if (li.closest('.el-aside, aside, .el-menu, nav, .sidebar')) deactivate();
}, true);

// ---------------------------------------------------------------- Init ----

var menuObserver = new MutationObserver(function() {
  injectMenuItem();
});

function init() {
  injectMenuItem();
  menuObserver.observe(document.getElementById('app') || document.body,
                       {childList: true, subtree: true});
  window.addEventListener('hashchange', onHashChange);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}

})();
