/* CASC Cut Times – tablet app. Plain JavaScript, no build step. */
(() => {
  'use strict';

  const $app = document.getElementById('app');
  const LS = { token: 'cct.token', exp: 'cct.exp', op: 'cct.operator', ops: 'cct.operators' };
  const PAGE = 60;

  const state = {
    view: 'pin',
    pin: '',
    pinMsg: '',
    operators: [],
    operator: null,
    data: null,          // /api/programs response
    tab: 'needs',
    machine: 'all',
    query: '',
    shown: PAGE,
    detail: null,        // { program, submission }
    entry: null,         // time-entry form state
    confirm: false,
    sending: false,
    saved: null,         // result after submit
  };

  /* ------------------------------------------------------------ helpers */

  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const ls = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } },
    del(k) { try { localStorage.removeItem(k); } catch { /* ignore */ } },
  };
  const initials = (name) => name.split(/\s+/).filter(Boolean).map((p) => p[0]).slice(0, 2).join('').toUpperCase();
  const hms = (sec) => {
    const s = Math.round(Number(sec) || 0);
    return `${Math.floor(s / 3600)}:${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
  };
  const minsOf = (sec) => Math.round((Number(sec) || 0) / 60);
  const dm = (iso) => { const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(iso || ''); return m ? `${m[3]}/${m[2]} ${m[4]}:${m[5]}` : ''; };
  const dmy = (iso) => { const m = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?/.exec(iso || ''); return m ? `${m[3]}/${m[2]}/${m[1]}${m[4] ? ` ${m[4]}:${m[5]}` : ''}` : ''; };
  const hm = (iso) => { const m = /T(\d{2}):(\d{2})/.exec(iso || ''); return m ? `${m[1]}:${m[2]}` : ''; };
  const todayUk = () => { const d = new Date(); return `${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}/${d.getFullYear()}`; };
  const todayIso = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
  const parseTime = (s) => { const m = /^(\d{1,2}):(\d{2})$/.exec(String(s || '')); if (!m) return null; const h = +m[1]; const mi = +m[2]; return h > 23 || mi > 59 ? null : h * 60 + mi; };
  const parseDate = (s) => {
    const m = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(String(s || ''));
    if (!m) return null;
    const d = new Date(+m[3], +m[2] - 1, +m[1]);
    if (d.getDate() !== +m[1] || d.getMonth() !== +m[2] - 1) return null;
    return `${m[3]}-${m[2]}-${m[1]}`;
  };
  const machineChip = (m) => `<span class="laser ${m === '3030' ? 'dark' : ''}">${esc(m)}</span>`;
  const statusPill = (entry) => {
    if (!entry) return '<span class="status todo">Needs times</span>';
    const map = { pending: ['pending', 'Waiting'], synced: ['synced', 'In SharePoint'], failed: ['failed', 'Not sent'] };
    const [c, t] = map[entry.status] || map.pending;
    return `<span class="status ${c}">${t}</span>`;
  };
  const icon = {
    back: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 6l-6 6 6 6"/></svg>',
    search: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#56687a" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/></svg>',
    tick: '<svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
    cross: '<svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  };

  let toastTimer = null;
  function toast(text) {
    let t = document.querySelector('.toast');
    if (!t) { t = document.createElement('div'); t.className = 'toast'; t.setAttribute('role', 'status'); document.body.appendChild(t); }
    t.textContent = text;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.remove(), 4000);
  }

  /* ---------------------------------------------------------------- API */

  function token() {
    const t = ls.get(LS.token);
    const exp = Number(ls.get(LS.exp) || 0);
    return t && exp > Date.now() ? t : null;
  }

  async function api(path, opts = {}) {
    const res = await fetch(path, {
      method: opts.method || 'GET',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token() || ''}` },
      body: opts.body ? JSON.stringify(opts.body) : undefined,
    });
    let data = null;
    try { data = await res.json(); } catch { /* not json */ }
    if (res.status === 401 && path !== '/api/login') { logout(); throw new Error('Please enter the site PIN again.'); }
    if (!res.ok || !data?.ok) throw Object.assign(new Error(data?.error || `Something went wrong (${res.status}).`), { status: res.status });
    return data;
  }

  function logout() {
    ls.del(LS.token); ls.del(LS.exp);
    state.view = 'pin'; state.pin = ''; state.data = null;
    render();
  }

  /* ------------------------------------------------------------- render */

  function topbar(title, { back = false, sync = false } = {}) {
    const d = state.data;
    let syncHtml = '';
    if (sync && d) {
      const at = d.waitingUpdatedAt;
      const age = at ? (Date.now() - new Date(at).getTime()) / 60e3 : Infinity;
      const stale = !at || age > 10;
      syncHtml = `<span class="sync ${stale ? 'stale' : ''}"><i></i>${at ? `${stale ? 'List not updated since' : 'List updated'} ${esc(stale ? dm(at) : hm(at))}` : 'List never updated'}</span>`;
    }
    return `<header class="bar">
      <div class="left">
        ${back ? `<button class="back" data-act="back">${icon.back}Programs</button>` : ''}
        <img src="/logo-white.png" alt="CASC Engineering">
        ${title ? `<h1>${esc(title)}</h1>` : ''}
      </div>
      <div class="right">
        ${syncHtml}
        ${state.operator ? `<span class="who"><span class="avatar">${esc(initials(state.operator))}</span><b>${esc(state.operator)}</b><button class="pill-btn" data-act="switch">Switch</button></span>` : ''}
      </div>
    </header>`;
  }

  function viewPin() {
    const dots = Math.max(4, state.pin.length);
    return `<div class="pin">
      <section class="intro">
        <img src="/logo-white.png" alt="CASC Engineering">
        <div><p class="eyebrow">Laser cut times</p><h2>Record cut times<br>for every nest.</h2>
        <p>Programs come straight from SigmaNEST. Type the start and end times and they go to the master sheet on SharePoint.</p></div>
        <p class="eyebrow" style="color:#8fa3b8;letter-spacing:0;text-transform:none">CASC Engineering</p>
      </section>
      <section class="pad-wrap">
        <div><h3>Enter site PIN</h3><p class="hint">Ask your supervisor if you don't know it.</p></div>
        <div class="dots" aria-label="${state.pin.length} digits entered">${Array.from({ length: dots }, (_, i) => `<span class="${i < state.pin.length ? 'on' : ''}"></span>`).join('')}</div>
        <div class="pad">
          ${[1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => `<button data-act="digit" data-d="${n}">${n}</button>`).join('')}
          <button class="clear" data-act="clear">Clear</button>
          <button data-act="digit" data-d="0">0</button>
          <button class="go" data-act="pin-go">Enter</button>
        </div>
        <p class="msg-bad" role="alert">${esc(state.pinMsg)}</p>
      </section>
    </div>`;
  }

  function viewOperator() {
    return `<div class="screen">
      <header class="bar"><div class="left"><img src="/logo-white.png" alt="CASC Engineering"></div><div class="right"><span class="sync" style="color:#b8c7d6">Laser cut times</span></div></header>
      <main class="ops-main">
        <div><h2>Who's cutting?</h2><p>Tap your name. It goes on every time you submit.</p></div>
        <div class="ops">${state.operators.map((o) => {
          const [first, ...rest] = o.split(' ');
          return `<button class="op" data-act="pick-op" data-op="${esc(o)}"><span class="avatar">${esc(initials(o))}</span><span style="display:flex;flex-direction:column;align-items:center;gap:2px"><b>${esc(first)}</b><span>${esc(rest.join(' '))}</span></span></button>`;
        }).join('') || '<p>No operators are set up. Add them to OPERATORS in Netlify.</p>'}</div>
        <button class="link-btn" data-act="lock">Lock tablet</button>
      </main>
    </div>`;
  }

  function filtered() {
    const d = state.data;
    if (!d) return { rows: [], counts: { needs: 0, done: 0, all: 0 }, machines: [] };
    const q = state.query.trim().toLowerCase();
    const machines = [...new Set(d.programs.map((p) => p.machine))].sort();
    const base = d.programs.filter((p) => (state.machine === 'all' || p.machine === state.machine)
      && (!q || p.no.toLowerCase().includes(q) || p.lines.some((l) => l.jn.toLowerCase().includes(q) || l.customer.toLowerCase().includes(q))));
    const counts = { needs: base.filter((p) => !p.entry).length, done: base.filter((p) => p.entry).length, all: base.length };
    let rows = state.tab === 'needs' ? base.filter((p) => !p.entry) : state.tab === 'done' ? base.filter((p) => p.entry) : base;
    const key = (p) => (state.tab === 'done' ? p.entry?.at : p.posted) || '';
    rows = rows.slice().sort((a, b) => key(b).localeCompare(key(a)) || b.no.localeCompare(a.no));
    return { rows, counts, machines };
  }

  function viewList() {
    if (!state.data) return `<div class="screen">${topbar('Programs')}<div class="loading">Loading programs…</div></div>`;
    const { rows, counts, machines } = filtered();
    const show = rows.slice(0, state.shown);
    const tab = (id, label) => `<button role="tab" aria-selected="${state.tab === id}" data-act="tab" data-tab="${id}">${label}<span class="n">${counts[id]}</span></button>`;
    const chip = (id, label) => `<button aria-pressed="${state.machine === id}" data-act="machine" data-m="${esc(id)}">${esc(label)}</button>`;
    return `<div class="screen">
      ${topbar('Programs', { sync: true })}
      <div class="tools">
        <div class="group">
          <div class="seg" role="tablist" aria-label="Status">${tab('needs', 'Needs times')}${tab('done', 'Done')}${tab('all', 'All')}</div>
          <div class="chips" aria-label="Laser">${chip('all', machines.length > 1 ? 'Both lasers' : 'All')}${machines.map((m) => chip(m, m)).join('')}</div>
        </div>
        <label class="search">${icon.search}<input id="q" type="search" placeholder="Search program, JN or customer" aria-label="Search program, JN or customer" value="${esc(state.query)}" autocomplete="off"></label>
      </div>
      <div class="list">
        <div class="cols"><span>Program</span><span>Laser</span><span>Material</span><span>Sheet</span><span>Planned</span><span>Posted</span><span>Customer · JN</span><span>${state.tab === 'needs' ? '' : 'Status'}</span></div>
        ${show.map(rowHtml).join('') || `<div class="empty">${state.query ? 'No programs match that search.' : state.tab === 'needs' ? 'Every program has its times. Nice work.' : 'Nothing here yet.'}</div>`}
        ${rows.length > show.length ? `<button class="more" data-act="more">Show ${Math.min(PAGE, rows.length - show.length)} more</button>` : ''}
      </div>
      <div class="foot"><span>${state.tab === 'done' ? 'Most recent first' : 'Newest first'} · programs since ${esc(dmy(state.data.startDate))}</span><span>Showing ${show.length} of ${rows.length}</span></div>
    </div>`;
  }

  function rowHtml(p) {
    const lines = p.lines.slice(0, 2).map((l) => `<span><b>${esc(l.customer)}</b><em>${esc(l.jn)}</em></span>`).join('');
    const more = p.lines.length > 2 ? `<span><em>+${p.lines.length - 2} more</em></span>` : '';
    const mat = [p.material, p.thickness !== null && p.thickness !== undefined ? `${p.thickness}mm` : ''].filter(Boolean).join(' · ');
    const right = p.entry
      ? `<span style="display:flex;flex-direction:column;gap:4px;align-items:flex-start">${statusPill(p.entry)}<span class="sub">${esc(p.entry.operator.split(' ')[0])} · ${esc(dm(p.entry.at))}</span></span>`
      : (state.tab === 'all' ? statusPill(null) : '<span></span>');
    return `<button class="row" data-act="open" data-no="${esc(p.no)}">
      <span class="prog">${esc(p.no)}</span>
      ${machineChip(p.machine)}
      <span class="mat">${esc(mat)}</span>
      <span class="mono" style="font-size:14px;color:#3b4f63;overflow:hidden;text-overflow:ellipsis">${esc(p.sheet)}</span>
      <span><span class="mono">${hms(p.plannedSec)}</span>${p.sheets > 1 ? `<span class="sub rep">× ${p.sheets} sheets</span>` : ''}</span>
      <span><span class="mono" style="font-size:14px;color:#3b4f63">${esc(dm(p.posted))}</span>${p.sigma === 'cleared' ? '<span class="sub">Cleared in Sigma</span>' : ''}</span>
      <span class="cust">${lines}${more}</span>
      ${right}
    </button>`;
  }

  function viewDetail() {
    if (!state.detail) return `<div class="screen">${topbar('', { back: true })}<div class="loading">Loading program…</div></div>`;
    const { program: p, submission: s } = state.detail;
    const total = p.plannedSec * (p.sheets || 1);
    const facts = [
      ['Material', p.material || '—'],
      ['Thickness', p.thickness !== null && p.thickness !== undefined ? `${p.thickness}mm` : '—'],
      ['Sheet', p.sheet || '—'],
      ['Size', p.sheetL && p.sheetW ? `${Math.round(p.sheetL)} × ${Math.round(p.sheetW)}` : '—'],
      ['Planned', p.sheets > 1 ? `${hms(total)}` : hms(p.plannedSec)],
      [p.sheets > 1 ? 'Sheets' : 'Scrap', p.sheets > 1 ? `${p.sheets} × ${hms(p.plannedSec)}` : (p.scrapPct !== null && p.scrapPct !== undefined ? `${p.scrapPct}%` : '—')],
    ];
    return `<div class="screen">
      ${topbar('', { back: true })}
      <div class="detail">
        <section class="card report">
          <div class="head">
            <div><div class="k">Program no.</div><div class="big">${esc(p.no)}</div></div>
            <div class="meta"><b>${esc(p.machine.replace(/_/g, ' '))}</b><span class="mono">Posted ${esc(dmy(p.posted))}</span>
              ${p.sigma === 'cleared' ? `<span class="tag">Cleared in SigmaNEST ${esc(dm(p.completed))}</span>` : '<span class="tag">Waiting in SigmaNEST</span>'}</div>
          </div>
          <div class="facts">${facts.map(([k, v]) => `<div><span class="k">${esc(k)}</span><b>${esc(v)}</b></div>`).join('')}</div>
          <div class="parts"><table>
            <thead><tr><th>Part name</th><th class="num">Nest qty</th><th>Next op</th><th>W/O</th><th>Customer</th></tr></thead>
            <tbody>${p.parts.map((x) => `<tr><td class="code">${esc(x.part)}</td><td class="num">${esc(x.qty)}</td><td>${esc(x.op)}</td><td class="code">${esc(x.wo)}</td><td>${esc(x.customer)}</td></tr>`).join('') || '<tr><td colspan="5">No parts recorded for this program.</td></tr>'}</tbody>
          </table></div>
        </section>
        <aside class="card entry">${s ? submittedHtml(p, s) : entryHtml(p)}</aside>
      </div>
      ${state.confirm ? confirmHtml(p) : ''}
    </div>`;
  }

  function submittedHtml(p, s) {
    return `<h2>Times submitted</h2>
      <div class="done-box">
        <div class="row2"><span>Status</span>${statusPill({ status: s.status })}</div>
        <div class="row2"><span>Operator</span><b>${esc(s.operator)}</b></div>
        <div class="row2"><span>Cut date</span><b class="mono">${esc(dmy(s.date))}</b></div>
        <div class="row2"><span>Entered</span><b class="mono">${esc(dmy(s.enteredAt))}</b></div>
        <div class="row2"><span>Entry</span><b>${s.mode === 'split' ? 'Split by customer' : 'Whole program'}</b></div>
      </div>
      <div class="lines">${s.rows.map((r) => `<div class="ln"><span><b>${esc(r.Customer)}</b> <em>${esc(r.JN)}</em></span><em>${r.Start ? `${esc(r.Start)}–${esc(r.End)} · ${esc(r.Minutes)} min` : ''}</em></div>`).join('')}</div>
      <div class="total"><span>Total <b>${esc(s.totalMinutes)} min</b></span><span>Planned ${minsOf(p.plannedSec * (p.sheets || 1))} min</span></div>
      ${s.status === 'failed' ? `<p class="err">Not in the master sheet yet${s.message ? `: ${esc(s.message)}` : ''}. Dhanush has been emailed.</p>` : ''}
      <p class="small">Submitted programs are locked. Ask your supervisor if something is wrong.</p>`;
  }

  function newEntry(p) {
    return {
      no: p.no,
      mode: 'whole',
      date: todayUk(),
      whole: { start: '', end: '' },
      lines: Object.fromEntries(p.lines.map((l) => [l.jn, { start: '', end: '' }])),
      errors: {},
      msg: '',
    };
  }

  function entryMinutes(p, e) {
    if (e.mode === 'whole') {
      const s = parseTime(e.whole.start); const en = parseTime(e.whole.end);
      return s !== null && en !== null && en > s ? en - s : null;
    }
    let sum = 0;
    for (const l of p.lines) {
      const s = parseTime(e.lines[l.jn].start); const en = parseTime(e.lines[l.jn].end);
      if (s === null || en === null || en <= s) return null;
      sum += en - s;
    }
    return sum;
  }

  function entryHtml(p) {
    const e = state.entry;
    const planned = minsOf(p.plannedSec * (p.sheets || 1));
    const total = entryMinutes(p, e);
    const bad = (k) => (e.errors[k] ? ' bad' : '');
    const timeInput = (key, val, label) => `<input class="tin${bad(key)}" data-time="${esc(key)}" value="${esc(val)}" inputmode="numeric" maxlength="5" placeholder="--:--" aria-label="${esc(label)}" autocomplete="off">`;
    const canSplit = p.lines.length > 1;
    const body = e.mode === 'whole'
      ? `<div class="fields">
          <label class="field">Date<input class="tin date${bad('date')}" data-date value="${esc(e.date)}" inputmode="numeric" maxlength="10" placeholder="DD/MM/YYYY" autocomplete="off"></label>
          <label class="field">Start${timeInput('whole.start', e.whole.start, 'Start time')}</label>
          <label class="field">End${timeInput('whole.end', e.whole.end, 'End time')}</label>
        </div>
        <div class="total"><span><b>${total === null ? '–' : `${total} min`}</b> cut</span><span>Planned ${planned} min</span></div>
        <div class="lines"><span class="k" style="margin-bottom:4px">On this program</span>${p.lines.map((l) => `<div class="ln"><b>${esc(l.customer)}</b><em>${esc(l.jn)}</em></div>`).join('')}</div>`
      : `<label class="datefield">Date<input class="tin date${bad('date')}" data-date value="${esc(e.date)}" inputmode="numeric" maxlength="10" placeholder="DD/MM/YYYY" autocomplete="off"></label>
        <div class="split-head"><span>Customer · JN</span><span style="text-align:center">Start</span><span style="text-align:center">End</span><span style="text-align:right">Min</span></div>
        <div class="split-list">${p.lines.map((l) => {
          const v = e.lines[l.jn];
          const s = parseTime(v.start); const en = parseTime(v.end);
          const m = s !== null && en !== null && en > s ? en - s : '';
          return `<div class="split-row">
            <span class="who-line"><b>${esc(l.customer)}</b><em>${esc(l.jn)}</em><small>Planned ${minsOf(l.plannedSec * (p.sheets || 1))} min</small></span>
            ${timeInput(`line.${l.jn}.start`, v.start, `${l.customer} ${l.jn} start`)}
            ${timeInput(`line.${l.jn}.end`, v.end, `${l.customer} ${l.jn} end`)}
            <span class="m">${m}</span></div>`;
        }).join('')}</div>
        <div class="total"><span>Total <b>${total === null ? '–' : `${total} min`}</b></span><span>Planned ${planned} min</span></div>`;
    return `<h2>Cut times</h2>
      ${canSplit ? `<div class="tabs2" role="tablist" aria-label="Time entry">
        <button role="tab" aria-selected="${e.mode === 'whole'}" data-act="mode" data-mode="whole">Whole program</button>
        <button role="tab" aria-selected="${e.mode === 'split'}" data-act="mode" data-mode="split">Split by customer</button></div>` : ''}
      ${body}
      <p class="err" role="alert">${esc(e.msg)}</p>
      <div style="display:flex;flex-direction:column;gap:8px">
        <button class="primary" data-act="review">Submit times</button>
        <p class="small">${e.mode === 'split' ? 'Each line gets its own row in the master sheet.' : "You'll check everything before it's sent."}</p>
      </div>`;
  }

  function confirmHtml(p) {
    const e = state.entry;
    const planned = minsOf(p.plannedSec * (p.sheets || 1));
    const total = entryMinutes(p, e);
    const rows = e.mode === 'whole'
      ? p.lines.map((l, i) => [l.customer, l.jn, i === 0 ? `${e.whole.start} – ${e.whole.end}` : '', i === 0 ? total : ''])
      : p.lines.map((l) => { const v = e.lines[l.jn]; return [l.customer, l.jn, `${v.start} – ${v.end}`, parseTime(v.end) - parseTime(v.start)]; });
    let warn = '';
    if (planned > 0 && total !== null) {
      if (total < planned / 2) warn = `This is much shorter than planned (${planned} min). Check the times before submitting.`;
      else if (total > planned * 2) warn = `This is much longer than planned (${planned} min). Check the times before submitting.`;
    }
    return `<div class="veil" role="dialog" aria-modal="true" aria-labelledby="ct">
      <div class="modal">
        <div class="top"><h2 id="ct">Submit times for ${esc(p.no)}?</h2><p>Check everything below. Once submitted, this program is locked and can't be changed.</p></div>
        <div class="facts4">
          <div><span class="k">Operator</span><b>${esc(state.operator)}</b></div>
          <div><span class="k">Date</span><b class="mono">${esc(e.date)}</b></div>
          <div><span class="k">Laser</span><b>${esc(p.machineShort)}</b></div>
          <div><span class="k">Entry</span><b>${e.mode === 'split' ? 'Split by customer' : 'Whole program'}</b></div>
        </div>
        <table><thead><tr><th>Customer</th><th>JN</th><th>Time</th><th style="text-align:right">Min</th></tr></thead>
          <tbody>${rows.map((r) => `<tr><td><b>${esc(r[0])}</b></td><td class="mono" style="font-size:14px">${esc(r[1])}</td><td class="mono">${esc(r[2])}</td><td class="mono" style="text-align:right">${esc(r[3])}</td></tr>`).join('')}</tbody></table>
        <div class="sum"><span>Total <b class="mono">${total} min</b></span><span style="color:#3b4f63">Planned ${planned} min</span></div>
        ${warn ? `<div class="warn">${esc(warn)}</div>` : ''}
        <div class="acts">
          <button class="secondary" data-act="cancel-confirm" ${state.sending ? 'disabled' : ''}>Go back and edit</button>
          <button class="primary" data-act="submit" ${state.sending ? 'disabled' : ''}>${state.sending ? 'Saving…' : 'Yes, submit'}</button>
        </div>
      </div>
    </div>`;
  }

  function viewSaved() {
    const r = state.saved;
    const failed = r.status === 'failed';
    const synced = r.status === 'synced';
    const today = todayIso();
    const mine = (state.data?.programs || [])
      .filter((p) => p.entry && p.entry.operator === state.operator && (p.entry.at || '').startsWith(today))
      .sort((a, b) => (b.entry.at || '').localeCompare(a.entry.at || ''))
      .slice(0, 6);
    return `<div class="screen">
      ${topbar('')}
      <main class="saved">
        <section class="card main">
          <div style="display:flex;align-items:center;gap:20px">
            <span class="tick ${failed ? 'bad' : ''}">${failed ? icon.cross : icon.tick}</span>
            <div><h2>${failed ? 'Saved, not sent yet' : 'Times saved'}</h2><p class="lead">Program ${esc(r.no)} · ${r.lines} line${r.lines > 1 ? 's' : ''} · ${r.total} min · ${esc(r.date)}</p></div>
          </div>
          <ol class="steps">
            <li><span class="dot done"></span><span><b>Saved</b><span>Your times are stored safely and this program is now locked.</span></span></li>
            <li><span class="dot ${failed ? 'bad' : synced ? 'done' : 'now'}"></span><span><b>${failed ? 'Couldn’t reach the master sheet' : 'Sending to the master sheet'}</b><span>${failed ? 'Dhanush has been emailed and will sort it out.' : 'Usually takes a few seconds.'}</span></span></li>
            <li><span class="dot ${synced ? 'done' : ''}"></span><span><b>In SharePoint</b><span>${synced ? 'Confirmed by the master sheet.' : 'Shows here once the master sheet confirms.'}</span></span></li>
          </ol>
          <p style="margin:0;color:#3b4f63">You can carry on. If the master sheet doesn't confirm within 30 minutes, Dhanush gets an email.</p>
          <button class="navy-btn" data-act="next" style="margin-top:auto">Next program</button>
        </section>
        <section class="recent">
          <h3>Your submissions today</h3>
          ${mine.map((p) => `<div class="item"><b>${esc(p.no)}</b><span style="min-width:0"><span style="font-weight:600">${esc([...new Set(p.lines.map((l) => l.customer))].join(', '))}</span><small>${esc(p.entry.minutes)} min · entered ${esc(hm(p.entry.at))}</small></span>${statusPill(p.entry)}</div>`).join('') || '<p style="color:#56687a">Nothing else yet today.</p>'}
        </section>
      </main>
    </div>`;
  }

  function render() {
    const focus = document.activeElement;
    const focusKey = focus?.dataset?.time || (focus?.hasAttribute?.('data-date') ? '__date' : focus?.id);
    const caret = focus?.selectionStart;
    const html = { pin: viewPin, operator: viewOperator, list: viewList, detail: viewDetail, saved: viewSaved }[state.view]();
    $app.innerHTML = html;
    if (focusKey) {
      const el = focusKey === '__date' ? $app.querySelector('[data-date]') : $app.querySelector(`[data-time="${CSS.escape(focusKey)}"]`) || document.getElementById(focusKey);
      if (el) { el.focus(); try { el.setSelectionRange(caret, caret); } catch { /* not a text field */ } }
    }
  }

  /* ------------------------------------------------------------ actions */

  async function loadPrograms(quiet = false) {
    try {
      const d = await api('/api/programs');
      state.data = d;
      if (d.operators?.length) { state.operators = d.operators; ls.set(LS.ops, JSON.stringify(d.operators)); }
      if (['list', 'saved'].includes(state.view)) render();
    } catch (e) {
      if (!quiet) toast(e.message);
    }
  }

  async function openProgram(no) {
    state.view = 'detail'; state.detail = null; state.confirm = false; render();
    try {
      const d = await api(`/api/program?no=${encodeURIComponent(no)}`);
      state.detail = d;
      state.entry = newEntry(d.program);
      render();
      window.scrollTo(0, 0);
    } catch (e) {
      toast(e.message); state.view = 'list'; render();
    }
  }

  function validate() {
    const p = state.detail.program;
    const e = state.entry;
    e.errors = {}; e.msg = '';
    const iso = parseDate(e.date);
    if (!iso) { e.errors.date = 1; e.msg = 'Type the date as DD/MM/YYYY.'; return false; }
    if (iso > todayIso()) { e.errors.date = 1; e.msg = "The cut date can't be in the future."; return false; }
    const check = (start, end, keyS, keyE, label) => {
      const s = parseTime(start); const en = parseTime(end);
      if (s === null) { e.errors[keyS] = 1; e.msg = `${label}: type the start time as HH:MM.`; return false; }
      if (en === null) { e.errors[keyE] = 1; e.msg = `${label}: type the end time as HH:MM.`; return false; }
      if (en <= s) { e.errors[keyE] = 1; e.msg = `${label}: the end time must be after the start time.`; return false; }
      return true;
    };
    if (e.mode === 'whole') return check(e.whole.start, e.whole.end, 'whole.start', 'whole.end', 'Whole program');
    for (const l of p.lines) {
      const v = e.lines[l.jn];
      if (!check(v.start, v.end, `line.${l.jn}.start`, `line.${l.jn}.end`, `${l.customer} ${l.jn}`)) return false;
    }
    return true;
  }

  async function submit() {
    const p = state.detail.program;
    const e = state.entry;
    state.sending = true; render();
    try {
      const r = await api('/api/submit', {
        method: 'POST',
        body: {
          no: p.no, operator: state.operator, date: e.date, mode: e.mode,
          whole: e.whole,
          lines: p.lines.map((l) => ({ jn: l.jn, ...e.lines[l.jn] })),
        },
      });
      state.saved = { no: p.no, status: r.status, lines: p.lines.length, total: entryMinutes(p, e), date: e.date };
      state.sending = false; state.confirm = false; state.view = 'saved';
      render();
      await loadPrograms(true);
      pollSaved(p.no, 0);
    } catch (err) {
      state.sending = false; state.confirm = false;
      e.msg = err.message;
      render();
    }
  }

  function pollSaved(no, n) {
    if (state.view !== 'saved' || state.saved?.no !== no || state.saved.status !== 'pending' || n > 12) return;
    setTimeout(async () => {
      await loadPrograms(true);
      const p = state.data?.programs.find((x) => x.no === no);
      if (p?.entry && state.saved?.no === no) { state.saved.status = p.entry.status; if (state.view === 'saved') render(); }
      pollSaved(no, n + 1);
    }, 5000);
  }

  function goList() {
    state.view = 'list'; state.detail = null; state.confirm = false; render();
    loadPrograms(true);
  }

  $app.addEventListener('click', async (ev) => {
    const b = ev.target.closest('[data-act]');
    if (!b) return;
    const act = b.dataset.act;
    if (act === 'digit') { if (state.pin.length < 12) state.pin += b.dataset.d; state.pinMsg = ''; render(); }
    else if (act === 'clear') { state.pin = ''; state.pinMsg = ''; render(); }
    else if (act === 'pin-go') {
      if (!state.pin) return;
      try {
        const r = await api('/api/login', { method: 'POST', body: { pin: state.pin } });
        ls.set(LS.token, r.token); ls.set(LS.exp, String(r.expiresAt));
        state.operators = r.operators || []; ls.set(LS.ops, JSON.stringify(state.operators));
        state.pin = ''; state.view = 'operator'; render();
      } catch (e) { state.pin = ''; state.pinMsg = e.message; render(); }
    }
    else if (act === 'pick-op') { state.operator = b.dataset.op; ls.set(LS.op, state.operator); goList(); }
    else if (act === 'lock') logout();
    else if (act === 'switch') { state.view = 'operator'; render(); }
    else if (act === 'tab') { state.tab = b.dataset.tab; state.shown = PAGE; render(); }
    else if (act === 'machine') { state.machine = b.dataset.m; state.shown = PAGE; render(); }
    else if (act === 'more') { state.shown += PAGE; render(); }
    else if (act === 'open') openProgram(b.dataset.no);
    else if (act === 'back') goList();
    else if (act === 'next') { state.query = ''; state.tab = 'needs'; goList(); }
    else if (act === 'mode') { state.entry.mode = b.dataset.mode; state.entry.errors = {}; state.entry.msg = ''; render(); }
    else if (act === 'review') { if (validate()) state.confirm = true; render(); }
    else if (act === 'cancel-confirm') { state.confirm = false; render(); }
    else if (act === 'submit') { if (!state.sending) submit(); }
  });

  // Typed time boxes: digits only, colon added for you (0910 -> 09:10). Date: 10112026 -> 10/11/2026.
  $app.addEventListener('input', (ev) => {
    const el = ev.target;
    if (el.id === 'q') { state.query = el.value; state.shown = PAGE; render(); return; }
    if (el.dataset.time !== undefined) {
      const d = el.value.replace(/\D/g, '').slice(0, 4);
      const v = d.length > 2 ? `${d.slice(0, 2)}:${d.slice(2)}` : d;
      el.value = v;
      const key = el.dataset.time;
      if (key.startsWith('whole.')) state.entry.whole[key.slice(6)] = v;
      else { const m = /^line\.(.*)\.(start|end)$/.exec(key); state.entry.lines[m[1]][m[2]] = v; }
      delete state.entry.errors[key];
      // move to the next box once a full time is typed
      if (d.length === 4) {
        const boxes = [...$app.querySelectorAll('[data-time]')];
        const i = boxes.indexOf(el);
        render();
        const next = $app.querySelectorAll('[data-time]')[i + 1];
        if (next) next.focus();
        return;
      }
      render();
    } else if (el.hasAttribute('data-date')) {
      const d = el.value.replace(/\D/g, '').slice(0, 8);
      el.value = d.length > 4 ? `${d.slice(0, 2)}/${d.slice(2, 4)}/${d.slice(4)}` : d.length > 2 ? `${d.slice(0, 2)}/${d.slice(2)}` : d;
      state.entry.date = el.value;
      delete state.entry.errors.date;
    }
  });

  // Keyboard PIN entry for testing on a PC
  document.addEventListener('keydown', (ev) => {
    if (state.view !== 'pin') return;
    if (/^\d$/.test(ev.key)) { state.pin += ev.key; render(); }
    else if (ev.key === 'Backspace') { state.pin = state.pin.slice(0, -1); render(); }
    else if (ev.key === 'Enter') $app.querySelector('[data-act="pin-go"]')?.click();
  });

  // Keep the list fresh while it's on screen.
  setInterval(() => { if (state.view === 'list' && token() && !document.hidden) loadPrograms(true); }, 60e3);

  /* -------------------------------------------------------------- start */

  if (token()) {
    try { state.operators = JSON.parse(ls.get(LS.ops) || '[]'); } catch { state.operators = []; }
    const op = ls.get(LS.op);
    if (op && state.operators.includes(op)) { state.operator = op; state.view = 'list'; loadPrograms(); }
    else state.view = 'operator';
  }
  render();
})();
