// The header's Upload menu (templates/header.html, docs/SPEC.md FR-3.2), on every page: files
// chosen here — or dropped on the map, which sends them here as an `hmt:upload-files` event —
// upload one at a time with their progress, then show as "Processing…" until the server has
// finished them. A .zip is refused here, with a note: archives aren't imported (ADR-0039). A
// finished import leaves the menu, whatever became of it: what
// it came to is the header's Sync item's, the /sync page, whose red dot this script also keeps
// — a failure the account hasn't seen there.
//
// The server's GET /v2/uploads/active is the list of what's still processing — a phone sync's
// too — and the count of unseen failures, read every POLL_MS while anything is in flight and
// every IDLE_MS otherwise. Whenever an import finishes, or a file's upload lands, the menu
// fires `hmt:imports-changed` on window, which the map listens to (MapView.tsx) to redraw its
// list and tracks. How many are in flight, uploading or processing, it keeps in its
// `data-in-flight` attribute and announces as `hmt:imports-in-flight`, for the map's first-run
// panel (apps/web's ui/useImportsInFlight.ts).
//
// Both page shells load this one plain script (layout.html, app/app.html), so the menu works the
// same on the map and on every server-rendered page.
//
// The menu's words are the server's catalog, rendered into <script class="upload-menu__strings">.
(function () {
  'use strict';

  var POLL_MS = 2000;
  var IDLE_MS = 20000;
  // How many files one pick or drop may bring (docs/SPEC.md FR-3.1).
  var MAX_FILES = 20;
  var ACCEPT = /\.(gpx|fit|tcx)$/i;
  var ZIP = /\.zip$/i;
  // Strava's archive holds its FIT files gzipped (templates/pages/import-strava.html).
  var GZ = /\.gz$/i;

  var menu = document.querySelector('[data-upload-menu]');
  if (!menu) return;
  var strings = JSON.parse(menu.querySelector('.upload-menu__strings').textContent);
  var input = menu.querySelector('.upload-menu__input');
  var list = menu.querySelector('.upload-menu__list');
  var idle = menu.querySelector('.upload-menu__idle');
  var notes = menu.querySelector('.upload-menu__notes');
  // The header's Sync item, where finished imports are: its dot is a failure not yet seen there.
  var syncLink = document.querySelector('[data-sync-link]');
  var syncAlert = syncLink && syncLink.querySelector('.sync-link__alert');
  var badge = menu.querySelector('.upload-menu__badge');
  var alertDot = menu.querySelector('.upload-menu__alert');

  var transfers = []; // { id, name, progress, sending } — files still to send, or being sent
  var active = []; // GET /v2/uploads/active's imports
  var unseenFailures = 0;
  var inFlight = -1; // the last count announced; -1 until the first render
  var noteList = []; // { id, text, error } — this page's own messages, dismissed one by one
  var uid = 0;
  var timer = null;
  var polling = false;

  function fill(template, values) {
    return template.replace(/\{(\w+)\}/g, function (m, key) {
      return Object.prototype.hasOwnProperty.call(values, key) ? String(values[key]) : m;
    });
  }

  function el(tag, className, text) {
    var e = document.createElement(tag);
    if (className) e.className = className;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function dismissButton(onClick) {
    var b = el('button', 'upload-menu__dismiss', '×');
    b.type = 'button';
    b.setAttribute('aria-label', strings.dismiss);
    b.title = strings.dismiss;
    b.addEventListener('click', onClick);
    return b;
  }

  function row(title, status) {
    var li = el('li', 'upload-menu__row');
    li.appendChild(el('span', 'upload-menu__title', title));
    li.appendChild(el('span', 'upload-menu__status', status));
    return li;
  }

  // Brings `container`'s children in line with `items`, keyed by `key`: an item already shown
  // keeps its element, updated by `update`, and only new ones are made. Rebuilding the lists on
  // every progress event and poll destroyed a focused dismiss button every 2 seconds and had a
  // screen reader announce each row again.
  // Two items may share a key (two files of one name sent in one second), so each key is counted
  // to stay unique, and whatever is past the last item is removed whatever its key.
  function syncList(container, items, key, make, update) {
    var existing = {};
    var seen = {};
    Array.prototype.forEach.call(container.children, function (child) { existing[child.dataset.key] = child; });
    items.forEach(function (item, i) {
      var base = key(item);
      seen[base] = (seen[base] || 0) + 1;
      var k = base + '#' + seen[base];
      var node = existing[k];
      delete existing[k];
      if (node) update(node, item);
      else {
        node = make(item);
        node.dataset.key = k;
      }
      if (container.children[i] !== node) container.insertBefore(node, container.children[i] || null);
    });
    while (container.children.length > items.length) container.lastElementChild.remove();
  }

  function setText(node, selector, text) {
    var target = node.querySelector(selector);
    if (target.textContent !== text) target.textContent = text;
  }

  function render() {
    guardUnload();
    var rows = transfers.map(function (t) {
      return { key: 't' + t.id, title: t.name, status: t.sending ? fill(strings.uploading, { percent: Math.round(t.progress * 100) }) : strings.queued };
    }).concat(active.map(function (a) {
      return { key: 'a' + keyOf(a), title: a.title, status: a.total > 1 ? fill(strings.processing_count, { done: a.done, total: a.total }) : strings.processing };
    }));
    syncList(list, rows, function (r) { return r.key; }, function (r) { return row(r.title, r.status); }, function (node, r) {
      setText(node, '.upload-menu__title', r.title);
      setText(node, '.upload-menu__status', r.status);
    });
    var busy = transfers.length + active.length;
    idle.hidden = busy > 0;
    badge.hidden = busy === 0;
    badge.textContent = String(busy);
    if (busy !== inFlight) {
      inFlight = busy;
      menu.setAttribute('data-in-flight', String(busy));
      window.dispatchEvent(new CustomEvent('hmt:imports-in-flight', { detail: busy }));
    }

    syncList(notes, noteList, function (n) { return 'n' + n.id; }, function (n) {
      var li = el('li', 'upload-menu__note' + (n.error ? ' upload-menu__note--error' : ''));
      li.appendChild(el('span', '', n.text));
      li.appendChild(dismissButton(function () {
        noteList = noteList.filter(function (x) { return x.id !== n.id; });
        render();
      }));
      return li;
    }, function () {
      // A note never changes once shown.
    });

    alertDot.hidden = !noteList.some(function (n) { return n.error; });
    if (syncAlert) {
      syncAlert.hidden = unseenFailures === 0;
      if (unseenFailures > 0) syncLink.title = fill(strings.failed_unseen, { n: unseenFailures });
      else syncLink.removeAttribute('title');
    }
  }

  function note(text, error) {
    uid += 1;
    noteList.push({ id: uid, text: text, error: !!error });
    render();
  }

  function changed() {
    window.dispatchEvent(new CustomEvent('hmt:imports-changed'));
  }

  // ---- What's still processing ----------------------------------------------------------

  function keyOf(a) {
    return a.title + '|' + a.submitted_at;
  }

  // The poll and each landed upload both read the list, and can overlap: an answer older than the
  // last one applied is dropped, or it would put a finished import back for one poll and announce
  // `hmt:imports-changed` again when it left once more. One overtaken by a read that then fails
  // still applies.
  var reads = 0;
  var applied = 0;

  function refresh() {
    var read = ++reads;
    return fetch('/v2/uploads/active', { credentials: 'same-origin', headers: { Accept: 'application/json' } })
      .then(function (res) { return res.ok ? res.json() : null; })
      .then(function (body) {
        if (!body || read < applied) return;
        applied = read;
        var before = {};
        active.forEach(function (a) { before[keyOf(a)] = a.done; });
        var now = {};
        body.imports.forEach(function (a) { now[keyOf(a)] = a.done; });
        var finishedSome = Object.keys(before).some(function (k) {
          return !(k in now) || now[k] > before[k];
        });
        active = body.imports;
        unseenFailures = body.unseen_failures;
        render();
        if (finishedSome) changed();
      })
      .catch(function () {
        // The next tick tries again.
      });
  }

  function schedule() {
    clearTimeout(timer);
    var busy = transfers.length > 0 || active.length > 0;
    timer = setTimeout(tick, busy ? POLL_MS : IDLE_MS);
  }

  function tick() {
    if (document.hidden) return schedule();
    if (polling) return;
    polling = true;
    refresh().then(function () {
      polling = false;
      schedule();
    });
  }

  // ---- Uploading --------------------------------------------------------------------------

  // The API's error body (docs/SPEC.md §1.4) carries the text for a person in `message`. Anything
  // else, such as Caddy's maintenance page, is not shown as it is: the status stands in for it.
  function errorMessage(xhr) {
    try {
      var body = JSON.parse(xhr.responseText || '');
      if (body && typeof body.message === 'string' && body.message) return body.message;
    } catch (e) {
      // Not the API's JSON.
    }
    return fill(strings.request_failed, { status: xhr.status });
  }

  // One XMLHttpRequest per file, for the upload-progress event fetch doesn't reliably have.
  function send(file, transfer) {
    return new Promise(function (resolve) {
      var xhr = new XMLHttpRequest();
      xhr.open('POST', '/v2/tracks/upload');
      xhr.withCredentials = true;
      xhr.upload.onprogress = function (event) {
        if (!event.lengthComputable) return;
        transfer.progress = event.loaded / event.total;
        render();
      };
      xhr.onload = function () {
        if (xhr.status < 200 || xhr.status >= 300) {
          note(fill(strings.failed_transfer, { filename: file.name, error: errorMessage(xhr) }), true);
          return resolve();
        }
        var body = {};
        try {
          body = JSON.parse(xhr.responseText);
        } catch (e) {
          // An upload the server took; nothing more to say about it.
        }
        if (body.status === 'already_processed') note(fill(strings.already, { filename: file.name }));
        resolve();
      };
      xhr.onerror = function () {
        note(fill(strings.failed_transfer, { filename: file.name, error: strings.network_error }), true);
        resolve();
      };
      var form = new FormData();
      form.append('file', file);
      xhr.send(form);
    });
  }

  function enqueue(fileList) {
    var all = Array.prototype.slice.call(fileList);
    // Every file that won't be sent says why, rather than dropping out of the pick unseen.
    all.filter(function (f) { return !ACCEPT.test(f.name); }).forEach(function (f) {
      var key = ZIP.test(f.name) ? 'zip_refused' : GZ.test(f.name) ? 'gz_refused' : 'type_refused';
      note(fill(strings[key], { filename: f.name }), true);
    });
    var files = all.filter(function (f) { return ACCEPT.test(f.name); });
    if (files.length > MAX_FILES) {
      note(fill(strings.too_many, { n: files.length }), true);
      files = [];
    }
    if (files.length === 0) return;
    menu.open = true;
    var queued = files.map(function (f) {
      uid += 1;
      return { id: uid, name: f.name, progress: 0, file: f };
    });
    transfers = transfers.concat(queued);
    render();
    schedule();
    // One at a time: per-file progress stays one XHR to follow, and a batch of a few files
    // against a personal server gains nothing from a pool.
    queued.reduce(function (chain, t) {
      return chain.then(function () {
        t.sending = true;
        render();
        return send(t.file, t).then(function () {
          transfers = transfers.filter(function (x) { return x.id !== t.id; });
          guardUnload();
          return refresh().then(changed);
        });
      });
    }, Promise.resolve()).then(schedule);
  }

  // Uploads live in this page's memory: leaving it (Sync, the logo, a language) drops the rest,
  // so the browser asks first while any remain, as the Edit window does for unsaved photos. Only
  // while any remain (render keeps it): Firefox keeps a page with the listener out of its
  // back/forward cache.
  function onBeforeUnload(event) {
    event.preventDefault();
    event.returnValue = '';
  }
  var guarding = false;
  function guardUnload() {
    var needed = transfers.length > 0;
    if (needed === guarding) return;
    guarding = needed;
    if (needed) window.addEventListener('beforeunload', onBeforeUnload);
    else window.removeEventListener('beforeunload', onBeforeUnload);
  }

  // A button, not a label around the hidden input, so the keyboard reaches it.
  menu.querySelector('.upload-menu__choose').addEventListener('click', function () {
    input.click();
  });

  input.addEventListener('change', function () {
    enqueue(input.files);
    input.value = '';
  });

  window.addEventListener('hmt:upload-files', function (event) {
    enqueue(event.detail);
  });

  // Opening the menu reads the latest at once rather than waiting for the next tick.
  menu.addEventListener('toggle', function () {
    if (menu.open) refresh();
  });

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) tick();
  });

  render();
  tick();
})();
