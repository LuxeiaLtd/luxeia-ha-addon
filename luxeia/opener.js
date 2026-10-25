/*
  The opener's workings (secure_updates_plan.md, stage 4). opener.html is
  the page phones keep; it fetches this file fresh every time (a new ?t=
  each load), so what it does can change without anyone clearing anything:
  a saved copy of an older opener once kept looking for an add-on that had
  moved (from copied in by hand to the add-on store) and said "Can't reach
  Luxeia Home" until each phone's cache was cleared.

  It asks Home Assistant, as the person already signed in to the HA app (or
  browser) around it, for a session for the add-on (ingress), and opens the
  add-on's own page in its place (or, from the touch displays' opener,
  display-opener.html, its display/ page: LUXEIA_OPEN_PATH). People who can't change settings can only
  ask about an add-on whose id they know, so it tries this add-on's own id
  first (run.sh writes it into ADDON), then every other id Luxeia Home can
  have.

  Each step has a time limit and says what it's doing ("Finding Luxeia
  Home…"), and a failure says which step and why in small print, and in
  Home Assistant's log (logger luxeia.opener / luxeia.display): on a Shelly
  Wall Display, Home Assistant's own dashboard was too slow for a big home,
  its connection dropped, and the opener used to wait on it for minutes.

  So a touch display can also open this page on its own, as the page the
  display starts on (/local/luxeia-display/index.html, not inside a Home
  Assistant dashboard). With no Home Assistant around it, it signs in the
  way the app does (Home Assistant's own sign-in, once; the tokens kept in
  luxeia_auth_tokens, the app's own format, so the display app reads them
  too), opens its own connection, and goes on into display/ as before.
  Phones never do this: their opener has no LUXEIA_OPEN_PATH.
*/
(function () {
  var ADDON = 'local_luxeia';
  // Luxeia Home's id from the add-on store is the first 8 characters of the
  // SHA-1 of the store's address as it was typed (lower-cased), then
  // "_luxeia" (tests/updater.sh checks these against the address)
  var OTHERS = [
    'local_luxeia',     // copied in by hand
    '326db77a_luxeia',  // https://github.com/LuxeiaLtd/luxeia-ha-addon
    'aa64e5ff_luxeia',  // ... with a "/" on the end
    'e25b6206_luxeia',  // ... with ".git" on the end
  ];
  var names = [ADDON].concat(OTHERS.filter(function (n) { return n !== ADDON; }));
  var PATH = window.LUXEIA_OPEN_PATH || '';
  var DISPLAY = PATH === 'display/';
  var STEP_MS = window.LUXEIA_STEP_MS || 15000; // how long one step may take before it's given up (shorter in tests)
  var TOKENS = 'luxeia_auth_tokens';
  var STATE = 'luxeia_opener_state';
  var msg = document.getElementById('msg');
  var small = null;
  var tries = 0;
  var failures = 0;
  var step = 'start';
  var logged = 0;

  function say(text, detail) {
    msg.textContent = text;
    if (detail === undefined) return;
    if (!small) {
      small = document.createElement('p');
      small.style.cssText = 'font-size:12px;opacity:.75;margin:12px 0 0;word-break:break-word';
      msg.parentNode.appendChild(small);
    }
    small.textContent = detail;
  }
  function at(name, text) { step = name; say(text, ''); }
  function problem(code, text) { var e = new Error(text || code); e.code = code; return e; }
  // A step that doesn't answer in time fails, rather than waiting for ever
  function limit(promise) {
    return new Promise(function (resolve, reject) {
      var timer = setTimeout(function () { reject(problem('timeout', 'no answer in ' + STEP_MS / 1000 + ' seconds')); }, STEP_MS);
      promise.then(function (v) { clearTimeout(timer); resolve(v); }, function (e) { clearTimeout(timer); reject(e); });
    });
  }
  function browser() {
    var m = /Chrome\/(\d+)/.exec(navigator.userAgent);
    return m ? 'Chrome ' + m[1] : 'browser';
  }
  function why(err) {
    if (!err) return 'unknown';
    if (typeof err === 'number') return 'error ' + err; // home-assistant-js-websocket: 3 is "connection lost"
    return [err.code, err.message].filter(function (x) { return x !== undefined && x !== ''; }).join(': ') || String(err);
  }

  // ---- Home Assistant's own connection, from the HA app (or browser) around this page
  function around() {
    try {
      var el = window.parent !== window && window.parent.document.querySelector('home-assistant');
      return el && el.hass && el.hass.connection ? el.hass : null;
    } catch (e) {
      return null;
    }
  }
  function borrowed(h) {
    return { call: function (m) { return limit(h.callWS(m)); }, close: function () {} };
  }

  // ---- Its own connection, for a display that opens this page on its own
  function socket(accessToken) {
    return new Promise(function (resolve, reject) {
      var ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/websocket');
      var id = 0;
      var pending = {};
      var ready = false;
      var timer = setTimeout(function () { fail(problem('timeout', 'no answer in ' + STEP_MS / 1000 + ' seconds')); }, STEP_MS);
      function fail(e) {
        clearTimeout(timer);
        Object.keys(pending).forEach(function (k) { pending[k].reject(e); });
        pending = {};
        if (!ready) reject(e);
        try { ws.close(); } catch (x) { /* already closed */ }
      }
      var conn = {
        call: function (m) {
          return limit(new Promise(function (res, rej) {
            id += 1;
            pending[id] = { resolve: res, reject: rej };
            ws.send(JSON.stringify(Object.assign({ id: id }, m)));
          }));
        },
        close: function () { try { ws.close(); } catch (x) { /* already closed */ } },
      };
      ws.onmessage = function (e) {
        var m;
        try { m = JSON.parse(e.data); } catch (x) { return; }
        if (m.type === 'auth_required') ws.send(JSON.stringify({ type: 'auth', access_token: accessToken }));
        else if (m.type === 'auth_invalid') fail(problem('auth_invalid', m.message || 'sign-in not accepted'));
        else if (m.type === 'auth_ok') { ready = true; clearTimeout(timer); resolve(conn); }
        else if (m.type === 'result' && pending[m.id]) {
          var p = pending[m.id];
          delete pending[m.id];
          if (m.success) p.resolve(m.result);
          else p.reject(problem((m.error && m.error.code) || 'error', m.error && m.error.message));
        }
      };
      ws.onerror = function () { fail(problem('connection', 'couldn’t connect to Home Assistant')); };
      ws.onclose = function () { fail(problem('connection', 'connection closed')); };
    });
  }

  // ---- Signing in on its own, as the app does (js/api/auth.js; same tokens, same format)
  function clientId() { return location.origin + '/'; }
  function read(store, key) { try { return JSON.parse(store.getItem(key) || 'null'); } catch (e) { return null; } }
  function keep(data, previous, client) {
    var t = {
      kind: 'oauth',
      access_token: data.access_token,
      refresh_token: data.refresh_token || (previous && previous.refresh_token),
      expires: Date.now() + (data.expires_in || 1800) * 1000,
      client_id: client || clientId(),
    };
    try { localStorage.setItem(TOKENS, JSON.stringify(t)); } catch (e) { /* storage blocked: signs in each time */ }
    return t;
  }
  function forget() { try { localStorage.removeItem(TOKENS); } catch (e) { /* ignore */ } }
  function tokenRequest(params) {
    var body = Object.keys(params).map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]); }).join('&');
    return limit(fetch('/auth/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: body })).then(function (res) {
      if (res.status === 400 || res.status === 401 || res.status === 403) throw problem('auth_invalid', 'the sign-in has run out');
      if (!res.ok) throw problem('http_' + res.status, 'Home Assistant answered ' + res.status);
      return res.json();
    });
  }
  function refresh(t) {
    return tokenRequest({ grant_type: 'refresh_token', refresh_token: t.refresh_token, client_id: t.client_id || clientId() })
      .then(function (data) { return keep(data, t, t.client_id || clientId()); });
  }
  function signIn() {
    var state = Math.random().toString(36).slice(2) + Date.now().toString(36);
    try { sessionStorage.setItem(STATE, JSON.stringify({ state: state, hash: location.hash })); } catch (e) { /* the check is skipped */ }
    say('Signing in…', '');
    location.assign('/auth/authorize?response_type=code&client_id=' + encodeURIComponent(clientId())
      + '&redirect_uri=' + encodeURIComponent(location.origin + location.pathname) + '&state=' + encodeURIComponent(state));
    return new Promise(function () {}); // the page is leaving
  }
  function signInButton(text) {
    say(text, '');
    var b = document.createElement('button');
    b.type = 'button';
    b.textContent = 'Sign in';
    b.style.cssText = 'margin-top:16px;min-height:48px;padding:0 28px;border:0;border-radius:12px;background:#BA9947;color:#161616;font:600 17px Montserrat,Roboto,system-ui,sans-serif';
    b.onclick = function () { signIn(); };
    msg.parentNode.appendChild(b);
  }
  // A token for its own connection: back from signing in, kept, the HA frontend's, or sign in now
  function tokens() {
    var q = new URLSearchParams(location.search);
    if (q.get('code') || q.get('error')) {
      var saved = read(sessionStorage, STATE);
      try { sessionStorage.removeItem(STATE); } catch (e) { /* ignore */ }
      history.replaceState(null, '', location.pathname + ((saved && saved.hash) || location.hash));
      if (!q.get('code')) return Promise.reject(problem('auth_invalid', 'sign-in cancelled'));
      if (saved && q.get('state') !== saved.state) return Promise.reject(problem('auth_invalid', 'sign-in didn’t match'));
      at('signin', 'Signing in…');
      return tokenRequest({ grant_type: 'authorization_code', code: q.get('code'), client_id: clientId() }).then(function (d) { return keep(d); });
    }
    var t = read(localStorage, TOKENS);
    if (!t || t.kind !== 'oauth' || !t.refresh_token) {
      var h = read(localStorage, 'hassTokens'); // Home Assistant's own "Keep me logged in"
      t = h && h.refresh_token && (!h.hassUrl || h.hassUrl === location.origin)
        ? { kind: 'oauth', access_token: h.access_token, refresh_token: h.refresh_token, expires: h.expires || 0, client_id: h.clientId || clientId() }
        : null;
    }
    if (!t) return signIn();
    if (!t.expires || t.expires - Date.now() < 60000) { at('signin', 'Signing in…'); return refresh(t); }
    return Promise.resolve(t);
  }
  function ownConnection() {
    return tokens().then(function (t) {
      at('connect', 'Connecting to your home…');
      return socket(t.access_token).catch(function (e) {
        // A kept token Home Assistant no longer takes: refresh it once
        if (e.code !== 'auth_invalid') throw e;
        return refresh(t).then(function (t2) { return socket(t2.access_token); });
      });
    });
  }

  // ---- The add-on, its session, and its page
  function supervisor(c, endpoint, method) {
    return c.call({ type: 'supervisor/api', endpoint: endpoint, method: method });
  }
  // The first id Home Assistant knows: its info, or null if none answer
  function find(c, i) {
    if (i >= names.length) return Promise.resolve(null);
    return supervisor(c, '/addons/' + names[i] + '/info', 'get').then(function (info) {
      if (info && info.ingress_url) {
        names = [names[i]].concat(names.filter(function (n, j) { return j !== i; })); // ask this one first next time
        return info;
      }
      return find(c, i + 1);
    }, function (e) {
      // An id it doesn't have is refused at once; a connection that's stopped answering isn't worth asking again
      if (e && (e.code === 'timeout' || e.code === 'connection' || e === 3)) throw e;
      return find(c, i + 1);
    });
  }
  function go(c) {
    at('find', 'Finding Luxeia Home…');
    return find(c, 0).then(function (info) {
      if (!info) throw problem('no_addon', 'Luxeia Home isn’t installed, or can’t be seen');
      if (info.state !== 'started') {
        say('Luxeia Home is starting. One moment…', '');
        return 'again';
      }
      at('session', 'Getting things ready…');
      return supervisor(c, '/ingress/session', 'post').then(function (s) {
        // As Home Assistant's own add-on panels set it
        document.cookie = 'ingress_session=' + s.session + ';path=/api/hassio_ingress/;SameSite=Strict'
          + (location.protocol === 'https:' ? ';Secure' : '');
        at('open', 'Opening…');
        location.replace(info.ingress_url + PATH + location.hash);
        return 'done';
      });
    });
  }

  // What went wrong, in small print and in Home Assistant's log (best effort, a few times at most)
  function report(c, err) {
    var detail = 'Details: ' + browser() + ' · step: ' + step + ' · ' + why(err);
    var tip = DISPLAY && around() ? ' · Tip: set this display to open ' + location.origin + '/local/luxeia-display/index.html on its own' : '';
    say('Can’t reach Luxeia Home just now. Trying again…', detail + tip);
    if (c && logged < 3) {
      logged += 1;
      c.call({ type: 'call_service', domain: 'system_log', service: 'write',
        service_data: { message: 'Luxeia Home opener: ' + detail, level: 'warning', logger: DISPLAY ? 'luxeia.display' : 'luxeia.opener' } })
        .catch(function () { /* the log is a nice-to-have */ });
    }
  }

  function attempt(getConnection) {
    var c = null;
    getConnection().then(function (conn) {
      c = conn;
      return go(c);
    }).then(function (result) {
      if (result === 'again') { if (c) c.close(); setTimeout(open, 3000); }
    }).catch(function (err) {
      if (err && err.code === 'auth_invalid' && !around()) {
        forget();
        if (c) c.close();
        signInButton('Sign in to open Luxeia Home on this display.');
        return;
      }
      failures += 1;
      report(c, err);
      if (c) c.close();
      setTimeout(open, Math.min(5000 * failures, 30000));
    });
  }

  function open() {
    tries += 1;
    var h = around();
    if (h) return attempt(function () { return Promise.resolve(borrowed(h)); });
    // A touch display showing this page on its own: sign in and connect itself
    if (DISPLAY && window.parent === window) return attempt(ownConnection);
    // Home Assistant may still be starting up around us
    if (tries < 40) return setTimeout(open, 250);
    say('Open Luxeia Home from the Home Assistant app.', '');
  }
  open();
})();
