/* Page-side glue for the iPhone app. Loaded after backend.js and before the page's own script
   (src/page.html, the app's own copy of the page). Does nothing unless the app sets
   window.__ytmStandalone.

   Where things come from:
     data (/api/...)  the user's own PC, through the app's ytmHttp bridge - as the web page always did.
                      While the PC cannot be reached, the copy of the server code inside the page
                      (backend.js) answers search / home / browse / queue anonymously.
     audio            the plain file on the PC (<pc>/media/<id>.m4a?mode=phone), or a file stored
                      in the app. Never YouTube directly.
     sound            surround, EQ and loudness are done by the app's own engine; the settings
                      (and the impulse responses, made by backend.js) are sent to it from here. */
(function () {
  'use strict';
  if (!window.__ytmStandalone) return;
  var B = window.__ytmBackend;
  if (!B || !B.dispatch) { try { console.error('standalone: backend.js did not start'); } catch (e) {} return; }

  var OFFLINE_MSG = '連不到電腦：只能播放已存在手機的歌';
  var realFetch = window.fetch ? window.fetch.bind(window) : null;
  var enc = typeof TextEncoder !== 'undefined' ? new TextEncoder() : null;
  var dec = typeof TextDecoder !== 'undefined' ? new TextDecoder() : null;

  function utf8(s) {
    if (enc) return enc.encode(s);
    var e = unescape(encodeURIComponent(s)), u = new Uint8Array(e.length);
    for (var i = 0; i < e.length; i++) u[i] = e.charCodeAt(i);
    return u;
  }
  function text(u) {
    if (dec) return dec.decode(u);
    var s = '';
    for (var i = 0; i < u.length; i++) s += String.fromCharCode(u[i]);
    return decodeURIComponent(escape(s));
  }
  function jsonResponse(status, obj) {
    return new Response(JSON.stringify(obj), { status: status, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
  }
  /* What the page lets the glue use (handed over by the page itself, see build-app.js). */
  var P = null;
  function plog(level, kind, data) { try { if (P && P.dbg) P.dbg(level, kind, data); } catch (x) {} }

  /* ---------------------------------------------------------- the PC: reachable or not
     Known for 20 s at a time. Every answer from the PC renews "reachable"; a failed call or a
     probe that gets no answer within 4 s means "not reachable" until the next probe. */
  var PC_FRESH_MS = Number(window.__ytmPcFreshMs) || 20000;
  var pc = { up: null, at: 0, ms: 0, error: '', probing: null };
  function pcSet(up, ms, error) {
    var changed = pc.up !== up;
    pc.up = up; pc.at = Date.now(); pc.ms = ms || 0; pc.error = up ? '' : String(error || '').slice(0, 120);
    if (changed) {
      plog(up ? 'I' : 'W', 'pc', { up: up ? 1 : 0, ms: pc.ms, error: pc.error });
      /* the notice on the home page follows at once (not shown when the app plays by itself) */
      try { var n = document.getElementById('pcNotice'); if (n) n.style.display = (up || nativeSongs()) ? 'none' : ''; } catch (e) {}
    }
    if (up) homeAuto('pc');
  }
  function pcProbe() {
    if (pc.probing) return pc.probing;
    var t0 = Date.now();
    pc.probing = B.bridgeHttp({ url: B.pcBase() + '/api/ir/bases', method: 'GET', headers: {}, body: null, timeoutMs: 4000 }).then(function (r) {
      if (r.status !== 200) throw new Error('HTTP ' + r.status);
      pcSet(true, Date.now() - t0, '');
      return true;
    }).catch(function (e) {
      pcSet(false, Date.now() - t0, (e && e.message) || e);
      return false;
    }).then(function (up) { pc.probing = null; return up; });
    return pc.probing;
  }
  /* -> Promise<boolean>; asks the PC only when the last answer is older than 20 s */
  function pcUp() {
    if (pc.up !== null && Date.now() - pc.at < PC_FRESH_MS) return Promise.resolve(pc.up);
    return pcProbe();
  }
  /* ---------------------------------------------------------- home feed, refreshed by itself
     What pulling the home page down does, done quietly: once at launch as soon as the PC answers,
     and again when the app comes back after being away for 10 minutes or more. Only the home
     feed is asked for again; what is playing and the queue are not touched. */
  var HOME_AWAY_MS = Number(window.__ytmHomeAwayMs) || 600000;
  var homeWant = true, hiddenAt = 0, homeRuns = 0;
  function homeAuto(why) {
    if (!homeWant || pc.up !== true || !P || !P.homeQuiet) return;
    homeWant = false;
    homeRuns++;
    var how = '';
    try { how = P.homeQuiet(); } catch (e) { how = 'error'; }
    plog('I', 'home-auto', { why: why, how: how, n: homeRuns });
  }
  try {
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) { hiddenAt = Date.now(); return; }
      if (hiddenAt && Date.now() - hiddenAt >= HOME_AWAY_MS) homeWant = true;
      hiddenAt = 0;
      if (homeWant) pcUp().then(function () { homeAuto('back'); });
    });
  } catch (e) {}
  try {
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && (pc.up !== true || Date.now() - pc.at >= PC_FRESH_MS)) pcProbe();
    });
  } catch (e) {}

  /* ---------------------------------------------------------- development log -> PC
     Best effort, but nothing is thrown away lightly: batches wait in a short line, one request at
     a time. After a failure the PC is left alone for a while and the line is kept (the oldest
     batches go first when it grows too long). The text is turned into UTF-8 bytes and those into
     base64 - song titles are rarely plain ASCII. */
  var DBG_WAIT_MS = Number(window.__ytmDebugWaitMs) || 20000, DBG_KEEP = 40;
  var dbgQueue = [], dbgBusy = false, dbgQuietUntil = 0, dbgTimer = null;
  var dbgStats = { sent: 0, failed: 0, dropped: 0, lastError: '', lastOkAt: 0 };
  function dbgPump() {
    if (dbgBusy || !dbgQueue.length) return;
    var wait = dbgQuietUntil - Date.now();
    if (wait > 0) {
      if (!dbgTimer) dbgTimer = setTimeout(function () { dbgTimer = null; dbgPump(); }, wait + 50);
      return;
    }
    dbgBusy = true;
    var body = dbgQueue[0], call;
    try {
      call = B.bridgeHttp({ url: B.pcBase() + '/api/debug', method: 'POST', headers: { 'Content-Type': 'application/json' }, body: B.b64(utf8(body)), timeoutMs: 8000 });
    } catch (e) { call = Promise.reject(e); }
    Promise.resolve(call).then(function (r) {
      if (!(r.status >= 200 && r.status < 300)) throw new Error('HTTP ' + r.status);
      if (dbgQueue[0] === body) dbgQueue.shift();
      dbgStats.sent += 1;
      dbgStats.lastOkAt = Date.now();
    }).catch(function (e) {
      dbgStats.failed += 1;
      dbgStats.lastError = String((e && e.message) || e).slice(0, 120);
      dbgQuietUntil = Date.now() + DBG_WAIT_MS;
    }).then(function () { dbgBusy = false; dbgPump(); });
  }
  function forwardDebug(t) {
    if (!t) return;
    dbgQueue.push(String(t));
    while (dbgQueue.length > DBG_KEEP) { dbgQueue.splice(dbgBusy ? 1 : 0, 1); dbgStats.dropped += 1; }
    dbgPump();
  }

  /* ---------------------------------------------------------- songs: stored, lengths, loudness */
  function stored() {
    try { var o = JSON.parse(localStorage.getItem('ytm_dl') || '{}'); return o && typeof o === 'object' ? o : {}; } catch (e) { return {}; }
  }
  /* Songs the page has stored in the app (its own list, kept in localStorage). */
  function downloaded(id) { var o = stored(); return !!(o[id] && o[id].state === 'done'); }
  var durs = {}, hints = {}, appLufs = {};
  function durOf(id) {
    if (durs[id] > 0) return durs[id];
    var o = stored();
    if (o[id] && o[id].duration > 0) return o[id].duration;
    return hints[id] > 0 ? hints[id] : 0;
  }
  /* The app carries yt-dlp itself: it can find a song from its id alone, and "ytdl://<id>"
     tells it to. Without it the address comes from the PC, as before. */
  function nativeSongs() { return !!(window.__ytmYtdlp); }
  /* Signed in to YouTube Music inside the app: the page's own youtubei calls are then
     stamped with the account (the app does that), and the account-only actions (like,
     playlists) are answered by the app instead of the PC. */
  function accountOn() { return !!(window.__ytmAccount); }

  /* The sign-in page: shown when nobody is signed in, or when the stored sign-in stopped working. */
  var promptEl = null;
  function closePrompt() {
    try { if (promptEl && promptEl.parentNode) promptEl.parentNode.removeChild(promptEl); } catch (e) {}
    promptEl = null;
  }
  function loginPrompt(reason) {
    if (promptEl || !hasAppHandler()) return;
    var skip = false;
    try { skip = localStorage.getItem('ytm_login_skip') === '1'; } catch (e) { skip = false; }
    if (reason === 'none' && skip) return;
    var wrap = document.createElement('div');
    wrap.setAttribute('role', 'dialog');
    wrap.setAttribute('aria-modal', 'true');
    wrap.setAttribute('style', 'position:fixed;left:0;top:0;right:0;bottom:0;z-index:99999;display:flex;align-items:center;justify-content:center;padding:24px;background:rgba(0,0,0,.72)');
    var card = document.createElement('div');
    card.setAttribute('style', 'width:100%;max-width:380px;background:#1c1c1c;color:#fff;border-radius:18px;padding:22px 20px;box-shadow:0 10px 40px rgba(0,0,0,.6)');
    var h = document.createElement('h2');
    h.textContent = reason === 'expired' ? '登入已失效' : '登入 YouTube Music';
    h.setAttribute('style', 'margin:0 0 10px;font-size:20px');
    var p = document.createElement('p');
    p.textContent = reason === 'expired'
      ? '你的 YouTube Music 登入已經失效，請重新登入。不登入也能繼續聽歌，但看不到個人推薦，喜歡的歌曲和播放紀錄也不會同步。'
      : '登入後可以看到自己的推薦內容，並同步喜歡的歌曲、播放清單和播放紀錄。不登入也能聽歌。';
    p.setAttribute('style', 'margin:0 0 18px;line-height:1.5;opacity:.85');
    var go = document.createElement('button');
    go.type = 'button';
    go.textContent = '登入';
    go.setAttribute('style', 'display:block;width:100%;margin:0 0 10px;padding:13px;border-radius:12px;border:0;background:#fff;color:#000;font:inherit;font-weight:600');
    go.addEventListener('click', function () { closePrompt(); raw({ cmd: 'login' }); });
    var later = document.createElement('button');
    later.type = 'button';
    later.textContent = '稍後';
    later.setAttribute('style', 'display:block;width:100%;margin:0 0 6px;' + BTN);
    later.addEventListener('click', closePrompt);
    card.appendChild(h);
    card.appendChild(p);
    card.appendChild(go);
    card.appendChild(later);
    if (reason === 'none') {
      var never = document.createElement('button');
      never.type = 'button';
      never.textContent = '不再提醒';
      never.setAttribute('style', 'display:block;width:100%;margin:0;padding:9px;border:0;background:transparent;color:inherit;opacity:.6;font:inherit');
      never.addEventListener('click', function () { try { localStorage.setItem('ytm_login_skip', '1'); } catch (e) {} closePrompt(); });
      card.appendChild(never);
    }
    wrap.appendChild(card);
    (document.body || document.documentElement).appendChild(wrap);
    promptEl = wrap;
  }
  function accountCall(what, id, u) {
    var h = null;
    try { h = window.webkit.messageHandlers.ytmAccount; } catch (e) { h = null; }
    if (!h) return Promise.resolve(jsonResponse(503, { error: '需要登入' }));
    var body = {};
    try { if (u && u.length) body = JSON.parse(text(u)) || {}; } catch (e) { body = {}; }
    var msg = { op: what, id: id };
    if (what === 'like' && body.status) msg.status = String(body.status);
    if (what === 'save' && body.playlistId) msg.playlistId = String(body.playlistId);
    return Promise.resolve(h.postMessage(msg)).then(function (r) {
      return jsonResponse(200, r || {});
    }, function (e) {
      return jsonResponse(503, { error: String((e && e.message) || e) });
    });
  }
  function media(id) {
    var url = nativeSongs() ? 'ytdl://' + id : B.mediaUrl(id);
    return { url: url, headers: {}, size: 0, durationSec: durOf(id), mime: 'audio/mp4', local: downloaded(id) };
  }

  /* ---------------------------------------------------------- the page's requests */
  var ROUTED = /^\/(api\/|media\/|icon-\d+\.png$|manifest\.webmanifest$)/;
  function localPath(address) {
    var s = String(address);
    if (s.charAt(0) === '/' && s.charAt(1) !== '/') return ROUTED.test(s) ? s : null;
    if (/^[a-z][a-z0-9+.-]*:/i.test(s)) {
      var here = location.protocol + '//' + location.host;
      if (s.slice(0, here.length + 1) !== here + '/') return null;
      s = s.slice(here.length);
      return ROUTED.test(s) ? s : null;
    }
    return null;
  }
  function bodyBytes(b) {
    if (b === undefined || b === null) return Promise.resolve(null);
    if (typeof b === 'string') return Promise.resolve(utf8(b));
    if (typeof Blob !== 'undefined' && b instanceof Blob) return b.arrayBuffer().then(function (ab) { return new Uint8Array(ab); });
    if (b instanceof ArrayBuffer) return Promise.resolve(new Uint8Array(b));
    if (ArrayBuffer.isView(b)) return Promise.resolve(new Uint8Array(b.buffer, b.byteOffset, b.byteLength));
    return Promise.resolve(utf8(String(b)));
  }
  function headerMap(h) {
    var out = {};
    if (!h) return out;
    if (typeof Headers !== 'undefined' && h instanceof Headers) h.forEach(function (v, k) { out[k] = v; });
    else if (Array.isArray(h)) h.forEach(function (p) { out[p[0]] = p[1]; });
    else for (var k in h) out[k] = h[k];
    return out;
  }
  function abortError() {
    try { return new DOMException('The operation was aborted.', 'AbortError'); } catch (e) { var x = new Error('aborted'); x.name = 'AbortError'; return x; }
  }
  /* The light that moves with the music: the app works the file out after it has downloaded the
     song and serves it next to the page. Not there yet -> one more look 4 s later, then 404. */
  function envFetch(id) {
    var look = function () {
      if (!realFetch) return Promise.resolve(null);
      return realFetch('env/' + id + '.bin').then(function (r) { return r.ok ? r.arrayBuffer() : null; }, function () { return null; });
    };
    return look().then(function (ab) {
      if (ab && ab.byteLength) return ab;
      return new Promise(function (resolve) { setTimeout(resolve, 4000); }).then(look);
    }).then(function (ab) {
      if (ab && ab.byteLength) return new Response(ab, { status: 200, headers: { 'Content-Type': 'application/octet-stream' } });
      return jsonResponse(404, { error: 'not computed yet' });
    });
  }
  /* Answered by the server code inside the page. */
  function inPage(path, method, headers, u, signal) {
    return new Promise(function (resolve, reject) {
      var aborted = false;
      B.dispatch({
        method: method, url: path, headers: headers, body: u,
        onAbort: function (stop) {
          if (signal) signal.addEventListener('abort', function () { aborted = true; stop(); reject(abortError()); });
        }
      }).then(function (r) {
        if (aborted) return;
        var none = method === 'HEAD' || r.status === 204 || r.status === 205 || r.status === 304;
        resolve(new Response(none ? null : r.body, { status: r.status, headers: r.headers }));
      }, reject);
    });
  }
  var TRACK = /^\/api\/track\/([\w-]{11})\/(status|prepare)$/;
  /* The PC cannot be reached: the page's own copy of the server answers what it can. */
  function offline(path, method, headers, u, signal) {
    var p0 = path.split('?')[0];
    var t = TRACK.exec(p0);
    if (t) {
      /* a song stored in the app is ready; so is any song when the app brings its own yt-dlp;
         otherwise this one needs the PC */
      if (downloaded(t[1]) || nativeSongs()) return Promise.resolve(jsonResponse(200, { state: 'ready', duration: durOf(t[1]), lufs: typeof appLufs[t[1]] === 'number' ? appLufs[t[1]] : null }));
      return Promise.resolve(jsonResponse(503, { error: OFFLINE_MSG }));
    }
    if (p0.indexOf('/media/') === 0) return Promise.resolve(jsonResponse(503, { error: OFFLINE_MSG }));
    return inPage(path, method, headers, u, signal);
  }
  /* The request as it is, sent to the PC. No Origin or Referer: to the server this is the app
     itself, not some other web page. */
  function toPc(path, method, headers, u) {
    var h = {}, k;
    for (k in headers) {
      var lk = String(k).toLowerCase();
      if (lk === 'content-type' || lk === 'range' || lk === 'accept') h[k] = String(headers[k]);
    }
    if (u && !Object.keys(h).some(function (x) { return x.toLowerCase() === 'content-type'; })) h['Content-Type'] = 'application/json';
    return B.bridgeHttp({ url: B.pcBase() + path, method: method, headers: h, body: u && u.length ? B.b64(u) : null, timeoutMs: 45000 }).then(function (r) {
      pcSet(true, pc.ms, '');
      var bytes = r.body ? B.unb64(r.body) : new Uint8Array(0);
      var out = {};
      ['content-type', 'content-range', 'accept-ranges'].forEach(function (name) { if (r.headers && r.headers[name]) out[name] = r.headers[name]; });
      var t = TRACK.exec(path.split('?')[0]);
      if (t && r.status === 200) {
        /* the length is remembered; the loudness is the app's own measurement when it has one */
        try {
          var j = JSON.parse(text(bytes));
          if (j && j.duration > 0) { durs[t[1]] = j.duration; if (cur.id === t[1] && !(cur.dur > 0)) cur.dur = j.duration; }
          if (j && typeof appLufs[t[1]] === 'number') { j.lufs = appLufs[t[1]]; bytes = utf8(JSON.stringify(j)); }
        } catch (e) {}
      }
      var none = method === 'HEAD' || r.status === 204 || r.status === 205 || r.status === 304;
      return new Response(none ? null : bytes, { status: r.status, headers: out });
    });
  }
  function routed(path, method, headers, body, signal) {
    if (signal && signal.aborted) return Promise.reject(abortError());
    method = String(method || 'GET').toUpperCase();
    var p0 = path.split('?')[0];
    var env = /^\/api\/env\/([\w-]{11})$/.exec(p0);
    if (env && method === 'GET') return envFetch(env[1]);
    return bodyBytes(body).then(function (u) {
      if (p0 === '/api/debug') {
        try { forwardDebug(u ? text(u) : ''); } catch (e) {}
        return jsonResponse(200, { ok: true });
      }
      /* Signed in, or simply able to play by itself: the account's own actions and the personal
         feeds stay in the app, where the requests carry the cookies - the PC would answer them
         anonymously. Nothing is asked of the PC for these, so no probe and no "offline" notice. */
      if (accountOn() || nativeSongs()) {
        var song = /^\/api\/song\/([\w-]{11})\/(like|playlists|save)$/.exec(p0);
        if (song && accountOn()) return accountCall(song[2], song[1], u);
        if (p0 === '/api/home' || p0 === '/api/search' || p0 === '/api/browse') return inPage(path, method, headers, u, signal);
      }
      /* The surround setting must be buildable without the PC, and the icons never needed it. */
      if (p0 === '/api/ir/bases' || p0.indexOf('/api/ir/custom/') === 0 || p0.indexOf('/api/') !== 0 && p0.indexOf('/media/') !== 0) return inPage(path, method, headers, u, signal);
      return pcUp().then(function (up) {
        if (!up) return offline(path, method, headers, u, signal);
        return toPc(path, method, headers, u).catch(function (e) {
          pcSet(false, 0, (e && e.message) || e);
          return offline(path, method, headers, u, signal);
        });
      });
    });
  }
  window.fetch = function (input, init) {
    var isReq = typeof Request !== 'undefined' && input instanceof Request;
    var path = localPath(isReq ? input.url : input);
    if (path === null) return realFetch(input, init);
    init = init || {};
    var headers = headerMap(isReq ? input.headers : null);
    var extra = headerMap(init.headers);
    for (var k in extra) headers[k] = extra[k];
    var method = init.method || (isReq ? input.method : 'GET');
    var body = init.body !== undefined ? init.body : (isReq && !/^(GET|HEAD)$/i.test(method) ? input.clone().arrayBuffer() : null);
    return Promise.resolve(body).then(function (b) { return routed(path, method, headers, b, init.signal || (isReq ? input.signal : null)); });
  };
  if (navigator.sendBeacon) {
    var realBeacon = navigator.sendBeacon.bind(navigator);
    try {
      navigator.sendBeacon = function (address, data) {
        var path = localPath(address);
        if (path === null) return realBeacon(address, data);
        if (path.split('?')[0] === '/api/debug') bodyBytes(data).then(function (u) { forwardDebug(u ? text(u) : ''); }).catch(function () {});
        return true;
      };
    } catch (e) {}
  }

  /* ---------------------------------------------------------- commands to the app
     The page posts load / queue / dl with addresses relative to the server (/media/<id>.m4a?...).
     The app gets the absolute address of the plain file on the PC instead. */
  function raw(m) {
    try { window.webkit.messageHandlers.ytm.postMessage(m); } catch (e) {}
  }
  function idOf(address) {
    var m = /\/media\/([\w-]{11})\.m4a/.exec(String(address || ''));
    return m ? m[1] : '';
  }
  /* The song the app was last told to load (or moved on to by itself). */
  var cur = { id: '', dur: 0, t: 0, t0: 0, wantPlay: false, retried: false, progress: '', lookup: '', local: false };
  var lastQueue = null, queueResent = {}, lastError = null, diagBox = null, diagApp = '', refused = false;

  /* ---------------------------------------------------------- automatic mixing between songs
     The app's player does the mixing. From here it gets the user's switch, and for each song what
     the PC has worked out about it (GET <pc>/api/mix/<id>: tempo, first beat, where the song
     proper starts and where it fades). That takes the PC a few seconds the first time, so it is
     asked for ahead - two songs at a time, the current and the next first - and never waited for:
     what is known goes along with loadSong / queue, the rest follows as { cmd: 'mixInfo' }. */
  var MIX_RETRY_MS = Number(window.__ytmMixRetryMs) || 60000;
  var mixKnown = {}, mixFailed = {}, mixBusy = {}, mixWant = [], mixActive = 0, mixSent = null;
  var sentMeta = {};
  var mixRun = null, mixLast = null, mixTimer = null, mixedTo = null, queuedIds = [], heldAdvance = null, heldTimer = null;
  function mixing() { try { return !!(P && P.mixOn && P.mixOn()); } catch (e) { return false; } }
  function mixOf(id) { return mixing() && mixKnown[id] ? mixKnown[id] : null; }
  function mixPump() {
    if (pc.up === false) { mixWant = []; return; }
    while (mixActive < 2 && mixWant.length) {
      var id = mixWant.shift();
      if (mixKnown[id] || mixBusy[id]) continue;
      mixFetch(id);
    }
  }
  function mixFetch(id) {
    mixBusy[id] = 1;
    mixActive += 1;
    B.bridgeHttp({ url: B.pcBase() + '/api/mix/' + id, method: 'GET', headers: {}, body: null, timeoutMs: 40000 }).then(function (r) {
      if (r.status !== 200) throw new Error('HTTP ' + r.status);
      var j = JSON.parse(text(B.unb64(r.body || '')));
      if (!j || !(j.bpm > 0)) throw new Error('no analysis');
      delete j.v;
      mixKnown[id] = j;
      delete mixFailed[id];
      if (mixing() && (id === cur.id || queuedIds.indexOf(id) >= 0)) raw({ cmd: 'mixInfo', id: id, mix: j });
    }).catch(function (e) {
      mixFailed[id] = Date.now();
      plog('W', 'mix-info-failed', { id: id, m: String((e && e.message) || e).slice(0, 80) });
    }).then(function () {
      delete mixBusy[id];
      mixActive -= 1;
      mixPump();
    });
  }
  /* ids in order of urgency; the newest request goes to the front of the line */
  function mixNeed(ids) {
    if (!mixing() || pc.up === false) return;
    var now = Date.now(), list = [];
    ids.forEach(function (id) {
      if (!id || list.indexOf(id) >= 0 || mixKnown[id] || mixBusy[id]) return;
      if (mixFailed[id] && now - mixFailed[id] < MIX_RETRY_MS) return;
      list.push(id);
    });
    mixWant = list.concat(mixWant.filter(function (id) { return list.indexOf(id) < 0; })).slice(0, 8);
    mixPump();
  }
  /* The switch, at the start and whenever it is moved. Turned on: the app is given what is known
     about the songs it already has, and the rest is asked for. */
  function sendMix() {
    var on = mixing();
    if (mixSent === on) return;
    mixSent = on;
    raw({ cmd: 'mix', on: on });
    if (!on) { mixWant = []; return; }
    var ids = (cur.id ? [cur.id] : []).concat(queuedIds);
    ids.forEach(function (id) { if (mixKnown[id]) raw({ cmd: 'mixInfo', id: id, mix: mixKnown[id] }); });
    mixNeed(ids);
  }
  function titleFor(id) {
    var items = (lastQueue && lastQueue.items) || [], i;
    for (i = 0; i < items.length; i++) if ((items[i].id || idOf(items[i].url)) === id && items[i].title) return items[i].title;
    try { return (P && P.titleOf && P.titleOf(id)) || ''; } catch (e) { return ''; }
  }
  /* After a mix the app says "advanced" when the overlap is over; the song is then some seconds
     in. The page is told together with the first position the app reports, so that it never
     shows 0:00 in between. */
  function releaseAdvance(t) {
    var a = heldAdvance;
    if (!a) return;
    heldAdvance = null;
    clearTimeout(heldTimer);
    if (typeof t === 'number') { a.t = t; cur.t = cur.t0 = t; }
    toPage(a);
  }

  var pageHandler = typeof window.__ytmNativeEvent === 'function' ? window.__ytmNativeEvent : null;
  function toPage(e) {
    if (e && e.type === 'error') {
      lastError = { id: e.id || cur.id, message: String(e.message || '原因不明').slice(0, 160), at: Date.now() };
      plog('E', 'native-error', { id: lastError.id, message: lastError.message });
    }
    try { if (pageHandler) return pageHandler(e); } catch (x) {}
  }
  function redraw() { try { if (P && P.render) P.render(); } catch (e) {} }
  /* At most once a second, and only when the status line would read differently. */
  var redrawTimer = null, redrawAt = 0, shownStatus = null;
  function redrawSoon() {
    if (redrawTimer) return;
    var wait = Math.max(0, 1000 - (Date.now() - redrawAt));
    redrawTimer = setTimeout(function () {
      redrawTimer = null;
      var now = '';
      try { now = String(glueStatus(true)); } catch (e) {}
      if (now === shownStatus) return;
      shownStatus = now;
      redrawAt = Date.now();
      redraw();
    }, wait);
  }
  function setProgress(t) {
    if (cur.progress === t) return;
    cur.progress = t;
    redraw();
  }
  /* The PC is away and this song is not stored: say so and stay put (no error event, so the page
     does not start skipping through the queue). */
  function refuseOffline(id) {
    plog('W', 'offline-refused', { id: id });
    lastError = { id: id, message: OFFLINE_MSG, at: Date.now() };
    cur.wantPlay = false;
    cur.lookup = '';
    refused = true;
    raw({ cmd: 'pause' });
    try { if (pageHandler) pageHandler({ type: 'state', playing: false }); } catch (e) {}
    try { if (P && P.fail) P.fail(OFFLINE_MSG); } catch (e2) {}
  }
  function sendLoadSong(id, startAt) {
    var s = media(id);
    cur.id = id;
    cur.dur = s.durationSec || 0;
    cur.t = cur.t0 = startAt || 0;
    cur.progress = '';
    /* The app has to look the address up first (yt-dlp), which takes a few seconds on the
       first song: say so instead of showing nothing. */
    cur.lookup = (String(s.url).indexOf('ytdl://') === 0 && !s.local) ? '正在取得歌曲…' : '';
    cur.local = s.local;
    cur.fresh = false;
    var msg = { cmd: 'loadSong', id: id, url: s.url, headers: s.headers, startAt: startAt || 0, size: s.size, duration: s.durationSec, mime: s.mime, local: s.local };
    var mx = mixOf(id);
    if (mx) msg.mix = mx;
    raw(msg);
    if (cur.lookup) redraw();
    sendArt(id);
    mixNeed([id]);
  }
  function onLoad(m) {
    var id = idOf(m.url);
    cur.wantPlay = false;
    if (!id) return false;
    if (pc.up === false && !downloaded(id) && !nativeSongs()) {
      /* known to be away: do not even try (and look again, in case it is back) */
      cur.id = ''; cur.retried = false;
      refuseOffline(id);
      if (Date.now() - pc.at >= PC_FRESH_MS) pcProbe();
      return true;
    }
    cur.retried = false;
    /* The song the app is already mixing into: it goes on playing, and where it has got to is
       whatever the app reports next. */
    var into = !!(mixRun && mixRun.to === id);
    if (mixRun && !into) { mixRun = null; clearTimeout(mixTimer); }
    if (heldAdvance) releaseAdvance(null);
    sendLoadSong(id, m.startAt || 0);
    cur.fresh = into;
    return true;
  }
  /* The songs that follow, for when the app carries on by itself with the screen locked. While
     the PC is away only stored songs can follow, so the list stops at the first one that is not. */
  function onQueue(m) {
    var items = Array.isArray(m.items) ? m.items : [];
    lastQueue = m;
    var out = [];
    for (var i = 0; i < items.length && out.length < 5; i++) {
      var it = items[i], id = it.id || idOf(it.url);
      if (!id) continue;
      if (it.duration > 0 && !(hints[id] > 0)) hints[id] = it.duration;
      var s = media(id);
      if (pc.up === false && !s.local && !nativeSongs()) break;
      var q = { id: id, url: s.url, headers: s.headers, size: s.size, local: s.local, mime: s.mime,
        title: it.title || '', artist: it.artist || '', artwork: it.artwork || '', duration: s.durationSec || it.duration || 0 };
      var mx = mixOf(id);
      if (mx) q.mix = mx;
      out.push(q);
    }
    queuedIds = out.map(function (x) { return x.id; });
    /* what the app was told about each song, should it ever play one the page has lost track of */
    out.forEach(function (x) { sentMeta[x.id] = { title: x.title, artist: x.artist, artwork: x.artwork, duration: x.duration }; });
    var all = Object.keys(sentMeta);
    while (all.length > 60) delete sentMeta[all.shift()];
    raw({ cmd: 'queue', items: out });
    if (out.length) sendArt(out[0].id);
    mixNeed((cur.id ? [cur.id] : []).concat(queuedIds));
    return true;
  }
  function onDownload(m) {
    var id = m.id || idOf(m.url);
    if (nativeSongs()) {
      var own = media(id);
      raw({ cmd: 'dl', id: id, url: own.url, headers: own.headers, size: own.size, mime: own.mime });
      return true;
    }
    pcUp().then(function (up) {
      if (!up) {
        try { if (P && P.toast) P.toast('連不到電腦，無法下載'); } catch (e) {}
        toPage({ type: 'dl', id: id, state: 'error' });
        return;
      }
      var s = media(id);
      raw({ cmd: 'dl', id: id, url: s.url, headers: s.headers, size: s.size, mime: s.mime });
    });
    return true;
  }

  /* ---------------------------------------------------------- events from the app
     The page assigns its own handler to window.__ytmNativeEvent later; this sits in front of it. */
  function networkTrouble(message) {
    var s = String(message || '');
    if (/\b4\d\d\b/.test(s)) return false;
    return /time[d ]?\s?out|network|connection|offline|internet|could not connect|cannot connect|not connected|lost|reset|unreachable|NSURLError|-10\d\d/i.test(s);
  }
  /* Songs the app counted as played while this page was not running (screen off, in the car)
     are kept by the app; they are fetched when the page starts, comes back, or is told of one. */
  function historyPull() {
    var h = null;
    try { h = window.webkit.messageHandlers.ytmAccount; } catch (e) { h = null; }
    if (!h || !P || !P.addHistory) return;
    try {
      Promise.resolve(h.postMessage({ op: 'historyPull' })).then(function (r) {
        if (r && r.items && r.items.length) {
          try { P.addHistory(r.items); } catch (e2) {}
        }
      }, function () {});
    } catch (e3) {}
  }
  try {
    document.addEventListener('visibilitychange', function () { if (!document.hidden) historyPull(); });
  } catch (e) {}
  function onAppEvent(e) {
    if (!e || typeof e.type !== 'string') return toPage(e);
    if (e.type === 'history') { historyPull(); return; }
    if (e.type === 'accountExpired') { plog('W', 'account-expired', {}); loginPrompt('expired'); return; }
    if (e.type === 'diag') { diagApp = String(e.text || ''); diagShow(); return; }
    if (e.type === 'light') {
      lightState = { state: String(e.state || 'off'), name: e.name == null ? null : String(e.name), detail: e.detail == null ? null : String(e.detail) };
      lightShowStatus();
      return;
    }
    if (e.type === 'prefetchError') {
      /* A queued song could not be fetched ahead: the song that is playing is left alone, and
         the queue is sent once more a little later. */
      plog('W', 'native-prefetch-error', { id: e.id || '', message: String(e.message || '').slice(0, 160) });
      var key = e.id || '?';
      if (queueResent[key] && Date.now() - queueResent[key] < 5 * 60 * 1000) return;
      queueResent[key] = Date.now();
      setTimeout(function () { if (lastQueue) onQueue(lastQueue); }, Number(window.__ytmRequeueMs) || 5000);
      return;
    }
    if (e.type === 'progress') {
      if (e.id && e.id !== cur.id) return;
      cur.lookup = '';
      var pct = e.total > 0 ? Math.max(0, Math.min(99, Math.floor(e.received * 100 / e.total))) : -1;
      setProgress(pct >= 0 ? '下載中 ' + pct + '%' : '下載中…');
      return;
    }
    if (e.type === 'report' || e.type === 'headroom') {
      try { if (reportUi && reportUi.update) reportUi.update(e); } catch (x) {}
      return;
    }
    if (e.type === 'band') {
      bandState = { state: String(e.state || 'off'), seconds: e.seconds, realtime: e.realtime, message: e.message ? String(e.message) : '' };
      if (bandState.state === 'failed' || bandState.state === 'late') plog('W', 'band-' + bandState.state, { message: bandState.message });
      redrawSoon();
      try { if (P && P.bandStatusChanged) P.bandStatusChanged(bandStatusText(), bandState); } catch (x) {}
      return;
    }
    if (e.type === 'lufs') {
      if (e.id && typeof e.lufs === 'number' && isFinite(e.lufs)) {
        appLufs[e.id] = e.lufs;
        try { if (P && P.gotLufs && P.vid() === e.id) { P.gotLufs(e.lufs); redraw(); } } catch (x2) {}
      }
      return;
    }
    if (e.type === 'mix') {
      mixLast = { stage: String(e.stage || ''), from: e.from || '', to: e.to || '', reason: e.reason || '', at: Date.now() };
      plog('I', 'mix-' + mixLast.stage, { from: mixLast.from, to: mixLast.to, overlap: e.overlap, synced: e.synced, reason: mixLast.reason });
      clearTimeout(mixTimer);
      if (e.stage === 'start') {
        mixRun = { to: e.to || '', title: titleFor(e.to) };
        if (e.to) sendArt(e.to);
        /* should the app never say how it ended, the line is cleared anyway */
        mixTimer = setTimeout(function () { if (mixRun) { mixRun = null; redraw(); } }, Number(window.__ytmMixStuckMs) || ((Number(e.overlap) > 0 ? Number(e.overlap) : 15) + 20) * 1000);
      } else {
        /* "done" may come just before "advanced": the song is remembered a moment longer */
        if (mixRun && e.stage === 'done') mixedTo = { id: mixRun.to, until: Date.now() + 3000 };
        mixRun = null;
      }
      redraw();
      return;
    }
    if (e.type === 'advanced') {
      var mixed = !!(mixRun && (!mixRun.to || mixRun.to === e.id)) || !!(mixedTo && mixedTo.id === e.id && Date.now() < mixedTo.until);
      /* one that is still being held back goes first, so the page hears of them in order */
      if (heldAdvance) releaseAdvance(null);
      mixedTo = null;
      if (mixRun) { mixRun = null; clearTimeout(mixTimer); }
      cur = { id: e.id || '', dur: e.id ? durOf(e.id) : 0, t: 0, t0: 0, wantPlay: true, retried: false, progress: '', lookup: '', local: e.id ? downloaded(e.id) : false };
      sendArt(cur.id);
      if (mixed) {
        heldAdvance = e;
        heldTimer = setTimeout(function () { releaseAdvance(null); }, 700);
        return;
      }
      return toPage(e);
    }
    if (e.type === 'resync') {
      /* the page was loaded again while the app played on */
      cur.lookup = '';
      if (cur.progress) cur.progress = '';
      if (typeof e.t === 'number') cur.t = e.t;
      plog('W', 'resync', { id: e.id || '', t: e.t, playing: !!e.playing });
      toPage(e);
      redraw();
      return;
    }
    if (e.type === 'time' || e.type === 'ready') {
      /* The address was found and the song is here: the waiting line goes away. */
      var lookupWas = !!cur.lookup;
      cur.lookup = '';
      /* The player can report about twice the real length for this kind of file. The length the
         PC gave is used; without one the page keeps to the length from its song list. */
      /* With no length known from the list or the PC (the first song after the app starts), the
         app's own measured length is used once it has one. */
      if (cur.dur > 0) e.dur = cur.dur;
      else if (!(e.exact === true && e.dur > 0)) delete e.dur;
      /* the line said "fetching the song": once the song plays it must go */
      if (lookupWas) redrawSoon();
      if (e.type === 'time') {
        if (heldAdvance && typeof e.t === 'number') releaseAdvance(e.t);
        if (cur.fresh && typeof e.t === 'number') { cur.fresh = false; cur.t0 = e.t; }
        if (typeof e.t === 'number') {
          if (e.t > cur.t0 + 3) cur.retried = false;
          cur.t = e.t;
        }
        if (cur.progress) setProgress('');
      }
      return toPage(e);
    }
    if (e.type === 'state') {
      if (e.playing && cur.progress) { cur.progress = ''; toPage(e); redraw(); return; }
      return toPage(e);
    }
    if (e.type === 'error') {
      var id = e.id || cur.id;
      if (id && cur.id && id !== cur.id) {
        /* about some other song (one fetched ahead): not the current song's trouble */
        plog('W', 'native-error-other', { id: id, message: String(e.message || '').slice(0, 160) });
        return;
      }
      cur.lookup = '';
      if (!cur.id) return toPage(e);
      var message = String(e.message || '');
      if (cur.progress) cur.progress = '';
      plog('W', 'native-error-first', { id: cur.id, message: message.slice(0, 160), retried: cur.retried ? 1 : 0, local: cur.local ? 1 : 0 });
      if (cur.local && message === 'stored file is missing') {
        /* The page thought the app had this song stored. It has not: take it off the list and
           play it from the PC instead. */
        try { if (P && P.dlForget) P.dlForget(cur.id); } catch (x4) {}
        try {
          var o = stored();
          if (o[cur.id]) { delete o[cur.id]; localStorage.setItem('ytm_dl', JSON.stringify(o)); }
        } catch (x5) {}
        return again(e, true);
      }
      /* a stored song does not come over the network: nothing to try again */
      if (!cur.retried && !cur.local && networkTrouble(message)) return again(e, false);
      cur.retried = false;
      return toPage(e);
    }
    return toPage(e);
  }
  /* The same song once more from where it had got to - if the PC is there. If it is not, that is
     said plainly instead of passing an error on (which would make the page skip ahead). */
  function again(e, fresh) {
    var id = cur.id, at = Math.floor(cur.t || 0), play = cur.wantPlay;
    pcProbe().then(function (up) {
      if (cur.id !== id) return;
      if (!up) { cur.id = ''; refuseOffline(id); return; }
      sendLoadSong(id, at);
      cur.retried = true;
      cur.wantPlay = play;
      if (play) raw({ cmd: 'play' });
    });
  }
  try {
    Object.defineProperty(window, '__ytmNativeEvent', {
      configurable: true,
      get: function () { return onAppEvent; },
      set: function (f) { pageHandler = f; }
    });
  } catch (e) {}

  /* ---------------------------------------------------------- sound settings -> the app's engine
     The app applies surround (two impulse responses, made here by the bundled server code),
     the five-band equaliser and loudness balancing itself. Each is sent once at the start and
     again only when it has changed. */
  var sent = { fx: null, eq: null, norm: null, mix: null, mixIr: null, profile: null }, fxSeq = 0, mixSeq = 0, soundTimer = null, bandState = null;
  function wavEnergy(u) {
    /* sum of squares of each channel of a 16-bit WAV, samples scaled to -1..1 */
    var dv = new DataView(u.buffer, u.byteOffset, u.byteLength), pos = 12, ch = 2, e = [0, 0];
    while (pos + 8 <= u.length) {
      var name = String.fromCharCode(u[pos], u[pos + 1], u[pos + 2], u[pos + 3]), size = dv.getUint32(pos + 4, true);
      if (name === 'fmt ') {
        ch = dv.getUint16(pos + 10, true);
        if (dv.getUint16(pos + 22, true) !== 16 || ch < 1 || ch > 2) throw new Error('unexpected impulse response format');
      }
      if (name === 'data') {
        var end = Math.min(u.length, pos + 8 + size);
        for (var o = pos + 8, i = 0; o + 1 < end; o += 2, i++) { var v = dv.getInt16(o, true) / 32768; e[ch === 1 ? 0 : i % 2] += v * v; }
        if (ch === 1) e[1] = e[0];
        return e;
      }
      pos += 8 + size + (size % 2);
    }
    throw new Error('impulse response is not a WAV file');
  }
  /* The page's matchGain(): surround on is made as loud as surround off. */
  function makeupFor(uL, uR, headroom) {
    var a = wavEnergy(uL), b = wavEnergy(uR);
    var e = (a[0] + b[0] + a[1] + b[1]) / 2;
    return (e > 0 ? Math.min(8, Math.max(0.25, 1 / Math.sqrt(e))) : 1) * headroom;
  }
  function getIr(path) {
    return B.dispatch({ method: 'GET', url: path, headers: {}, body: null }).then(function (r) {
      if (r.status !== 200) throw new Error('HTTP ' + r.status);
      return r.body;
    });
  }
  function sendFx() {
    var headroom = P.headroom();
    if (!P.surround()) {
      fxSeq++;
      if (sent.fx === 'off') return;
      sent.fx = 'off';
      /* Surround off still sits at the page's headroom level, so on and off are equally loud. */
      raw({ cmd: 'fx', key: 'off', surround: false, irL: null, irR: null, makeup: headroom });
      return;
    }
    /* Band modes (test build): the app separates the song with its model. Speakers: no
       impulse responses. Headphones: one pair per separated part. */
    var band = P.band ? P.band() : null;
    if (band === 'band') {
      fxSeq++;
      if (sent.fx === 'band') return;
      sent.fx = 'band';
      raw({ cmd: 'fx', key: 'band', surround: true, mode: 'band', irL: null, irR: null, makeup: headroom });
      return;
    }
    if (band === 'bandHead') {
      var bq = P.bandIrQuery(), bkey = 'bandHead' + bq;
      if (sent.fx === bkey) { fxSeq++; return; }
      var bmine = ++fxSeq;
      var parts = ['drums', 'bass', 'other', 'vocals'], urls = [];
      var bmx = P.bandMix ? P.bandMix() : null;
      parts.forEach(function (n) { var pq = bandPosQuery(bmx, n); urls.push('/api/ir/band/' + n + '/L.wav' + bq + pq, '/api/ir/band/' + n + '/R.wav' + bq + pq); });
      Promise.all(urls.map(getIr)).then(function (r) {
        if (bmine !== fxSeq) return;
        sent.fx = bkey;
        var ir = {}, e = 0;
        parts.forEach(function (n, i) {
          ir[n] = { L: B.b64(r[2 * i]), R: B.b64(r[2 * i + 1]) };
          var a = wavEnergy(r[2 * i]), b = wavEnergy(r[2 * i + 1]);
          e += (a[0] + b[0] + a[1] + b[1]) / 2 / parts.length;
        });
        var mk = (e > 0 ? Math.min(8, Math.max(0.25, 1 / Math.sqrt(e))) : 1) * headroom;
        raw({ cmd: 'fx', key: bkey, surround: true, mode: 'bandHead', bandIr: ir, irL: null, irR: null, makeup: mk });
      }, function (err) {
        if (bmine !== fxSeq) return;
        try { console.warn('standalone: band responses not available (' + ((err && err.message) || err) + '), playing without'); } catch (x) {}
        sent.fx = 'off';
        raw({ cmd: 'fx', key: 'off', surround: false, irL: null, irR: null, makeup: headroom });
      });
      return;
    }
    /* Stage mode: no impulse responses, the app splits and places the sound itself. */
    var st = P.stage ? P.stage() : null;
    if (st) {
      var sk = 'stage-' + st.width + '-' + st.depth + '-' + st.vocal;
      fxSeq++;
      if (sent.fx === sk) return;
      sent.fx = sk;
      raw({ cmd: 'fx', key: sk, surround: true, mode: 'stage', stage: { width: st.width, depth: st.depth, vocal: st.vocal }, irL: null, irR: null, makeup: headroom });
      return;
    }
    var pathL = P.irUrl('L'), pathR = P.irUrl('R');
    var key = pathL.split('?')[1] || pathL;
    if (sent.fx === key) { fxSeq++; return; }
    var mine = ++fxSeq;
    Promise.all([getIr(pathL), getIr(pathR)]).then(function (r) {
      if (mine !== fxSeq) return;
      sent.fx = key;
      raw({ cmd: 'fx', key: key, surround: true, irL: B.b64(r[0]), irR: B.b64(r[1]), makeup: makeupFor(r[0], r[1], headroom) });
    }, function (err) {
      if (mine !== fxSeq) return;
      try { console.warn('standalone: surround setting not available (' + ((err && err.message) || err) + '), playing without'); } catch (e) {}
      sent.fx = 'off';
      raw({ cmd: 'fx', key: 'off', surround: false, irL: null, irR: null, makeup: headroom });
    });
  }
  /* Band mixer: volumes, solo, mute and positions per part. Sent apart from fx so that the app
     applies them without starting over (and without separating again). For headphones the
     positions are made into responses here, and sent along when they change. */
  var BAND_NAMES = ['drums', 'bass', 'other', 'vocals'];
  function bandPosQuery(bm, n) {
    var p = bm && bm.parts && bm.parts[n];
    if (!p) return '';
    return '&az=' + Math.round(p.az) + '&w=' + Math.round(p.width) + '&d=' + Math.round(p.depth) +
      ((n === 'drums' || n === 'bass') && bm.low ? '&lo=' + Math.round(bm.low) : '');
  }
  function sendBandMix() {
    var bm = P.bandMix ? P.bandMix() : null;
    if (!bm || !P.surround()) { sent.mix = null; return; }
    var parts = {};
    BAND_NAMES.forEach(function (n) {
      var p = bm.parts[n];
      parts[n] = { gain: p.gain / 100, solo: !!p.solo, mute: !!p.mute, az: p.az, depth: p.depth, width: p.width };
    });
    var key = bm.mode + JSON.stringify(parts) + '|' + (bm.low || 0) + '|' + (bm.mode === 'bandHead' ? P.bandIrQuery() : '');
    if (sent.mix === key) return;
    if (bm.mode !== 'bandHead') {
      sent.mix = key;
      raw({ cmd: 'bandMix', mode: bm.mode, parts: parts });
      return;
    }
    var bq = P.bandIrQuery(), irKey = bq + BAND_NAMES.map(function (n) { return bandPosQuery(bm, n); }).join('|');
    if (sent.mixIr === irKey) {
      sent.mix = key;
      raw({ cmd: 'bandMix', mode: bm.mode, parts: parts });
      return;
    }
    var mine = ++mixSeq;
    var urls = [];
    BAND_NAMES.forEach(function (n) { var pq = bandPosQuery(bm, n); urls.push('/api/ir/band/' + n + '/L.wav' + bq + pq, '/api/ir/band/' + n + '/R.wav' + bq + pq); });
    Promise.all(urls.map(getIr)).then(function (r) {
      if (mine !== mixSeq) return;
      var ir = {};
      BAND_NAMES.forEach(function (n, i) { ir[n] = { L: B.b64(r[2 * i]), R: B.b64(r[2 * i + 1]) }; });
      sent.mix = key;
      sent.mixIr = irKey;
      raw({ cmd: 'bandMix', mode: bm.mode, parts: parts, ir: ir });
    }, function (err) {
      try { console.warn('standalone: band mixer responses not available (' + ((err && err.message) || err) + ')'); } catch (x) {}
    });
  }
  function glueStatus(surround) { return cur.progress || cur.lookup || (mixRun ? '轉場中 → ' + (mixRun.title || '下一首') : '') || (surround ? (P && P.band && P.band() ? (bandStatusText() || 'App：樂團模式') : (P && P.stage && P.stage() ? 'App：舞台模式' : 'App：手機處理環繞')) : 'App：環繞關閉'); }
  function bandStatusText() {
    if (!(P && P.band && P.band()) || !bandState) return '';
    var s = bandState.state;
    if (s === 'loading') return '樂團：分軌中…';
    if (s === 'running') return '樂團中（每段 ' + (+bandState.seconds || 0).toFixed(1) + ' 秒，' + (+bandState.realtime || 0).toFixed(1) + '× 即時）';
    if (s === 'late') return '樂團：來不及，暫時播原音';
    if (s === 'failed') return /model not in the app|does not load/.test(bandState.message || '') ? '樂團：模型載入失敗（播原音）' : '樂團暫停（模型無法執行或記憶體不足，重試中；先播原音）';
    return '';
  }
  function sendPageInfo() {
    if (!P) return;
    var info = { cmd: 'pageInfo', profile: P.profile ? String(P.profile()) : '', full: P.fullOpen ? !!P.fullOpen() : false };
    var k = JSON.stringify(info);
    if (sent.profile === k) return;
    sent.profile = k;
    raw(info);
  }
  function sendSound() {
    if (!P) return;
    try {
      var g = P.eqGains(), gk = JSON.stringify(g);
      if (sent.eq !== gk) { sent.eq = gk; raw({ cmd: 'eq', gains: g }); }
      var n = { cmd: 'normTarget', on: !!P.normOn(), target: P.normTarget() }, nk = JSON.stringify(n);
      if (sent.norm !== nk) { sent.norm = nk; raw(n); }
      sendFx();
      sendBandMix();
      sendPageInfo();
    } catch (e) { try { console.error('standalone: sound settings', e); } catch (x) {} }
  }
  function soundSoon() {
    clearTimeout(soundTimer);
    soundTimer = setTimeout(sendSound, 400);
  }

  /* ---------------------------------------------------------- settings sheet: PC address, diagnosis */
  function clock(ms) { try { return new Date(ms).toTimeString().slice(0, 8); } catch (e) { return '?'; } }
  function diagText() {
    var out = [];
    out.push('建置時間 ' + (B.built || '?'));
    out.push('現在 ' + clock(Date.now()) + '  目前歌曲 ' + (cur.id || '(無)') + '  位置 ' + Math.round(cur.t || 0) + ' s' + (cur.local ? '  (已存在手機)' : ''));
    out.push('電腦位址 ' + B.pcBase());
    out.push('連得到電腦 ' + (pc.up === null ? '尚未測試' : (pc.up ? '是' : '否')) + (pc.at ? '  上次測試 ' + clock(pc.at) + '  ' + pc.ms + ' ms' : '') + (pc.error ? '  ' + pc.error : ''));
    var nextId = queuedIds[0] || '';
    out.push('自動混音 ' + (mixing() ? '開' : '關') + '  分析資料：目前這首 ' + (cur.id && mixKnown[cur.id] ? '有' : '無') + '  下一首 ' + (nextId && mixKnown[nextId] ? '有' : '無') + (mixRun ? '  轉場中 → ' + mixRun.to : ''));
    if (mixLast) out.push('最近的混音事件 ' + clock(mixLast.at) + '  ' + mixLast.stage + '  ' + mixLast.from + ' → ' + mixLast.to + (mixLast.reason ? '  ' + mixLast.reason : ''));
    if (lastError) out.push('最近的播放錯誤 ' + clock(lastError.at) + '  ' + lastError.id + '  ' + lastError.message);
    out.push('除錯紀錄轉送 已送 ' + dbgStats.sent + '  失敗 ' + dbgStats.failed + '  排隊 ' + dbgQueue.length + '  丟棄 ' + dbgStats.dropped + (dbgStats.lastError ? '  最後錯誤: ' + dbgStats.lastError : ''));
    out.push('最近的網路呼叫（經由 App）：');
    (B.bridgeLog || []).slice(-10).forEach(function (c) {
      out.push('  ' + clock(c.at) + ' ' + c.method + ' ' + c.host + c.path + '  ' + (c.error ? '錯誤: ' + c.error : 'HTTP ' + c.status) + '  ' + c.ms + ' ms');
    });
    out.push('');
    out.push('帳號 ' + (accountOn() ? '已登入' : '未登入') + '　歷史紀錄 ' + (function () {
      try { var v = JSON.parse(localStorage.getItem('ytm_history') || '[]'); return ((v && v.length) || 0) + ' 筆'; } catch (e) { return '讀不到'; }
    })());
    out.push('App 紀錄：');
    out.push(diagApp || '（等待 App 回覆…）');
    return out.join('\n');
  }
  function diagShow() { if (diagBox) diagBox.textContent = diagText(); }
  var BTN = 'padding:9px 14px;border-radius:10px;border:1px solid rgba(255,255,255,.25);background:transparent;color:inherit;font:inherit';
  /* Reports to a PC receiver (its own address, not the PC address above: setting it never
     makes the page use a PC). The app keeps the address and sends; this only asks it to. */
  var reportUi = null;
  function reportControls(panel) {
    var h = document.createElement('h3');
    h.textContent = '診斷報告傳到電腦';
    panel.appendChild(h);
    var input = document.createElement('input');
    input.type = 'url';
    input.placeholder = 'http://100.66.200.10:8790';
    input.setAttribute('aria-label', '報告接收位址');
    input.setAttribute('style', 'width:100%;box-sizing:border-box;padding:9px 10px;border-radius:10px;border:1px solid rgba(255,255,255,.25);background:rgba(0,0,0,.25);color:inherit;font:inherit;margin:4px 0 8px');
    panel.appendChild(input);
    var row = document.createElement('div');
    row.setAttribute('style', 'display:flex;flex-wrap:wrap;gap:8px;margin:0 0 6px');
    var mk = function (text, fn) {
      var b = document.createElement('button');
      b.type = 'button';
      b.setAttribute('style', BTN);
      b.textContent = text;
      b.addEventListener('click', fn);
      row.appendChild(b);
      return b;
    };
    var note = document.createElement('p');
    note.setAttribute('style', 'margin:0 0 10px;opacity:.8;font-size:13px');
    note.textContent = '留空＝不傳。設定後會自動傳送：App 進入背景、每首歌結束（至少間隔 2 分鐘）、上次異常結束。';
    mk('儲存位址', function () { note.textContent = '儲存中…'; raw({ cmd: 'report', action: 'set', base: input.value.trim() }); });
    mk('測試連線', function () { note.textContent = '測試中…'; raw({ cmd: 'report', action: 'ping', base: input.value.trim() }); });
    mk('立即傳送報告', function () { note.textContent = '傳送中…'; raw({ cmd: 'report', action: 'set', base: input.value.trim() }); setTimeout(function () { raw({ cmd: 'report', action: 'send' }); }, 300); });
    panel.appendChild(row);
    panel.appendChild(note);
    var hr = document.createElement('label');
    hr.setAttribute('style', 'display:flex;gap:8px;align-items:center;margin:0 0 12px');
    var cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = true;
    cb.addEventListener('change', function () { raw({ cmd: 'headroom', on: !!cb.checked }); });
    hr.appendChild(cb);
    hr.appendChild(document.createTextNode('自動保留餘裕（避免低音重時人聲被壓低，最多降 3 dB）'));
    panel.appendChild(hr);
    var NAMES = { set: '儲存', ping: '測試連線', send: '傳送報告', get: '' };
    reportUi = {
      update: function (e) {
        if (e.type === 'headroom') { cb.checked = !!e.on; return; }
        if (e.action === 'get') { if (document.activeElement !== input) input.value = e.base || ''; return; }
        if (e.action === 'set' && e.ok) { input.value = e.base || ''; note.textContent = e.base ? '已儲存：' + e.base : '已關閉報告傳送'; return; }
        if (e.action === 'set' && !e.ok) { note.textContent = '沒有儲存：' + (e.message || ''); return; }
        if (e.action === 'ping') { note.textContent = e.ok ? '連線成功' : '連線失敗：' + (e.message || ''); return; }
        note.textContent = (NAMES[e.action] || e.action) + (e.ok ? '：成功' : '：失敗 ' + (e.message || ''));
      }
    };
    raw({ cmd: 'report', action: 'get' });
    raw({ cmd: 'headroom' });
  }
  function sheetExtras(panel) {
    try {
      /* the ambient light (only where the app is there to talk to the controller) */
      var hasApp = false;
      try { hasApp = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ytm); } catch (e0) { hasApp = false; }
      if (hasApp) {
        /* folded away until opened: most people never use it */
        var det = document.createElement('details');
        det.setAttribute('style', 'margin:10px 0');
        var sum = document.createElement('summary');
        sum.textContent = '氛圍燈';
        sum.setAttribute('style', 'font-size:18px;font-weight:600;cursor:pointer;padding:6px 0');
        det.appendChild(sum);
        lightControls(det);
        panel.appendChild(det);
      }

      var ah = document.createElement('h3');
      ah.textContent = 'YouTube Music 帳號';
      panel.appendChild(ah);
      var arow = document.createElement('div');
      arow.setAttribute('style', 'display:flex;gap:8px;align-items:center;margin:6px 0');
      var anote = document.createElement('span');
      anote.setAttribute('style', 'flex:1;opacity:.8');
      anote.textContent = accountOn() ? '已登入' : '未登入（只能匿名播放）';
      var abtn = document.createElement('button');
      abtn.type = 'button';
      abtn.setAttribute('style', BTN);
      abtn.textContent = accountOn() ? '登出' : '登入';
      abtn.addEventListener('click', function () {
        abtn.disabled = true;
        anote.textContent = accountOn() ? '正在登出…' : '登入中…';
        raw({ cmd: accountOn() ? 'logout' : 'login' });
        setTimeout(function () { abtn.disabled = false; anote.textContent = accountOn() ? '已登入' : '未登入（只能匿名播放）'; }, 1500);
      });
      arow.appendChild(anote);
      arow.appendChild(abtn);
      panel.appendChild(arow);

      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = '診斷';
      b.setAttribute('style', 'display:block;margin:14px 0 6px;' + BTN);
      var box = document.createElement('pre');
      box.setAttribute('style', 'display:none;max-height:45vh;overflow:auto;-webkit-overflow-scrolling:touch;white-space:pre-wrap;word-break:break-all;font:11px/1.45 ui-monospace,Menlo,Consolas,monospace;background:rgba(0,0,0,.45);border-radius:8px;padding:8px;margin:0 0 8px;user-select:text;-webkit-user-select:text');
      b.addEventListener('click', function () {
        diagBox = box;
        diagApp = '';
        box.style.display = 'block';
        diagShow();
        raw({ cmd: 'diag' });
        setTimeout(function () { if (diagBox === box && !diagApp) { diagApp = '（App 沒有回覆 diag）'; diagShow(); } }, 4000);
      });
      panel.appendChild(b);
      panel.appendChild(box);
      if (hasApp) reportControls(panel);
    } catch (e) {}
  }

  /* ---------------------------------------------------------- music-reactive ambient light
     The app's player drives the car's light from the music; the page keeps the settings, sends
     them whole ({ cmd: 'light', ... }) on every change and once at start, and shows the state the
     app reports ({ type: 'light', state, name, detail }). */
  var LIGHT_KEY = 'ytm_light';
  var LIGHT_DEFAULT = { on: false, style: 'beat', level: 1.0, floor: 0.12, hue: -1, offsetMs: -50, colourMode: 'song', saturation: 1, intensity: 1, zones: 'all' };
  /* where the colour comes from: the song's cover art, a slow drift, or one fixed hue */
  var LIGHT_COLOURS = [['song', '依歌曲'], ['drift', '緩慢變換'], ['fixed', '固定']];
  var LIGHT_STYLES = [['soft', '柔和'], ['beat', '節拍'], ['colour', '多彩']];
  var lightState = { state: 'off', name: null, detail: null };
  var lightLastSent = 0, lightTimer = null, lightStatusEl = null;
  function clampNum(v, lo, hi, def) { v = Number(v); return isFinite(v) ? Math.max(lo, Math.min(hi, v)) : def; }
  function lightSettings() {
    var o = null;
    try { o = JSON.parse(localStorage.getItem(LIGHT_KEY) || 'null'); } catch (e) { o = null; }
    o = o && typeof o === 'object' ? o : {};
    var hue = Number(o.hue), fixedHue = Number(o.fixedHue);
    /* settings saved before there was a choice: a drifting colour (-1) becomes "by song", a chosen
       hue stays fixed */
    var mode = o.colourMode === 'song' || o.colourMode === 'drift' || o.colourMode === 'fixed' ? o.colourMode : (isFinite(hue) && hue >= 0 ? 'fixed' : 'song');
    if (!(isFinite(fixedHue) && fixedHue >= 0)) fixedHue = isFinite(hue) && hue >= 0 ? hue : 200;
    fixedHue = Math.round(Math.min(360, fixedHue));
    return {
      on: o.on === true,
      style: o.style === 'soft' || o.style === 'beat' || o.style === 'colour' ? o.style : LIGHT_DEFAULT.style,
      level: Math.round(clampNum(o.level, 0.1, 1, LIGHT_DEFAULT.level) * 100) / 100,
      floor: Math.round(clampNum(o.floor, 0, 0.5, LIGHT_DEFAULT.floor) * 100) / 100,
      colourMode: mode,
      fixedHue: fixedHue,
      /* -1 unless fixed: what builds of the app that know nothing of colourMode go by */
      hue: mode === 'fixed' ? fixedHue : -1,
      offsetMs: Math.round(clampNum(o.offsetMs, -300, 500, LIGHT_DEFAULT.offsetMs)),
      saturation: Math.round(clampNum(o.saturation, 0, 1, LIGHT_DEFAULT.saturation) * 100) / 100,
      intensity: Math.round(clampNum(o.intensity, 0, 1, LIGHT_DEFAULT.intensity) * 100) / 100,
      zones: o.zones === 'split' ? 'split' : 'all'
    };
  }
  function lightSave(next) {
    try { localStorage.setItem(LIGHT_KEY, JSON.stringify(next)); } catch (e) {}
  }
  function sendLight() {
    var v = lightSettings();
    lightLastSent = Date.now();
    raw({ cmd: 'light', on: v.on, style: v.style, level: v.level, floor: v.floor, hue: v.hue, offsetMs: v.offsetMs, colourMode: v.colourMode, saturation: v.saturation, intensity: v.intensity, zones: v.zones });
  }
  /* while a slider is dragged: at most one message per 100 ms, the last value always goes out */
  function lightSendSoon() {
    var wait = 100 - (Date.now() - lightLastSent);
    if (wait <= 0) { clearTimeout(lightTimer); lightTimer = null; sendLight(); return; }
    if (!lightTimer) lightTimer = setTimeout(function () { lightTimer = null; sendLight(); }, wait);
  }
  function lightSendNow() { clearTimeout(lightTimer); lightTimer = null; sendLight(); }
  function lightStatusText() {
    var st = lightState.state;
    if (st === 'searching') return '尋找中';
    if (st === 'connecting') return '連線中';
    if (st === 'connected') return '已連線：' + (lightState.name || '');
    if (st === 'error') return '錯誤：' + (lightState.detail || '原因不明');
    return '未開啟';
  }
  function lightShowStatus() { try { if (lightStatusEl) lightStatusEl.textContent = lightStatusText(); } catch (e) {} }
  function lightControls(panel) {
    var v = lightSettings();
    var change = function (key, val, how) {
      var next = lightSettings();
      next[key] = val;
      lightSave(next);
      if (how === 'drag') lightSendSoon(); else lightSendNow();
    };
    var mkRow = function () {
      var r = document.createElement('div');
      r.setAttribute('style', 'display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0');
      return r;
    };
    var label = function (t) { var x = document.createElement('span'); x.textContent = t; x.setAttribute('style', 'min-width:5.5em'); return x; };
    var button = function (t, on, mark) {
      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = t;
      b.setAttribute('data-light', mark);
      b.setAttribute('aria-pressed', on ? 'true' : 'false');
      b.setAttribute('style', BTN + (on ? ';background:rgba(255,255,255,.18);border-color:rgba(255,255,255,.6)' : ''));
      return b;
    };
    var press = function (b, on) {
      b.setAttribute('aria-pressed', on ? 'true' : 'false');
      b.setAttribute('style', BTN + (on ? ';background:rgba(255,255,255,.18);border-color:rgba(255,255,255,.6)' : ''));
    };
    /* the switch, and what the app says about the connection */
    var r1 = mkRow();
    r1.appendChild(label('隨音樂變化'));
    var sw = button(v.on ? '開' : '關', v.on, 'on');
    sw.addEventListener('click', function () {
      var on = !lightSettings().on;
      sw.textContent = on ? '開' : '關';
      press(sw, on);
      change('on', on, 'now');
    });
    r1.appendChild(sw);
    var st = document.createElement('span');
    st.setAttribute('data-light', 'status');
    st.setAttribute('style', 'opacity:.8');
    lightStatusEl = st;
    lightShowStatus();
    r1.appendChild(st);
    panel.appendChild(r1);
    /* sliders: sent while dragging (at most every 100 ms) and once more when let go */
    var slider = function (name, mark, min, max, step, value, show, key, toValue) {
      var r = mkRow();
      r.appendChild(label(name));
      var inp = document.createElement('input');
      inp.type = 'range';
      inp.min = String(min); inp.max = String(max); inp.step = String(step); inp.value = String(value);
      inp.setAttribute('data-light', mark);
      inp.setAttribute('aria-label', name);
      inp.setAttribute('style', 'flex:1;min-width:8em;height:24px');
      var out = document.createElement('span');
      out.setAttribute('style', 'min-width:4.5em;text-align:right');
      out.textContent = show(value);
      inp.addEventListener('input', function () { out.textContent = show(Number(inp.value)); change(key, toValue(Number(inp.value)), 'drag'); });
      inp.addEventListener('change', function () { out.textContent = show(Number(inp.value)); change(key, toValue(Number(inp.value)), 'now'); });
      r.appendChild(inp);
      r.appendChild(out);
      panel.appendChild(r);
      return { row: r, input: inp, out: out };
    };
    var pct = function (x) { return Math.round(x) + ' %'; };
    /* intensity: how much the light follows the beat; at 0 it only takes the song's colour */
    slider('強度', 'intensity', 0, 100, 1, Math.round(v.intensity * 100), pct, 'intensity', function (x) { return Math.round(Math.max(0, Math.min(100, x))) / 100; });
    var ihint = document.createElement('p');
    ihint.setAttribute('data-light', 'intensity-hint');
    ihint.textContent = '0% 時只依歌曲換顏色，不跟隨節奏';
    panel.appendChild(ihint);
    /* zones: zone 1 is the upper lights (dash, doors), zone 2 the footwell */
    var rz = mkRow();
    rz.appendChild(label('分區'));
    var zoneBtns = [];
    var zhint = document.createElement('p');
    zhint.setAttribute('data-light', 'zones-hint');
    zhint.textContent = '上方燈跟旋律與人聲，腳踏燈跟低音鼓點';
    var showZoneHint = function (z) { zhint.style.display = z === 'split' ? '' : 'none'; };
    [['all', '全部一起'], ['split', '上方與腳踏分開']].forEach(function (x) {
      var b = button(x[1], v.zones === x[0], 'zones-' + x[0]);
      b.addEventListener('click', function () {
        zoneBtns.forEach(function (o) { press(o.b, o.v === x[0]); });
        showZoneHint(x[0]);
        change('zones', x[0], 'now');
      });
      zoneBtns.push({ b: b, v: x[0] });
      rz.appendChild(b);
    });
    panel.appendChild(rz);
    showZoneHint(v.zones);
    panel.appendChild(zhint);
    /* style */
    var r2 = mkRow();
    r2.appendChild(label('風格'));
    var styleBtns = [];
    LIGHT_STYLES.forEach(function (x) {
      var b = button(x[1], v.style === x[0], 'style-' + x[0]);
      b.addEventListener('click', function () {
        styleBtns.forEach(function (o) { press(o.b, o.v === x[0]); });
        change('style', x[0], 'now');
      });
      styleBtns.push({ b: b, v: x[0] });
      r2.appendChild(b);
    });
    panel.appendChild(r2);
    slider('最大亮度', 'level', 10, 100, 1, Math.round(v.level * 100), pct, 'level', function (x) { return Math.round(Math.max(10, Math.min(100, x))) / 100; });
    slider('最低亮度', 'floor', 0, 50, 1, Math.round(v.floor * 100), pct, 'floor', function (x) { return Math.round(Math.max(0, Math.min(50, x))) / 100; });
    /* colour: from the song's cover art, a slow drift, or one hue chosen with a slider (shown in a
       swatch, and only when fixed) */
    var r3 = mkRow();
    r3.appendChild(label('顏色'));
    var colourBtns = [];
    LIGHT_COLOURS.forEach(function (x) {
      var b = button(x[1], v.colourMode === x[0], 'colour-' + x[0]);
      colourBtns.push({ b: b, v: x[0] });
      r3.appendChild(b);
    });
    panel.appendChild(r3);
    /* saturation: applies to every colour mode */
    slider('飽和度', 'saturation', 0, 100, 1, Math.round(v.saturation * 100), pct, 'saturation', function (x) { return Math.round(Math.max(0, Math.min(100, x))) / 100; });
    var hueStart = v.fixedHue;
    var hue = slider('色相', 'hue', 0, 360, 1, hueStart, function (x) { return Math.round(x) + '°'; }, 'fixedHue', function (x) { return Math.round(Math.max(0, Math.min(360, x))); });
    var sw2 = document.createElement('span');
    sw2.setAttribute('data-light', 'swatch');
    var paint = function (h) { sw2.setAttribute('style', 'display:inline-block;width:22px;height:22px;border-radius:6px;border:1px solid rgba(255,255,255,.4);background:hsl(' + Math.round(h) + ',100%,50%)'); };
    paint(hueStart);
    hue.row.appendChild(sw2);
    hue.input.addEventListener('input', function () { paint(Number(hue.input.value)); });
    var showHue = function (mode) { hue.row.style.display = mode === 'fixed' ? 'flex' : 'none'; };
    showHue(v.colourMode);
    colourBtns.forEach(function (o) {
      o.b.addEventListener('click', function () {
        colourBtns.forEach(function (x) { press(x.b, x.v === o.v); });
        showHue(o.v);
        change('colourMode', o.v, 'now');
      });
    });
    /* timing */
    slider('燈光延遲', 'offset', -300, 500, 10, v.offsetMs, function (x) { return (x > 0 ? '+' : '') + Math.round(x) + ' ms'; }, 'offsetMs', function (x) { return Math.round(Math.max(-300, Math.min(500, x)) / 10) * 10; });
    var hint = document.createElement('p');
    hint.textContent = '燈光比聲音早就往右調';
    panel.appendChild(hint);
  }
  /* ---------------------------------------------------------- cover art for the light
     The app takes each song's light colour from its cover. It is told where the cover of the
     current song and of the next one is, once per song (again only if the address changes). */
  var artSent = {};
  /* a square image of about 300 px where the address says its size; video stills as 480x360 */
  function artUrl(u) {
    u = String(u || '');
    if (u.indexOf('//') === 0) u = 'https:' + u;
    if (/^https?:\/\/[^\/]*(googleusercontent\.com|ggpht\.com)\//.test(u)) return /=[whs]\d+[^\/]*$/.test(u) ? u.replace(/=[whs]\d+[^\/]*$/, '=w300-h300-l90-rj') : u;
    var m = /i\.ytimg\.com\/vi(?:_webp)?\/([\w-]{11})\//.exec(u);
    if (m) return 'https://i.ytimg.com/vi/' + m[1] + '/hqdefault.jpg';
    return /^https:\/\//.test(u) ? u : '';
  }
  function sendArt(id) {
    if (!id || !hasAppHandler()) return;
    var src = '';
    try { src = (P && P.thumbOf && P.thumbOf(id)) || ''; } catch (e) { src = ''; }
    if (!src && sentMeta[id]) src = sentMeta[id].artwork || '';
    var url = artUrl(src);
    if (!url || artSent[id] === url) return;
    artSent[id] = url;
    raw({ cmd: 'lightArt', id: id, url: url });
  }
  function hasAppHandler() {
    try { return !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ytm); } catch (e) { return false; }
  }

  /* Called by the page (see build-app.js). */
  /* The app calls this when the sign-in state changes: the home feed is then asked for again,
     so it comes back personal (or anonymous again). */
  window.__ytmAccountChanged = function (on) {
    plog('I', 'account', { on: !!on });
    if (on) closePrompt();
    try { if (P && P.homeQuiet) P.homeQuiet(); } catch (e) {}
  };

  window.__ytmGlue = {
    /* nativePost(): true = taken care of here */
    post: function (m) {
      if (!m || typeof m.cmd !== 'string') return false;
      if (m.cmd === 'load') { refused = false; return onLoad(m); }
      if (m.cmd === 'play' && refused) {
        /* the page presses play right after choosing the song: there is nothing to play, and the
           song before it must not start again */
        setTimeout(function () { try { if (pageHandler) pageHandler({ type: 'state', playing: false }); } catch (e) {} }, 0);
        return true;
      }
      if (m.cmd === 'play') cur.wantPlay = true;
      else if (m.cmd === 'pause') cur.wantPlay = false;
      else if (m.cmd === 'seek' && typeof m.t === 'number') cur.t = m.t;
      /* While an "advanced" is held back the page still believes the old song is playing; what it
         says about that song (lock screen, length) is dropped here - the app has moved on. */
      if ((m.cmd === 'meta' || m.cmd === 'dur') && heldAdvance && m.id && cur.id && m.id !== cur.id) {
        plog('I', 'stale-' + m.cmd, { id: m.id, cur: cur.id });
        return true;
      }
      if (m.cmd === 'queue') return onQueue(m);
      if (m.cmd === 'dl') return onDownload(m);
      return false;
    },
    /* the page hands over what the glue may use, once, while it starts */
    page: function (p) {
      P = p;
      historyPull();
      /* not signed in: offered once, a moment after the page is up */
      setTimeout(function () { if (!accountOn()) loginPrompt('none'); }, 2500);
      homeAuto('page');
      raw({ cmd: 'config', pc: B.pcBase() });
      /* the light settings, so that the app knows them from the start */
      if (hasAppHandler()) sendLight();
      sendMix();
      setTimeout(sendSound, 0);
    },
    /* a sound setting was changed (fxApply and the loudness controls) */
    sound: soundSoon,
    pageInfo: function () { try { sendPageInfo(); } catch (e) {} },
    bandStatus: function () { return bandStatusText(); },
    /* the line under the player */
    status: function (surround) { return glueStatus(surround); },
    /* the mixing switch was moved */
    mix: sendMix,
    /* title, artist, artwork and length of a song as it was last sent to the app in a queue */
    sentMeta: function (id) { return sentMeta[id] || null; },
    /* is the app mixing into this song right now? (the page then leaves the player alone) */
    mixingInto: function (id) { return !!(mixRun && mixRun.to === id); },
    /* why the last song could not be played, for the page's own error text and toast */
    errorText: function () { return lastError && Date.now() - lastError.at < 15000 ? '無法播放：' + lastError.message : ''; },
    /* true while the PC is known to be out of reach (the home page shows a notice) */
    offline: function () { return pc.up === false && !nativeSongs(); },
    /* the page's settings sheet asks for the app-only items */
    diag: sheetExtras,
    pc: function () { return { base: B.pcBase(), up: pc.up, ms: pc.ms, at: pc.at }; },
    probe: pcProbe,
    /* for the tests: what the status line would say */
    lightStatus: lightStatusText,
    debugStats: function () { return { queued: dbgQueue.length, busy: dbgBusy, sent: dbgStats.sent, failed: dbgStats.failed, dropped: dbgStats.dropped, lastError: dbgStats.lastError }; },
    forwardDebug: forwardDebug
  };
})();
