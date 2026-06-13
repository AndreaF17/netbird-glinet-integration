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
  var INPUT_DISABLED = Object.assign({}, INPUT, {
    background: '#f5f6fa', color: '#a0a0a3', cursor: 'not-allowed'
  });

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
        sshEnabled: false,
        upLog: '',
        setupKey: '',
        mgmtUrl: '',
        busy: false,
        msg: '',
        msgErr: false,
        timer: null,
        logTimer: null,
        // collapsible sections; null = auto (Connection opens while
        // disconnected, collapses once connected) until the user clicks.
        connOpenUser: null,
        peersOpen: false,
        // -- self-update (Software update card) --
        updChecking: false,   // a check_update RPC is in flight
        updChecked: false,    // at least one check has returned
        updOk: false,         // last check reached GitHub
        updAvailable: false,  // a newer package exists
        updCurrent: '',       // installed package version (e.g. 0.72.3-1)
        updLatest: '',        // latest published package version
        updHtmlUrl: '',       // release page link
        updating: false,      // an install is running
        updLog: '',
        updLogTimer: null
      };
    },

    created: function () {
      this.fetchStatus();
      this.timer = setInterval(this.fetchStatus, 4000);
      this.checkUpdate();   // auto-check once on load; install stays manual
    },

    beforeDestroy: function () {
      if (this.timer) clearInterval(this.timer);
      if (this.logTimer) clearInterval(this.logTimer);
      if (this.updLogTimer) clearInterval(this.updLogTimer);
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
      },
      // Connect form is locked while connected (or while anything runs).
      formLocked: function () {
        return this.mgmtConnected || this.busy || this.upInProgress || !this.installed;
      },
      connOpen: function () {
        if (this.connOpenUser !== null) return this.connOpenUser;
        return !this.mgmtConnected;
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
          self.sshEnabled = !!res.ssh_enabled;
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
        if (self.formLocked) return;
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

      toggleSsh: function () {
        var self = this;
        if (self.busy || self.upInProgress || !self.running || !self.mgmtConnected) return;
        var target = !self.sshEnabled;
        self.busy = true;
        self.upLog = '';
        self.setMsg((target ? 'Enabling' : 'Disabling') + ' SSH…', false);
        callRpc('set_ssh', { enabled: target }).then(function (res) {
          res = res || {};
          self.busy = false;
          if (res.err_code) { self.setMsg(res.err_msg || 'SSH change failed', true); return; }
          self.upInProgress = true;
          self.startLogPolling();
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
      },

      // -- self-update --------------------------------------------------------
      checkUpdate: function () {
        var self = this;
        if (self.updChecking || self.updating) return;
        self.updChecking = true;
        callRpc('check_update', {}).then(function (res) {
          res = res || {};
          self.updChecking = false;
          self.updChecked = true;
          self.updOk = !!res.ok;
          if (res.ok) {
            self.updAvailable = !!res.update_available;
            self.updCurrent = res.current || '';
            self.updLatest = res.latest || '';
            self.updHtmlUrl = res.html_url || '';
          }
        }).catch(function () {
          self.updChecking = false;
          self.updChecked = true;
          self.updOk = false;
        });
      },

      startUpdate: function () {
        var self = this;
        if (self.updating || !self.updAvailable) return;
        self.updating = true;
        self.updLog = '';
        callRpc('do_update', {}).then(function (res) {
          res = res || {};
          if (res.err_code) {
            self.updating = false;
            self.setMsg(res.err_msg || 'Could not start update', true);
            return;
          }
          self.startUpdateLogPolling();
        }).catch(function (e) {
          self.updating = false;
          self.setMsg(String(e && e.message ? e.message : e), true);
        });
      },

      startUpdateLogPolling: function () {
        var self = this;
        if (self.updLogTimer) return;
        var poll = function () {
          callRpc('get_update_log', {}).then(function (res) {
            res = res || {};
            if (res.log) self.updLog = String(res.log);
            if (!res.in_progress) {
              if (self.updLogTimer) { clearInterval(self.updLogTimer); self.updLogTimer = null; }
              self.updating = false;
              // Re-read installed version + re-check (the panel may reload as
              // nginx restarts; this refreshes whatever survives).
              self.fetchStatus();
              self.checkUpdate();
            }
          }).catch(function () {
            // nginx is briefly down during opkg install/postinst — keep polling.
          });
        };
        poll();
        self.updLogTimer = setInterval(poll, 2500);
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

      function makeToggle(on, isDisabled, onClick) {
        return h('div', {
          style: {
            position: 'relative', display: 'inline-block', width: '36px',
            height: '22px', borderRadius: '11px',
            cursor: isDisabled ? 'not-allowed' : 'pointer',
            background: on ? '#00c8b5' : '#a0a0a3',
            opacity: isDisabled ? '0.5' : '1', transition: 'background 0.2s'
          },
          on: { click: function () { if (!isDisabled) onClick(); } }
        }, [
          h('div', {
            style: {
              position: 'absolute', width: '18px', height: '18px', borderRadius: '50%',
              background: '#fff', top: '2px', left: on ? '16px' : '2px',
              transition: 'left 0.2s'
            }
          })
        ]);
      }

      // Collapsible card header: title + caret, click toggles.
      function collapsibleHead(title, extra, open, onToggle) {
        return h('div', {
          style: Object.assign({}, HEAD, { cursor: 'pointer', userSelect: 'none' }),
          on: { click: onToggle }
        }, [
          h('span', {}, title + (extra ? ' ' : '')),
          h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px' } }, [
            extra ? h('span', { style: { fontSize: '12px', fontWeight: '400', color: '#a0a0a3' } }, extra) : null,
            h('span', {
              style: {
                display: 'inline-block', fontSize: '12px', color: '#a0a0a3',
                transition: 'transform 0.15s',
                transform: open ? 'rotate(90deg)' : 'rotate(0deg)'
              }
            }, '▸')
          ])
        ]);
      }

      // ---- status card ----
      var daemonBtn = h('button', {
        style: self.busy ? disabled(BTN_PLAIN) : BTN_PLAIN,
        attrs: { disabled: self.busy },
        on: { click: function () { self.svc(self.running ? 'stop' : 'start'); } }
      }, self.running ? 'Stop' : 'Start');

      var bootToggle = makeToggle(self.enabled, self.busy, function () {
        self.svc(self.enabled ? 'disable' : 'enable');
      });

      // SSH toggle: only meaningful while connected (the change is applied
      // through `netbird up`, which needs a working management session).
      var sshDisabled = self.busy || self.upInProgress || !self.running || !self.mgmtConnected;
      var sshToggle = makeToggle(self.sshEnabled, sshDisabled, self.toggleSsh);

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
        row('Start on boot', [bootToggle]),
        row('Management connection', mgmtState),
        row('Allow NetBird SSH access', [sshToggle]),
        row('NetBird IP', [h('span', {}, self.running ? self.nbIp : '-')]),
        row('Hostname (FQDN)', [h('span', {}, self.running ? self.nbFqdn : '-')])
      ]);

      // ---- software update card ----
      // Only meaningful once the package is installed. Auto-checks on load;
      // the install itself is always an explicit click.
      var updateCard = null;
      if (self.installed) {
        var updRight;
        if (self.updating) {
          updRight = h('span', { style: { fontSize: '12px', color: '#5272f7' } }, 'Updating…');
        } else if (!self.updChecked || self.updChecking) {
          updRight = h('span', { style: { fontSize: '12px', color: '#a0a0a3' } }, 'Checking…');
        } else if (!self.updOk) {
          updRight = h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px' } }, [
            h('span', { style: { fontSize: '12px', color: '#a0a0a3' } }, 'Check unavailable'),
            h('button', { style: BTN_PLAIN, on: { click: self.checkUpdate } }, 'Retry')
          ]);
        } else if (self.updAvailable) {
          updRight = h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px', flexWrap: 'wrap' } }, [
            h('span', {
              style: {
                fontSize: '12px', fontWeight: '600', color: '#fff', background: '#00c8b5',
                borderRadius: '10px', padding: '2px 10px'
              }
            }, 'v' + self.updLatest + ' available'),
            self.updHtmlUrl ? h('a', {
              attrs: { href: self.updHtmlUrl, target: '_blank', rel: 'noopener' },
              style: { fontSize: '12px', color: '#5272f7' }
            }, 'release notes') : null,
            h('button', { style: BTN, on: { click: self.startUpdate } }, 'Update now')
          ]);
        } else {
          updRight = h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px' } }, [
            dot('ok', 'Up to date'),
            h('button', { style: BTN_PLAIN, on: { click: self.checkUpdate } }, 'Check again')
          ].reduce(function (a, b) { return a.concat(b); }, []));
        }

        var updChildren = [
          h('div', { style: HEAD }, [
            h('span', {}, 'Software update'),
            updRight
          ])
        ];
        // Current version line + live install log.
        updChildren.push(row('Installed version',
          [h('span', {}, self.updCurrent ? ('v' + self.updCurrent) : ('pkg v' + VERSION))]));
        if (self.updating || self.updLog) {
          updChildren.push(h('pre', {
            style: {
              margin: '0 18px 14px', padding: '10px 12px', background: '#1e1e24',
              color: '#c9c9d1', fontFamily: 'monospace', fontSize: '11px',
              lineHeight: '1.5', borderRadius: '6px', maxHeight: '220px',
              overflow: 'auto', whiteSpace: 'pre-wrap', wordBreak: 'break-all'
            }
          }, self.updLog || 'Starting…'));
        }
        if (self.updating) {
          updChildren.push(h('div', {
            style: { fontSize: '12px', color: '#a0a0a3', padding: '0 18px 14px', lineHeight: '1.5' }
          }, 'Installing in the background. The admin panel may briefly reload while the web server '
             + 'restarts — your NetBird enrollment is preserved.'));
        }
        updateCard = h('div', { style: CARD }, updChildren);
      }

      // ---- connection card (collapsible) ----
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

      var connBody = !self.connOpen ? [] : [
        h('div', { style: { padding: '10px 18px' } }, [
          h('div', { style: { fontSize: '12px', color: '#606266', marginBottom: '6px' } },
            'Setup key (leave empty for browser SSO login)'),
          h('input', {
            style: self.formLocked ? INPUT_DISABLED : INPUT,
            attrs: {
              type: 'password',
              placeholder: 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX',
              autocomplete: 'off',
              disabled: self.formLocked
            },
            domProps: { value: self.setupKey },
            on: { input: function (e) { self.setupKey = e.target.value; } }
          })
        ]),
        h('div', { style: { padding: '10px 18px' } }, [
          h('div', { style: { fontSize: '12px', color: '#606266', marginBottom: '6px' } },
            'Management URL (leave empty for https://api.netbird.io)'),
          h('input', {
            style: self.formLocked ? INPUT_DISABLED : INPUT,
            attrs: {
              type: 'text',
              placeholder: 'https://netbird.example.com',
              autocomplete: 'off',
              disabled: self.formLocked
            },
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
            style: self.formLocked ? disabled(BTN) : BTN,
            attrs: { disabled: self.formLocked },
            on: { click: self.connect }
          }, self.upInProgress ? 'Working…' : 'Connect'),
          h('button', {
            style: (self.busy || !self.running || !self.mgmtConnected) ? disabled(BTN_DANGER) : BTN_DANGER,
            attrs: { disabled: self.busy || !self.running || !self.mgmtConnected },
            on: { click: self.disconnect }
          }, 'Disconnect'),
          self.msg ? h('span', {
            style: { fontSize: '12px', color: self.msgErr ? '#f56c6c' : '#00c8b5' }
          }, self.msg) : null
        ]),
        self.mgmtConnected ? h('div', {
          style: { fontSize: '12px', color: '#a0a0a3', padding: '0 18px 12px', lineHeight: '1.5' }
        }, 'Connected — disconnect first to enroll with a different setup key or management server.')
        : h('div', {
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
      ];

      var connectCard = h('div', { style: CARD }, [
        collapsibleHead('Connection',
          self.mgmtConnected ? 'connected' : null,
          self.connOpen,
          function () { self.connOpenUser = !self.connOpen; })
      ].concat(connBody));

      // ---- peers card (collapsible) ----
      var peersCard = null;
      if (self.running) {
        var peersExtra = self.peers.connected + ' / ' + self.peers.total + ' connected';
        var peersBody = [];
        if (self.peersOpen) {
          if (self.peers.details.length === 0) {
            peersBody = [h('div', {
              style: { padding: '14px 18px', fontSize: '12px', color: '#a0a0a3' }
            }, 'No peers in this network yet.')];
          } else {
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
              // Normalize: a peer is either Connected or Disconnected —
              // netbird's transient states (Connecting…) read as down.
              var ok = String(g(p, 'status', 'connectionStatus') || '')
                .toLowerCase() === 'connected';
              return h('tr', {}, [
                td([g(p, 'fqdn', 'hostname') || '?']),
                td([g(p, 'netbirdIp', 'netbirdIP', 'ip') || '?']),
                td(dot(ok ? 'ok' : 'err', ok ? 'Connected' : 'Disconnected'))
              ]);
            });
            peersBody = [h('table', { style: { width: '100%', borderCollapse: 'collapse' } },
              [h('tr', {}, [th('Peer'), th('NetBird IP'), th('Status')])].concat(rows))];
          }
        }
        peersCard = h('div', { style: CARD }, [
          collapsibleHead('Peers', peersExtra, self.peersOpen,
            function () { self.peersOpen = !self.peersOpen; })
        ].concat(peersBody));
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
        updateCard,
        connectCard,
        peersCard,
        h('div', { style: { textAlign: 'center', fontSize: '11px', color: '#ccc', marginTop: '8px' } },
          'NetBird for GL-X2000 · netbird.io · auto-refreshes every 4s')
      ]);
    }
  };
})()
