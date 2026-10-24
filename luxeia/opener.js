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
  var msg = document.getElementById('msg');
  var tries = 0;
  function say(text) { msg.textContent = text; }

  // Home Assistant's own connection, from the HA app (or browser) around this page
  function hass() {
    try {
      var el = window.parent !== window && window.parent.document.querySelector('home-assistant');
      return el && el.hass && el.hass.connection ? el.hass : null;
    } catch (e) {
      return null;
    }
  }
  function supervisor(h, endpoint, method) {
    return h.callWS({ type: 'supervisor/api', endpoint: endpoint, method: method });
  }
  // The first id Home Assistant knows: its info, or null if none answer
  function find(h, i) {
    if (i >= names.length) return Promise.resolve(null);
    return supervisor(h, '/addons/' + names[i] + '/info', 'get').then(function (info) {
      if (info && info.ingress_url) {
        names = [names[i]].concat(names.filter(function (n, j) { return j !== i; })); // ask this one first next time
        return info;
      }
      return find(h, i + 1);
    }, function () {
      return find(h, i + 1);
    });
  }

  function open() {
    tries += 1;
    var h = hass();
    if (!h) {
      // Home Assistant may still be starting up around us
      if (tries < 40) return setTimeout(open, 250);
      say('Open Luxeia Home from the Home Assistant app.');
      return;
    }
    find(h, 0).then(function (info) {
      if (!info) throw new Error('no Luxeia Home');
      if (info.state !== 'started') {
        say('Luxeia Home is starting. One moment…');
        return setTimeout(open, 3000);
      }
      return supervisor(h, '/ingress/session', 'post').then(function (s) {
        // As Home Assistant's own add-on panels set it
        document.cookie = 'ingress_session=' + s.session + ';path=/api/hassio_ingress/;SameSite=Strict'
          + (location.protocol === 'https:' ? ';Secure' : '');
        location.replace(info.ingress_url + (window.LUXEIA_OPEN_PATH || '') + location.hash);
      });
    }).catch(function () {
      say('Can’t reach Luxeia Home just now. Trying again…');
      setTimeout(open, 5000);
    });
  }
  open();
})();
