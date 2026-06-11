/**
 * netbird: native GL.iNet 4.x OUI view (Applications → NetBird).
 *
 * Installed (gzipped) as /www/views/gl-sdk4-ui-netbird.common.js.gz and
 * registered via /usr/share/oui/menu.d/netbird.json — the same mechanism
 * GL.iNet uses for its own panels, so the SPA handles routing, sidebar and
 * topbar natively. Constraints of the OUI view loader:
 *   - CommonJS: module.exports = (function(){ ... })()
 *   - Vue 2 options object with a render(h) function (no templates/SFC)
 *   - RPC via window.$rpcRequest('call', ['sid', 'netbird', method, params])
 *
 * Backend: /usr/lib/oui-httpd/rpc/netbird (shipped in this package).
 * Format reference: bigmalloy/gl-mt3000-starlink-panel (MIT).
 */
module.exports = (function () {
  'use strict';

  var VERSION = '{{VERSION}}';

  // -- RPC: prefer the panel's own helper; fall back to raw /rpc ----------
  function callRpc(method, params) {
    if (typeof window.$rpcRequest === 'function') {
      return window.$rpcRequest('call', ['sid', 'netbird', method, params || {}]);
    }
    var token = (document.cookie.match(/Admin-Token=([^;]+)/) || [])[1] || '';
    return fetch('/rpc', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0', id: Date.now(), method: 'call',
        params: [token, 'netbird', method, params || {}]
      })
    }).then(function (r) { return r.json(); })
      .then(function (d) {
        if (d.error) throw new Error(d.error.message || 'RPC error');
        return d.result || {};
      });
  }

  // -- defensive getters over `netbird status --json` ---------------------
  function g(obj) {
    for (var i = 1; i < arguments.length; i++) {
      if (obj && obj[arguments[i]] !== undefined) return obj[arguments[i]];
    }
    return undefined;
  }

  // -- shared styles -------------------------------------------------------
  var CARD = {
    background: '#fff', borderRadius: '8px', marginBottom: '16px',
    boxShadow: '0 1px 4px rgba(0,0,0,0.08)', overflow: 'hidden'
  };
  var HEAD = {
    display: 'flex', justifyContent: 'space-between', alignItems: 'center',
    padding: '14px 18px', borderBottom: '1px solid #ebebf0',
    fontSize: '15px', fontWeight: '600', color: '#303133'
  };
  var ROW = {
    display: 'flex', justifyContent: 'space-between', alignItems: 'center',
    padding: '12px 18px', borderBottom: '1px solid #f5f5f5',
    minHeight: '46px', fontSize: '13px', color: '#303133'
  };
  var BTN = {
    padding: '5px 16px', borderRadius: '15px', border: '1px solid #5272f7',
    background: '#5272f7', color: '#fff', fontSize: '12px', cursor: 'pointer'
  };
  var BTN_PLAIN = Object.assign({}, BTN, { background: 'transparent', color: '#5272f7' });
  var BTN_DANGER = Object.assign({}, BTN, {
    background: 'transparent', color: '#f56c6c', borderColor: '#f56c6c'
  });
  var INPUT = {
    width: '100%', boxSizing: 'border-box', padding: '8px 12px',
    border: '1px solid #dcdfe6', borderRadius: '6px', fontSize: '13px',
    color: '#303133', background: '#fff', outline: 'none'
  };

  function disabled(style) {
    return Object.assign({}, style, { opacity: '0.45', cursor: 'not-allowed' });
  }

  function dotColor(state) {
    return state === 'ok' ? '#00c8b5' : state === 'warn' ? '#e6a23c' : '#f56c6c';
  }

  return {
    name: 'NetbirdView',

    data: function () {
      return {
        loading: true,
        installed: false,
        enabled: false,
        running: false,
        version: 'unknown',
        status: null,
        upInProgress: false,
        upLog: '',
        setupKey: '',
        mgmtUrl: '',
        busy: false,
        msg: '',
        msgErr: false,
        timer: null,
        logTimer: null
      };
    },

    created: function () {
      this.fetchStatus();
      this.timer = setInterval(this.fetchStatus, 4000);
    },

    beforeDestroy: function () {
      if (this.timer) clearInterval(this.timer);
      if (this.logTimer) clearInterval(this.logTimer);
    },

    computed: {
      mgmtConnected: function () {
        var m = g(this.status || {}, 'management');
        return !!(m && g(m, 'connected'));
      },
      nbIp: function () {
        return g(this.status || {}, 'netbirdIp', 'netbirdIP', 'ip') || '-';
      },
      nbFqdn: function () {
        return g(this.status || {}, 'fqdn', 'domain') || '-';
      },
      peers: function () {
        var p = g(this.status || {}, 'peers') || {};
        return {
          total: g(p, 'total') || 0,
          connected: g(p, 'connected') || 0,
          details: g(p, 'details') || []
        };
      }
    },

    methods: {
      setMsg: function (text, isErr) {
        this.msg = text || '';
        this.msgErr = !!isErr;
      },

      fetchStatus: function () {
        var self = this;
        callRpc('get_status', {}).then(function (res) {
          res = res || {};
          if (res.err_code) return;
          self.installed = !!res.installed;
          self.enabled = !!res.enabled;
          self.running = !!res.running;
          self.version = res.version || 'unknown';
          self.status = res.status || null;
          self.upInProgress = !!res.up_in_progress;
          self.loading = false;
          if (self.upInProgress) self.startLogPolling();
        }).catch(function () { self.loading = false; });
      },

      startLogPolling: function () {
        var self = this;
        if (self.logTimer) return;
        var poll = function () {
          callRpc('get_up_log', {}).then(function (res) {
            res = res || {};
            if (res.log) self.upLog = String(res.log);
            if (!res.in_progress) {
              if (self.logTimer) { clearInterval(self.logTimer); self.logTimer = null; }
              self.setMsg('', false);
              self.fetchStatus();
            }
          }).catch(function () {});
        };
        poll();
        self.logTimer = setInterval(poll, 2000);
      },

      connect: function () {
        var self = this;
        if (self.busy || self.upInProgress) return;
        var key = (self.setupKey || '').trim();
        var url = (self.mgmtUrl || '').trim();
        if (key && !/^[A-Za-z0-9-]+$/.test(key)) {
          self.setMsg('Setup key may only contain letters, digits and dashes.', true);
          return;
        }
        if (url && !/^https?:\/\/[^\s'"`;|&<>\\]+$/.test(url)) {
          self.setMsg('Management URL looks invalid.', true);
          return;
        }
        self.busy = true;
        self.upLog = '';
        self.setMsg('Starting…', false);
        callRpc('up', { setup_key: key, management_url: url }).then(function (res) {
          res = res || {};
          self.busy = false;
          if (res.err_code) { self.setMsg(res.err_msg || 'Failed to start', true); return; }
          self.upInProgress = true;
          self.setMsg('Connecting…', false);
          self.startLogPolling();
        }).catch(function (e) {
          self.busy = false;
          self.setMsg(String(e && e.message ? e.message : e), true);
        });
      },

      disconnect: function () {
        var self = this;
        if (self.busy) return;
        self.busy = true;
        self.setMsg('Disconnecting…', false);
        callRpc('down', {}).then(function (res) {
          res = res || {};
          self.busy = false;
          self.setMsg(res.err_code ? (res.err_msg || 'Failed') : 'Disconnected.', !!res.err_code);
          setTimeout(self.fetchStatus, 1500);
        }).catch(function (e) {
          self.busy = false;
          self.setMsg(String(e && e.message ? e.message : e), true);
        });
      },

      svc: function (action) {
        var self = this;
        if (self.busy) return;
        self.busy = true;
        callRpc('service', { action: action }).then(function (res) {
          res = res || {};
          self.busy = false;
          if (res.err_code) self.setMsg(res.err_msg || 'Action failed', true);
          setTimeout(self.fetchStatus, 800);
        }).catch(function () {
          self.busy = false;
          setTimeout(self.fetchStatus, 800);
        });
      }
    },

    render: function (h) {
      var self = this;

      if (self.loading) {
        return h('div', { style: { padding: '40px', textAlign: 'center', color: '#999' } },
          'Loading NetBird status…');
      }

      function row(label, children) {
        return h('div', { style: ROW }, [
          h('span', { style: { color: '#606266' } }, label),
          h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px' } }, children)
        ]);
      }

      function dot(state, text) {
        return [
          h('span', {
            style: {
              display: 'inline-block', width: '8px', height: '8px',
              borderRadius: '50%', marginRight: '6px', background: dotColor(state)
            }
          }),
          h('span', {}, text)
        ];
      }

      // ---- status card ----
      var daemonBtn = h('button', {
        style: self.busy ? disabled(BTN_PLAIN) : BTN_PLAIN,
        attrs: { disabled: self.busy },
        on: { click: function () { self.svc(self.running ? 'stop' : 'start'); } }
      }, self.running ? 'Stop' : 'Start');

      var toggle = h('div', {
        style: {
          position: 'relative', display: 'inline-block', width: '36px',
          height: '22px', borderRadius: '11px', cursor: self.busy ? 'not-allowed' : 'pointer',
          background: self.enabled ? '#00c8b5' : '#a0a0a3',
          opacity: self.busy ? '0.5' : '1', transition: 'background 0.2s'
        },
        on: { click: function () { if (!self.busy) self.svc(self.enabled ? 'disable' : 'enable'); } }
      }, [
        h('div', {
          style: {
            position: 'absolute', width: '18px', height: '18px', borderRadius: '50%',
            background: '#fff', top: '2px', left: self.enabled ? '16px' : '2px',
            transition: 'left 0.2s'
          }
        })
      ]);

      var mgmtState = self.running && self.mgmtConnected ? dot('ok', 'Connected')
        : self.running ? dot('warn', self.upInProgress ? 'Connecting…' : 'Disconnected')
        : dot('err', 'Daemon stopped');

      var statusCard = h('div', { style: CARD }, [
        h('div', { style: HEAD }, [
          h('span', {}, 'NetBird'),
          h('span', { style: { fontSize: '11px', fontWeight: '400', color: '#a0a0a3' } },
            'netbird ' + self.version + ' · pkg v' + VERSION)
        ]),
        row('Daemon', [].concat(
          dot(self.running ? 'ok' : 'err', self.running ? 'Running' : 'Stopped'),
          [daemonBtn])),
        row('Start on boot', [toggle]),
        row('Management connection', mgmtState),
        row('NetBird IP', [h('span', {}, self.running ? self.nbIp : '-')]),
        row('Hostname (FQDN)', [h('span', {}, self.running ? self.nbFqdn : '-')]),
        row('Peers', [h('span', {},
          self.running ? (self.peers.connected + ' / ' + self.peers.total + ' connected') : '-')])
      ]);

      // ---- connect card ----
      var logChildren = null;
      if (self.upLog) {
        var parts = self.upLog.split(/(https?:\/\/[^\s]+)/g);
        logChildren = parts.map(function (part) {
          if (/^https?:\/\//.test(part)) {
            return h('a', {
              attrs: { href: part, target: '_blank', rel: 'noopener' },
              style: { color: '#7da2ff', wordBreak: 'break-all' }
            }, part);
          }
          return part;
        });
      }

      var connectCard = h('div', { style: CARD }, [
        h('div', { style: HEAD }, [h('span', {}, 'Connection')]),
        h('div', { style: { padding: '10px 18px' } }, [
          h('div', { style: { fontSize: '12px', color: '#606266', marginBottom: '6px' } },
            'Setup key (leave empty for browser SSO login)'),
          h('input', {
            style: INPUT,
            attrs: { type: 'password', placeholder: 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX', autocomplete: 'off' },
            domProps: { value: self.setupKey },
            on: { input: function (e) { self.setupKey = e.target.value; } }
          })
        ]),
        h('div', { style: { padding: '10px 18px' } }, [
          h('div', { style: { fontSize: '12px', color: '#606266', marginBottom: '6px' } },
            'Management URL (leave empty for https://api.netbird.io)'),
          h('input', {
            style: INPUT,
            attrs: { type: 'text', placeholder: 'https://netbird.example.com', autocomplete: 'off' },
            domProps: { value: self.mgmtUrl },
            on: { input: function (e) { self.mgmtUrl = e.target.value; } }
          })
        ]),
        h('div', {
          style: {
            display: 'flex', gap: '10px', padding: '14px 18px',
            alignItems: 'center', flexWrap: 'wrap'
          }
        }, [
          h('button', {
            style: (self.busy || self.upInProgress || !self.installed) ? disabled(BTN) : BTN,
            attrs: { disabled: self.busy || self.upInProgress || !self.installed },
            on: { click: self.connect }
          }, self.upInProgress ? 'Connecting…' : 'Connect'),
          h('button', {
            style: (self.busy || !self.running || !self.mgmtConnected) ? disabled(BTN_DANGER) : BTN_DANGER,
            attrs: { disabled: self.busy || !self.running || !self.mgmtConnected },
            on: { click: self.disconnect }
          }, 'Disconnect'),
          self.msg ? h('span', {
            style: { fontSize: '12px', color: self.msgErr ? '#f56c6c' : '#00c8b5' }
          }, self.msg) : null
        ]),
        h('div', {
          style: { fontSize: '12px', color: '#a0a0a3', padding: '0 18px 12px', lineHeight: '1.5' }
        }, 'With a setup key the router enrolls headlessly. Without one, a login URL appears '
           + 'in the output below — open it in your browser to authorize this router.'),
        logChildren ? h('pre', {
          style: {
            margin: '0 18px 14px', padding: '10px 12px', background: '#1e1e24',
            color: '#c9c9d1', fontFamily: 'monospace', fontSize: '11px',
            lineHeight: '1.5', borderRadius: '6px', maxHeight: '220px',
            overflow: 'auto', whiteSpace: 'pre-wrap', wordBreak: 'break-all'
          }
        }, logChildren) : null
      ]);

      // ---- peers card ----
      var peersCard = null;
      if (self.running && self.peers.details.length > 0) {
        var th = function (t) {
          return h('th', {
            style: {
              textAlign: 'left', padding: '8px 18px', borderBottom: '1px solid #f5f5f5',
              color: '#909399', fontSize: '11px', textTransform: 'uppercase', fontWeight: '400'
            }
          }, t);
        };
        var td = function (children) {
          return h('td', {
            style: {
              textAlign: 'left', padding: '8px 18px', borderBottom: '1px solid #f5f5f5',
              color: '#606266', fontSize: '12px'
            }
          }, children);
        };
        var rows = self.peers.details.map(function (p) {
          var stx = String(g(p, 'status', 'connectionStatus') || '?');
          var ok = stx.toLowerCase() === 'connected';
          return h('tr', {}, [
            td([g(p, 'fqdn', 'hostname') || '?']),
            td([g(p, 'netbirdIp', 'netbirdIP', 'ip') || '?']),
            td(dot(ok ? 'ok' : 'err', stx))
          ]);
        });
        peersCard = h('div', { style: CARD }, [
          h('div', { style: HEAD }, [h('span', {}, 'Peers')]),
          h('table', { style: { width: '100%', borderCollapse: 'collapse' } },
            [h('tr', {}, [th('Peer'), th('NetBird IP'), th('Status')])].concat(rows))
        ]);
      }

      var banner = !self.installed ? h('div', {
        style: {
          marginBottom: '16px', padding: '12px 16px', borderRadius: '8px',
          background: '#fdf3e7', borderLeft: '3px solid #e6a23c',
          color: '#856404', fontSize: '13px', lineHeight: '1.5'
        }
      }, 'The netbird binary was not found at /usr/sbin/netbird. Reinstall the package.') : null;

      return h('div', { style: { padding: '16px', maxWidth: '760px', margin: '0 auto' } }, [
        banner,
        statusCard,
        connectCard,
        peersCard,
        h('div', { style: { textAlign: 'center', fontSize: '11px', color: '#ccc', marginTop: '8px' } },
          'NetBird for GL-X2000 · netbird.io · auto-refreshes every 4s')
      ]);
    }
  };
})()
