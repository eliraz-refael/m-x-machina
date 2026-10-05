/* M-x Machina landing page: hero command list, interactive Emacs illustration, quickstart tabs.
   Everything in the frame is fictional and runs locally; nothing is sent anywhere. */
(function () {
  'use strict';

  var still = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  function $(sel, root) { return (root || document).querySelector(sel); }
  function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* ---------- Hero: M-x command list ---------- */

  function initCommands() {
    var typed = $('#mx-typed');
    var buttons = $$('.mx-cmd');
    if (!typed || !buttons.length) return;
    var current = 0;
    var paused = false;

    function show(i) {
      current = i;
      buttons.forEach(function (b, j) { b.setAttribute('aria-pressed', j === i ? 'true' : 'false'); });
      var name = buttons[i].querySelector('.mx-cmd__name').textContent;
      var span = document.createElement('span');
      span.className = 'type';
      span.style.setProperty('--n', String(name.length));
      span.textContent = name;
      typed.textContent = '';
      typed.appendChild(span);
    }

    buttons.forEach(function (b, i) {
      b.addEventListener('click', function () { paused = true; show(i); });
    });
    show(0);
    if (!still) {
      setInterval(function () {
        if (!paused && document.visibilityState !== 'hidden') show((current + 1) % buttons.length);
      }, 3400);
    }
  }

  /* ---------- Quickstart tabs and copy ---------- */

  var SNIPPETS = {
    emacs: "git clone https://github.com/eliraz-refael/m-x-machina.git\n\n;; init.el (adjust the path)\n(add-to-list 'load-path \"/path/to/m-x-machina/lisp\")\n(require 'mx-machina)\n\n;; then\nM-x mx-machina      ; sidebar, press n for a new agent",
    doom: "git clone https://github.com/eliraz-refael/m-x-machina.git\n\n;; config.el (adjust the location)\n(load! \"m-x-machina/examples/doom.el\")\n\n;; SPC o a a  sidebar      SPC o a n  new agent\n;; SPC o a d  dashboard    SPC o a b  board\n;; SPC o a z  focus        SPC o a ]  next needing attention",
    demo: ";; No model, credentials or network\nM-x load-file RET /path/to/m-x-machina/examples/demo.el\nM-x mx-machina-demo\n\n;; Send /work to simulate 20 seconds of work.\n;; In the sidebar: i inspects identity, x stops, RET resumes.",
    cli: ";; in the Emacs that owns the agents\n(mx-machina-messaging-mode 1)\n\n# from a terminal, or from inside an agent\n/path/to/m-x-machina/scripts/mxm list\n/path/to/m-x-machina/scripts/mxm send 'Work/Billing Service/Harness' \\\n    'Summarize the API changes.' --wait\n/path/to/m-x-machina/scripts/mxm result REQUEST_ID"
  };

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      document.body.removeChild(ta);
      if (ok) resolve(); else reject(new Error('copy failed'));
    });
  }

  function initTabs() {
    var tabs = $$('.tab');
    var panel = $('#qs-panel');
    var code = $('#qs-code');
    var copy = $('#qs-copy');
    var status = $('#qs-copy-status');
    if (!tabs.length || !panel || !code) return;
    var active = 'emacs';
    var clearTimer = null;

    function select(tab, focus) {
      active = tab.getAttribute('data-tab');
      tabs.forEach(function (t) {
        var on = t === tab;
        t.setAttribute('aria-selected', on ? 'true' : 'false');
        t.tabIndex = on ? 0 : -1;
      });
      panel.setAttribute('aria-labelledby', tab.id);
      code.textContent = SNIPPETS[active];
      if (status) status.textContent = '';
      if (focus) tab.focus();
    }

    tabs.forEach(function (t, i) {
      t.addEventListener('click', function () { select(t, false); });
      t.addEventListener('keydown', function (e) {
        var n = null;
        if (e.key === 'ArrowRight') n = (i + 1) % tabs.length;
        else if (e.key === 'ArrowLeft') n = (i - 1 + tabs.length) % tabs.length;
        else if (e.key === 'Home') n = 0;
        else if (e.key === 'End') n = tabs.length - 1;
        if (n === null) return;
        e.preventDefault();
        select(tabs[n], true);
      });
    });

    if (copy) {
      copy.hidden = false;
      copy.addEventListener('click', function () {
        copyText(SNIPPETS[active]).then(function () {
          status.textContent = 'Copied to clipboard';
        }, function () {
          status.textContent = 'Copy failed. Select the text instead.';
        });
        clearTimeout(clearTimer);
        clearTimer = setTimeout(function () { status.textContent = ''; }, 2500);
      });
    }
  }

  /* ---------- Interactive Emacs illustration ---------- */

  var FOLDERS = ['Work', 'Work/Billing Service', 'Work/Docs Site', 'Personal', 'Personal/Emacs'];
  var GROUP_ORDER = ['Work/Billing Service', 'Work/Docs Site', 'Personal/Emacs', 'Personal', ''];
  var LABEL = { working: 'working', waiting: 'approval', ready: 'ready', stopped: 'stopped', error: 'error', starting: 'starting' };
  var CLS = { working: 'c-work', waiting: 'c-wait', ready: 'c-ready', stopped: 'c-stop', error: 'c-err', starting: 'c-stop' };

  function agent(id, name, folder, status, unread, iface, profile, model, project, tree, branch, conv, log) {
    return { id: id, name: name, folder: folder, status: status, unread: unread, iface: iface, profile: profile,
      model: model, project: project, tree: tree, branch: branch, conv: conv, log: log };
  }

  function seedAgents() {
    return [
      agent('harness', 'Harness', 'Work/Billing Service', 'working', false, 'EAT', 'claude-eat-work', 'sonnet', 'billing-service', '~/src/billing-harness', 'harness/retry-tests', '7c1e9a42', [
        ['you', 'Add tests for the retry queue consumer. Keep the public API unchanged.'],
        ['tool', 'Read src/queue/consumer.ts'],
        ['tool', 'Edit test/queue/consumer.test.ts  +84 −3'],
        ['agent', 'Covering backoff, poison messages and shutdown. Running the queue suite next.'],
        ['tool', 'Bash npm test -- queue']]),
      agent('effect', 'Migrate to Effect v4', 'Work/Billing Service', 'waiting', false, 'agent-shell', 'claude-acp-work', 'opus', 'billing-service', '~/src/billing-effect4', 'effect-v4', 'b82d0f13', [
        ['you', 'Move the payments module to Effect v4. Stop before the database layer.'],
        ['tool', 'Edit src/payments/layer.ts  +31 −27'],
        ['agent', 'Imports and Layer construction are updated in payments/. I want to typecheck before going further.'],
        ['perm', 'Bash: pnpm typecheck']]),
      agent('review', 'API review', 'Work/Billing Service', 'ready', true, 'agent-shell', 'claude-acp-work', 'sonnet', 'billing-service', '~/src/billing-service', 'main', '31aa7c55', [
        ['you', 'Review the invoices API diff and list anything risky.'],
        ['agent', 'Three things stand out: the pagination cursor changed type, a missing invoice now returns 200 with null instead of 404, and the rate-limit header was renamed. The first two break existing clients.']]),
      agent('changelog', 'Changelog', 'Work/Docs Site', 'ready', false, 'vterm', 'claude-eat-work-vterm', '', 'docs-site', '~/src/docs-site', 'changelog-draft', 'e019b6d2', [
        ['you', 'Draft changelog entries from the PRs merged since the last tag.'],
        ['agent', 'Drafted nine entries under Added, Changed and Fixed. Two PR titles were ambiguous, so I marked them TODO.']]),
      agent('tests', 'mx-machina tests', 'Personal/Emacs', 'working', false, 'agent-shell', 'claude-acp-personal', 'sonnet', 'm-x-machina', '~/src/mxm-attention-tests', 'tests/attention-wrap', '5d7e21c0', [
        ['you', 'Add a test for attention navigation wrapping across folders.'],
        ['tool', 'Read test/attention-test.el'],
        ['agent', 'Writing a case where the queue wraps from the last unread agent back to the first approval request.']]),
      agent('dotfiles', 'dotfiles', 'Personal', 'stopped', false, 'EAT', 'claude-eat-personal', 'sonnet', 'dotfiles', '~/dotfiles', 'main', '4f1c2a90', [
        ['you', 'Tidy the fish config and remove unused abbreviations.'],
        ['agent', 'Removed eleven unused abbreviations and grouped the rest by tool.'],
        ['sys', 'Stopped with x. Conversation ID, profile and worktree retained.']]),
      agent('scratch', 'Scratch', '', 'error', false, 'agent-shell', 'claude-acp-personal', '', 'scratch', '~/src/scratch', 'main', '9b03e6aa', [
        ['err', 'Resume failed: the backend reported Resource not found for saved conversation 9b03e6aa.'],
        ['sys', 'The record is kept and no replacement conversation was started. Press i for recovery steps.']])
    ];
  }

  function initDemo() {
    var frame = $('#mx-frame');
    if (!frame) return;
    var side = $('#mx-side'), main = $('#mx-main'), modeline = $('#mx-modeline'), msgEl = $('#mx-msg'), srEl = $('#mx-sr');

    var S = {
      agents: seedAgents(), cursor: 'a:harness', shown: 'harness', mode: 'conv', focus: false,
      collapsed: [], expanded: [], boardSel: 0, diag: 'harness', help: 'harness', esh: 'harness',
      flash: '', readLeft: 0
    };
    var inView = false, armed = false, readKey = '', readTimer = null, scrollKey = '';

    function find(id) { for (var i = 0; i < S.agents.length; i++) if (S.agents[i].id === id) return S.agents[i]; return null; }
    function patchAgent(id, p) { var a = find(id); for (var k in p) a[k] = p[k]; return a; }
    function parent(p) { var i = p.lastIndexOf('/'); return i < 0 ? '' : p.slice(0, i); }
    function spinning(a) { return a.status === 'working' || a.status === 'starting'; }
    function live(a) { return a.status === 'working' || a.status === 'ready' || a.status === 'waiting' || a.status === 'starting'; }
    function dot(a) { return spinning(a) ? '<span class="spin ' + CLS[a.status] + '" aria-hidden="true"></span>' : '<span class="mx-dot ' + CLS[a.status] + '" aria-hidden="true">●</span>'; }
    function say(text) { msgEl.textContent = text; }
    function announce(text) { srEl.textContent = ''; setTimeout(function () { srEl.textContent = text; }, 30); }

    function rows() {
      var out = [];
      (function walk(path, depth) {
        FOLDERS.forEach(function (f) {
          if (parent(f) !== path) return;
          out.push({ t: 'f', path: f, depth: depth });
          if (S.collapsed.indexOf(f) < 0) walk(f, depth + 1);
        });
        S.agents.forEach(function (a) {
          if (a.folder !== path) return;
          out.push({ t: 'a', a: a, depth: depth });
          if (S.expanded.indexOf(a.id) >= 0) out.push({ t: 'd', a: a, depth: depth });
        });
      })('', 0);
      return out;
    }
    function navKeys() { return rows().filter(function (r) { return r.t !== 'd'; }).map(function (r) { return r.t === 'f' ? 'f:' + r.path : 'a:' + r.a.id; }); }
    function laneOf(a) { return a.status === 'error' ? 'stopped' : (a.status === 'starting' ? 'other' : a.status); }
    function groups() { return GROUP_ORDER.filter(function (g) { return S.agents.some(function (a) { return a.folder === g; }); }); }
    function lanes() {
      var L = [['working', 'Working'], ['waiting', 'Waiting'], ['ready', 'Ready'], ['stopped', 'Stopped']];
      if (S.agents.some(function (a) { return a.status === 'starting'; })) L.push(['other', 'Other']);
      return L;
    }
    function cards() {
      var out = [];
      groups().forEach(function (g) { lanes().forEach(function (L) { S.agents.forEach(function (a) { if (a.folder === g && laneOf(a) === L[0]) out.push(a); }); }); });
      return out;
    }
    function target() {
      if (S.mode === 'board') { var c = cards(); return c[Math.min(S.boardSel, c.length - 1)] || null; }
      if (S.focus) return find(S.shown);
      return S.cursor.indexOf('a:') === 0 ? find(S.cursor.slice(2)) : null;
    }
    function describe(key) {
      if (key.indexOf('f:') === 0) return 'Folder ' + key.slice(2) + (S.collapsed.indexOf(key.slice(2)) >= 0 ? ', collapsed' : ', expanded');
      var a = find(key.slice(2));
      return a.name + ', ' + LABEL[a.status] + (a.unread ? ', unread reply' : '');
    }

    /* ----- rendering ----- */

    function renderSide() {
      var html = '<div class="mx-side__head"><span>*mx-machina*</span><span>? actions</span></div>';
      rows().forEach(function (r) {
        var pad = 'padding-left:' + (10 + r.depth * 14) + 'px';
        if (r.t === 'f') {
          var key = 'f:' + r.path, open = S.collapsed.indexOf(r.path) < 0;
          var sub = S.agents.filter(function (a) { return a.folder === r.path || a.folder.indexOf(r.path + '/') === 0; });
          var w = sub.filter(function (a) { return a.status === 'working'; }).length;
          var q = sub.filter(function (a) { return a.status === 'waiting'; }).length;
          var u = sub.filter(function (a) { return a.unread; }).length;
          var sums = (w ? '<span class="mx-row__sum c-work">●' + w + '</span>' : '') +
                     (q ? '<span class="mx-row__sum c-wait">●' + q + '</span>' : '') +
                     (u ? '<span class="mx-row__sum c-unread">*' + u + '</span>' : '');
          var summary = [w ? w + ' working' : '', q ? q + ' waiting' : '', u ? u + ' unread' : ''].filter(Boolean).join(', ');
          html += '<button type="button" tabindex="-1" class="mx-row mx-row--folder' + (S.cursor === key ? ' is-cursor' : '') + '" style="' + pad + '" data-row="' + esc(key) + '" aria-expanded="' + open + '" aria-label="' + esc('Folder ' + r.path + (summary ? ', ' + summary : '')) + '">' +
            '<span class="mx-row__caret" aria-hidden="true">' + (open ? '▾' : '▸') + '</span>' +
            '<span class="mx-row__name">' + esc(r.path.slice(r.path.lastIndexOf('/') + 1)) + '</span>' +
            '<span aria-hidden="true" style="display:inline-flex;gap:6px">' + sums + '</span></button>';
        } else if (r.t === 'a') {
          var a = r.a, akey = 'a:' + a.id;
          var cls = 'mx-row' + (S.cursor === akey ? ' is-cursor' : '') + (S.mode === 'conv' && S.shown === a.id ? ' is-shown' : '') +
                    (a.unread ? ' is-unread' : '') + (S.flash === a.id ? ' flash' : '');
          html += '<button type="button" tabindex="-1" class="' + cls + '" style="' + pad + '" data-row="' + esc(akey) + '" aria-label="' + esc(a.name + ', ' + LABEL[a.status] + (a.unread ? ', unread reply' : '')) + '">' +
            dot(a) + '<span class="mx-row__name">' + (a.unread ? '*' : '') + esc(a.name) + '</span></button>';
        } else {
          var d = r.a;
          html += '<dl class="mx-detail" style="padding-left:' + (30 + r.depth * 14) + 'px">' +
            '<div><dt>status</dt><dd class="' + CLS[d.status] + '">' + LABEL[d.status] + '</dd></div>' +
            '<div><dt>dir</dt><dd>' + esc(d.tree) + '</dd></div>' +
            '<div><dt>branch</dt><dd>' + esc(d.branch) + '</dd></div>' +
            '<div><dt>profile</dt><dd>' + esc(d.profile) + '</dd></div>' +
            '<div><dt>saved ID</dt><dd>' + (d.conv ? 'saved · ' + esc(d.conv) : 'pending') + '</dd></div></dl>';
        }
      });
      side.innerHTML = html;
    }

    function readTag() {
      var a = find(S.shown);
      if (!a || !a.unread) return '';
      return S.readLeft > 0 ? 'unread · clears in ' + S.readLeft + 's' : 'unread';
    }

    function renderConv() {
      var a = find(S.shown);
      var html = '<div class="mx-hl"><span class="mx-hl__name">' + dot(a) + '<b class="' + (a.unread ? 'is-unread' : '') + '">' + (a.unread ? '*' : '') + esc(a.name) + '</b></span>' +
        '<span class="' + CLS[a.status] + '">' + LABEL[a.status] + '</span>' +
        '<span style="color:var(--e-soft)">' + esc(a.project) + '</span>' +
        '<span style="color:var(--e-dim)">model <span style="color:var(--e-soft)">' + esc(a.model || 'not reported') + '</span></span>' +
        '<span class="mx-hl__read" id="mx-readtag">' + readTag() + '</span></div>' +
        '<div class="mx-hl2"><span>' + esc(a.tree) + '</span><span>⎇ ' + esc(a.branch) + '</span><span>' + esc(a.folder || '(root)') + '</span><span>' + esc(a.iface) + '</span></div>' +
        '<div class="mx-pane" id="mx-buf">';
      a.log.forEach(function (l) {
        var kind = l[0], text = esc(l[1]);
        if (kind === 'perm') {
          if (a.status === 'waiting') {
            html += '<div class="mx-perm"><div><span class="mx-perm__title">Permission requested</span> <span style="color:var(--e-strong)">' + text + '</span></div>' +
              '<div class="mx-perm__acts"><button type="button" class="is-primary" data-act="allow">Allow once</button><button type="button" data-act="deny">Deny</button></div></div>';
          } else {
            html += '<div class="mx-ln--tool">Permission request, no longer pending: ' + text + '</div>';
          }
        } else {
          html += '<div class="mx-ln--' + kind + '">' + text + '</div>';
        }
      });
      if (a.status === 'working') html += '<div class="mx-tail mx-tail--working"><span class="spin" aria-hidden="true"></span><span>working…</span></div>';
      if (a.status === 'starting') html += '<div class="mx-tail mx-tail--starting"><span class="spin" aria-hidden="true"></span><span>starting, waiting for the backend to confirm the session…</span></div>';
      if (a.status === 'ready') html += '<div class="mx-tail mx-tail--ready"><span class="mx-caret-block caret" aria-hidden="true"></span></div>';
      if (a.status === 'stopped') html += '<div class="mx-tail mx-tail--stopped">Process stopped. Saved conversation ' + esc(a.conv) + ': press RET to resume it.</div>';
      return html + '</div>';
    }

    function renderBoard() {
      var c = cards(), sel = c[Math.min(S.boardSel, c.length - 1)], selId = sel ? sel.id : '';
      var html = '<div class="mx-pane mx-pane--grid" id="mx-buf"><div class="mx-board-hint">Agent board · grouped by folder · h/j/k/l move · RET opens · q returns</div>';
      groups().forEach(function (g) {
        html += '<div class="mx-group"><div class="mx-group__title">' + esc(g || '(root)') + '</div><div class="mx-lanes">';
        lanes().forEach(function (L) {
          var cs = S.agents.filter(function (a) { return a.folder === g && laneOf(a) === L[0]; });
          html += '<div class="mx-lane"><div class="mx-lane__title">' + L[1].toUpperCase() + ' · ' + cs.length + '</div>';
          cs.forEach(function (a) {
            html += '<button type="button" tabindex="-1" class="mx-cardbtn' + (a.id === selId ? ' is-selected' : '') + (S.flash === a.id ? ' flash' : '') + '" data-card="' + esc(a.id) + '" aria-label="' + esc(a.name + ', ' + LABEL[a.status] + (a.unread ? ', unread reply' : '')) + '">' +
              '<span class="mx-cardbtn__name">' + dot(a) + '<b>' + esc(a.name) + '</b></span>' +
              (a.unread ? '<span class="mx-tag mx-tag--new">NEW</span>' : '') +
              (a.status === 'error' ? '<span class="mx-tag mx-tag--err">ERROR</span>' : '') +
              '<span class="mx-cardbtn__sub">' + esc(a.iface + ' · ' + a.branch) + '</span></button>';
          });
          if (!cs.length) html += '<span class="mx-lane__empty" aria-hidden="true">—</span>';
          html += '</div>';
        });
        html += '</div></div>';
      });
      return html + '</div>';
    }

    function renderDiag() {
      var d = find(S.diag), term = d.iface !== 'agent-shell', on = live(d);
      var rowsHtml = [
        ['Profile', d.profile, 'configured', 'c-ready'],
        [term ? 'Executable' : 'ACP client', term ? 'claude' : 'agent-shell', 'found', 'c-ready'],
        ['Checkout', d.tree, 'present', 'c-ready'],
        ['Branch', d.branch, 'matches record', 'c-ready'],
        ['Conversation', d.conv, d.status === 'error' ? 'backend: not found' : 'saved', d.status === 'error' ? 'c-err' : 'c-ready'],
        ['Process', on ? 'running' : 'exited', on ? 'live' : 'stopped', on ? 'c-ready' : 'c-stop']
      ];
      if (term) rowsHtml.push(['SessionStart', 'hook events', on ? 'confirmed' : 'not running', on ? 'c-ready' : 'c-stop']);
      var html = '<div class="mx-pane mx-pane--grid" id="mx-buf"><div class="mx-title">Diagnostics — ' + esc(d.name) + '</div><dl class="mx-kv">' +
        rowsHtml.map(function (r) { return '<div><dt>' + r[0] + '</dt><dd>' + esc(r[1]) + '</dd><dd class="' + r[3] + '">' + r[2] + '</dd></div>'; }).join('') + '</dl>';
      if (d.status === 'error') {
        html += '<ol class="mx-steps"><li class="mx-steps__title">Recovery steps</li>' +
          '<li>1. Restore the original profile ' + esc(d.profile) + ' and its account configuration.</li>' +
          '<li>2. Press R here to retry the same conversation ID. No prompt is submitted.</li>' +
          '<li>3. If the history is gone, create a separate agent with n and keep this record while you investigate.</li></ol>';
      } else {
        html += '<p class="mx-ok">No problems found.</p>';
      }
      return html + '<p class="mx-note">Checked without starting the agent or contacting the backend.<br>g refresh · w copy summary · W rebind worktree · R retry · q return</p></div>';
    }

    function renderHelp() {
      var h = find(S.help), on = live(h);
      var acts = [
        ['o', h.status === 'stopped' ? 'Resume saved conversation' : 'Open conversation', h.status !== 'error', 'saved conversation not found, see i'],
        ['x', 'Stop process', on, 'not running'],
        ['i', 'Diagnose', true, ''],
        ['u', 'Mark read', h.unread, 'no unread output'],
        ['z', 'Focus conversation', true, ''],
        ['e', 'Eshell in worktree', true, ''],
        ['R', 'Rename (keeps conversation ID)', true, ''],
        ['M', 'Move to folder', true, ''],
        ['W', 'Rebind worktree or branch', !on, 'stop the agent first'],
        ['a', on ? 'Stop and archive' : 'Archive', true, '']
      ];
      return '<div class="mx-pane mx-pane--grid" id="mx-buf"><div class="mx-title">Actions — ' + esc(h.name) + '</div><ul class="mx-acts">' +
        acts.map(function (x) {
          return '<li class="' + (x[2] ? '' : 'is-off') + '"><span class="mx-acts__k">' + x[0] + '</span><span>' + x[1] + (x[2] ? '' : '<span class="sr-only"> (unavailable)</span>') + '</span>' +
            (x[2] ? '' : '<span class="mx-acts__why">' + x[3] + '</span>') + '</li>';
        }).join('') + '</ul><p class="mx-note">Opening this menu starts nothing and marks nothing read. q or ? closes it.</p></div>';
    }

    function renderEshell() {
      var e = find(S.esh);
      return '<div class="mx-pane mx-sh" id="mx-buf"><div style="color:var(--e-dim)">Welcome to the Emacs shell</div>' +
        '<div style="margin-top:8px"><span class="mx-sh__prompt">' + esc(e.tree) + ' $</span> git branch --show-current</div>' +
        '<div>' + esc(e.branch) + '</div>' +
        '<div style="display:flex;gap:8px;align-items:center"><span class="mx-sh__prompt">' + esc(e.tree) + ' $</span><span class="mx-caret-block caret" aria-hidden="true" style="height:15px"></span></div>' +
        '<div class="mx-note" style="margin-top:12px;font-style:italic">A separate shell for ' + esc(e.name) + '. History, directory and unsent input are kept; the agent itself is untouched.</div></div>';
    }

    function renderEditor() {
      return '<div class="mx-pane" id="mx-buf"><pre class="mx-code"><span class="k">export async function</span> consume(queue: Queue, handler: Handler) {\n' +
        '  <span class="k">for await</span> (<span class="k">const</span> message <span class="k">of</span> queue) {\n' +
        '    <span class="k">try</span> {\n      <span class="k">await</span> handler(message)\n      <span class="k">await</span> queue.ack(message)\n' +
        '    } <span class="k">catch</span> (error) {\n      <span class="k">await</span> queue.retry(message, backoff(message.attempts))\n    }\n  }\n}</pre>' +
        '<p class="mx-note" style="font-style:italic">Your editor layout from before the first RET. The sidebar stays; RET reopens an agent.</p></div>';
    }

    function renderModeline() {
      var a = find(S.shown), e = find(S.esh);
      var buf = { conv: a.name, board: '*mx-machina-board*', diag: '*mx-machina-diagnostics*', help: '*mx-machina-actions*', eshell: '*eshell: ' + e.name + '*', editor: 'consumer.ts' }[S.mode];
      var mode = { conv: a.iface, board: 'Board', diag: 'Diagnostics', help: 'Actions', eshell: 'Eshell', editor: 'TypeScript' }[S.mode];
      var counts = [['working', 'working'], ['ready', 'ready'], ['waiting', 'approval'], ['stopped', 'stopped'], ['error', 'error'], ['starting', 'starting']]
        .map(function (x) { return { n: S.agents.filter(function (b) { return b.status === x[0]; }).length, lab: x[1], cls: CLS[x[0]] }; })
        .filter(function (x) { return x.n; })
        .map(function (x) { return '<span class="' + x.cls + '">' + x.n + ' ' + x.lab + '</span>'; }).join(' · ');
      modeline.innerHTML = '<span class="mx-modeline__buf">' + (S.focus ? '<span class="mx-modeline__focus">FOCUS </span>' : '') + '<b>' + esc(buf) + '</b> <span class="mx-modeline__mode">(' + esc(mode) + ')</span></span>' +
        '<span>Agents: ' + counts + '</span>';
    }

    function render() {
      var oldBuf = $('#mx-buf', main), keepTop = oldBuf ? oldBuf.scrollTop : 0, sideTop = side.scrollTop;
      var focusedAct = document.activeElement && main.contains(document.activeElement) ? document.activeElement.getAttribute('data-act') : null;

      frame.classList.toggle('is-focus', S.focus);
      renderSide();
      side.scrollTop = sideTop;
      main.innerHTML = { conv: renderConv, board: renderBoard, diag: renderDiag, help: renderHelp, eshell: renderEshell, editor: renderEditor }[S.mode]();
      renderModeline();

      var a = find(S.shown), buf = $('#mx-buf', main);
      var key = S.mode + '|' + S.shown + '|' + (a ? a.log.length + a.status : '');
      if (buf) {
        if (key !== scrollKey) buf.scrollTop = S.mode === 'conv' ? buf.scrollHeight : 0;
        else buf.scrollTop = keepTop;
      }
      scrollKey = key;
      if (focusedAct) { var again = $('[data-act="' + focusedAct + '"]', main); if (again) again.focus(); else frame.focus({ preventScroll: true }); }

      var cur = $('.mx-row.is-cursor', side) || $('.mx-cardbtn.is-selected', main);
      if (cur && cur.scrollIntoView) {
        var box = (cur.closest('.mx-side') || buf);
        if (box) {
          var cr = cur.getBoundingClientRect(), br = box.getBoundingClientRect();
          if (cr.top < br.top || cr.bottom > br.bottom) box.scrollTop += (cr.top < br.top ? cr.top - br.top - 8 : cr.bottom - br.bottom + 8);
        }
      }
      syncRead();
    }

    /* ----- unread acknowledgment: 5 continuous visible seconds ----- */

    function visible() { return document.visibilityState !== 'hidden' && inView; }
    function paintReadTag() { var t = $('#mx-readtag', main); if (t) t.textContent = readTag(); }

    function syncRead() {
      var a = find(S.shown);
      var key = S.mode === 'conv' && a && a.unread ? a.id : '';
      if (key === readKey) return;
      readKey = key;
      clearInterval(readTimer); readTimer = null;
      if (!key) { S.readLeft = 0; return; }
      S.readLeft = 5; paintReadTag();
      readTimer = setInterval(function () {
        if (!visible()) { S.readLeft = 5; paintReadTag(); return; }
        S.readLeft -= 1;
        if (S.readLeft > 0) { paintReadTag(); return; }
        clearInterval(readTimer); readTimer = null; readKey = '';
        var b = patchAgent(key, { unread: false });
        S.readLeft = 0;
        say('Marked read: ' + b.name + ' was visible for 5 continuous seconds.');
        render();
      }, 1000);
    }

    /* ----- simulated events ----- */

    function flash(id) { S.flash = id; setTimeout(function () { if (S.flash === id) { S.flash = ''; } }, 1700); }

    function finishHarness() {
      var h = find('harness');
      if (!h || h.status !== 'working') return;
      h.log = h.log.concat([['tool', '41 passed, 0 failed'], ['agent', 'Done: six new retry tests, all passing. No public API changes; the diff stays inside test/queue/.']]);
      patchAgent('harness', { status: 'ready', unread: true });
      flash('harness');
      render();
    }

    function decide(allow) {
      var a = find(S.shown);
      if (!a || a.status !== 'waiting') return;
      a.log = a.log.map(function (l) { return l[0] === 'perm' ? [allow ? 'tool' : 'sys', (allow ? 'Allowed once · ' : 'Denied · ') + l[1]] : l; });
      if (!allow) {
        a.log.push(['agent', 'Understood. I left the typecheck to you; the payments imports are ready for review.']);
        patchAgent(a.id, { status: 'ready', unread: true });
        say('Denied.');
        render();
        frame.focus({ preventScroll: true });
        return;
      }
      patchAgent(a.id, { status: 'working' });
      say('Allowed once.');
      render();
      frame.focus({ preventScroll: true });
      setTimeout(function () {
        var b = find(a.id);
        if (!b || b.status !== 'working') return;
        b.log = b.log.concat([['tool', 'pnpm typecheck: 0 errors'], ['agent', 'Typecheck passes. I stopped before the database layer, as asked.']]);
        patchAgent(b.id, { status: 'ready', unread: true });
        flash(b.id);
        render();
      }, 4500);
    }

    /* ----- commands ----- */

    function move(d) {
      var keys = navKeys(), i = keys.indexOf(S.cursor);
      if (i < 0) i = 0;
      S.cursor = keys[Math.max(0, Math.min(keys.length - 1, i + d))];
      announce(describe(S.cursor));
    }
    function boardMove(d) {
      var c = cards();
      S.boardSel = Math.max(0, Math.min(c.length - 1, S.boardSel + d));
      announce(c[S.boardSel].name + ', ' + LABEL[c[S.boardSel].status]);
    }
    function toggle(key) {
      if (key.indexOf('f:') === 0) {
        var p = key.slice(2);
        S.collapsed = S.collapsed.indexOf(p) >= 0 ? S.collapsed.filter(function (x) { return x !== p; }) : S.collapsed.concat([p]);
        announce(describe(key));
        return;
      }
      var id = key.slice(2);
      var open = S.expanded.indexOf(id) >= 0;
      S.expanded = open ? S.expanded.filter(function (x) { return x !== id; }) : S.expanded.concat([id]);
      var a = find(id);
      announce(open ? 'Details hidden' : a.name + ': ' + LABEL[a.status] + ', directory ' + a.tree + ', branch ' + a.branch + ', profile ' + a.profile + ', saved ID ' + a.conv);
    }
    function open(key) {
      if (key.indexOf('f:') === 0) { toggle(key); return; }
      var a = find(key.slice(2));
      S.cursor = 'a:' + a.id; S.shown = a.id; S.mode = 'conv';
      if (a.status === 'error') { say('Resume blocked: the backend has no conversation ' + a.conv + '. Press i for recovery steps. Nothing new was started.'); return; }
      if (a.status === 'stopped') {
        a.status = 'starting';
        say('Resuming saved conversation ' + a.conv + '…');
        setTimeout(function () {
          var b = find(a.id);
          if (!b || b.status !== 'starting') return;
          b.log = b.log.concat([['sys', 'Resumed conversation ' + b.conv + ' with profile ' + b.profile + ' in ' + b.tree + '. Earlier input was not replayed.']]);
          b.status = 'ready';
          say(b.name + ' is ready.');
          render();
        }, 1500);
        return;
      }
      say('Opened ' + a.name + ' beside the sidebar.');
    }
    function stop(a) {
      if (a.status === 'stopped' || a.status === 'error') { say(a.name + ' is not running.'); return; }
      a.status = 'stopped';
      a.log = a.log.concat([['sys', 'Stopped with x. Conversation ID, profile, worktree and unread flag retained.']]);
      say('Stopped ' + a.name + '. RET resumes the same conversation.');
    }
    function attention(dir) {
      var q = S.agents.filter(function (a) { return a.status === 'waiting'; })
        .concat(S.agents.filter(function (a) { return a.unread && a.status !== 'waiting'; }));
      if (!q.length) { say('No agents need attention.'); return; }
      var t = target(), i = -1;
      for (var j = 0; t && j < q.length; j++) if (q[j].id === t.id) i = j;
      var n = i < 0 ? 0 : (i + dir + q.length) % q.length, a = q[n];
      for (var p = a.folder; p; p = parent(p)) S.collapsed = S.collapsed.filter(function (c) { return c !== p; });
      S.cursor = 'a:' + a.id;
      if (S.mode === 'board') S.boardSel = cards().indexOf(a);
      say('Attention ' + (n + 1) + '/' + q.length + ': ' + (a.folder ? a.folder + '/' : '') + a.name + ' — ' + (a.status === 'waiting' ? 'approval request' : 'unread reply') + '. RET opens it.');
    }
    function notHere(what) { say(what + ' Not simulated in this illustration.'); }

    var HANDLED = 'j k l h r o u x i e c q g n z B D N M R W a f m ? ] [ Enter Tab ArrowDown ArrowUp ArrowLeft ArrowRight'.split(' ');

    function press(k) {
      if (HANDLED.indexOf(k) < 0) return false;
      var board = S.mode === 'board', t = target();
      function need(fn) { if (t) fn(t); else say('Select an agent first (j/k).'); }
      switch (k) {
        case 'j': case 'ArrowDown': board ? boardMove(1) : move(1); break;
        case 'k': case 'ArrowUp': board ? boardMove(-1) : move(-1); break;
        case 'l': case 'ArrowRight': if (board) boardMove(1); else return false; break;
        case 'h': case 'ArrowLeft': if (board) boardMove(-1); else return false; break;
        case 'Tab': board ? boardMove(1) : toggle(S.cursor); break;
        case 'Enter': case 'r': case 'o': if (board) { if (t) open('a:' + t.id); } else open(S.cursor); break;
        case ']': attention(1); break;
        case '[': attention(-1); break;
        case 'z':
          if (S.focus) { S.focus = false; say('Previous layout restored.'); break; }
          var fa = t || find(S.shown);
          S.focus = true; S.mode = 'conv'; S.shown = fa.id; S.cursor = 'a:' + fa.id;
          say('Focused ' + fa.name + '. Press z again to restore your windows.');
          break;
        case 'B':
          if (board) { S.mode = 'conv'; say('Board closed. Previous layout restored.'); break; }
          S.boardSel = Math.max(0, cards().indexOf(t)); S.mode = 'board'; S.focus = false;
          say('Agent board. Cards follow real state and cannot be dragged between columns.');
          break;
        case 'i': need(function (a) { S.mode = 'diag'; S.diag = a.id; S.focus = false; say('Diagnostics for ' + a.name + '. Nothing was started and the backend was not contacted.'); }); break;
        case '?':
          if (S.mode === 'help') { S.mode = 'conv'; break; }
          need(function (a) { S.mode = 'help'; S.help = a.id; S.focus = false; say('Actions for ' + a.name + '. Disabled entries explain why.'); });
          break;
        case 'e': need(function (a) { S.mode = 'eshell'; S.esh = a.id; S.focus = false; say('Eshell in ' + a.tree + '. The agent was not started or stopped.'); }); break;
        case 'x': need(stop); break;
        case 'u': need(function (a) { if (a.unread) { a.unread = false; say('Marked read: ' + a.name + '.'); } else say(a.name + ' has no unread output.'); }); break;
        case 'c': S.mode = 'editor'; S.focus = false; say('Conversation view closed. The agent keeps running and your earlier editor layout is back.'); break;
        case 'q':
          if (S.mode === 'board' || S.mode === 'diag' || S.mode === 'help' || S.mode === 'eshell') { S.mode = 'conv'; say('Returned to the conversation.'); }
          else if (S.focus) { S.focus = false; say('Previous layout restored.'); }
          else say('In Emacs, q hides the sidebar. Agents keep running.');
          break;
        case 'g': say('Refreshed. No agents were launched and nothing was marked read.'); break;
        case 'n': say('n asks for a name and repository, whether to create a new worktree, then agent, account, interface and folder. Not simulated here.'); break;
        case 'D': notHere('D opens the full session table.'); break;
        case 'N': notHere('N creates a folder, such as Work/New/Path.'); break;
        case 'M': notHere('M moves the agent to another folder.'); break;
        case 'R': notHere('R renames the agent and keeps its conversation ID.'); break;
        case 'W': notHere('W points a stopped agent at a moved worktree after you confirm.'); break;
        case 'a': notHere('a archives the agent and keeps its conversation and worktree.'); break;
        case 'f': notHere(board ? 'f limits the board to one folder.' : 'f opens the worktree in Dired.'); break;
        case 'm': notHere('m opens Magit for the worktree.'); break;
      }
      render();
      return true;
    }

    /* ----- wiring ----- */

    frame.addEventListener('keydown', function (e) {
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      var inner = e.target !== frame;
      if (e.key === 'Escape') { e.preventDefault(); frame.blur(); say('Left the frame. Click it or Tab back in to continue.'); return; }
      if (e.key === 'Tab' && (e.shiftKey || inner)) return;
      if (inner && (e.key === 'Enter' || e.key === ' ')) return;
      if (press(e.key)) e.preventDefault();
    });

    frame.addEventListener('click', function (e) {
      var row = e.target.closest('[data-row]');
      if (row) { S.cursor = row.getAttribute('data-row'); open(S.cursor); render(); frame.focus({ preventScroll: true }); return; }
      var card = e.target.closest('[data-card]');
      if (card) { open('a:' + card.getAttribute('data-card')); render(); frame.focus({ preventScroll: true }); return; }
      var act = e.target.closest('[data-act]');
      if (act) { decide(act.getAttribute('data-act') === 'allow'); return; }
    });

    $$('.keybtn').forEach(function (b) {
      b.addEventListener('click', function () { press(b.getAttribute('data-key')); });
    });

    var arm = function () {
      if (armed) return;
      armed = true;
      setTimeout(finishHarness, 9000);
    };
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (entries) {
        var en = entries[entries.length - 1];
        inView = en.isIntersecting && en.intersectionRatio > 0.3;
        if (inView) arm();
      }, { threshold: [0, 0.3, 0.6] }).observe(frame);
    } else {
      inView = true;
      arm();
    }

    say('Click the frame, then try j k RET TAB ] z B i ?  (Shift+Tab or Esc leaves)');
    render();
  }

  function init() {
    initCommands();
    initTabs();
    initDemo();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
